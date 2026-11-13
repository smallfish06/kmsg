import AppKit
import ApplicationServices.HIServices
import Foundation

/// Switches for exercising typing paths a healthy KakaoTalk never reaches
/// (AXValue normally fills the composer; focus normally lands where asked).
/// Compiled out of release builds. `KMSG_DEBUG_TYPING=<name>`:
///   forced       send: treat the composer as not found (blind typing path)
///   typed-draft  send: type instead of setting AXValue, then clear the draft
///                and stop before Enter — nothing is sent
enum DebugTypingHook {
    static func isOn(_ name: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KMSG_DEBUG_TYPING"] == name
        #else
        return false
        #endif
    }
}

/// Where a run of character keys is meant to land.
enum TypingTarget {
    /// This exact element must hold keyboard focus.
    case element(UIElement)
    /// No handle on the target: whatever holds focus must be a text input.
    case focusedTextInput
}

/// One per runner, shared by its copies (the struct is passed by value into
/// resolvers and automations), so a refusal anywhere reaches the summary line.
final class TypingBlockReporter {
    private var sink: ((String) -> Void)?
    private var reported: Set<String> = []

    func install(_ sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    /// Each distinct token is reported once per run; retries repeat it.
    func report(_ token: String) {
        guard reported.insert(token).inserted else { return }
        if let sink {
            sink(token)
        } else {
            // Commands without a summary line still must not refuse silently.
            FileHandle.standardError.write(Data("[kmsg] type.blocked=\(token)\n".utf8))
        }
    }
}

struct AXActionRunner {
    typealias TraceWriter = (String) -> Void

    private let traceEnabled: Bool
    private let traceWriter: TraceWriter
    private let typingBlocks = TypingBlockReporter()

    init(traceEnabled: Bool) {
        self.traceEnabled = traceEnabled
        // Monotonic elapsed time since runner creation so trace lines double as
        // a lightweight profile of where a command spends its wall clock.
        let start = DispatchTime.now()
        self.traceWriter = { message in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            guard let data = String(format: "[trace-ax] [+%8.3fs] %@\n", elapsed, message).data(using: .utf8) else { return }
            FileHandle.standardError.write(data)
        }
    }

    func log(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        traceWriter(message())
    }

    @discardableResult
    func waitUntil(
        label: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        evaluateAfterTimeout: Bool = true,
        condition: () -> Bool
    ) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() {
                log("\(label): ready")
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let elapsed = Date().timeIntervalSince(start)
        log("\(label): timeout after \(String(format: "%.2f", elapsed))s")
        return evaluateAfterTimeout ? condition() : false
    }

