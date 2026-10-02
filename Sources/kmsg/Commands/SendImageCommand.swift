import ArgumentParser
import AppKit
import Foundation

struct SendImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-image",
        abstract: "Send an image to a chat",
        discussion: """
            Use either:
              kmsg send-image <recipient> <image-path>
              kmsg send-image --chat-id <chat-id> <image-path>
            """
    )

    @Option(name: .long, help: "Send using a chat_id from 'kmsg chats'")
    var chatID: String?

    @Argument(help: "Recipient name, or image path when --chat-id is used")
    var firstValue: String?

    @Argument(help: "Image path when recipient is provided")
    var secondValue: String?

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Disable AX path cache for this run")
    var noCache: Bool = false

    @Flag(name: [.short, .long], help: "Keep chat and list windows open after sending image")
    var keepWindow: Bool = false

    @Flag(name: .long, help: "Enable deep window recovery when fast window detection fails")
    var deepRecovery: Bool = false

    // SendCommand 와 같은 검증. 사진은 지우기가 더 어렵기도 하다.
    @Option(
        name: .customLong("expect-anchor"),
        parsing: .singleValue,
        help: "Recent message text that must appear in the chat before sending. Repeatable."
    )
    var expectAnchors: [String] = []

    @Option(name: .customLong("expect-min"), help: "How many --expect-anchor values must match (default 1)")
    var expectMin: Int = 1

    var recipient: String? {
        guard chatID == nil else { return nil }
        return firstValue
    }

    var imagePath: String {
        if chatID == nil {
            return secondValue ?? ""
        }
        return firstValue ?? ""
    }

    private var targetDescription: String {
        if let chatID {
            return "chat_id '\(chatID)'"
        }
        return "'\(recipient ?? "")'"
    }

    func validate() throws {
        if let chatID, !chatID.isEmpty {
            guard let firstValue, !firstValue.isEmpty else {
                throw ValidationError("Image path is required when using --chat-id.")
            }
            guard secondValue == nil else {
                throw ValidationError("Recipient cannot be provided together with --chat-id.")
            }
            return
        }

        guard let firstValue, !firstValue.isEmpty else {
            throw ValidationError("Recipient is required.")
        }
        guard let secondValue, !secondValue.isEmpty else {
            throw ValidationError("Image path is required.")
        }
    }

    func run() throws {
        // Image phase marks use `step`: the bridge uses text-send `phase`
        // marks to permit some retries. Observing an image must not change
        // its existing conservative interrupted-send / no-replay policy.
        let profiler = PhaseProfiler(command: "send-image", phaseMarkerKey: "step")
        profiler.note("pid", String(ProcessInfo.processInfo.processIdentifier))
        var runFailed = true
        defer { profiler.emitSummary(status: runFailed ? "fail" : "ok") }
        profiler.begin("permission")
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        profiler.begin("file")
        let imageURL = URL(fileURLWithPath: imagePath)

        guard FileManager.default.fileExists(atPath: imagePath) else {
            print("Error: File not found at \(imagePath)")
            throw ExitCode.failure
        }

        profiler.begin("auth")
        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: !noCache,
            deepRecoveryEnabled: deepRecovery,
            note: { key, value in profiler.note(key, value) }
        )

        do {
            print("Looking for chat with \(targetDescription)...")
            // chat_id resolution reuses SendCommand's routing: existing window
            // -> chat list row -> search fallback. The title path stays for
            // callers without a registry id, but it opens the FIRST search
            // result for a display name — wrong when two friends share one.
            let resolution: ChatWindowResolution
            profiler.begin("resolve")
            if let chatID {
                resolution = try chatWindowResolver.resolve(chatID: chatID)
            } else {
                resolution = try chatWindowResolver.resolve(query: recipient ?? "")
            }

            let draftState = ChatWindowCleanup.ImageDraftState(window: resolution.window)
            let cleanup = ChatWindowCleanup(kakao: kakao, runner: runner)
            // Clear leftovers and close on EVERY exit path. A send whose
            // confirmation click misreports failure can leave the pasted
            // attachment behind as a per-chat draft, and KakaoTalk flushes
            // that draft on the next window open — observed live as a
            // duplicate photo sent minutes later by an unrelated read.
            defer {
                clearLeftoverDraft(in: resolution.window, cleanup: cleanup, state: draftState, profiler: profiler)
                if draftState.identityVerified {
                    closeWindowsIfNeeded(
                        resolution: resolution,
                        kakao: kakao,
                        resolver: chatWindowResolver,
                        runner: runner,
                        profiler: profiler
                    )
                } else {
                    profiler.note("close.result", keepWindow ? "kept" : "unconfirmed")
                    profiler.note("close.authority", "unverified")
                    if !keepWindow {
                        print("⚠ WINDOW_LEFT_OPEN: target identity unverified; cleanup skipped")
                    }
                }
            }
            // 클립보드에 손대기 전에 확인한다. 붙여넣은 뒤 실패하면 그 첨부가 per-chat
            // 초안으로 남아 다음 창 열기에서 흘러나간다(2026-08-04 중복 사진 사고).
            profiler.begin("verify")
            try ChatIdentityVerifier(kakao: kakao, runner: runner).verify(
                window: resolution.window,
                fallbackChatTitle: recipient ?? chatID ?? "",
                anchors: expectAnchors,
                minimumMatches: expectMin,
                note: { key, value in profiler.note(key, value) }
            )
            draftState.identityVerified = true
            try sendImageToWindow(imageURL, window: resolution.window, kakao: kakao, runner: runner, profiler: profiler, draftState: draftState)
            runFailed = false
        } catch {
            print("Failed to send image: \(error)")
            throw ExitCode.failure
        }
    }

    private func sendImageToWindow(_ imageURL: URL, window: UIElement, kakao: KakaoTalkApp, runner: AXActionRunner, profiler: PhaseProfiler, draftState: ChatWindowCleanup.ImageDraftState) throws {
        let confirmationDiagnostics = ImageConfirmationDiagnostics.make()
        defer { confirmationDiagnostics?.emit() }
        // 1. Copy image to clipboard
        profiler.begin("clipboard")
        guard let image = NSImage(contentsOf: imageURL) else {
            throw KakaoTalkError.actionFailed("Failed to load image from \(imageURL.path)")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        draftState.clipboardPrepared = true
        pasteboard.writeObjects([image])

        runner.log("Image copied to clipboard")

        // 2. Activate KakaoTalk and focus window
        profiler.begin("focus")
        kakao.activate()
        try? window.focus()
        Thread.sleep(forTimeInterval: 0.3)

        // ⌘V 는 프론트모스트 창으로 간다. 해석된 방 창이 실제로 포커스를 못 잡았으면
        // 붙여넣기는 그때 앞에 있는 창(=남의 방)에 들어간다 — 그 뒤의 확인 시트 탐색은
        // `window` 안에서 하므로 시트를 못 보고 "direct-send path" 로 성공 처리된다.
        // 포커스가 그 창이 아니면 여기서 멈춘다.
        ChatWindowCleanup(kakao: kakao, runner: runner).rememberPasteInput(in: window, state: draftState)
        let focusedNow = kakao.focusedWindow
        guard let focusedNow, CFEqual(focusedNow.axElement, window.axElement) else {
            throw KakaoTalkError.actionFailed(
                "[WRONG_WINDOW] chat window '\(window.title ?? "")' did not take focus (focused: '\(focusedNow?.title ?? "")'); refusing to paste"
            )
        }

        // 3. Paste image
        profiler.begin("paste")
        draftState.pasteDispatched = true
        runner.pressPaste()
        runner.log("Paste command sent")

        // 4. Confirmation sheet can be transient or skipped entirely depending on KakaoTalk state.
        profiler.begin("sheet")
        if let confirmationSheet = waitForConfirmationSheet(in: window, runner: runner, diagnostics: confirmationDiagnostics) {
            profiler.note("sheet.found", "1")
            runner.log("Confirmation sheet found")
            profiler.begin("sheet_settle")
            Thread.sleep(forTimeInterval: 0.2)

            profiler.begin("button")
            guard let button = findSendButton(in: confirmationSheet) else {
                profiler.note("button.found", "0")
                profiler.begin("complete")
                if !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner, diagnostics: confirmationDiagnostics) {
                    throw KakaoTalkError.elementNotFound("Send button not found on confirmation sheet")
                }
                runner.log("send-image: sheet vanished before button lookup; treating as success")
                print("✓ Image sent to \(targetDescription)")
                profiler.begin("settle")
                Thread.sleep(forTimeInterval: 0.5)
                return
            }

            profiler.note("button.found", "1")
            profiler.begin("click")
            let clicked = runner.clickWithRetry(button, label: "send button")
            profiler.note("click.ok", clicked ? "1" : "0")
            if !clicked {
                profiler.begin("complete")
                if !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner, diagnostics: confirmationDiagnostics) {
                    throw KakaoTalkError.actionFailed("Failed to click send button after retries")
                }
            }
        } else {
            profiler.note("sheet.found", "0")
            runner.log("send-image: confirmation sheet not observed; allowing direct-send path")
            profiler.begin("direct_wait")
            Thread.sleep(forTimeInterval: 0.7)
        }

        print("✓ Image sent to \(targetDescription)")

        // Give it a moment to finish sending
        profiler.begin("settle")
        Thread.sleep(forTimeInterval: 0.5)
    }

    // Remove anything still sitting in the chat input (and the clipboard copy
    // of the image) before the window closes. KakaoTalk persists a non-empty
    // input as a per-chat draft, and the next window open can send it.
    private func clearLeftoverDraft(
        in window: UIElement,
        cleanup: ChatWindowCleanup,
        state: ChatWindowCleanup.ImageDraftState,
        profiler: PhaseProfiler
    ) {
        let result = cleanup.clearImageDraft(in: window, state: state, allowWindowClose: !keepWindow, profiler: profiler)
        profiler.note("draft.result", result.rawValue)
        // Text emptiness cannot certify the attachment or delivery state.
        profiler.note("draft.attachment", "unverified")
    }

    private func closeWindowsIfNeeded(
        resolution: ChatWindowResolution,
        kakao: KakaoTalkApp,
        resolver: ChatWindowResolver,
        runner: AXActionRunner,
        profiler: PhaseProfiler
    ) {
        guard !keepWindow else {
            profiler.note("close.result", "kept")
            runner.log("send-image: keep-window enabled; skipping auto-close")
            return
        }

        if closeChatWindowWithRetry(resolution.window, resolver: resolver, runner: runner, profiler: profiler) {
            profiler.note("close.result", "verified")
            print("✓ Chat window closed.")
        } else {
            profiler.note("close.result", "unconfirmed")
            // Loud and greppable on stdout: a chat window left open makes
            // KakaoTalk auto-read every incoming message (no unread badge),
            // which blinds the bridge's badge-triggered read loop — observed
            // live 2026-08-03 as a user message sitting unanswered for 23
            // minutes. The bridge watches for this marker.
            print("⚠ WINDOW_LEFT_OPEN: chat window could not be closed after image send")
        }

        // 채팅 목록 창은 닫지 않는다(send 와 같은 이유). 예전에는 방 창을 닫은 뒤 목록 창도 무조건
        // 닫았다 — 목록 창은 활성화로 안 돌아와서, 닫히면 다음 chats 가 목록을 못 본다.
    }

    // A lingering confirmation sheet or send overlay can make AXClose, the
    // close button, and cmd+w all bounce off. Escape dismisses whatever modal
    // is in the way, then the close is retried and VERIFIED each time.
    private func closeChatWindowWithRetry(
        _ window: UIElement,
        resolver: ChatWindowResolver,
        runner: AXActionRunner,
        profiler: PhaseProfiler
    ) -> Bool {
        ChatWindowCleanup(kakao: resolver.cleanupApplication, runner: runner).closeWithRetry(
            window,
            close: { resolver.closeWindow($0) },
            beforeAttempt: { profiler.begin("close\($0)") },
            note: { profiler.note($0, $1) }
        )
    }

    private func waitForConfirmationSheet(
        in window: UIElement, runner: AXActionRunner, diagnostics: ImageConfirmationDiagnostics? = nil
    ) -> UIElement? {
        var sheet: UIElement?
        _ = runner.waitUntil(label: "confirmation sheet", timeout: 1.5, pollInterval: 0.1) {
            sheet = locateConfirmationSheet(in: window, diagnostics: diagnostics)
            return sheet != nil
        }
        return sheet
    }

    private func locateConfirmationSheet(in window: UIElement, diagnostics: ImageConfirmationDiagnostics? = nil) -> UIElement? {
        let started = diagnostics?.beginLookup()
        defer { if let started { diagnostics?.endLookup(started) } }
        let elements: [AXUIElement]? = window.attributeOptional(kAXSheetsAttribute)
        if let elements {
            if let found = elements.first {
                diagnostics?.directPresent += 1
                return UIElement(found)
            }
            diagnostics?.directEmpty += 1
        } else {
            diagnostics?.directUnknown += 1
        }
        diagnostics?.fallbackWalks += 1
        let found = findConfirmationSheetInDescendants(of: window, diagnostics: diagnostics)
        if found != nil { diagnostics?.fallbackFound += 1 }
        return found
    }

    // Keep the existing BFS and Optional result. Batching changes when a
    // node's role and children are observed, not the authority of a missing
    // sheet or the existing completion/retry policy.
    private func findConfirmationSheetInDescendants(
        of window: UIElement, diagnostics: ImageConfirmationDiagnostics?
    ) -> UIElement? {
        var queue = window.children
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            diagnostics?.fallbackBatchReads += 1
            let values = current.batchAttributes([kAXRoleAttribute, kAXChildrenAttribute])
            let batchRole = values[0] as? String
            let role: String?
            if let batchRole {
                role = batchRole
            } else {
                diagnostics?.fallbackRoleScalarReads += 1
                role = current.role
            }
            diagnostics?.fallbackVisits += 1
            if role == nil { diagnostics?.fallbackUnknownRoles += 1 }
            if role == kAXSheetRole { return current }
            // If role needed a scalar retry, discard the earlier children
            // slot and retain the original role-before-children read order.
            if batchRole != nil, let children = values[1] as? [AXUIElement] {
                queue.append(contentsOf: children.map { UIElement($0) })
            } else {
                diagnostics?.fallbackChildrenScalarReads += 1
                queue.append(contentsOf: current.children)
            }
        }
        return nil
    }


    private func findSendButton(in confirmationSheet: UIElement) -> UIElement? {
        confirmationSheet.findAll(role: kAXButtonRole).first { button in
            let title = (button.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title == "전송" || title == "Send"
        }
    }

    private func waitForSendCompletion(
        in window: UIElement,
        confirmationSheet: UIElement,
        runner: AXActionRunner,
        diagnostics: ImageConfirmationDiagnostics? = nil
    ) -> Bool {
        runner.waitUntil(label: "send-image completion", timeout: 1.5, pollInterval: 0.1) {
            locateConfirmationSheet(in: window, diagnostics: diagnostics) == nil ||
                !windowContainsElement(window, target: confirmationSheet, diagnostics: diagnostics)
        }
    }

    private func windowContainsElement(
        _ window: UIElement, target: UIElement, diagnostics: ImageConfirmationDiagnostics? = nil
    ) -> Bool {
        let started = diagnostics?.beginContains()
        defer { if let started { diagnostics?.endContains(started) } }
        let found = window.findFirst(where: { candidate in
            diagnostics?.containsVisits += 1
            return areSameAXElement(candidate, target)
        }) != nil
        if found { diagnostics?.containsFound += 1 }
        return found
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
}
