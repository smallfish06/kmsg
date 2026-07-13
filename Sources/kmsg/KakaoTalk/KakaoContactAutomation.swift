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
}

struct KakaoContactAutomation {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner

    init(kakao: KakaoTalkApp, runner: AXActionRunner) {
        self.kakao = kakao
        self.runner = runner
    }

    func addFriend(kakaoID: String) throws -> KakaoFriendAddResult {
        let rootWindow = try requireUsableWindow()
        try navigateToFriends(in: rootWindow)
        let addRoot = try openFriendAddUI(from: rootWindow)
        // Friend-add happens entirely inside an AXPopover. Scope every step to
        // it: the main window also holds a "내 기본프로필" search field, and
        // without scoping the input lookup grabs that instead of the ID field.
        let popover = waitForPopover(in: rootWindow) ?? addRoot
        try selectKakaoIDMode(in: popover)
        // Re-fetch after the mode switch swaps the popover's contents.
        let idRoot = waitForPopover(in: rootWindow) ?? popover
        let input = try requireBestTextInput(in: idRoot, label: "KakaoTalk ID input")
        try setText(kakaoID, on: input, label: "KakaoTalk ID input")
        try triggerSearch(in: idRoot, input: input)
        let resultRoot = waitForPopover(in: rootWindow) ?? idRoot
        let friendName = resolveFriendDisplayName(in: resultRoot, fallback: kakaoID)
        try pressFriendAddConfirmation(in: resultRoot)
        return KakaoFriendAddResult(friendName: friendName, chatTitle: friendName, externalChatID: nil)
    }

    private func requireUsableWindow() throws -> UIElement {
        if let window = kakao.ensureMainWindow(timeout: 5.0, trace: { message in runner.log(message) }) {
            return window
        }
        throw KakaoTalkError.windowNotFound("[\(ContactAutomationFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable")
    }

    private func currentRoot(preferred: UIElement) -> UIElement {
        kakao.focusedWindow ?? kakao.mainWindow ?? kakao.windows.last ?? preferred
    }

    private func navigateToFriends(in rootWindow: UIElement) throws {
        if let friendsButton = rootWindow.findFirst(identifier: "friends") ?? findButton(in: rootWindow, matching: ["친구", "friends"]) {
            guard activate(friendsButton, label: "friends tab") else {
                throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.friendsTabNotFound.rawValue)] Could not activate Friends tab")
            }
            _ = runner.waitUntil(label: "friends tab content", timeout: 0.5, pollInterval: 0.05) {
                currentRoot(preferred: rootWindow).findFirst(identifier: "friends") != nil
            }
            return
        }
        throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendsTabNotFound.rawValue)] Friends tab button not found")
    }

    private func openFriendAddUI(from rootWindow: UIElement) throws -> UIElement {
        let patterns = [
            "친구 추가", "친구추가", "add friend", "add friends",
            "친구", "추가", "add", "plus", "+"
        ]
        guard let addButton = findButton(in: currentRoot(preferred: rootWindow), matching: patterns) else {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Friend add button not found")
        }
        guard activate(addButton, label: "friend add button") else {
            throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Could not open friend add UI")
        }
        return waitForNewRoot(after: rootWindow, label: "friend add UI") ?? currentRoot(preferred: rootWindow)
    }

    private func selectKakaoIDMode(in root: UIElement) throws {
        // The mode tab is a plain button titled exactly "ID" (KakaoTalk desktop);
        // "id" as an exact-match pattern (scoreElement weights == over contains)
        // selects it. The longer strings cover older/localized builds.
        let patterns = ["id", "카카오톡 id", "카카오톡ID", "카카오 id", "kakao id", "kakaotalk id", "id로", "아이디"]
        if let button = findButton(in: root, matching: patterns) ?? findStaticOrButton(in: root, matching: patterns) {
            _ = activate(button, label: "KakaoTalk ID mode")
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
        let patterns = ["검색", "search", "확인", "다음", "next"]
        if let button = findButton(in: root, matching: patterns) {
            _ = activate(button, label: "friend search button")
        } else if runner.focusWithVerification(input, label: "KakaoTalk ID input", attempts: 1) {
            runner.pressEnterKey()
        }
        let found = runner.waitUntil(label: "friend search result", timeout: 2.0, pollInterval: 0.1) {
            hasAnyText(in: currentRoot(preferred: root), matching: ["친구", "추가", "add", "profile", "프로필"])
        }
        if !found {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendResultNotFound.rawValue)] Friend search result did not appear")
        }
    }

    private func pressFriendAddConfirmation(in root: UIElement) throws {
        let patterns = ["친구 추가", "추가", "add friend", "add", "확인", "confirm"]
        guard let button = findButton(in: currentRoot(preferred: root), matching: patterns) else {
            runner.log("friend add: no explicit add button found; assuming existing friend or auto-added result")
            return
        }
        guard activate(button, label: "friend add confirmation") else {
            throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Could not press friend add confirmation")
        }
        Thread.sleep(forTimeInterval: 0.2)
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
        let ready = runner.setTextWithVerification(text, on: input, label: label, attempts: 2) ||
            runner.typeTextWithVerification(text, on: input, label: label, attempts: 2)
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
        return element.isEnabled && (role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXComboBox")
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

        let ignored = ["친구", "추가", "검색", "카카오톡", "id", "아이디", "프로필", "확인"]
        let texts = candidates.flatMap { collectTexts($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { text in
                guard text.count >= 2, text.count <= 40 else { return false }
                let lower = text.lowercased()
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
