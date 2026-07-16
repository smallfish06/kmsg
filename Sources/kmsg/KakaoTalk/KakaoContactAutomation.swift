import ApplicationServices.HIServices
import Foundation

struct KakaoFriendAddResult {
    let friendName: String
    let chatTitle: String
    let externalChatID: String?
}

private enum ContactAutomationFailureCode: String {
    case windowNotReady = "WINDOW_NOT_READY"
    case friendsTabNotFound = "FRIENDS_TAB_NOT_FOUND"
    case friendAddUINotFound = "FRIEND_ADD_UI_NOT_FOUND"
    case searchFieldNotFound = "SEARCH_FIELD_NOT_FOUND"
    case inputNotReflected = "INPUT_NOT_REFLECTED"
    case friendResultNotFound = "FRIEND_RESULT_NOT_FOUND"
    case chatStartUINotFound = "CHAT_START_UI_NOT_FOUND"
    case chatWindowNotReady = "CHAT_WINDOW_NOT_READY"
    case messageInputNotFound = "MESSAGE_INPUT_NOT_FOUND"
    case messageSendNotConfirmed = "MESSAGE_SEND_NOT_CONFIRMED"
    case chatIdentityNotConfirmed = "CHAT_IDENTITY_NOT_CONFIRMED"
}

struct KakaoContactAutomation {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner

    init(kakao: KakaoTalkApp, runner: AXActionRunner) {
        self.kakao = kakao
        self.runner = runner
    }

