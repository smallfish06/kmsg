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
        // triggerSearch already blocked until the result card (친구 추가 button)
        // appeared, so a match is guaranteed here.
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

    private func openFriendAddUI(from rootWindow: UIElement) throws {
        // The person+ toolbar button has no title/identifier — only
        // AXDescription "친구 추가" (collectTexts includes axDescription, so this
        // exact-matches at the top score). Keep the patterns tight: the loose
        // "친구"/"추가"/"+" fallbacks also matched the sidebar Friends tab
        // (AXHelp "친구 (⌘1)") and could open the wrong thing.
        let patterns = ["친구 추가", "친구추가", "add friend", "add friends"]
        guard let addButton = findButton(in: currentRoot(preferred: rootWindow), matching: patterns) else {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Friend add button not found")
        }
        // The toolbar person+ button ignores AXPress/Enter (custom KakaoTalk
        // control) — only a real mouse click opens the popover. Try activate
        // once, then click the button center, re-checking for the popover each
        // time. addFriend's guard reports the final failure if it never opens.
        for attempt in 0..<3 {
            if attempt == 0 {
                _ = activate(addButton, label: "friend add button")
            } else if let frame = addButton.frame {
                runner.mouseClick(at: CGPoint(x: frame.midX, y: frame.midY), label: "friend add button")
            }
            if waitForPopover(in: rootWindow) != nil {
                return
            }
        }
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
        // A hit renders a result card with its 친구 추가 button at the BOTTOM of
        // the popover; before the result (or with no match) the only 친구 추가
        // elements are the header static text and the 연락처/ID tab row near the
        // top. Keying off a *bottom-half* add button avoids two failure modes we
        // hit live: the no-result notice lingering in the AX tree after a card
        // renders (false timeout), and a slow lookup letting a top tab element
        // satisfy a plain button check before the card exists (early wrong
        // click). Network lookup → wait generously; no bottom button → time out.
        let found = runner.waitUntil(label: "friend search result", timeout: 8.0, pollInterval: 0.15) {
            hasBottomAddButton(in: currentRoot(preferred: root))
        }
        if !found {
            throw KakaoTalkError.elementNotFound("[\(ContactAutomationFailureCode.friendResultNotFound.rawValue)] No user found for this KakaoTalk ID (it may not exist or the user disallows ID search)")
        }
    }

    // True when a 친구 추가 button exists in the bottom half of the add popover —
    // i.e. a result card is showing, not just the header/tab row.
    private func hasBottomAddButton(in root: UIElement) -> Bool {
        let popover = findPopover(in: root) ?? (root.role == "AXPopover" ? root : nil)
        guard let popover, let pf = popover.frame else { return false }
        let threshold = pf.minY + pf.height * 0.5
        let buttons = popover.findAll(where: { ($0.role ?? "") == kAXButtonRole }, limit: 48, maxNodes: 1_200)
        return buttons.contains { button in
            scoreElement(button, matching: ["친구 추가"]) > 100 && (button.frame?.minY ?? 0) > threshold
        }
    }

    private func pressFriendAddConfirmation(in root: UIElement) throws {
        let patterns = ["친구 추가", "추가", "add friend", "add", "확인", "confirm"]
        // The result card's 친구 추가 button sits at the bottom of the popover;
        // the 연락처/ID tab row is near the top. findButton returns the highest-
        // scored match, which on some layouts is a tab — so among all matches
        // pick the lowest one (largest minY) to avoid clicking a tab instead.
        let candidates = root
            .findAll(where: { ($0.role ?? "") == kAXButtonRole || ($0.role ?? "") == "AXMenuButton" }, limit: 48, maxNodes: 1_200)
            .filter { $0.isEnabled && scoreElement($0, matching: patterns) > 100 }
        guard let button = candidates.max(by: { ($0.frame?.minY ?? 0) < ($1.frame?.minY ?? 0) }) else {
            runner.log("friend add: no explicit add button found; assuming existing friend or auto-added result")
            return
        }
        // Like the other popover controls, the confirm button ignores AXPress/
        // Enter — a real mouse click at its center is what commits the add.
        if let frame = button.frame {
            runner.mouseClick(at: CGPoint(x: frame.midX, y: frame.midY), label: "friend add confirmation")
        } else if !activate(button, label: "friend add confirmation") {
            throw KakaoTalkError.actionFailed("[\(ContactAutomationFailureCode.friendAddUINotFound.rawValue)] Could not press friend add confirmation")
        }
        Thread.sleep(forTimeInterval: 0.3)
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
