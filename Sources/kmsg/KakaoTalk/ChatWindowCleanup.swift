import AppKit
import ApplicationServices.HIServices
import Foundation

/// Cleanup authority is tied to the original app process and exact AX handle.
/// A failed window query is never evidence that a target has disappeared.
final class ChatWindowCleanup {
    enum Presence: String { case present, absent, unknown }
    enum DraftResult: String {
        case notOwned = "not-owned"
        case notPasted = "not-pasted"
        case targetAbsent = "target-absent"
        case unknown
        case focusUnconfirmed = "focus-unconfirmed"
        case inputMissing = "input-missing"
        case textEmpty = "text-empty"
        case textUnconfirmed = "text-unconfirmed"
    }

    /// Command-local mutation milestones; these never claim delivery or that
    /// an image attachment was removed. A pre-paste user's draft is not ours.
    final class ImageDraftState {
        fileprivate let window: UIElement
        init(window: UIElement) { self.window = window }
        var identityVerified = false
        var clipboardPrepared = false
        var pasteDispatched = false
        fileprivate var pasteInput: UIElement?
        fileprivate var pasteInputWindow: UIElement?
    }

    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner
    private let processID: pid_t?

    init(kakao: KakaoTalkApp, runner: AXActionRunner) {
        self.kakao = kakao
        self.runner = runner
        self.processID = Self.pid(of: kakao.applicationElement)
    }

    func presence(of target: UIElement) -> Presence {
        guard sameProcess(target),
              let windows = Self.elements(kAXWindowsAttribute, of: kakao.applicationElement),
              windows.allSatisfy({ Self.pid(of: $0) == processID }) else { return .unknown }
        return windows.contains { Self.same($0, target) } ? .present : .absent
    }

    /// App AX focus alone can remain stale while another app is frontmost.
    /// Checking immediately before a key narrows this race; HID is not atomic.
    func canSendWindowKey(to target: UIElement) -> Bool {
        guard frontmostIsOriginalProcess(), presence(of: target) == .present,
              let focused = Self.element(kAXFocusedWindowAttribute, of: kakao.applicationElement)
        else { return false }
        if Self.same(focused, target) { return true }
        if case .owned(let sheet) = sheetState(in: target) { return Self.same(focused, sheet) }
        return false
    }

    func canSendInputKey(to input: UIElement, in target: UIElement) -> Bool {
        guard canSendWindowKey(to: target), Self.pid(of: input) == processID,
              let focused = Self.element(kAXFocusedUIElementAttribute, of: kakao.applicationElement),
              Self.same(focused, input),
              let systemFocused = Self.element(kAXFocusedUIElementAttribute, of: UIElement.systemWide()),
              Self.same(systemFocused, input), isChatInput(input, in: target),
              frontmostIsOriginalProcess() else { return false }
        // A positive sheet observation blocks input deletion even if the app's
        // cached focused-input attribute still points at the old composer.
        if let sheets = Self.elements(kAXSheetsAttribute, of: target), !sheets.isEmpty { return false }
        return true
    }

    /// Only positive, direct AXSheets evidence can authorize draft Escape.
    /// No transcript search or guessed modal identity is used here.
    @discardableResult
    func dismissOwnedSheet(in target: UIElement) -> Bool {
        guard case .owned(let sheet) = sheetState(in: target),
              canSendWindowKey(to: target),
              case .owned(let current) = sheetState(in: target), Self.same(sheet, current),
              frontmostIsOriginalProcess() else { return false }
        runner.pressEscapeKey()
        return true // Key dispatched, not proof that the sheet vanished.
    }

