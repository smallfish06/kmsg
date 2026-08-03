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
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let imageURL = URL(fileURLWithPath: imagePath)

        guard FileManager.default.fileExists(atPath: imagePath) else {
            print("Error: File not found at \(imagePath)")
            throw ExitCode.failure
        }

        let kakao = try AuthBootstrap.requireAuthenticated(traceAX: traceAX)
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: !noCache,
            deepRecoveryEnabled: deepRecovery
        )

        do {
            print("Looking for chat with \(targetDescription)...")
            // chat_id resolution reuses SendCommand's routing: existing window
            // -> chat list row -> search fallback. The title path stays for
            // callers without a registry id, but it opens the FIRST search
            // result for a display name — wrong when two friends share one.
            let resolution: ChatWindowResolution
            if let chatID {
                resolution = try chatWindowResolver.resolve(chatID: chatID)
            } else {
                resolution = try chatWindowResolver.resolve(query: recipient ?? "")
            }

            // Clear leftovers and close on EVERY exit path. A send whose
            // confirmation click misreports failure can leave the pasted
            // attachment behind as a per-chat draft, and KakaoTalk flushes
            // that draft on the next window open — observed live as a
            // duplicate photo sent minutes later by an unrelated read.
            defer {
                clearLeftoverDraft(in: resolution.window, runner: runner)
                closeWindowsIfNeeded(
                    resolution: resolution,
                    kakao: kakao,
                    resolver: chatWindowResolver,
                    runner: runner
                )
            }
            try sendImageToWindow(imageURL, window: resolution.window, kakao: kakao, runner: runner)
        } catch {
            print("Failed to send image: \(error)")
            throw ExitCode.failure
        }
    }

    private func sendImageToWindow(_ imageURL: URL, window: UIElement, kakao: KakaoTalkApp, runner: AXActionRunner) throws {
        // 1. Copy image to clipboard
        guard let image = NSImage(contentsOf: imageURL) else {
            throw KakaoTalkError.actionFailed("Failed to load image from \(imageURL.path)")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        runner.log("Image copied to clipboard")

        // 2. Activate KakaoTalk and focus window
        kakao.activate()
        try? window.focus()
        Thread.sleep(forTimeInterval: 0.3)

        // 3. Paste image
        runner.pressPaste()
        runner.log("Paste command sent")

        // 4. Confirmation sheet can be transient or skipped entirely depending on KakaoTalk state.
        if let confirmationSheet = waitForConfirmationSheet(in: window, runner: runner) {
            runner.log("Confirmation sheet found")
            Thread.sleep(forTimeInterval: 0.2)

            guard let button = findSendButton(in: confirmationSheet) else {
                if !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner) {
                    throw KakaoTalkError.elementNotFound("Send button not found on confirmation sheet")
                }
                runner.log("send-image: sheet vanished before button lookup; treating as success")
                print("✓ Image sent to \(targetDescription)")
                Thread.sleep(forTimeInterval: 0.5)
                return
            }

            if !runner.clickWithRetry(button, label: "send button"),
               !waitForSendCompletion(in: window, confirmationSheet: confirmationSheet, runner: runner)
            {
                throw KakaoTalkError.actionFailed("Failed to click send button after retries")
            }
        } else {
            runner.log("send-image: confirmation sheet not observed; allowing direct-send path")
            Thread.sleep(forTimeInterval: 0.7)
        }

        print("✓ Image sent to \(targetDescription)")

        // Give it a moment to finish sending
        Thread.sleep(forTimeInterval: 0.5)
    }

    // Remove anything still sitting in the chat input (and the clipboard copy
    // of the image) before the window closes. KakaoTalk persists a non-empty
    // input as a per-chat draft, and the next window open can send it.
    private func clearLeftoverDraft(in window: UIElement, runner: AXActionRunner) {
        NSPasteboard.general.clearContents()
        runner.pressEscapeKey()
        guard let input = window.findAll(role: kAXTextAreaRole, limit: 4, maxNodes: 200).first else {
            runner.log("send-image: no input area found to clear")
            return
        }
        try? input.focus()
        Thread.sleep(forTimeInterval: 0.1)
        runner.pressCommandA()
        runner.pressDeleteKey()
        runner.log("send-image: cleared input draft and clipboard")
    }

    private func closeWindowsIfNeeded(
        resolution: ChatWindowResolution,
        kakao: KakaoTalkApp,
        resolver: ChatWindowResolver,
        runner: AXActionRunner
    ) {
        guard !keepWindow else {
            runner.log("send-image: keep-window enabled; skipping auto-close")
            return
        }

        if resolver.closeWindow(resolution.window) {
            print("✓ Chat window closed.")
        } else {
            runner.log("send-image: close window could not be verified")
        }

        if let listWindow = kakao.chatListWindow,
           !areSameAXElement(listWindow, resolution.window)
        {
            if resolver.closeWindow(listWindow) {
                runner.log("send-image: chat list window closed")
            } else {
                runner.log("send-image: chat list window could not be verified")
            }
        }
    }

    private func waitForConfirmationSheet(in window: UIElement, runner: AXActionRunner) -> UIElement? {
        var sheet: UIElement?
        _ = runner.waitUntil(label: "confirmation sheet", timeout: 1.5, pollInterval: 0.1) {
            sheet = locateConfirmationSheet(in: window)
            return sheet != nil
        }
        return sheet
    }

    private func locateConfirmationSheet(in window: UIElement) -> UIElement? {
        if let found = window.attributeOptional(kAXSheetsAttribute).flatMap({ (elements: [AXUIElement]) in elements.first }) {
            return UIElement(found)
        }
        return window.findFirst(where: { $0.role == kAXSheetRole })
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
        runner: AXActionRunner
    ) -> Bool {
        runner.waitUntil(label: "send-image completion", timeout: 1.5, pollInterval: 0.1) {
            locateConfirmationSheet(in: window) == nil || !windowContainsElement(window, target: confirmationSheet)
        }
    }

    private func windowContainsElement(_ window: UIElement, target: UIElement) -> Bool {
        window.findFirst(where: { candidate in
            areSameAXElement(candidate, target)
        }) != nil
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
}