    @discardableResult
    func focusWithVerification(
        _ element: UIElement,
        label: String,
        attempts: Int = 3,
        retryDelay: TimeInterval = 0.08
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            do {
                try element.focus()
            } catch {
                log("\(label): focus attempt \(attempt) failed (\(error))")
            }

            if element.isFocused || waitUntil(label: "\(label) focused", timeout: 0.25, condition: {
                element.isFocused
            }) {
                log("\(label): focused on attempt \(attempt)")
                return true
            }

            do {
                try element.press()
            } catch {
                log("\(label): press fallback \(attempt) failed (\(error))")
            }

            if element.isFocused || waitUntil(label: "\(label) focused", timeout: 0.25, condition: {
                element.isFocused
            }) {
                log("\(label): focused by press fallback on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): focus verification failed")
        return false
    }

    @discardableResult
    func setTextWithVerification(
        _ text: String,
        on element: UIElement,
        label: String,
        attempts: Int = 2,
        retryDelay: TimeInterval = 0.08
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            do {
                try element.setAttribute(kAXValueAttribute, value: text as CFString)
            } catch {
                log("\(label): set AXValue attempt \(attempt) failed (\(error))")
                Thread.sleep(forTimeInterval: retryDelay)
                continue
            }

            let reflected = waitUntil(label: "\(label) AXValue reflected", timeout: 0.3, condition: {
                isInputReflected(expected: text, current: element.stringValue)
            })
            if reflected {
                log("\(label): set AXValue succeeded on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): set AXValue verification failed")
        return false
    }

    @discardableResult
    func typeTextWithVerification(
        _ text: String,
        on element: UIElement?,
        label: String,
        attempts: Int = 2,
        perCharacterDelay: TimeInterval = 0.01,
        retryDelay: TimeInterval = 0.08
    ) -> Bool {
        let target: TypingTarget = element.map { .element($0) } ?? .focusedTextInput
        for attempt in 1...max(attempts, 1) {
            let before = element?.stringValue
            // A refusal is not a reflection miss: the focus was already polled,
            // so another attempt would only be refused again.
            guard typeTextGuarded(text, into: target, label: label, perCharacterDelay: perCharacterDelay) else {
                return false
            }
            guard let element else {
                log("\(label): typed without verification target")
                return true
            }

            let reflected = waitUntil(label: "\(label) typing reflected", timeout: 0.3, condition: {
                let after = element.stringValue
                return isTypingReflected(before: before, after: after, typed: text)
            })
            if reflected {
                log("\(label): typing reflected on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): typing verification failed")
        return false
    }

    @discardableResult
    func pressEnterWithVerification(
        on element: UIElement?,
        label: String,
        attempts: Int = 2,
        reflectionTimeout: TimeInterval = 0.45,
        retryDelay: TimeInterval = 0.12
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            let before = element?.stringValue ?? ""
            pressKey(code: 36)

            guard let element else {
                log("\(label): Enter sent without verification target")
                return true
            }

            let reflected = waitUntil(label: "\(label) Enter reflected", timeout: reflectionTimeout, condition: {
                let after = element.stringValue ?? ""
                return didEnterEffect(before: before, after: after)
            })
            if reflected {
                log("\(label): Enter reflected on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): Enter verification failed")
        return false
    }

    @discardableResult
    func clickWithRetry(
        _ element: UIElement,
        label: String,
        attempts: Int = 3,
        retryDelay: TimeInterval = 0.2
    ) -> Bool {
        for attempt in 1...attempts {
            do {
                try element.press()
                log("\(label): clicked on attempt \(attempt)")
                return true
            } catch {
                log("\(label): click attempt \(attempt) failed (\(error))")
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }
        return false
    }

    func pressEscape() {
        pressKey(code: 53)
    }

    func pressEnterKey() {
        pressKey(code: 36)
    }

    func pressEscapeKey() {
        pressKey(code: 53)
    }

    func pressDownArrowKey() {
        pressKey(code: 125)
    }

    func pressTabKey() {
        pressKey(code: 48)
    }

    func pressShiftTabKey() {
        pressKey(code: 48, flags: .maskShift)
    }

    func pressSpaceKey() {
        pressKey(code: 49)
    }

    func pressCommandW() {
        pressKey(code: 13, flags: .maskCommand) // W
    }

    func pressCommandOne() {
        pressKey(code: 18, flags: .maskCommand) // 1 — KakaoTalk: show friends tab
    }

    func pressCommandTwo() {
        pressKey(code: 19, flags: .maskCommand) // 2 — KakaoTalk: show chats tab/window
    }

    func pressCommandA() {
        pressKey(code: 0, flags: .maskCommand) // A
    }

    func pressPaste() {
        pressKey(code: 9, flags: .maskCommand) // V
    }

    func pressDeleteKey() {
        pressKey(code: 51) // Backspace
    }

    /// Unguarded typing for the login screen only (Auth/). The blind login
    /// path runs when no login form could be found in the AX tree, so there is
    /// no focused element to hold it to. Everything else types through
    /// `typeTextGuarded`.
    func typeTextDirect(_ text: String, label: String, perCharacterDelay: TimeInterval = 0.01) {
        typeText(text, perCharacterDelay: perCharacterDelay)
        log("\(label): typed without reflection check")
    }

    /// Route typing refusals onto a command's summary line as `type.blocked=<role>`.
    func reportTypingBlocks(to note: @escaping (String, String) -> Void) {
        typingBlocks.install { note("type.blocked", $0) }
    }

    /// Type only if KakaoTalk's focused element is a text input (and, given a
    /// target element, that element). Returns false without posting a single
    /// key event otherwise. See `TypingFocusGuard` for why.
    @discardableResult
    func typeTextGuarded(
        _ text: String,
        into target: TypingTarget,
        label: String,
        perCharacterDelay: TimeInterval = 0.01
    ) -> Bool {
        guard typingAllowed(into: target, label: label) else { return false }
        typeText(text, perCharacterDelay: perCharacterDelay)
        return true
    }

    /// Read-only view of what the guard sees right now (`kmsg inspect --focus`).
    func currentTypingFocus() -> (observation: TypingFocusGuard.Observation, verdict: TypingFocusGuard.Verdict) {
        let observation = observeTypingFocus(.focusedTextInput)
        return (observation, TypingFocusGuard.verdict(for: observation))
    }

    private func typingAllowed(into target: TypingTarget, label: String) -> Bool {
        // Key focus can trail an AXFocused write by a beat; look up to three
        // times before refusing. An allowed read costs one look.
        var verdict = TypingFocusGuard.verdict(for: observeTypingFocus(target))
        var looks = 1
        while verdict != .allow, looks < 3 {
            Thread.sleep(forTimeInterval: 0.08)
            verdict = TypingFocusGuard.verdict(for: observeTypingFocus(target))
            looks += 1
        }
        guard case .block(let token) = verdict else { return true }
        log("\(label): typing blocked, focus=\(token); no key events posted")
        typingBlocks.report(token)
        return false
    }

    private func observeTypingFocus(_ target: TypingTarget) -> TypingFocusGuard.Observation {
        guard let pid = KakaoTalkApp.runningApplication?.processIdentifier else {
            return TypingFocusGuard.Observation(focusReadable: false)
        }

        // HID key events go to the system's frontmost app. KakaoTalk keeps
        // answering with its own focused element while another app is in
        // front, and activate() is only a request: with another app active it
        // can be ignored (seen locally — the composer-less send path would
        // have typed the message and Enter into that other app).
        //
        // KakaoTalk's own AXFrontmost is the signal. The system-wide focused
        // element is consulted only when that cannot be read: it fails
        // outright when the frontmost app does not answer AX
        // (kAXErrorCannotComplete with an Electron app in front), so it can
        // add evidence but never clear it. Unreadable is not evidence.
        let app = UIElement.application(pid: pid)
        var focusInOtherApp = false
        if let frontmost: Bool = app.attributeOptional(kAXFrontmostAttribute) {
            focusInOtherApp = !frontmost
        } else if let systemFocused = UIElement.systemWide().focusedUIElement {
            var owner: pid_t = 0
            if AXUIElementGetPid(systemFocused.axElement, &owner) == .success, owner > 0, owner != pid {
                focusInOtherApp = true
            }
        }

        guard let focused = app.focusedUIElement else {
            return TypingFocusGuard.Observation(focusReadable: false, focusInOtherApp: focusInOtherApp)
        }

        var isExpectedElement: Bool?
        if case .element(let expected) = target {
            isExpectedElement = Self.isSameOrInside(focused, expected)
        }
        return TypingFocusGuard.Observation(
            focusReadable: true,
            role: focused.role,
            subrole: focused.subrole,
            isExpectedElement: isExpectedElement,
            focusInOtherApp: focusInOtherApp
        )
    }

    /// The focused element is the target, or sits just inside it (a combo box
    /// or search field can report its inner text field as focused).
    private static func isSameOrInside(_ focused: UIElement, _ expected: UIElement) -> Bool {
        var cursor: UIElement? = focused
        var hops = 0
        while let element = cursor, hops <= 3 {
            if CFEqual(element.axElement, expected.axElement) { return true }
            cursor = element.parent
            hops += 1
        }
        return false
    }

    private func typeText(_ text: String, perCharacterDelay: TimeInterval) {
        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            let unit = String(char)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                var unicode = Array(unit.utf16)
                down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: perCharacterDelay)
        }
    }

    private func pressKey(code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Post a left-button double-click at the given screen point.
    /// KakaoTalk's search/chat-list rows expose only AXShowDefaultUI/AXShowAlternateUI and
    /// ignore both AXPress and keyboard Enter, so a hardware-level double-click is the only
    /// reliable way to open them.
    func mouseClick(at point: CGPoint, label: String) {
        log("\(label): click at (\(Int(point.x)),\(Int(point.y)))")
        postMouseClicks(at: point, clickCount: 1)
    }

    func mouseDoubleClick(at point: CGPoint, label: String) {
        log("\(label): double-click at (\(Int(point.x)),\(Int(point.y)))")
        postMouseClicks(at: point, clickCount: 2)
    }

    private func postMouseClicks(at point: CGPoint, clickCount: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let restorePoint = CGEvent(source: nil)?.location

        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)

        for click in 1...max(clickCount, 1) {
            if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                up.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.04)
        }

        // Return the cursor so the click does not strand the user's pointer.
        if let restorePoint {
            CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: restorePoint,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
    }

    private func isInputReflected(expected: String, current: String?) -> Bool {
        guard let current else { return false }
        return current == expected || current.contains(expected)
    }

    private func isTypingReflected(before: String?, after: String?, typed: String) -> Bool {
        guard let after else { return false }
        if after == typed || after.contains(typed) {
            return true
        }
        guard let before else { return !after.isEmpty }
        return after != before
    }

    private func didEnterEffect(before: String, after: String) -> Bool {
        let trimmedAfter = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty && trimmedAfter.isEmpty {
            return true
        }
        return after != before
    }
}