    /// Both send commands use the same retry boundary. Never send Escape to
    /// whatever happens to be frontmost after a stale target failed to close.
    func closeWithRetry(
        _ target: UIElement,
        close: (UIElement) -> Bool,
        beforeAttempt: (Int) -> Void = { _ in },
        note: (String, String) -> Void = { _, _ in }
    ) -> Bool {
        for attempt in 1...3 {
            beforeAttempt(attempt)
            if close(target) {
                note("close.attempts", String(attempt))
                return true
            }
            let state = presence(of: target)
            note("close.state", state.rawValue)
            if state == .absent {
                note("close.attempts", String(attempt))
                return true
            }
            guard state == .present, attempt < 3, canSendWindowKey(to: target) else {
                note("close.attempts", String(attempt))
                note("close.escape", "skipped")
                return false
            }
            // Here Escape may dismiss an overlay or close this exact target.
            // The next attempt treats confirmed absence as idempotent success.
            note("close.escape", "target")
            runner.pressEscapeKey()
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    /// Optional command-local witness, captured just before our paste. The
    /// handle never authorizes cleanup without a fresh ownership/focus check.
    func rememberPasteInput(in target: UIElement, state: ImageDraftState) {
        guard state.identityVerified, Self.same(state.window, target),
              let input = Self.element(kAXFocusedUIElementAttribute, of: kakao.applicationElement),
              canSendInputKey(to: input, in: target) else { return }
        state.pasteInput = input
        state.pasteInputWindow = target
    }

    func clearImageDraft(
        in target: UIElement,
        state: ImageDraftState,
        allowWindowClose: Bool,
        profiler: PhaseProfiler
    ) -> DraftResult {
        guard state.identityVerified, Self.same(state.window, target) else { return .notOwned }
        if state.clipboardPrepared {
            profiler.begin("draft_clipboard")
            NSPasteboard.general.clearContents()
        }
        guard state.pasteDispatched else { return .notPasted }
        switch presence(of: target) {
        case .absent: return .targetAbsent
        case .unknown: return .unknown
        case .present: break
        }
        // Prefer the composer witnessed immediately before this command's
        // paste. Do not add a pre-Escape transcript walk when it is unavailable.
        var input: UIElement?
        if let remembered = state.pasteInput, let owner = state.pasteInputWindow,
           Self.same(owner, target), isChatInput(remembered, in: target) {
            input = remembered
        }
        profiler.begin("draft_escape")
        if allowWindowClose {
            guard canSendWindowKey(to: target) else { return .focusUnconfirmed }
            profiler.note("draft.escape", "target")
            runner.pressEscapeKey()
        } else {
            profiler.note("draft.escape", dismissOwnedSheet(in: target) ? "owned-sheet" : "skipped")
        }
        switch presence(of: target) {
        case .absent: return .targetAbsent
        case .unknown: return .unknown
        case .present: break
        }
        profiler.begin("draft_input")
        if let remembered = input, isChatInput(remembered, in: target) {
            profiler.note("draft.inputSource", "before-paste")
        } else {
            // Dismissing a sheet may expose or replace the composer. This is
            // the original bounded post-Escape lookup, with a complete no-sheet
            // ancestor proof so a replacement confirmation caption is refused.
            input = target.findAll(role: kAXTextAreaRole, limit: 4, maxNodes: 200)
                .first { isChatInput($0, in: target) }
            profiler.note("draft.inputSource", input == nil ? "none" : "after-escape")
        }
        guard let input else {
            profiler.note("draft.input", "0")
            return .inputMissing
        }
        profiler.note("draft.input", "1")
        profiler.begin("draft_clear")
        do { try input.focus() } catch { return .focusUnconfirmed }
        Thread.sleep(forTimeInterval: 0.1)
        guard canSendInputKey(to: input, in: target) else { return .focusUnconfirmed }
        runner.pressCommandA()
        guard canSendInputKey(to: input, in: target) else { return .focusUnconfirmed }
        runner.pressDeleteKey()
        // Exact successful String emptiness is text-only evidence. It says
        // nothing about attachment/render state or whether a photo was sent.
        return Self.string(kAXValueAttribute, of: input) == "" ? .textEmpty : .textUnconfirmed
    }

    /// Require a complete bounded ancestor chain to the exact target with
    /// no sheet anywhere on it. Direct AXWindow equality alone also matches a
    /// confirmation caption, so it cannot identify the chat composer.
    private func isChatInput(_ input: UIElement, in target: UIElement) -> Bool {
        guard Self.pid(of: input) == processID,
              Self.string(kAXRoleAttribute, of: input) == kAXTextAreaRole else { return false }
        var cursor = input
        for _ in 0..<12 {
            guard let parent = Self.element(kAXParentAttribute, of: cursor), Self.pid(of: parent) == processID else { return false }
            if Self.same(parent, target) { return true }
            guard let role = Self.string(kAXRoleAttribute, of: parent), role != kAXSheetRole,
                  !Self.same(parent, cursor) else { return false }
            cursor = parent
        }
        return false
    }

    private enum SheetState { case none, owned(UIElement), unknown }

    private func sheetState(in target: UIElement) -> SheetState {
        guard sameProcess(target), let sheets = Self.elements(kAXSheetsAttribute, of: target) else { return .unknown }
        if sheets.isEmpty { return .none }
        guard sheets.count == 1, let sheet = sheets.first,
              Self.pid(of: sheet) == processID,
              Self.string(kAXRoleAttribute, of: sheet) == kAXSheetRole,
              belongs(sheet, to: target) else { return .unknown }
        return .owned(sheet)
    }

    private func sameProcess(_ target: UIElement) -> Bool {
        guard let processID,
              KakaoTalkApp.runningApplication?.processIdentifier == processID,
              Self.pid(of: kakao.applicationElement) == processID,
              Self.pid(of: target) == processID else { return false }
        return true
    }

    private func frontmostIsOriginalProcess() -> Bool {
        guard let processID else { return false }
        return KakaoTalkApp.runningApplication?.processIdentifier == processID &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    }

    /// Parent fallback is bounded ancestry, never a subtree traversal.
    private func belongs(_ element: UIElement, to target: UIElement) -> Bool {
        if let owner = Self.element(kAXWindowAttribute, of: element), Self.same(owner, target) { return true }
        var cursor = element
        for _ in 0..<8 {
            guard let parent = Self.element(kAXParentAttribute, of: cursor), Self.pid(of: parent) == processID else { return false }
            if Self.same(parent, target) { return true }
            if Self.same(parent, cursor) { return false }
            cursor = parent
        }
        return false
    }

    private static func same(_ a: UIElement, _ b: UIElement) -> Bool { CFEqual(a.axElement, b.axElement) }

    private static func pid(of element: UIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element.axElement, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    private static func raw(_ attribute: String, of element: UIElement) -> CFTypeRef? {
        // UIElement.attribute preserves AX failure before the typed decode.
        try? element.attribute(attribute)
    }

    private static func elements(_ attribute: String, of element: UIElement) -> [UIElement]? {
        guard let value = raw(attribute, of: element), CFGetTypeID(value) == CFArrayGetTypeID(),
              let values = value as? [AnyObject], values.count <= 1024 else { return nil }
        var result: [UIElement] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            result.append(UIElement(unsafeDowncast(value, to: AXUIElement.self)))
        }
        return result
    }

    private static func element(_ attribute: String, of element: UIElement) -> UIElement? {
        guard let value = raw(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return UIElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    private static func string(_ attribute: String, of element: UIElement) -> String? {
        guard let value = raw(attribute, of: element), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }
}