    func addFriend(kakaoID: String, message: String? = nil) throws -> KakaoFriendAddResult {
        // A first conversation does not exist in the Chats tab yet. Friend-add
        // must therefore enter the 1:1 chat from the Friends result/profile and
        // send its optional first message through that exact window in this
        // process. A second `kmsg send` process could resolve a same-title chat
        // window or fall back to Chats search, so it is deliberately avoided.
        // On failure, clear the partial UI. On success, preserve and re-raise the
        // direct chat after putting the main list back on Chats behind it.
        var openedChatWindow: UIElement?
        defer {
            if openedChatWindow == nil {
                dismissLeftoverUI()
            }
            restoreChatsTab()
            if let openedChatWindow {
                kakao.activate()
                _ = tryRaiseWindow(openedChatWindow, label: "opened friend chat")
            }
        }
        let rootWindow = try requireMainListWindow()
        try navigateToFriends(in: rootWindow)
        try openFriendAddUI(from: rootWindow)
        // Friend-add happens entirely inside an AXPopover. Require it: the main
        // window's "이름으로 검색" AXSearchField must never be the target, so if
        // the popover didn't open we fail loudly instead of typing the ID there.
        guard let popover = waitForPopover(in: rootWindow) else {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Friend add popover did not open")
        }
        try selectKakaoIDMode(in: popover)
        // Re-fetch after the mode switch swaps the popover's contents.
        let idRoot = waitForPopover(in: rootWindow) ?? popover
        let input = try requireBestTextInput(in: idRoot, label: "KakaoTalk ID input")
        try setText(kakaoID, on: input, label: "KakaoTalk ID input")
        // triggerSearch blocks until a result card renders (its bottom button):
        // 친구 추가 for a new contact, 1:1 채팅 when the id is already a friend.
        try triggerSearch(in: idRoot, input: input)
        let resultRoot = waitForPopover(in: rootWindow) ?? idRoot
        let friendName = resolveFriendDisplayName(in: resultRoot, fallback: kakaoID)
        let chatWindow = try openOneToOneChat(
            from: resultRoot,
            mainListWindow: rootWindow,
            friendName: friendName
        )
        openedChatWindow = chatWindow

        // The chat title is read from the exact window opened by the Friends
        // flow. It is metadata only; it must never be used as an identity
        // fallback when duplicate display names exist.
        guard let chatTitle = usableChatTitle(chatWindow.title) else {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.chatIdentityNotConfirmed.rawValue)] Friends-opened chat had no exact usable title"
            )
        }
        let externalChatID: String?

        if let message {
            try sendFirstMessage(message, in: chatWindow)
            externalChatID = try confirmChatIdentity(
                chatTitle: chatTitle,
                opener: message,
                mainListWindow: rootWindow
            )
        } else {
            externalChatID = nil
        }

        return KakaoFriendAddResult(
            friendName: friendName,
            chatTitle: chatTitle,
            externalChatID: externalChatID
        )
    }

    // ESC closes the friend-add popover and the profile window KakaoTalk opens
    // after a successful add. Two presses with a beat between them cover both.
    private func dismissLeftoverUI() {
        runner.pressEscapeKey()
        Thread.sleep(forTimeInterval: 0.15)
        runner.pressEscapeKey()
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func restoreChatsTab() {
        runner.pressCommandTwo()
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func requireMainListWindow() throws -> UIElement {
        // A standalone conversation window is a "usable" window to
        // KakaoTalkApp.ensureMainWindow(), but it cannot host the Friends tab
        // or the friend-add popover. Mirror chat discovery's recovery path:
        // activate KakaoTalk, use Cmd+2 to restore the main list window, wait
        // for that exact window, then raise it before any coordinate clicks.
        guard kakao.ensureMainWindow(timeout: 5.0, trace: { message in runner.log(message) }) != nil else {
            throw KakaoTalkError.windowNotFound("[\(ContactAutomationFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable")
        }

        kakao.activate()
        Thread.sleep(forTimeInterval: 0.08)
        // These key events are global. Clear a prior crashed run only after
        // KakaoTalk is frontmost so Escape cannot land in another app.
        dismissLeftoverUI()
        runner.pressCommandTwo()

        var listWindow: UIElement?
        _ = runner.waitUntil(label: "friend add main list window restore", timeout: 1.4, pollInterval: 0.08) {
            listWindow = kakao.chatListWindow
            return listWindow != nil
        }

        if listWindow == nil {
            // Activation does not reopen a main window that the user closed
            // while leaving KakaoTalk running. Reopen once, then repeat the
            // same deterministic Cmd+2 recovery before failing.
            runner.log("friend add: main list window missing after Cmd+2; forcing app reopen")
            _ = KakaoTalkApp.forceOpen(timeout: 0.8)
            kakao.activate()
            runner.pressCommandTwo()
            _ = runner.waitUntil(label: "friend add main list window reopen", timeout: 1.4, pollInterval: 0.08) {
                listWindow = kakao.chatListWindow
                return listWindow != nil
            }
        }

        guard let window = listWindow else {
            throw KakaoTalkError.windowNotFound("[\(ContactAutomationFailureCode.windowNotReady.rawValue)] KakaoTalk main list window unavailable")
        }

        _ = tryRaiseWindow(window)
        Thread.sleep(forTimeInterval: 0.15)
        return window
    }

    private func currentRoot(preferred: UIElement) -> UIElement {
        if preferred.role == "AXPopover" {
            return preferred
        }
        return kakao.chatListWindow ?? kakao.mainWindow ?? kakao.focusedWindow ?? kakao.windows.last ?? preferred
    }

    private func navigateToFriends(in rootWindow: UIElement) throws {
        if let friendsButton = rootWindow.findFirst(identifier: "friends") ?? findButton(in: rootWindow, matching: ["친구", "friends"]) {
            guard activate(friendsButton, label: "friends tab") else {
                throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.friendsTabNotFound.rawValue)] Could not activate Friends tab")
            }
            // The navigation button exists on every tab, so checking for it
            // returns immediately and races the actual content transition.
            // Wait for a Friends-only control before resolving/clicking it.
            let ready = runner.waitUntil(label: "friends tab content", timeout: 1.2, pollInterval: 0.05) {
                findFriendAddButton(in: rootWindow) != nil
            }
            guard ready else {
                throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Friends tab did not render the friend add button")
            }
            return
        }
        throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendsTabNotFound.rawValue)] Friends tab button not found")
    }

    private func openFriendAddUI(from rootWindow: UIElement) throws {
        // The person+ toolbar button has no title/identifier — only
        // AXDescription "친구 추가" (collectTexts includes axDescription, so this
        // exact-matches at the top score). Keep the patterns tight: the loose
        // "친구"/"추가"/"+" fallbacks also matched the sidebar Friends tab
        // (AXHelp "친구 (⌘1)") and could open the wrong thing.
        // The toolbar person+ button ignores AXPress/Enter (custom KakaoTalk
        // control) — only a real mouse click opens the popover. Re-resolve the
        // button after each attempt because the tab transition can invalidate
        // its AX handle, and click its current center every time.
        var foundButton = false
        for _ in 0..<3 {
            guard let addButton = findFriendAddButton(in: rootWindow) else { continue }
            foundButton = true
            if let frame = addButton.frame {
                runner.mouseClick(at: CGPoint(x: frame.midX, y: frame.midY), label: "friend add button")
            } else {
                _ = activate(addButton, label: "friend add button")
            }
            if waitForPopover(in: rootWindow) != nil {
                return
            }
        }
        if !foundButton {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Friend add button not found")
        }
    }

    private func findFriendAddButton(in root: UIElement) -> UIElement? {
        findButton(in: root, matching: ["친구 추가", "친구추가", "add friend", "add friends"])
    }

    private func selectKakaoIDMode(in root: UIElement) throws {
        // The mode tab is a plain button titled exactly "ID" (KakaoTalk desktop);
        // "id" as an exact-match pattern (scoreElement weights == over contains)
        // selects it. The longer strings cover older/localized builds.
        let patterns = ["id", "카카오톡 id", "카카오톡ID", "카카오 id", "kakao id", "kakaotalk id", "id로", "아이디"]
        guard let button = findButton(in: root, matching: patterns) ?? findStaticOrButton(in: root, matching: patterns) else {
            return
        }
        // Like the person+ button, this tab ignores AXPress/Enter — activate()
        // only focuses it, leaving the popover on the 연락처 (name/phone) tab so
        // the id is searched there and never resolves. A real mouse click at the
        // tab's center actually switches to ID mode; retry until the ID field's
        // "친구 카카오톡 ID" placeholder appears.
        for attempt in 0..<3 {
            if attempt == 0 {
                _ = activate(button, label: "KakaoTalk ID mode")
            } else if let frame = button.frame {
                runner.mouseClick(at: CGPoint(x: frame.midX, y: frame.midY), label: "KakaoTalk ID mode")
            }
            let switched = runner.waitUntil(label: "KakaoTalk ID mode active", timeout: 0.6, pollInterval: 0.05) {
                hasIdPlaceholder(in: currentRoot(preferred: root))
            }
            if switched { return }
        }
    }

    private func hasIdPlaceholder(in root: UIElement) -> Bool {
        let fields = root.findAll(where: { ($0.role ?? "") == kAXTextFieldRole }, limit: 12, maxNodes: 400)
        return fields.contains { field in
            let placeholder: String? = field.attributeOptional(kAXPlaceholderValueAttribute)
            let lower = (placeholder ?? "").lowercased()
            return lower.contains("id") || lower.contains("아이디")
        }
    }

    // Friend-add UI is an AXPopover inside the main window, not a separate
    // window — waitForNewRoot never sees it. Poll for it so we can scope input/
    // button lookups to the popover instead of the whole window.
    private func waitForPopover(in root: UIElement) -> UIElement? {
        var popover: UIElement?
        _ = runner.waitUntil(label: "friend add popover", timeout: 1.0, pollInterval: 0.05) {
            popover = findPopover(in: root) ?? kakao.mainWindow.flatMap { findPopover(in: $0) }
            return popover != nil
        }
        return popover
    }

    private func findPopover(in root: UIElement) -> UIElement? {
        if root.role == "AXPopover" { return root }
        return root.findFirst { $0.role == "AXPopover" }
    }

    private func triggerSearch(in root: UIElement, input: UIElement) throws {
        // KakaoTalk commits the ID search when Enter is pressed in the input
        // field — there is no search button inside the popover, and findButton
        // would otherwise pick the main window's 검색 control (which does nothing
        // here and skips the Enter). Focus the field and press Enter.
        _ = runner.focusWithVerification(input, label: "KakaoTalk ID input", attempts: 2)
        runner.pressEnterKey()
        // A hit renders a result card whose action button sits at the BOTTOM of
        // the popover: 친구 추가 for a new contact, 1:1 채팅 when the id is
        // already a friend. Before the result (or with no match) the only
        // matching elements are the header static text and the 연락처/ID tab row
        // near the top. Keying off a *bottom-half* button avoids two failure
        // modes hit live: the no-result notice lingering in the AX tree after a
        // card renders (false timeout), and a slow lookup letting a top tab
        // element satisfy a plain button check before the card exists (early
        // wrong click). Network lookup → wait generously; nothing → time out.
        let found = runner.waitUntil(label: "friend search result", timeout: 8.0, pollInterval: 0.15) {
            bottomButton(in: currentRoot(preferred: root), matching: ["친구 추가", "1:1 채팅", "1:1"]) != nil
        }
        if !found {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendResultNotFound.rawValue)] No user found for this KakaoTalk ID (it may not exist or the user disallows ID search)")
        }
    }

    // Best-scored button in the bottom half of the add popover — i.e. on the
    // result card, never the header/tab row at the top.
    private func bottomButton(in root: UIElement, matching patterns: [String]) -> UIElement? {
        let popover = findPopover(in: root) ?? (root.role == "AXPopover" ? root : nil)
        guard let popover, let pf = popover.frame else { return nil }
        let threshold = pf.minY + pf.height * 0.5
        let buttons = popover.findAll(where: { ($0.role ?? "") == kAXButtonRole }, limit: 48, maxNodes: 1_200)
        return buttons
            .filter { ($0.frame?.minY ?? 0) > threshold && $0.isEnabled && scoreElement($0, matching: patterns) > 100 }
            .max { scoreElement($0, matching: patterns) < scoreElement($1, matching: patterns) }
    }

    private func pressFriendAddConfirmation(_ button: UIElement) throws {
        // Like the other popover controls, the confirm button ignores AXPress/
        // Enter — a real mouse click at its center is what commits the add.
        if let frame = button.frame {
            runner.mouseClick(at: CGPoint(x: frame.midX, y: frame.midY), label: "friend add confirmation")
        } else if !activate(button, label: "friend add confirmation") {
            throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Could not press friend add confirmation")
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func openOneToOneChat(
        from resultRoot: UIElement,
        mainListWindow: UIElement,
        friendName: String
    ) throws -> UIElement {
        // Snapshot before confirming a new friend. A new profile/chat window is
        // then distinguishable from unrelated chat windows already on screen.
        let windowsBeforeStart = kakao.windows
        let chatPatterns = [
            "1:1 채팅", "1:1대화", "채팅하기", "대화하기", "메시지 보내기",
        ]

        var actionRoot = resultRoot
        var chatAction: UIElement
        if let existingFriendChat = bottomButton(in: resultRoot, matching: ["1:1 채팅", "1:1"]) {
            runner.log("friend add: existing friend; opening 1:1 chat from result card")
            chatAction = existingFriendChat
        } else if let addButton = bottomButton(in: resultRoot, matching: ["친구 추가"]) {
            try pressFriendAddConfirmation(addButton)

            var resolvedAction: (element: UIElement, root: UIElement)?
            let foundAction = runner.waitUntil(label: "friend profile 1:1 chat action", timeout: 3.0, pollInterval: 0.1) {
                resolvedAction = findFreshChatStartAction(
                    preferredRoot: resultRoot,
                    mainListWindow: mainListWindow,
                    windowsBeforeStart: windowsBeforeStart,
                    matching: chatPatterns
                )
                return resolvedAction != nil
            }
            guard foundAction, let resolvedAction else {
                throw KakaoTalkError.elementNotFound(
                    "[\(ContactAutomationFailureCode.chatStartUINotFound.rawValue)] 1:1 chat action did not appear after adding '\(friendName)'"
                )
            }
            actionRoot = resolvedAction.root
            chatAction = resolvedAction.element
        } else {
            throw KakaoTalkError.elementNotFound(
                "[\(ContactAutomationFailureCode.chatStartUINotFound.rawValue)] Friend result had neither Add Friend nor 1:1 Chat action"
            )
        }

        // A newly-added friend's profile is itself a new/focused window. Take
        // the readiness baseline only after resolving that profile's 1:1
        // action so the profile cannot masquerade as the chat it should open.
        let windowsBeforeChatStart = kakao.windows
        let focusedWindowBeforeChatStart = kakao.focusedWindow

        var chatWindow: UIElement?
        for attempt in 0..<3 where chatWindow == nil {
            var actionAvailable = true
            if attempt > 0 {
                if let refreshedAction = findFreshChatStartAction(
                    preferredRoot: resultRoot,
                    mainListWindow: mainListWindow,
                    windowsBeforeStart: windowsBeforeStart,
                    matching: chatPatterns
                ) {
                    actionRoot = refreshedAction.root
                    chatAction = refreshedAction.element
                    runner.log("friend add: retrying refreshed 1:1 chat action (attempt \(attempt + 1))")
                } else {
                    // The action can disappear while Kakao is still turning the
                    // profile into a chat. Keep waiting without clicking stale UI.
                    runner.log("friend add: 1:1 action unavailable on retry; waiting for chat transition")
                    actionAvailable = false
                }
            }

            if actionAvailable {
                try pressOneToOneChat(chatAction)
            }

            _ = runner.waitUntil(
                label: "friend 1:1 chat ready attempt \(attempt + 1)",
                timeout: attempt == 2 ? 2.8 : 1.6,
                pollInterval: 0.1
            ) {
                chatWindow = findInputReadyChatWindow(
                    friendName: friendName,
                    excluding: mainListWindow,
                    windowsBeforeStart: windowsBeforeChatStart,
                    focusedWindowBeforeStart: focusedWindowBeforeChatStart
                )
                return chatWindow != nil
            }
        }
        guard let chatWindow else {
            throw KakaoTalkError.windowNotFound(
                "[\(ContactAutomationFailureCode.chatWindowNotReady.rawValue)] 1:1 chat for '\(friendName)' did not expose a message input"
            )
        }

        closeTransientProfileWindowIfNeeded(
            actionRoot,
            chatWindow: chatWindow,
            mainListWindow: mainListWindow
        )
        runner.log("friend add: 1:1 chat ready title='\(chatWindow.title ?? friendName)'")
        return chatWindow
    }

    private func sendFirstMessage(_ message: String, in chatWindow: UIElement) throws {
        kakao.activate()
        _ = tryRaiseWindow(chatWindow, label: "friend first-message chat")

        let exactWindowFocused = runner.waitUntil(
            label: "friend first-message exact chat focus",
            timeout: 0.8,
            pollInterval: 0.05
        ) {
            guard let focusedWindow = kakao.focusedWindow else { return false }
            return sameElement(focusedWindow, chatWindow)
        }
        guard exactWindowFocused else {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.messageInputNotFound.rawValue)] Friends-opened chat window did not retain focus"
            )
        }

        guard let resolvedInput = resolveExactChatMessageInput(in: chatWindow),
              let input = focusExactChatMessageInput(resolvedInput, in: chatWindow)
        else {
            throw KakaoTalkError.elementNotFound(
                "[\(ContactAutomationFailureCode.messageInputNotFound.rawValue)] Message input was not found inside the Friends-opened chat window"
            )
        }

        guard let currentValue = input.stringValue else {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.messageInputNotFound.rawValue)] Friends-opened chat input did not expose a verifiable value"
            )
        }
        let placeholder: String? = input.attributeOptional(kAXPlaceholderValueAttribute)
        let existingDraft = currentValue == placeholder ? "" : currentValue
        if !existingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.messageInputNotFound.rawValue)] Refusing to replace a non-empty draft in the Friends-opened chat"
            )
        }

        // Real key events keep Kakao's rich composer state in sync. AXValue is
        // only a fallback, and both paths must reflect on an element that is a
        // descendant of the exact window opened above.
        var inputReady = runner.typeTextWithVerification(
            message,
            on: input,
            label: "friend first-message input",
            attempts: 1
        ) && input.stringValue == message
        if !inputReady {
            inputReady = runner.setTextWithVerification(
                message,
                on: input,
                label: "friend first-message input",
                attempts: 1
            ) && input.stringValue == message
        }
        guard inputReady,
              exactChatWindowIsFocused(chatWindow),
              exactChatMessageInputHasFocus(input, in: chatWindow),
              isSameOrDescendant(input, of: chatWindow)
        else {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.inputNotReflected.rawValue)] First message did not reflect in the Friends-opened chat"
            )
        }

        // Send once. Do not retry Enter after an ambiguous result: that could
        // duplicate a message. Success requires the exact chat to remain focused
        // and its verified composer value to clear.
        runner.pressEnterKey()
        let sent = runner.waitUntil(
            label: "friend first-message send reflected",
            timeout: 0.8,
            pollInterval: 0.05,
            evaluateAfterTimeout: false
        ) {
            guard exactChatWindowIsFocused(chatWindow) else { return false }
            if let value = input.stringValue {
                return value.isEmpty
            }
            if let replacement = focusedExactChatMessageInput(in: chatWindow),
               let value = replacement.stringValue
            {
                return value.isEmpty
            }
            return false
        }
        guard sent else {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.messageSendNotConfirmed.rawValue)] First-message send was not confirmed in the Friends-opened chat"
            )
        }
        runner.log("friend add: first message sent through exact Friends-opened chat window")
    }

    private func confirmChatIdentity(
        chatTitle: String,
        opener: String,
        mainListWindow: UIElement
    ) throws -> String {
        let normalizedTitle = ChatTextNormalizer.normalize(chatTitle)
        let normalizedOpener = ChatTextNormalizer.normalize(opener)
        guard !normalizedTitle.isEmpty, !normalizedOpener.isEmpty else {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.chatIdentityNotConfirmed.rawValue)] Chat title or opener could not be normalized"
            )
        }

        // Keep the exact conversation window alive in openedChatWindow while
        // temporarily bringing the main list to Chats. The outer defer raises
        // that same AX handle again on both success and failure.
        kakao.activate()
        runner.pressCommandTwo()
        Thread.sleep(forTimeInterval: 0.25)
        do {
            try AXPathCacheStore.shared.clear(slots: [.chatListContainer, .chatRowTitle, .chatRowPreview])
        } catch {
            runner.log("friend identity: chat-list cache clear failed (\(error))")
        }

        let scanner = ChatListScanner()
        for attempt in 1...4 {
            let listWindow = kakao.chatListWindow ?? mainListWindow
            let snapshots = scanner.scan(in: listWindow, limit: 40, trace: { runner.log($0) })

            if scanner.looksLikeFriendsList(snapshots, trace: { runner.log($0) }) {
                runner.log("friend identity attempt \(attempt): main list still shows Friends")
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            let matches = snapshots.enumerated().filter { _, snapshot in
                guard let lastMessage = snapshot.discovery.lastMessage else { return false }
                return ChatTextNormalizer.normalize(snapshot.discovery.title) == normalizedTitle &&
                    ChatTextNormalizer.normalize(lastMessage) == normalizedOpener
            }

            if matches.count > 1 {
                throw KakaoTalkError.actionFailed(
                    "[\(ContactAutomationFailureCode.chatIdentityNotConfirmed.rawValue)] Multiple chat rows matched the exact title and opener"
                )
            }

            if let match = matches.first {
                let registry = ChatIdentityRegistryStore.shared
                let assignedIDs = registry.assignChatIDs(for: snapshots.map(\.discovery))
                guard assignedIDs.indices.contains(match.offset) else {
                    throw KakaoTalkError.actionFailed(
                        "[\(ContactAutomationFailureCode.chatIdentityNotConfirmed.rawValue)] Matched chat row had no registry position"
                    )
                }
                let chatID = assignedIDs[match.offset]
                guard !chatID.isEmpty else {
                    throw KakaoTalkError.actionFailed(
                        "[\(ContactAutomationFailureCode.chatIdentityNotConfirmed.rawValue)] Matched chat row did not receive a registry id"
                    )
                }
                runner.log(
                    "friend identity: confirmed unique row title='\(match.element.discovery.title)' chat_id='\(chatID)'"
                )
                return chatID
            }

            runner.log("friend identity attempt \(attempt): exact title/opener row not visible")
            Thread.sleep(forTimeInterval: 0.2)
        }

        throw KakaoTalkError.actionFailed(
            "[\(ContactAutomationFailureCode.chatIdentityNotConfirmed.rawValue)] No unique chat row matched the exact title and opener"
        )
    }

    private func resolveExactChatMessageInput(in chatWindow: UIElement) -> UIElement? {
        if let focused = focusedExactChatMessageInput(in: chatWindow) {
            runner.log("friend message input: resolved from exact-window focus")
            return focused
        }

        let candidates = chatWindow.findAll(where: { element in
            let role = element.role ?? ""
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            return role == kAXTextAreaRole || role == kAXTextFieldRole || editable
        }, limit: 32, maxNodes: 800)
        if let input = bestExactChatMessageInput(candidates, in: chatWindow) {
            runner.log("friend message input: resolved from bounded exact-window scan")
            return input
        }

        // Some Kakao builds omit the rich composer from AXChildren. Hit-testing
        // a few central points in the bottom portion of this exact window can
        // still expose its leaf element without traversing the transcript.
        guard let frame = chatWindow.frame, frame.width > 0, frame.height > 0 else { return nil }
        let probePoints = [
            CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.82),
            CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.88),
            CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.76),
        ]

        for point in probePoints {
            guard exactChatWindowIsFocused(chatWindow),
                  let hit = try? kakao.applicationElement.element(at: point),
                  isSameOrDescendant(hit, of: chatWindow)
            else { continue }

            if let input = bestExactChatMessageInput(inputCandidates(around: hit), in: chatWindow) {
                runner.log("friend message input: resolved by exact-window hit test")
                return input
            }

            guard isSafeComposerFocusProbe(hit, at: point, in: chatWindow) else { continue }
            runner.mouseClick(at: point, label: "friend message composer probe")
            let focused = runner.waitUntil(
                label: "friend message composer probe focus",
                timeout: 0.25,
                pollInterval: 0.04
            ) {
                focusedExactChatMessageInput(in: chatWindow) != nil
            }
            if focused, let input = focusedExactChatMessageInput(in: chatWindow) {
                runner.log("friend message input: resolved from exact-window probe focus")
                return input
            }
        }

        runner.log("friend message input: no candidate inside exact Friends-opened chat window")
        return nil
    }

    private func focusExactChatMessageInput(_ input: UIElement, in chatWindow: UIElement) -> UIElement? {
        guard isExactChatMessageInput(input, in: chatWindow), exactChatWindowIsFocused(chatWindow) else {
            return nil
        }

        _ = runner.focusWithVerification(input, label: "friend first-message input", attempts: 1)
        if let focused = focusedExactChatMessageInput(in: chatWindow) {
            return focused
        }

        if let frame = input.frame {
            runner.mouseClick(at: CGPoint(x: frame.midX, y: frame.midY), label: "friend first-message input")
            _ = runner.waitUntil(label: "friend first-message input focused", timeout: 0.3, pollInterval: 0.04) {
                focusedExactChatMessageInput(in: chatWindow) != nil
            }
        }
        return focusedExactChatMessageInput(in: chatWindow)
    }

    private func focusedExactChatMessageInput(in chatWindow: UIElement) -> UIElement? {
        guard exactChatWindowIsFocused(chatWindow),
              let focused = kakao.applicationElement.focusedUIElement,
              isSameOrDescendant(focused, of: chatWindow)
        else { return nil }
        return bestExactChatMessageInput(inputCandidates(around: focused), in: chatWindow)
    }

    private func exactChatMessageInputHasFocus(_ input: UIElement, in chatWindow: UIElement) -> Bool {
        guard exactChatWindowIsFocused(chatWindow),
              let focused = kakao.applicationElement.focusedUIElement,
              isSameOrDescendant(focused, of: chatWindow)
        else { return false }
        return sameElement(focused, input) ||
            isSameOrDescendant(focused, of: input) ||
            isSameOrDescendant(input, of: focused)
    }

    private func inputCandidates(around element: UIElement) -> [UIElement] {
        var candidates = [element]
        var cursor = element.parent
        var hops = 0
        while let current = cursor, hops < 8 {
            candidates.append(current)
            cursor = current.parent
            hops += 1
        }
        candidates.append(contentsOf: element.findAll(where: { candidate in
            let role = candidate.role ?? ""
            let editable: Bool = candidate.attributeOptional(kAXEditableAttribute) ?? false
            return role == kAXTextAreaRole || role == kAXTextFieldRole || editable
        }, limit: 12, maxNodes: 64))
        return deduplicate(candidates)
    }

    private func bestExactChatMessageInput(_ candidates: [UIElement], in chatWindow: UIElement) -> UIElement? {
        candidates
            .filter { isExactChatMessageInput($0, in: chatWindow) }
            .max { lhs, rhs in
                exactChatMessageInputScore(lhs, in: chatWindow) < exactChatMessageInputScore(rhs, in: chatWindow)
            }
    }

    private func isExactChatMessageInput(_ element: UIElement, in chatWindow: UIElement) -> Bool {
        guard isSameOrDescendant(element, of: chatWindow) else { return false }
        let enabled: Bool? = element.attributeOptional(kAXEnabledAttribute)
        guard enabled != false else { return false }

        let role = element.role ?? ""
        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        guard role == kAXTextAreaRole || role == kAXTextFieldRole || editable else { return false }
        guard role != kAXStaticTextRole, role != kAXImageRole, element.subrole != "AXSearchField" else {
            return false
        }
        let text = normalize(elementText(element))
        guard !text.contains("검색"), !text.contains("search") else { return false }

        guard let windowFrame = chatWindow.frame,
              let elementFrame = element.frame,
              windowFrame.width > 0,
              windowFrame.height > 0,
              windowFrame.insetBy(dx: -4, dy: -4).intersects(elementFrame)
        else { return false }
        let relativeY = (elementFrame.midY - windowFrame.minY) / windowFrame.height
        return relativeY > 0.52 && elementFrame.width > windowFrame.width * 0.18
    }

    private func exactChatMessageInputScore(_ element: UIElement, in chatWindow: UIElement) -> Double {
        let role = element.role ?? ""
        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        var score = role == kAXTextAreaRole ? 10_000.0 : (role == kAXTextFieldRole ? 8_000.0 : 0.0)
        if editable { score += 4_000.0 }
        if element.isFocused { score += 2_000.0 }
        if let windowFrame = chatWindow.frame, let elementFrame = element.frame, windowFrame.width > 0 {
            score += Double(elementFrame.width / windowFrame.width) * 1_000.0
            score += Double((elementFrame.midY - windowFrame.minY) / max(windowFrame.height, 1.0)) * 500.0
        }
        return score
    }

    private func isSafeComposerFocusProbe(_ hit: UIElement, at point: CGPoint, in chatWindow: UIElement) -> Bool {
        guard isSameOrDescendant(hit, of: chatWindow), let windowFrame = chatWindow.frame else { return false }
        let relativeX = (point.x - windowFrame.minX) / max(windowFrame.width, 1.0)
        let relativeY = (point.y - windowFrame.minY) / max(windowFrame.height, 1.0)
        guard relativeX > 0.3, relativeX < 0.7, relativeY > 0.7 else { return false }

        let role = hit.role ?? ""
        let blockedRoles: Set<String> = [
            kAXButtonRole, kAXImageRole, kAXCheckBoxRole, "AXLink", "AXMenuItem", "AXPopUpButton",
        ]
        if blockedRoles.contains(role) { return false }
        if role == kAXStaticTextRole {
            let text = normalize(elementText(hit))
            return text.contains("메시지") || text.contains("message") || text.contains("입력")
        }
        return true
    }

    private func exactChatWindowIsFocused(_ chatWindow: UIElement) -> Bool {
        guard let focusedWindow = kakao.focusedWindow,
              sameElement(focusedWindow, chatWindow),
              kakao.windows.contains(where: { sameElement($0, chatWindow) })
        else { return false }
        return true
    }

    private func isSameOrDescendant(_ element: UIElement, of ancestor: UIElement) -> Bool {
        var cursor: UIElement? = element
        var visited: [UIElement] = []
        var hops = 0
        while let current = cursor, hops < 16 {
            if sameElement(current, ancestor) { return true }
            if visited.contains(where: { sameElement($0, current) }) { return false }
            visited.append(current)
            cursor = current.parent
            hops += 1
        }
        return false
    }

    private func findFreshChatStartAction(
        preferredRoot: UIElement,
        mainListWindow: UIElement,
        windowsBeforeStart: [UIElement],
        matching patterns: [String]
    ) -> (element: UIElement, root: UIElement)? {
        var roots: [UIElement] = []
        if let focused = kakao.focusedWindow,
           !windowsBeforeStart.contains(where: { sameElement($0, focused) })
        {
            roots.append(focused)
        }
        roots.append(contentsOf: kakao.windows.reversed().filter { window in
            !windowsBeforeStart.contains(where: { sameElement($0, window) })
        })
        if let popover = findPopover(in: mainListWindow) ?? kakao.mainWindow.flatMap({ findPopover(in: $0) }) {
            roots.append(popover)
        }
        roots.append(preferredRoot)

        for root in deduplicate(roots) {
            if let bottomAction = bottomButton(in: root, matching: patterns) {
                return (bottomAction, root)
            }
            if let action = findActionCandidate(in: root, matching: patterns) {
                return (action, root)
            }
        }
        return nil
    }

    private func pressOneToOneChat(_ action: UIElement) throws {
        // Kakao's result/profile actions can advertise AXPress while ignoring
        // it. Use the same real click required by the add confirmation.
        if let frame = action.frame {
            runner.mouseClick(at: CGPoint(x: frame.midX, y: frame.midY), label: "friend 1:1 chat")
            return
        }
        guard activate(action, label: "friend 1:1 chat") else {
            throw KakaoTalkError.actionFailed(
                "[\(ContactAutomationFailureCode.chatStartUINotFound.rawValue)] Could not activate 1:1 chat action"
            )
        }
    }

    private func findInputReadyChatWindow(
        friendName: String,
        excluding mainListWindow: UIElement,
        windowsBeforeStart: [UIElement],
        focusedWindowBeforeStart: UIElement?
    ) -> UIElement? {
        var candidates: [UIElement] = []
        let focusedWindowAfterClick = kakao.focusedWindow
        if let focusedWindowAfterClick {
            candidates.append(focusedWindowAfterClick)
        }
        candidates.append(contentsOf: kakao.windows.reversed())

        let normalizedFriendName = normalize(friendName)
        return deduplicate(candidates).compactMap { window -> (window: UIElement, score: Int)? in
            guard !sameElement(window, mainListWindow), usableChatTitle(window.title) != nil else { return nil }

            let isNewWindow = !windowsBeforeStart.contains { sameElement($0, window) }
            let isFocusedAfterClick = focusedWindowAfterClick.map { sameElement($0, window) } ?? false
            let focusChanged = isFocusedAfterClick &&
                !(focusedWindowBeforeStart.map { sameElement($0, window) } ?? false)
            let normalizedTitle = normalize(window.title ?? "")
            let titleMatches = !normalizedFriendName.isEmpty &&
                (normalizedTitle == normalizedFriendName || normalizedTitle.contains(normalizedFriendName) ||
                    normalizedFriendName.contains(normalizedTitle))
            let strongTitleMatch = !normalizedFriendName.isEmpty && normalizedTitle == normalizedFriendName
            let openedByThisClick = (isNewWindow || focusChanged) && titleMatches
            guard openedByThisClick else { return nil }

            // Names are not a reliable discriminator: Kakao decorates the
            // Friend result but may shorten the chat title. Prefer a bounded
            // composer scan, but Kakao builds that expose no editable AX node
            // can still be recognized by the click-caused window/focus change.
            // The pre-click snapshot and vanished 1:1 action keep the profile
            // window from satisfying this structural fallback.
            let stillShowsChatStartAction = hasOneToOneChatAction(in: window)
            let structuralCandidate = isNewWindow && focusChanged && strongTitleMatch && !stillShowsChatStartAction
            let structuralTransition = structuralCandidate && isStableStructuralChatWindow(
                window,
                normalizedTitle: normalizedTitle
            )
            let hasComposer = structuralTransition ? false : hasChatComposer(
                in: window,
                stillShowsChatStartAction: stillShowsChatStartAction
            )
            runner.log(
                "friend chat candidate title='\(window.title ?? "")' new=\(isNewWindow) " +
                    "focusChanged=\(focusChanged) titleMatches=\(titleMatches) " +
                    "startAction=\(stillShowsChatStartAction) composer=\(hasComposer) structural=\(structuralTransition)"
            )
            guard hasComposer || structuralTransition else { return nil }

            var score = 0
            if titleMatches { score += 2_000 }
            if isNewWindow { score += 1_000 }
            if focusChanged { score += 500 }
            return (window, score)
        }
        .max { $0.score < $1.score }?
        .window
    }

    private func isStableStructuralChatWindow(_ window: UIElement, normalizedTitle: String) -> Bool {
        Thread.sleep(forTimeInterval: 0.12)
        guard let focused = kakao.focusedWindow,
              sameElement(focused, window),
              kakao.windows.contains(where: { sameElement($0, window) }),
              normalize(window.title ?? "") == normalizedTitle,
              !hasOneToOneChatAction(in: window)
        else { return false }
        return true
    }

    private func hasChatComposer(in root: UIElement, stillShowsChatStartAction: Bool) -> Bool {
        let candidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let role = element.role ?? ""
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            return role == kAXTextAreaRole || role == kAXTextFieldRole || editable
        }, limit: 32, maxNodes: 800)

        let matched = candidates.first { element in
            let role = element.role ?? ""
            guard role != kAXStaticTextRole, role != kAXImageRole, element.subrole != "AXSearchField" else {
                return false
            }

            let text = normalize(elementText(element))
            guard !text.contains("검색"), !text.contains("search") else { return false }
            let isMessageLabeled = (text.contains("메시지") || text.contains("message") || text.contains("입력")) &&
                !text.contains("상태") && !text.contains("profile") && !text.contains("프로필")
            // Kakao's rich-text composer is not stable across builds: some
            // versions expose a custom editable AXGroup instead of AXTextArea.
            // Its bottom/wide geometry still distinguishes it from profile and
            // search controls, so retain custom editable candidates here.
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            let customComposer = (role == kAXTextFieldRole || editable) && !stillShowsChatStartAction
            guard role == kAXTextAreaRole || isMessageLabeled || customComposer else { return false }

            guard let rootFrame = root.frame, let elementFrame = element.frame,
                  rootFrame.height > 0, rootFrame.width > 0
            else { return role == kAXTextAreaRole || isMessageLabeled || customComposer }

            let relativeY = (elementFrame.midY - rootFrame.minY) / rootFrame.height
            return relativeY > 0.5 && elementFrame.width > rootFrame.width * 0.25
        }
        if matched == nil, !candidates.isEmpty {
            let sample = candidates.prefix(4).map { element in
                let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
                return "role=\(element.role ?? "") subrole=\(element.subrole ?? "") editable=\(editable)"
            }.joined(separator: ", ")
            runner.log("friend composer candidates rejected: \(sample)")
        }
        return matched != nil
    }

    private func hasOneToOneChatAction(in root: UIElement) -> Bool {
        // Keep this narrower than the action-discovery patterns above: an
        // input-ready chat can itself expose a "메시지 보내기" control.
        let patterns = ["1:1 채팅", "1:1대화", "채팅하기", "대화하기"]
        let candidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let role = element.role ?? ""
            return role == kAXButtonRole || role == kAXStaticTextRole || role == kAXRowRole || role == kAXCellRole
        }, limit: 32, maxNodes: 800)
        return candidates.contains { scoreElement($0, matching: patterns) > 100 }
    }

    private func usableChatTitle(_ rawTitle: String?) -> String? {
        guard let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        let normalized = normalize(title)
        // AX identity already excludes the main list window. Only reject its
        // truly generic app title; users can legitimately be named "친구" or
        // "Chats" and those titles must remain usable.
        let genericTitles: Set<String> = ["카카오톡", "kakaotalk"]
        return genericTitles.contains(normalized) ? nil : title
    }

    private func findActionCandidate(in root: UIElement, matching patterns: [String]) -> UIElement? {
        let candidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let role = element.role ?? ""
            return role == kAXButtonRole || role == "AXMenuButton" || role == "AXPopUpButton" ||
                role == kAXStaticTextRole || role == kAXRowRole || role == kAXCellRole
        }, limit: 120, maxNodes: 1_800)

        return candidates.map { element in
            (element: element, score: scoreElement(element, matching: patterns))
        }
        .filter { $0.score > 0 }
        .max { $0.score < $1.score }?
        .element
    }

    private func closeTransientProfileWindowIfNeeded(
        _ actionRoot: UIElement,
        chatWindow: UIElement,
        mainListWindow: UIElement
    ) {
        guard actionRoot.role == kAXWindowRole,
              !sameElement(actionRoot, chatWindow),
              !sameElement(actionRoot, mainListWindow),
              kakao.windows.contains(where: { sameElement($0, actionRoot) })
        else { return }

        if supportsAction("AXClose", on: actionRoot) {
            do {
                try actionRoot.performAction("AXClose")
                runner.log("friend add: closed transient friend profile window")
                return
            } catch {
                runner.log("friend add: transient profile AXClose failed (\(error))")
            }
        }
        if tryRaiseWindow(actionRoot, label: "transient friend profile") {
            runner.pressCommandW()
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    private func deduplicate(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        for element in elements where !unique.contains(where: { sameElement($0, element) }) {
            unique.append(element)
        }
        return unique
    }

    private func requireBestTextInput(in root: UIElement, label: String) throws -> UIElement {
        guard let input = locateSearchField(in: root) ?? findBestTextInput(in: root) else {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.searchFieldNotFound.rawValue)] \(label) not found")
        }
        return input
    }

    private func setText(_ text: String, on input: UIElement, label: String) throws {
        guard runner.focusWithVerification(input, label: label, attempts: 2) else {
            throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.inputNotReflected.rawValue)] Could not focus \(label)")
        }
        _ = runner.setTextWithVerification("", on: input, label: "\(label) clear", attempts: 1)
        // KakaoTalk's ID search only reacts to real key events — setting AXValue
        // fills the field but never triggers the search (the popover keeps its
        // "검색을 허용한 친구만…" placeholder). Type the id; fall back to AXValue
        // injection only if typing fails to reflect.
        let ready = runner.typeTextWithVerification(text, on: input, label: label, attempts: 2) ||
            runner.setTextWithVerification(text, on: input, label: label, attempts: 2)
        if !ready {
            throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.inputNotReflected.rawValue)] \(label) did not reflect input")
        }
    }

    private func locateSearchField(in root: UIElement) -> UIElement? {
        let inputs = root.findAll(where: { isTextInput($0) }, limit: 24, maxNodes: 600)
        // Prefer the focused input only when it's inside this scope (the
        // popover). Otherwise the app-wide focused field can be the main
        // window's "내 기본프로필" search box, which must not be used here.
        if let focused = kakao.applicationElement.focusedUIElement, isTextInput(focused),
            inputs.contains(where: { sameElement($0, focused) }) {
            return focused
        }

        let scored = inputs.map { input in
            (input: input, score: scoreTextInput(input))
        }.sorted { lhs, rhs in lhs.score > rhs.score }
        return scored.first(where: { $0.score > 0 })?.input ?? inputs.first
    }

    private func findBestTextInput(in root: UIElement) -> UIElement? {
        let inputs = root.findAll(where: { isTextInput($0) }, limit: 36, maxNodes: 800)
        return inputs.max { lhs, rhs in scoreTextInput(lhs) < scoreTextInput(rhs) }
    }

    private func isTextInput(_ element: UIElement) -> Bool {
        let role = element.role ?? ""
        guard element.isEnabled, role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXComboBox" else {
            return false
        }
        // The friends-list "이름으로 검색" box is an AXSearchField in the main
        // window — never the friend-add ID field. Excluding it prevents typing
        // the ID into the wrong box if the add popover isn't found.
        if element.subrole == "AXSearchField" { return false }
        return true
    }

    private func scoreTextInput(_ element: UIElement) -> Int {
        let joined = elementText(element).lowercased()
        var score = 0
        if joined.contains("search") || joined.contains("검색") || joined.contains("id") || joined.contains("아이디") {
            score += 2_000
        }
        if element.isFocused {
            score += 1_000
        }
        if element.isEnabled {
            score += 300
        }
        if let frame = element.frame {
            if frame.width >= 120 { score += 200 }
            if frame.height >= 20 { score += 100 }
        }
        return score
    }

    private func findButton(in root: UIElement, matching patterns: [String]) -> UIElement? {
        let buttons = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let role = element.role ?? ""
            return role == kAXButtonRole || role == "AXMenuButton" || role == "AXPopUpButton"
        }, limit: 48, maxNodes: 1_200)

        return buttons.map { button in
            (button: button, score: scoreElement(button, matching: patterns))
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in lhs.score > rhs.score }
        .first?.button
    }

    private func findStaticOrButton(in root: UIElement, matching patterns: [String]) -> UIElement? {
        let candidates = root.findAll(where: { element in
            let role = element.role ?? ""
            return role == kAXButtonRole || role == kAXStaticTextRole || role == kAXCellRole || role == kAXRowRole
        }, limit: 80, maxNodes: 1_500)
        return candidates.map { element in
            (element: element, score: scoreElement(element, matching: patterns))
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in lhs.score > rhs.score }
        .first?.element
    }

    private func resolveFriendDisplayName(in root: UIElement, fallback: String) -> String {
        let candidates = root.findAll(where: { element in
            let role = element.role ?? ""
            return role == kAXStaticTextRole || role == kAXCellRole || role == kAXRowRole
        }, limit: 80, maxNodes: 1_500)

        let allTexts = candidates.flatMap { collectTexts($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        runner.log("friend result texts: \(allTexts.joined(separator: " | "))")

        let ignored = ["친구", "추가", "검색", "카카오톡", "id", "아이디", "프로필", "확인"]
        let texts = allTexts
            .filter { text in
                guard text.count >= 2, text.count <= 40 else { return false }
                let lower = text.lowercased()
                // collectTexts includes AX identifiers ("_NS:37") and element
                // refs — never display names. Drop them so the fallback (the
                // kakao id) is used instead of a meaningless internal token.
                if lower.hasPrefix("_ns:") || lower.hasPrefix("axuielement") { return false }
                return !ignored.contains(where: { lower.contains($0) })
            }

        return texts.first ?? fallback
    }

    private func hasAnyText(in root: UIElement, matching patterns: [String]) -> Bool {
        findStaticOrButton(in: root, matching: patterns) != nil
    }

    private func activate(_ element: UIElement, label: String) -> Bool {
        if supportsAction(kAXPressAction, on: element) {
            do {
                try element.press()
                runner.log("\(label): activated via AXPress")
                return true
            } catch {
                runner.log("\(label): AXPress failed (\(error))")
            }
        }

        if supportsAction("AXConfirm", on: element) {
            do {
                try element.performAction("AXConfirm")
                runner.log("\(label): activated via AXConfirm")
                return true
            } catch {
                runner.log("\(label): AXConfirm failed (\(error))")
            }
        }

        if runner.focusWithVerification(element, label: label, attempts: 1) {
            runner.pressEnterKey()
            return true
        }

        if let frame = element.frame {
            runner.mouseDoubleClick(at: CGPoint(x: frame.midX, y: frame.midY), label: label)
            return true
        }

        return false
    }

    private func tryRaiseWindow(_ window: UIElement, label: String = "main list window") -> Bool {
        if supportsAction(kAXRaiseAction, on: window) {
            do {
                try window.performAction(kAXRaiseAction)
                runner.log("friend add: \(label) raised via AXRaise")
                return true
            } catch {
                runner.log("friend add: \(label) AXRaise failed (\(error))")
            }
        }
        return false
    }

    private func waitForNewRoot(after oldRoot: UIElement, label: String) -> UIElement? {
        var newRoot: UIElement?
        _ = runner.waitUntil(label: label, timeout: 1.2, pollInterval: 0.08) {
            let focused = kakao.focusedWindow
            if let focused, !sameElement(focused, oldRoot) {
                newRoot = focused
                return true
            }
            let windows = kakao.windows
            if let last = windows.last, !sameElement(last, oldRoot) {
                newRoot = last
                return true
            }
            return false
        }
        return newRoot
    }

    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        (try? element.actionNames().contains(action)) ?? false
    }

    private func sameElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    private func scoreElement(_ element: UIElement, matching patterns: [String]) -> Int {
        let text = normalize(elementText(element))
        var score = 0
        for pattern in patterns {
            let normalizedPattern = normalize(pattern)
            if text == normalizedPattern {
                score += 5_000
            } else if text.contains(normalizedPattern) {
                score += 2_500
            }
        }
        if element.isEnabled {
            score += 100
        }
        return score
    }

    private func elementText(_ element: UIElement) -> String {
        collectTexts(element).joined(separator: " ")
    }

    private func collectTexts(_ element: UIElement) -> [String] {
        var values: [String] = []
        for value in [element.title, element.axDescription, element.identifier, element.stringValue, element.helpText] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(value)
            }
        }
        for child in element.children.prefix(12) {
            for value in [child.title, child.axDescription, child.identifier, child.stringValue, child.helpText] {
                if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    values.append(value)
                }
            }
        }
        return values
    }

    private func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
