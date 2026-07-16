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
}

struct KakaoContactAutomation {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner

    init(kakao: KakaoTalkApp, runner: AXActionRunner) {
        self.kakao = kakao
        self.runner = runner
    }

    func addFriend(kakaoID: String) throws -> KakaoFriendAddResult {
        // A first conversation does not exist in the Chats tab yet. Friend-add
        // must therefore enter the 1:1 chat from the Friends result/profile and
        // leave that input-ready window exposed for the following `kmsg send`.
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

        let resolvedChatTitle = chatWindow.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chatTitle = resolvedChatTitle.flatMap { title in
            let normalizedTitle = normalize(title)
            let normalizedFriendName = normalize(friendName)
            return !normalizedFriendName.isEmpty &&
                (normalizedTitle == normalizedFriendName || normalizedTitle.contains(normalizedFriendName))
                ? title
                : nil
        } ?? friendName
        return KakaoFriendAddResult(friendName: friendName, chatTitle: chatTitle, externalChatID: nil)
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
                    windowsBeforeStart: windowsBeforeStart
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
        windowsBeforeStart: [UIElement]
    ) -> UIElement? {
        var candidates: [UIElement] = []
        if let focused = kakao.focusedWindow {
            candidates.append(focused)
        }
        candidates.append(contentsOf: kakao.windows.reversed())

        let normalizedFriendName = normalize(friendName)
        return deduplicate(candidates).compactMap { window -> (window: UIElement, score: Int)? in
            guard !sameElement(window, mainListWindow), hasMessageInput(in: window) else {
                return nil
            }

            let isNewWindow = !windowsBeforeStart.contains { sameElement($0, window) }
            let normalizedTitle = normalize(window.title ?? "")
            let titleMatches = !normalizedFriendName.isEmpty &&
                (normalizedTitle == normalizedFriendName || normalizedTitle.contains(normalizedFriendName))
            // A newly opened profile may also expose editable controls. Require
            // the chat window title to identify the intended friend rather than
            // accepting any new input-bearing window.
            guard titleMatches else { return nil }

            var score = 0
            if titleMatches { score += 2_000 }
            if isNewWindow { score += 1_000 }
            if let focused = kakao.focusedWindow, sameElement(focused, window) { score += 500 }
            return (window, score)
        }
        .max { $0.score < $1.score }?
        .window
    }

    private func hasMessageInput(in root: UIElement) -> Bool {
        let candidates = root.findAll(where: { element in
            guard element.isEnabled else { return false }
            let role = element.role ?? ""
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            return role == kAXTextAreaRole || role == kAXTextFieldRole || editable
        }, limit: 72, maxNodes: 900)

        return candidates.contains { element in
            let role = element.role ?? ""
            guard role != kAXStaticTextRole, role != kAXImageRole, element.subrole != "AXSearchField" else {
                return false
            }
            let text = normalize(elementText(element))
            guard !text.contains("검색"), !text.contains("search") else { return false }
            let isMessageLabeled = (text.contains("메시지") || text.contains("message") || text.contains("입력")) &&
                !text.contains("상태") && !text.contains("profile") && !text.contains("프로필")
            guard role == kAXTextAreaRole || isMessageLabeled else { return false }

            if let rootFrame = root.frame, let elementFrame = element.frame, rootFrame.height > 0, rootFrame.width > 0 {
                let relativeY = (elementFrame.midY - rootFrame.minY) / rootFrame.height
                return relativeY > 0.5 && elementFrame.width > rootFrame.width * 0.25
            }
            return role == kAXTextAreaRole
        }
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
