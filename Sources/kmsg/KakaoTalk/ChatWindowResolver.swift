import ApplicationServices.HIServices
import Foundation

enum ChatWindowLayoutMode: String {
    case preserve
    case left
    case right
    case splitLeft = "split-left"
    case splitRight = "split-right"

    var isRightAligned: Bool {
        self == .right || self == .splitRight
    }

    var isSplit: Bool {
        self == .splitLeft || self == .splitRight
    }
}

enum ChatWindowResolutionMethod {
    case existingWindow
    case openedViaChatList
    case openedViaSearch
}

enum ChatWindowInteractionMode {
    case allowUIAutomation
    case backgroundSafe
}

struct ChatWindowResolution {
    let window: UIElement
    let method: ChatWindowResolutionMethod

    var openedViaSearch: Bool {
        method == .openedViaSearch
    }

    var openedTransiently: Bool {
        method != .existingWindow
    }
}

private enum ChatWindowFailureCode: String {
    case backgroundSafeBlocked = "BACKGROUND_SAFE_BLOCKED"
    case focusFail = "FOCUS_FAIL"
    case inputNotReflected = "INPUT_NOT_REFLECTED"
    case windowNotReady = "WINDOW_NOT_READY"
    case searchMiss = "SEARCH_MISS"
    case resolveBudget = "RESOLVE_BUDGET"
    /// 방을 열긴 했는데 그 창의 제목이 요청한 방이 아니다. 종전에는 이 상황에서 포커스된
    /// 창/폴백 창/메인 창 중 채팅 입력창이 있는 아무 창을 돌려줬다 — 그게 남의 방을 읽고
    /// 남의 방에 보내는 경로였다(2026-08-15 talkfriend: 목록 재정렬 사이에 다른 유저의
    /// 창을 읽어 그 유저의 톡이 남의 대화에 섞였다). 이제는 실패다.
    case wrongWindow = "WRONG_WINDOW"
}

/// resolve 전체에 걸리는 시간 예산.
///
/// 방을 못 찾는 해석은 사다리를 끝까지 내려간다 — 제목 200행 훑기 → 레지스트리 스캔 →
/// 이름 검색. 프로덕션 실측(2026-08-09 최희연)에서 그 한 번이 `resolve=18.53` 을 쓰고
/// **결국 실패했다**(같은 15분 구간 p50 0.34s / p90 0.91s).
///
/// 비용은 시간만이 아니다. 브릿지는 계정당 단일 outbound lock 으로 발송을 직렬화하므로
/// 한 방의 18초짜리 헛수고가 그 계정의 모든 답장을 18초 뒤로 민다. **18초 걸려 실패하는
/// 것보다 빨리 실패하는 게 낫다** — 다음 tick 이 어차피 다시 집어간다.
///
/// 기본 8초는 관측된 정상 p90(0.91s)의 아홉 배이면서 위 사고의 절반보다 작다. 새로
/// 붙인 res.list/res.search 계측으로 내역이 드러나면 조인다.
struct ResolveDeadline {
    private let start: DispatchTime
    private let budget: TimeInterval

    static let defaultBudget: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["KMSG_RESOLVE_BUDGET_MS"],
           let ms = Double(raw),
           ms > 0
        {
            return ms / 1000
        }
        return 8.0
    }()

    init(budget: TimeInterval = ResolveDeadline.defaultBudget) {
        self.start = .now()
        self.budget = budget
    }

    var elapsed: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }

    var isExceeded: Bool {
        elapsed >= budget
    }

    func describe(_ step: String) -> String {
        "[\(ChatWindowFailureCode.resolveBudget.rawValue)] gave up before \(step): "
            + String(format: "%.2fs", elapsed) + " spent of a "
            + String(format: "%.2fs", budget) + " resolve budget"
    }
}

private struct SearchScanProfile {
    let label: String
    let timeout: TimeInterval
    let pollInterval: TimeInterval
    let rowLimit: Int
    let cellLimit: Int
    let supplementalLimit: Int
    let candidateNodeBudget: Int
    let textLimit: Int
    let textNodeBudget: Int
    let includeSupplementalRoles: Bool
    let includeApplicationRoot: Bool
}

private struct SearchCandidate {
    let element: UIElement
    let textScore: Int
    let matchedText: String
    /// Screen point captured while the element was still fresh. KakaoTalk invalidates
    /// search-result AX handles within a few hundred ms, so the coordinate must be read
    /// at scan time, not at click time.
    let clickPoint: CGPoint?
}

struct ChatWindowResolver {
    private static let minimumReadableWindowSize = CGSize(width: 760, height: 900)
    private static let minimumSplitWindowSize = CGSize(width: 520, height: 680)
    private static let maximumAutomaticWindowSize = CGSize(width: 1200, height: 1000)
    /// 채팅 목록에서 chat-id 해석이 훑는 행 수. 제목 훑기와 레지스트리 스캔이 **같은**
    /// 값을 써야 한다 — 다르면 뒤엣것이 앞엣것이 이미 본 행을 다시 걷거나, 앞엣것이
    /// 본 행을 뒤엣것이 못 본다.
    ///
    /// **이 지평선이 목록보다 짧으면 그 아래 방은 chat-id 로 원리적으로 못 찾는다.**
    /// 못 찾은 해석은 이름 검색으로 떨어지는데, 검색은 (a) 동명이인이면 카톡이 아무 방이나
    /// 열어주고 (b) 검색어가 목록 필터로 GUI 에 남아 뒤이은 모든 실행을 물려받게 한다
    /// (2026-08-09 09:50 UTC: rows=1 이 153회 연속, 10분간 수신 전면 정지). 200 으로
    /// 굳어 있던 동안 프로덕션 목록이 264행이라 상시 64행이 그 아래였고, 10분 표본에서
    /// `res.rows=200`(지평선 소진) 5건과 `res.search` 5건이 정확히 짝을 이뤘다.
    ///
    /// 기본값은 브릿지의 스캔 지평선(`KMSG_CHAT_SCAN_LIMIT`, 500)과 맞춘다 — 브릿지가
    /// 보는 방은 해석도 볼 수 있어야 한다. 목록이 길어져 walk 가 늘어나는 대가는
    /// `ResolveDeadline` 이 문다(scanUntilTitle 이 25행마다 예산을 확인한다).
    private static let chatListResolveHorizon: Int = {
        if let raw = ProcessInfo.processInfo.environment["KMSG_CHAT_RESOLVE_HORIZON"],
           let rows = Int(raw),
           rows > 0
        {
            return rows
        }
        return 500
    }()

    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner
    private let useCache: Bool
    private let deepRecoveryEnabled: Bool
    private let layoutMode: ChatWindowLayoutMode
    private let interactionMode: ChatWindowInteractionMode
    /// 요약 줄에 실을 사실을 호출자(커맨드의 PhaseProfiler)로 흘린다. runner.log 는
    /// --trace-ax 없이는 안 보이는데 브릿지는 그 플래그 없이 돌아서, resolve 가 어디서
    /// 시간을 썼는지 프로덕션에서 답할 수 있는 창구가 여기뿐이다.
    private let note: (String, String) -> Void

    init(
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        useCache: Bool = true,
        deepRecoveryEnabled: Bool = false,
        layoutMode: ChatWindowLayoutMode = .preserve,
        interactionMode: ChatWindowInteractionMode = .allowUIAutomation,
        note: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.kakao = kakao
        self.runner = runner
        self.useCache = useCache
        self.deepRecoveryEnabled = deepRecoveryEnabled
        self.layoutMode = layoutMode
        self.interactionMode = interactionMode
        self.note = note
    }

    private func noteSeconds(_ key: String, _ seconds: TimeInterval) {
        note(key, String(format: "%.2f", seconds))
    }

    func resolve(query: String) throws -> ChatWindowResolution {
        if interactionMode == .backgroundSafe {
            return try resolveExistingWindowOnly(query: query)
        }

        let usableWindow = try requireUsableWindow()

        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            standardizeReadableWindow(existingWindow, label: "existing chat window")
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        let deadline = ResolveDeadline()
        let searchWindow = selectSearchWindow(fallback: usableWindow)
        standardizeReadableWindow(searchWindow, label: "search root window")
        let chatWindow = try searchStep(deadline) {
            try openChatViaSearch(query: query, in: searchWindow, fallbackWindow: usableWindow, deadline: deadline)
        }
        standardizeReadableWindow(chatWindow, label: "opened chat window")
        return ChatWindowResolution(window: chatWindow, method: .openedViaSearch)
    }

    /// 검색 경로의 벽시계를 요약 줄에 남긴다. 성공·실패 양쪽에서 남겨야 "실패가 왜
    /// 오래 걸렸나"를 답한다.
    private func searchStep(_ deadline: ResolveDeadline, _ body: () throws -> UIElement) rethrows -> UIElement {
        let before = deadline.elapsed
        defer { noteSeconds("res.search", deadline.elapsed - before) }
        return try body()
    }

    func resolve(chatID: String) throws -> ChatWindowResolution {
        guard let record = ChatIdentityRegistryStore.shared.record(for: chatID) else {
            throw KakaoTalkError.elementNotFound("Unknown chat_id '\(chatID)'. Run 'kmsg chats' first to refresh the local registry.")
        }

        if interactionMode == .backgroundSafe {
            return try resolveExistingWindowOnly(query: record.displayName)
        }

        let usableWindow = try requireUsableWindow()
        let query = record.displayName

        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            standardizeReadableWindow(existingWindow, label: "existing chat window")
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        let deadline = ResolveDeadline()
        if let chatListWindow = ensureChatListWindow() {
            let listStart = deadline.elapsed
            let chatWindow = openChatListRow(
                chatID: chatID,
                query: query,
                in: chatListWindow,
                fallbackWindow: usableWindow,
                deadline: deadline
            )
            noteSeconds("res.list", deadline.elapsed - listStart)
            if let chatWindow {
                standardizeReadableWindow(chatWindow, label: "opened chat window")
                return ChatWindowResolution(window: chatWindow, method: .openedViaChatList)
            }
        }

        // 목록 사다리를 다 내려온 뒤라 남은 예산이 얼마 없을 수 있다. 검색은 이 해석에서
        // 가장 비싼 단계이므로 시작 전에 한 번 끊는다.
        guard !deadline.isExceeded else {
            throw KakaoTalkError.actionFailed(deadline.describe("the search fallback"))
        }
        runner.log("chat_id: falling back to search for '\(query)'")
        let searchWindow = selectSearchWindow(fallback: usableWindow)
        standardizeReadableWindow(searchWindow, label: "search root window")
        let chatWindow = try searchStep(deadline) {
            try openChatViaSearch(query: query, in: searchWindow, fallbackWindow: usableWindow, deadline: deadline)
        }
        standardizeReadableWindow(chatWindow, label: "opened chat window")
        return ChatWindowResolution(window: chatWindow, method: .openedViaSearch)
    }

    @discardableResult
    func closeWindow(_ window: UIElement) -> Bool {
        let closeAction = "AXClose"

        kakao.activate()
        _ = tryRaiseWindow(window)

        if supportsAction(closeAction, on: window) {
            do {
                try window.performAction(closeAction)
                if waitForWindowClosed(window, label: "close via AXClose") {
                    return true
                }
            } catch {
                runner.log("close window: AXClose failed (\(error))")
            }
        }

        if let closeButton = findCloseButton(in: window) {
            do {
                try closeButton.press()
                if waitForWindowClosed(window, label: "close via button") {
                    return true
                }
            } catch {
                runner.log("close window: button press failed (\(error))")
            }
        }

        runner.log("close window: fallback via cmd+w")
        runner.pressCommandW()
        return waitForWindowClosed(window, label: "close via cmd+w")
    }

    private func resolveExistingWindowOnly(query: String) throws -> ChatWindowResolution {
        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            runner.log("background-safe: matched already exposed chat window")
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        if let focusedWindow = kakao.focusedWindow,
           titleMatchesExactly(query: query, candidate: focusedWindow.title)
        {
            runner.log("background-safe: matched already focused chat window")
            return ChatWindowResolution(window: focusedWindow, method: .existingWindow)
        }

        throw KakaoTalkError.elementNotFound(
            "[\(ChatWindowFailureCode.backgroundSafeBlocked.rawValue)] No already exposed chat window matched '\(query)'. " +
            "Background-safe mode does not activate KakaoTalk, open chat rows, search, resize, or close windows."
        )
    }

    private func requireUsableWindow() throws -> UIElement {
        if let immediateWindow = kakao.focusedWindow ?? kakao.mainWindow ?? kakao.windows.first {
            runner.log("Usable window found via immediate probe")
            return immediateWindow
        }

        if let usableWindow = kakao.ensureMainWindow(timeout: 0.9, mode: .fast, trace: { message in
            runner.log(message)
        }) {
            return usableWindow
        }

        runner.log("window fast path failed; attempting one-shot open defense")
        if let usableWindow = attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: !deepRecoveryEnabled) {
            return usableWindow
        }

        guard deepRecoveryEnabled else {
            runner.log("window fast path failed; deep recovery disabled")
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable (fast mode)")
        }

        runner.log("window: escalating to full recovery (3.0s)")
        if let usableWindow = kakao.ensureMainWindow(timeout: 3.0, mode: .recovery, trace: { message in
            runner.log(message)
        }) {
            return usableWindow
        }

        throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable")
    }

    private func attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: Bool) -> UIElement? {
        runner.log("window: quick-open defense start")

        let hasVisibleWindow = kakao.focusedWindow != nil || kakao.mainWindow != nil || !kakao.windows.isEmpty
        if forceOpenEvenIfWindowPresent || !hasVisibleWindow {
            if KakaoTalkApp.isRunning {
                if hasVisibleWindow && forceOpenEvenIfWindowPresent {
                    runner.log("window: forcing open /Applications/KakaoTalk.app (fast-mode fallback)")
                } else {
                    runner.log("window: no visible windows; forcing open /Applications/KakaoTalk.app")
                }
                _ = KakaoTalkApp.forceOpen(timeout: 0.8)
            } else {
                runner.log("window: KakaoTalk not running; launching")
                _ = KakaoTalkApp.launch(timeout: 0.8)
            }
        } else {
            runner.log("window: quick-open defense skipped (windows already present)")
        }

        kakao.activate()
        if let usableWindow = kakao.ensureMainWindow(timeout: 0.8, mode: .fast, trace: { message in
            runner.log(message)
        }) {
            runner.log("window: quick-open defense succeeded")
            return usableWindow
        }

        runner.log("window: quick-open defense failed")
        return nil
    }

    private func selectSearchWindow(fallback: UIElement) -> UIElement {
        if let chatListWindow = ensureChatListWindow() {
            runner.log("search root selected: chatListWindow")
            return chatListWindow
        }
        if let mainWindow = kakao.mainWindow {
            runner.log("search root selected: mainWindow")
            return mainWindow
        }
        runner.log("search root selected: fallback usable window")
        return fallback
    }

    /// The chat search field and chat rows live in the chat list window. When only
    /// standalone chat windows are open (e.g. left behind by a previous send/read),
    /// that window is gone and both the row scan and the search fallback would run
    /// against a chat window, which cannot open other chats. KakaoTalk restores the
    /// list window with ⌘2 (chats tab), so recover it before giving up.
    private func ensureChatListWindow() -> UIElement? {
        if let chatListWindow = kakao.chatListWindow {
            return chatListWindow
        }
        guard interactionMode != .backgroundSafe else {
            return nil
        }

        runner.log("chat list: window missing; restoring via cmd+2")
        kakao.activate()
        Thread.sleep(forTimeInterval: 0.08)
        runner.pressCommandTwo()

        var restored: UIElement?
        _ = runner.waitUntil(label: "chat list window restore", timeout: 1.4, pollInterval: 0.08, evaluateAfterTimeout: false) {
            restored = kakao.chatListWindow
            return restored != nil
        }
        if restored == nil {
            runner.log("chat list: restore via cmd+2 failed")
        }
        return restored
    }

    private func openChatViaSearch(
        query: String,
        in rootWindow: UIElement,
        fallbackWindow: UIElement,
        deadline: ResolveDeadline
    ) throws -> UIElement {
        runner.log("search: locating search field")

        guard let searchField = locateSearchField(in: rootWindow) else {
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] Search field not found")
        }

        // 검색은 방을 열면 끝나지만 검색어는 창에 남는다. 그 상태는 프로세스가 아니라
        // 카톡 GUI 에 남으므로 **뒤이어 뜨는 모든 kmsg 실행이 통째로 물려받는다** —
        // 목록이 필터된 채라 `chats` 는 한두 행짜리 결과를 정상으로 돌려주고,
        // `--chat-id` 해석은 그 목록에서 행을 못 찾아 매번 검색 경로로 떨어져 필터를
        // 다시 깐다(스스로 일감을 만드는 고리). 실측 2026-08-09 09:50~10:00 UTC:
        // rows=1 스캔이 153회 연속, 그 10분간 read/send 0건(수신 전면 정지), 복구
        // 직후의 첫 read 는 resolve 에만 16.0s 를 썼다.
        //
        // 그래서 성공·실패를 가리지 않고 나가면서 끈다. 종전에는 실패 경로에만
        // pressEscape 가 있어서, **정확히 잘 된 검색만** 필터를 남겼다.
        //
        // 정리는 목록 창의 검색창에 포커스를 주므로 방금 연 채팅창을 덮을 수 있다.
        // 두 호출자 모두 반환 직후 standardizeReadableWindow 로 그 창을 다시 올리므로
        // (그게 캡처가 가려지지 않는다는 보장이다) 여기서 따로 되돌리지 않는다.
        defer { clearChatListSearch(searchField, in: rootWindow, label: query) }

        guard runner.focusWithVerification(searchField, label: "search field", attempts: 1) else {
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.focusFail.rawValue)] Could not focus search field")
        }

        _ = runner.setTextWithVerification("", on: searchField, label: "search field clear", attempts: 1)

        // KakaoTalk's chat search only reacts to real key events — injecting AXValue
        // fills the field but never triggers the search, so the result list stays
        // empty. Type the query; fall back to AXValue injection only if typing
        // fails to reflect.
        let searchInputReady =
            runner.typeTextWithVerification(query, on: searchField, label: "search field input", attempts: 2) ||
            runner.setTextWithVerification(query, on: searchField, label: "search field input", attempts: 1)

        guard searchInputReady else {
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.inputNotReflected.rawValue)] Search keyword was not entered")
        }

        var matchingCandidates = waitForMatchingSearchResults(query: query, rootWindow: rootWindow)
        if matchingCandidates.isEmpty {
            // 후보 대기는 waitUntil 의 timeout(0.22s/0.75s)보다 훨씬 오래 걸릴 수 있다 —
            // 한 폴 회차가 candidateNodeBudget 만큼 AX 트리를 걷고, waitUntil 은 회차
            // 중간에 끊지 못한다. 그래서 두 번째 대기에 들어가기 전에 예산을 본다.
            guard !deadline.isExceeded else {
                throw KakaoTalkError.actionFailed(deadline.describe("the Enter-commit retry"))
            }
            // Like the friend-add ID search, KakaoTalk's chat search commits on
            // Enter — typing alone can leave the result list unpopulated.
            runner.log("search: no candidates after typing; committing search via Enter")
            if searchField.isFocused || runner.focusWithVerification(searchField, label: "search field commit", attempts: 1) {
                runner.pressEnterKey()
                // Enter can also open the top result outright; take that window if it matches.
                if let opened = resolveOpenedChatWindowFast(query: query) {
                    runner.log("search: Enter opened matching chat directly")
                    return opened
                }
                matchingCandidates = waitForMatchingSearchResults(query: query, rootWindow: rootWindow)
            }
        }
        guard let matchingResult = pickBestSearchResult(from: matchingCandidates) else {
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] No search result found for '\(query)'")
        }

        // 결과를 여는 단계도 여러 번 시도한다(활성화 → 더블클릭 → 선택 → Enter →
        // Down+Enter). 여기까지 예산을 다 썼으면 그 사다리를 시작하지 않는다.
        guard !deadline.isExceeded else {
            throw KakaoTalkError.actionFailed(deadline.describe("opening the matched search result"))
        }
        let openTriggered = triggerSearchResultOpen(
            matchingResult,
            searchField: searchField
        ) {
            resolveOpenedChatWindowFast(query: query) != nil
        }
        guard openTriggered else {
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.searchMiss.rawValue)] Could not open matched search result")
        }

        if let window = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
            return window
        }

        throw KakaoTalkError.windowNotFound("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Chat window for '\(query)' did not open")
    }

    /// 채팅 목록의 검색어를 지운다.
    ///
    /// **값만 비우면(AXValue) 안 된다** — 카톡 검색은 실제 키 이벤트에만 반응해서
    /// (검색어를 넣을 때 타이핑을 쓰는 것과 같은 이유), AXValue 로 비우면 필드는
    /// 비었는데 목록은 필터된 채로 남는다. 그건 지금 상태보다 나쁘다: 눈에 보이는
    /// 증거까지 사라진다.
    ///
    /// 필드를 잡지 못하면 **키를 하나도 보내지 않는다.** 포커스가 다른 창에 있으면
    /// ⌘A 와 delete 가 그 창으로 가고, 그 창은 채팅창일 수 있다.
    private func clearChatListSearch(_ searchField: UIElement, in rootWindow: UIElement, label: String) {
        guard !(searchField.stringValue ?? "").isEmpty else { return }

        // AX 포커스와 키 이벤트의 목적지는 다른 축이다. focusWithVerification 은 AX
        // 속성을 세팅할 뿐이고, pressCommandA/pressDeleteKey 는 CGEvent 라 **프론트모스트
        // 앱**으로 간다 — 카톡을 올리지 않으면 그 키는 이 프로세스를 띄운 터미널로 간다
        // (첫 판이 정확히 그래서 "FAILED to clear" 로 죽었다). 이 파일의 다른 키 입력
        // 자리들이 전부 activate 를 먼저 부르는 이유가 이거다.
        kakao.activate()
        _ = tryRaiseWindow(rootWindow)
        Thread.sleep(forTimeInterval: 0.08)

        guard runner.focusWithVerification(searchField, label: "search field clear", attempts: 1) else {
            runner.log("search: could not focus the field to clear '\(label)' — the chat list may stay filtered")
            return
        }

        runner.pressCommandA()
        runner.pressDeleteKey()

        var cleared = runner.waitUntil(
            label: "search field emptied",
            timeout: 0.3,
            pollInterval: 0.05,
            evaluateAfterTimeout: true
        ) {
            (searchField.stringValue ?? "").isEmpty
        }

        // 필드를 잡은 상태에서의 Escape 는 검색을 통째로 끝낸다(NSSearchField 기본 동작).
        // 한 번 더 쓰는 이유는 실패의 대가가 비대칭이라서다 — 여기서 못 지우면 다음
        // 스캔들이 필터된 목록을 정상 결과로 돌려준다.
        if !cleared {
            runner.log("search: cmd+A/delete did not empty '\(label)'; retrying with escape")
            runner.pressEscapeKey()
            cleared = runner.waitUntil(
                label: "search field emptied (escape)",
                timeout: 0.3,
                pollInterval: 0.05,
                evaluateAfterTimeout: true
            ) {
                (searchField.stringValue ?? "").isEmpty
            }
        }
        // 실패는 조용히 넘어가면 안 된다: 다음 `chats` 가 필터된 목록을 정상 결과로
        // 돌려주는 게 바로 여기서 시작한다.
        runner.log(cleared ? "search: cleared '\(label)' from the chat list search field"
                           : "search: FAILED to clear '\(label)' — the chat list is still filtered")
    }

    /// 목록이 남은 검색어로 필터돼 있으면 지운다. 지웠으면 true.
    ///
    /// 위의 정리와 중복이지만 겨냥하는 게 다르다 — 저건 우리가 만든 잔재를 그 자리에서
    /// 치우는 것이고, 이건 **누가 남겼든** (사람이 그 Mac 에서 직접 검색창에 타이핑한
    /// 경우 포함) 다음 스캔 한 번으로 회복시키는 그물이다. 잔재의 대가가 수신 전면
    /// 정지라서, 정리 한 곳에만 걸어두지 않는다.
    @discardableResult
    func clearChatListSearchIfDirty(in window: UIElement) -> Bool {
        guard interactionMode != .backgroundSafe else { return false }
        // 검색창을 "찾아내려고" 버튼을 누르지는 않는다(locateSearchField 의 마지막
        // 수단). 이건 매 tick 도는 경로라 그 부작용이 상시화된다.
        guard let searchField = findExistingSearchField(in: window) else { return false }
        let residue = searchField.stringValue ?? ""
        guard !residue.isEmpty else { return false }

        runner.log("chats: chat list search field still holds '\(residue)' — clearing it before the scan")
        clearChatListSearch(searchField, in: window, label: residue)
        return (searchField.stringValue ?? "").isEmpty
    }

    private var titleScanHorizon: Int { Self.chatListResolveHorizon }

    private func openChatListRow(
        chatID: String,
        query: String,
        in chatListWindow: UIElement,
        fallbackWindow: UIElement,
        deadline: ResolveDeadline
    ) -> UIElement? {
        runner.log("chat_id: scanning chat list rows")
        standardizeReadableWindow(chatListWindow, label: "chat list window")
        let scanner = ChatListScanner()
        let registry = ChatIdentityRegistryStore.shared

        // Widen the scan instead of extracting all 200 rows up front: each
        // row's title/preview costs an AX round-trip (~0.1s), so a full scan
        // ran 20+ seconds while the target of a badge-triggered read — the
        // chat that JUST received a message — sits at the top of the list.
        // Rows already scanned keep their relative order at every horizon, so
        // id assignment for the found prefix matches what a full scan would
        // assign except when a same-title chat first appears beyond the
        // current horizon — a case the server refuses to bind anyway.
        //
        // **목록은 한 번만 걷는다.** 종전에는 제목 훑기와 레지스트리 스캔이 같은 200행을
        // 각각 한 번씩 걸어 미스 경로가 400 walk 였는데, 사다리를 끝까지 내려가는 것이
        // 바로 그 미스 경로다. 프로덕션 실측(2026-08-09, 재시작 직후 sweep n=121):
        // res.list 합 568s(n=102) 대 res.search 합 116s(n=44) — 목록이 비용의 대부분이다.
        // scanUntilTitle 은 걸으면서 스냅샷을 모으고 제목이 맞으면 거기서 멈추므로,
        // 적중은 예전처럼 몇 행에서 끝나고 미스는 walk 가 절반이 된다.
        //
        // 끊는 자리는 스캔 앞과 스캔 안 두 곳이다. 지평선이 목록보다 짧던 동안에는 walk
        // 최악값이 지평선에 묶여 앞에서만 끊어도 됐지만, 지평선을 목록 길이까지 열면 그
        // 상한이 같이 풀린다. scanUntilTitle 이 25행마다 예산을 확인한다(행마다가 아니다).
        guard !deadline.isExceeded else {
            runner.log("chat_id: \(deadline.describe("the chat list scan"))")
            return nil
        }
        var (titleMatch, snapshots, stoppedEarly) = scanner.scanUntilTitle(
            query,
            in: chatListWindow,
            limit: titleScanHorizon,
            shouldStop: { deadline.isExceeded },
            trace: { message in runner.log(message) }
        )
        note("res.rows", String(snapshots.count))
        if stoppedEarly {
            note("res.cut", "1")
        }
        if let titleMatch {
            runner.log("chat_id: matched row by title '\(query)'")
            return openMatchedRow(titleMatch, query: query, in: chatListWindow, fallbackWindow: fallbackWindow)
        }

        guard !snapshots.isEmpty else {
            runner.log("chat_id: chat list scan returned no rows")
            return nil
        }

        // The main window sitting on the friends tab scans "successfully"
        // but yields friend rows whose titles never match a chat — the scan
        // then falls back to search, wasting ~10s. Mirror ChatsCommand:
        // detect the timestamp-less friends list and switch to the chats
        // tab (⌘2) once.
        if scanner.looksLikeFriendsList(snapshots, in: chatListWindow, trace: { runner.log($0) }) {
            runner.log("chat_id: scan looks like the FRIENDS list — switching to the chats tab (⌘2) and rescanning")
            kakao.activate()
            runner.pressCommandTwo()
            Thread.sleep(forTimeInterval: 0.4)
            let recovered = scanner.scanUntilTitle(
                query,
                in: chatListWindow,
                limit: titleScanHorizon,
                shouldStop: { deadline.isExceeded },
                trace: { message in runner.log(message) }
            )
            if let recoveredMatch = recovered.match {
                runner.log("chat_id: matched row by title '\(query)' after tab recovery")
                return openMatchedRow(recoveredMatch, query: query, in: chatListWindow, fallbackWindow: fallbackWindow)
            }
            guard !recovered.snapshots.isEmpty else {
                runner.log("chat_id: chat list scan returned no rows after tab recovery")
                return nil
            }
            snapshots = recovered.snapshots
        }

        // 제목이 정확히 안 맞아도 여기서 걸릴 수 있다. 판정 기준이 다르기 때문이다 —
        // 위는 제목 완전일치이고 여기는 chat id, 즉 정규화한 제목의 해시다. 공백·문장부호·
        // 대소문자만 다른 방과 동명이인 접미사(_2)는 이 판정에서만 갈린다. 그래서 걷기는
        // 합쳐도 판정은 둘 다 남긴다.
        let assignedIDs = registry.assignChatIDs(for: snapshots.map(\.discovery))
        guard let matchIndex = assignedIDs.firstIndex(of: chatID) else {
            note("res.miss", "absent")
            runner.log("chat_id: no visible chat row matched \(chatID) in top \(snapshots.count) rows")
            return nil
        }

        let row = snapshots[matchIndex].element
        note("res.miss", Self.titleMissKind(expected: query, found: snapshots[matchIndex].discovery.title))
        note("res.idx", String(matchIndex + 1))
        runner.log("chat_id: matched row title='\(snapshots[matchIndex].discovery.title)'")
        return openMatchedRow(row, query: query, in: chatListWindow, fallbackWindow: fallbackWindow)
    }

    /// 제목 fast path 가 빗나간 이유를 한 낱말로 요약한다.
    ///
    /// 여기까지 왔다는 것은 목록을 끝까지 걷고도 제목이 안 맞았고, 그 뒤 chat id 판정이
    /// 방을 찾았다는 뜻이다. 프로덕션 10분 표본에서 `res.rows` 가 151·160·200 처럼 서로
    /// 다른 방에서 **같은 값**으로 반복됐다 — 방이 깊은 곳에 있는 것이 아니라 walk 가
    /// 소진된 것이고, 그 구간이 해석 비용의 30%다. 원인을 모르면 고칠 수 없는데 브릿지는
    /// `--trace-ax` 없이 돌아 runner.log 가 안 보이므로, 요약 줄에 실을 수 있는 형태로
    /// 남긴다.
    ///
    /// 제목 자체는 남기지 않는다 — 이 줄은 API 파드 로그로 흘러가고 방 제목은 사용자의
    /// 표시 이름이다. 원인을 가르는 데 필요한 것은 문자열이 아니라 **어긋난 방식**이다.
    ///
    /// - `norm`: 정규화하면 같다 (공백·문장부호·대소문자 차이)
    /// - `trunc`: 한쪽이 다른 쪽의 접두사다 (창 폭에 따라 말줄임된 제목이 유력한 가설)
    /// - `diff`: 아예 다른 문자열 (레지스트리의 displayName 이 낡았다는 뜻)
    /// - `absent`: id 판정도 못 찾았다 (걸은 행 안에 그 방이 없다 — 지평선/스캔 문제)
    private static func titleMissKind(expected: String, found: String) -> String {
        if expected == found { return "none" }
        let expectedKey = ChatTextNormalizer.normalizeForMatch(expected)
        let foundKey = ChatTextNormalizer.normalizeForMatch(found)
        if expectedKey == foundKey { return "norm" }
        if !expectedKey.isEmpty, !foundKey.isEmpty,
           expectedKey.hasPrefix(foundKey) || foundKey.hasPrefix(expectedKey)
        {
            return "trunc"
        }
        return "diff"
    }

    private func openMatchedRow(
        _ row: UIElement,
        query: String,
        in chatListWindow: UIElement,
        fallbackWindow: UIElement
    ) -> UIElement? {
        kakao.activate()
        _ = tryRaiseWindow(chatListWindow)

        if triggerChatListRowOpen(row, in: chatListWindow, opened: { resolveOpenedChatWindowFast(query: query) != nil }) {
            if let window = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
                return window
            }
        }

        runner.log("chat_id: matched row did not open a chat window")
        return nil
    }

    /// 목록 행을 열 때도 검색 결과와 같은 **사다리**를 탄다 — 한 단을 밟고 창이 떴는지
    /// 짧게 확인한 뒤에야 다음 단으로 간다.
    ///
    /// 종전에는 AXPress 가 "지원됨"으로 답하면 그걸로 끝이었고, 창이 안 뜨면 그대로 3초를
    /// 기다리다 WRONG_WINDOW → 검색으로 떨어졌다. 브릿지 Mac 에서는 그 경로가 정상
    /// read/send 의 **46%** 였다(2026-08-16 00:30~02:30 KST 173건 중 79건, 전부
    /// `res.list=3.09` — 대기 만료값 — 뒤 `res.search=2.2` 로 성공). 즉 그 Mac 의 목록
    /// 행은 AXPress 를 받되 **선택만 하고 열지는 않는다**(개발 Mac 의 행은 AXPress 자체를
    /// 지원하지 않아 처음부터 선택+Enter 로 열리고 0.3s 에 뜬다). 검색으로 구제되는 방은
    /// 3~5초 손해로 끝나지만, **기호뿐인 제목은 검색창이 받지 못하므로**('.', '☆・・・・・☆')
    /// 그 방들은 read/send 가 100% 죽었다 — 2026-08-16 02:15 KST 답장 3회 실패.
    ///
    /// 더블클릭은 여기 넣지 않는다. 검색 결과는 화면에 보이지만 목록 행은 147번째일 수
    /// 있어 클릭 좌표가 남의 행일 수 있다 — 제목 검증이 뒤에서 잡겠지만 굳이 남의 방을
    /// 열 이유가 없다. Enter 는 목록 창을 방금 올렸으므로(activate + raise) 선택된 행을
    /// 연다. 어느 단이 열었는지 `res.open` 로 남긴다 — 브릿지는 runner.log 를 못 본다.
    static let rowOpenConfirmTimeout: TimeInterval = 0.4

    private func triggerChatListRowOpen(_ row: UIElement, in chatListWindow: UIElement, opened: () -> Bool) -> Bool {
        var didTriggerAction = false

        if tryActivateSearchResult(row, label: "chat list row") {
            didTriggerAction = true
            if runner.waitUntil(
                label: "chat list row open confirm (press)",
                timeout: Self.rowOpenConfirmTimeout,
                pollInterval: 0.05,
                evaluateAfterTimeout: false,
                condition: opened
            ) {
                note("res.open", "press")
                return true
            }
            runner.log("chat_id: AXPress on the row did not open a chat window; trying select+Enter")
        }

        var selected = trySelectSearchResult(row, label: "chat list row")
        if !selected, let parent = row.parent {
            selected = trySelectSearchResult(parent, label: "chat list row.parent")
        }
        if selected {
            // AXPress 가 늦게 창을 열었을 수 있다 — 그 창이 키 윈도우면 Enter 가 그 입력창으로
            // 간다. 목록 창을 다시 올린 뒤에도 안 열려 있을 때만 친다.
            kakao.activate()
            _ = tryRaiseWindow(chatListWindow)
            if opened() {
                note("res.open", "press-late")
                return true
            }
            runner.pressEnterKey()
            didTriggerAction = true
            if runner.waitUntil(
                label: "chat list row open confirm (enter)",
                timeout: Self.rowOpenConfirmTimeout,
                pollInterval: 0.05,
                evaluateAfterTimeout: false,
                condition: opened
            ) {
                note("res.open", "enter")
                return true
            }
            runner.log("chat_id: select+Enter on the row did not open a chat window within \(Self.rowOpenConfirmTimeout)s")
        }

        return didTriggerAction
    }

    private func standardizeReadableWindow(_ window: UIElement, label: String) {
        guard interactionMode != .backgroundSafe else {
            runner.log("\(label): background-safe mode; preserving window focus, size, and position")
            return
        }

        kakao.activate()
        _ = tryRaiseWindow(window)

        // preserve mode (default) keeps the user's window size/position untouched;
        // only bring it forward. Resizing is opt-in via --layout left/right.
        guard layoutMode != .preserve else {
            return
        }

        guard let currentSize = window.size else {
            runner.log("\(label): size unavailable; skipping resize")
            return
        }
        let currentFrame = window.frame

        let targetSize = readableTargetSize(for: currentSize)
        guard targetSize != currentSize else {
            runner.log("\(label): size already readable \(Int(currentSize.width))x\(Int(currentSize.height))")
            if let layoutFrame = automaticLayoutFrame(for: window, preferredSize: targetSize, currentFrame: currentFrame) {
                applyWindowFrame(layoutFrame, to: window, label: label)
            }
            return
        }

        if let layoutFrame = automaticLayoutFrame(for: window, preferredSize: targetSize, currentFrame: currentFrame) {
            applyWindowFrame(layoutFrame, to: window, label: label)
        } else {
            do {
                try window.setSize(targetSize)
                if let currentPosition = currentFrame?.origin {
                    try? window.setPosition(currentPosition)
                }
                runner.log("\(label): resized to \(Int(targetSize.width))x\(Int(targetSize.height))")
                Thread.sleep(forTimeInterval: 0.08)
            } catch {
                runner.log("\(label): resize failed (\(error))")
            }
        }
    }

    private func readableTargetSize(for currentSize: CGSize) -> CGSize {
        CGSize(
            width: readableTargetDimension(
                current: currentSize.width,
                minimum: Self.minimumReadableWindowSize.width,
                automaticMaximum: Self.maximumAutomaticWindowSize.width
            ),
            height: readableTargetDimension(
                current: currentSize.height,
                minimum: Self.minimumReadableWindowSize.height,
                automaticMaximum: Self.maximumAutomaticWindowSize.height
            )
        )
    }

    private func readableTargetDimension(current: CGFloat, minimum: CGFloat, automaticMaximum: CGFloat) -> CGFloat {
        if current >= automaticMaximum {
            return current
        }

        return max(current, minimum)
    }

    private func automaticLayoutFrame(
        for window: UIElement,
        preferredSize: CGSize,
        currentFrame: CGRect?
    ) -> CGRect? {
        guard layoutMode != .preserve else {
            return nil
        }

        let currentFrame = currentFrame ?? window.frame ?? CGRect(origin: .zero, size: preferredSize)
        let screenFrame = screenFrame(containing: currentFrame) ?? CGDisplayBounds(CGMainDisplayID())
        let usableFrame = screenFrame.insetBy(dx: 24, dy: 24)
        guard usableFrame.width > 0, usableFrame.height > 0 else {
            return nil
        }

        if layoutMode.isSplit {
            return splitLayoutFrame(in: usableFrame)
        }

        let layoutSize = CGSize(
            width: min(
                max(preferredSize.width, Self.minimumReadableWindowSize.width),
                min(Self.maximumAutomaticWindowSize.width, usableFrame.width)
            ),
            height: min(
                max(preferredSize.height, Self.minimumReadableWindowSize.height),
                min(Self.maximumAutomaticWindowSize.height, usableFrame.height)
            )
        )
        let x = layoutMode.isRightAligned ? usableFrame.maxX - layoutSize.width : usableFrame.minX
        let y = min(max(currentFrame.minY, usableFrame.minY), usableFrame.maxY - layoutSize.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: layoutSize)
    }

    private func splitLayoutFrame(in usableFrame: CGRect) -> CGRect {
        let halfWidth = floor(usableFrame.width / 2)
        let width = min(
            max(halfWidth, min(Self.minimumSplitWindowSize.width, usableFrame.width)),
            usableFrame.width
        )
        let height = min(
            max(Self.minimumSplitWindowSize.height, usableFrame.height),
            usableFrame.height
        )
        let x = layoutMode.isRightAligned ? usableFrame.maxX - width : usableFrame.minX
        return CGRect(origin: CGPoint(x: x, y: usableFrame.minY), size: CGSize(width: width, height: height))
    }

    private func screenFrame(containing frame: CGRect) -> CGRect? {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }

        let referencePoint = CGPoint(x: frame.midX, y: frame.midY)
        return displays
            .map(CGDisplayBounds)
            .first { $0.contains(referencePoint) }
    }

    private func applyWindowFrame(_ frame: CGRect, to window: UIElement, label: String) {
        do {
            try window.setFrame(frame)
            runner.log("\(label): laid out \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))")
            Thread.sleep(forTimeInterval: 0.08)
        } catch {
            runner.log("\(label): layout failed (\(error)); falling back to size-only resize")
            do {
                try window.setSize(frame.size)
                Thread.sleep(forTimeInterval: 0.08)
            } catch {
                runner.log("\(label): resize fallback failed (\(error))")
            }
        }
    }

    private func resolveCachedElement(
        slot: AXPathSlot,
        root: UIElement,
        validate: (UIElement) -> Bool
    ) -> UIElement? {
        guard useCache else { return nil }
        return AXPathCacheStore.shared.resolve(
            slot: slot,
            root: root,
            validate: validate,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement) {
        guard useCache else { return }
        AXPathCacheStore.shared.remember(
            slot: slot,
            root: root,
            element: element,
            trace: { message in
                runner.log(message)
            }
        )
    }

    /// 이미 화면에 있는 검색창만 찾는다. 부작용이 없어서 매 tick 도는 경로에서도
    /// 부를 수 있다 — 아래 locateSearchField 는 못 찾으면 검색 버튼들을 눌러본다.
    private func findExistingSearchField(in rootWindow: UIElement) -> UIElement? {
        if let cachedSearchField = resolveCachedElement(
            slot: .searchField,
            root: rootWindow,
            validate: { field in
                field.isEnabled && field.role == kAXTextFieldRole
            }
        ) {
            return cachedSearchField
        }

        let initialFields = discoverSearchFieldCandidates(in: rootWindow)
        if let field = pickSearchField(from: initialFields) {
            rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
            return field
        }

        return nil
    }

    private func locateSearchField(in rootWindow: UIElement) -> UIElement? {
        if let field = findExistingSearchField(in: rootWindow) {
            return field
        }

        let searchButtons = rootWindow.findAll(role: kAXButtonRole, limit: 24, maxNodes: 220).filter { button in
            let title = (button.title ?? "").lowercased()
            let description = (button.axDescription ?? "").lowercased()
            let identifier = (button.identifier ?? "").lowercased()

            if identifier == "friends" || identifier == "chatrooms" || identifier == "more" {
                return false
            }

            return title.contains("search")
                || title.contains("검색")
                || description.contains("search")
                || description.contains("검색")
                || identifier.contains("search")
        }

        for button in searchButtons.prefix(4) {
            do {
                try button.press()
                runner.log("search: pressed search-like button title='\(button.title ?? "")' id='\(button.identifier ?? "")'")
            } catch {
                runner.log("search: search-like button press failed (\(error))")
            }

            Thread.sleep(forTimeInterval: 0.08)
            let fields = discoverSearchFieldCandidates(in: rootWindow)
            if let field = pickSearchField(from: fields) {
                rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
                return field
            }
        }

        return nil
    }

    private func discoverSearchFieldCandidates(in rootWindow: UIElement) -> [UIElement] {
        var fields: [UIElement] = []
        fields.append(contentsOf: rootWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        if let focusedWindow = kakao.focusedWindow {
            fields.append(contentsOf: focusedWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        if let mainWindow = kakao.mainWindow {
            fields.append(contentsOf: mainWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        return fields.filter { $0.isEnabled }
    }

    private func waitForMatchingSearchResults(query: String, rootWindow: UIElement) -> [SearchCandidate] {
        let fastProfile = SearchScanProfile(
            label: "fast",
            timeout: 0.22,
            pollInterval: 0.04,
            rowLimit: 24,
            cellLimit: 24,
            supplementalLimit: 0,
            candidateNodeBudget: 320,
            textLimit: 6,
            textNodeBudget: 80,
            includeSupplementalRoles: false,
            includeApplicationRoot: false
        )
        let expandedProfile = SearchScanProfile(
            label: "expanded",
            timeout: 0.75,
            pollInterval: 0.05,
            rowLimit: 120,
            cellLimit: 120,
            supplementalLimit: 80,
            candidateNodeBudget: 1_200,
            textLimit: 16,
            textNodeBudget: 220,
            includeSupplementalRoles: true,
            includeApplicationRoot: true
        )

        var matches: [SearchCandidate] = []
        let foundFast = runner.waitUntil(label: "search results (\(fastProfile.label))", timeout: fastProfile.timeout, pollInterval: fastProfile.pollInterval) {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: fastProfile)
            return !matches.isEmpty
        }
        if !foundFast {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: fastProfile)
        }
        if !matches.isEmpty {
            runner.log("search: matching candidates=\(matches.count) via \(fastProfile.label)")
            return matches
        }

        runner.log("search: no matches in fast scan; expanding search scope")
        let foundExpanded = runner.waitUntil(label: "search results (\(expandedProfile.label))", timeout: expandedProfile.timeout, pollInterval: expandedProfile.pollInterval) {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: expandedProfile)
            return !matches.isEmpty
        }
        if !foundExpanded {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: expandedProfile)
        }
        runner.log("search: matching candidates=\(matches.count)")
        return matches
    }

    private func findMatchingSearchResults(
        query: String,
        rootWindow: UIElement,
        profile: SearchScanProfile
    ) -> [SearchCandidate] {
        var roots: [UIElement] = [rootWindow]
        if let focusedWindow = kakao.focusedWindow {
            roots.append(focusedWindow)
        }
        if let mainWindow = kakao.mainWindow {
            roots.append(mainWindow)
        }
        if profile.includeApplicationRoot {
            roots.append(kakao.applicationElement)
        }
        roots = deduplicateElements(roots)

        var results: [SearchCandidate] = []
        for root in roots {
            var candidates: [UIElement] = []
            candidates.append(contentsOf: root.findAll(role: kAXRowRole, limit: profile.rowLimit, maxNodes: profile.candidateNodeBudget))
            candidates.append(contentsOf: root.findAll(role: kAXCellRole, limit: profile.cellLimit, maxNodes: profile.candidateNodeBudget))

            if profile.includeSupplementalRoles {
                candidates.append(contentsOf: root.findAll(role: kAXGroupRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
                candidates.append(contentsOf: root.findAll(role: kAXButtonRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
                candidates.append(contentsOf: root.findAll(role: kAXStaticTextRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
            }

            candidates = deduplicateElements(candidates)
            for candidate in candidates {
                let (matchScore, matchedText) = bestQueryMatch(
                    query: query,
                    in: candidate,
                    textLimit: profile.textLimit,
                    textNodeBudget: profile.textNodeBudget
                )
                // 검색 결과도 제목이 완전히 같은 행만 받는다. 카톡 검색은 부분일치·대화
                // 내용까지 결과에 섞어 주는데, 그중 "가장 점수 높은 것"을 여는 것은 대상 방이
                // 없을 때(리네임·나감) 남의 방을 여는 것과 같다. 대상이 없으면 SEARCH_MISS 가
                // 맞는 결과다 — 브릿지는 그 코드로 리네임 복구를 시작한다.
                guard matchScore > 0, let matchedText, titleMatchesExactly(query: query, candidate: matchedText) else { continue }
                let activationCandidate = activationTarget(for: candidate)
                // Capture the click coordinate now, while the handle is valid.
                let clickPoint = centerPoint(of: candidate.frame) ?? centerPoint(of: activationCandidate.frame)
                results.append(
                    SearchCandidate(
                        element: activationCandidate,
                        textScore: matchScore,
                        matchedText: matchedText,
                        clickPoint: clickPoint
                    )
                )
            }

            if !results.isEmpty && !profile.includeSupplementalRoles {
                break
            }
        }

        return deduplicateSearchCandidates(results)
    }

    /// 행/검색 결과를 연 뒤 제목이 맞는 창이 뜰 때까지 기다린다.
    ///
    /// 종전 0.8s 는 "제목이 없어도 포커스된 창을 받는" 폴백이 뒤에 있을 때의 값이었다.
    /// 그 폴백을 없애자(WRONG_WINDOW) 브릿지 Mac 에서는 새 창의 제목이 그 안에 채워지지
    /// 않아 정상 read/send 의 절반이 WRONG_WINDOW → 검색(+2s) 으로 돌아 성공했다
    /// (2026-08-16 00:02~00:10 KST 실측: ok 62건 중 res.wrong=1, resolve 0.3s→3s). 제목이
    /// 채워지면 즉시 반환하므로 여유를 길게 잡아도 빠른 창엔 비용이 없다.
    static let openedWindowTitleTimeout: TimeInterval = 3.0

    private func waitForOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        var resolved: UIElement?
        _ = runner.waitUntil(
            label: "chat context ready",
            timeout: Self.openedWindowTitleTimeout,
            pollInterval: 0.05,
            evaluateAfterTimeout: false
        ) {
            resolved = resolveOpenedChatWindowFast(query: query)
            return resolved != nil
        }
        return resolved ?? resolveOpenedChatWindow(query: query, fallbackWindow: fallbackWindow)
    }

    private func resolveOpenedChatWindowFast(query: String) -> UIElement? {
        if let matchedWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return matchedWindow
        }

        if let focusedWindow = kakao.focusedWindow,
           titleMatchesExactly(query: query, candidate: focusedWindow.title)
        {
            return focusedWindow
        }

        return nil
    }

    /// 열린 창을 제목으로만 확정한다. **제목이 안 맞으면 없는 것이다.**
    ///
    /// 종전의 3~5단계 — 포커스된 창, 폴백 창, 메인 창 중 "채팅 입력창이 있는" 아무 창 —
    /// 는 "어떻게든 성공시키자"였고, 그 성공은 남의 방이었다. 2026-08-15 20:57 KST
    /// (talkfriend): 목록 행 클릭 뒤 제목 매칭이 안 돼 13초를 기다리다 그때 열려 있던
    /// 다른 유저의 창을 돌려줬고, 그 유저의 톡이 남의 대화로 들어가 캐릭터가 답장했으며
    /// 서버는 방 제목을 그 유저 이름으로 갈아치웠다. `res.rows=2 res.list=13.46` 로 남은
    /// 그 read 는 `status=ok` 였다 — 실패가 성공으로 기록되는 것이 이 폴백의 정확한 해악이다.
    ///
    /// 실패는 호출자가 다음 사다리(검색)나 에러로 넘긴다. 무엇을 열었는지는 로그에 남긴다 —
    /// 브릿지가 못 보는 runner.log 이지만, WRONG_WINDOW 실패의 요약 줄에 `res.wrong` 로도
    /// 실어 사후 추적이 되게 한다.
    private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        if let fastWindow = resolveOpenedChatWindowFast(query: query) {
            return fastWindow
        }
        let focused = kakao.focusedWindow
        let opened = focused?.title ?? fallbackWindow.title ?? ""
        if !opened.isEmpty, !titleMatchesExactly(query: query, candidate: opened) {
            runner.log("[\(ChatWindowFailureCode.wrongWindow.rawValue)] opened window '\(opened)' does not match '\(query)'; not using it")
            note("res.wrong", "1")
            // 무엇을 열었는지의 **종류**만 요약 줄에 남긴다 (제목은 사용자 표시 이름이라 안 적는다).
            // 브릿지 Mac 은 runner.log 를 못 보는데, 2026-08-16 새벽 행 열기 사다리(AXPress→
            // 선택+Enter)를 넣고도 res.open 이 한 번도 안 찍혔다 — 행이 별도 창이 아니라
            // 목록 창 안의 패널로 열리는지(list+input), 아무것도 안 열리는지(list, 입력창 없음),
            // 다른 창이 앞에 있는지(other)를 이 키로 가른다.
            //   list  : 열린(포커스) 창이 목록 창 그 자체
            //   other : 목록 창도 아니고 제목도 다른 창
            // 뒤에 붙는 +input 은 그 창에 채팅 입력창(AXTextArea 등)이 있다는 뜻이다.
            let isListWindow = focused == nil
                || (focused?.title != nil && focused?.title == fallbackWindow.title)
                || (focused?.frame != nil && focused?.frame == fallbackWindow.frame)
            let probe = focused ?? fallbackWindow
            let hasInput = windowContainsLikelyChatInput(probe)  // 진단 표기일 뿐 창을 받지 않는다
            note("res.wrongkind", (isListWindow ? "list" : "other") + (hasInput ? "+input" : ""))
            note("res.wins", String(kakao.windows.count))
        }
        return nil
    }

    private func windowContainsLikelyChatInput(_ window: UIElement) -> Bool {
        if window.findFirst(where: { element in
            guard element.isEffectivelyEnabled else { return false }
            return element.role == kAXTextAreaRole
        }) != nil {
            return true
        }

        return window.findFirst(where: { element in
            isLikelyMessageInputElement(element, in: window) && element.role != kAXTextFieldRole
        }) != nil
    }

    private func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool {
        guard element.isEffectivelyEnabled else { return false }
        let role = element.role ?? ""
        if role == kAXTextAreaRole {
            return true
        }

        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
            return false
        }
        return true
    }

    private func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool {
        let role = element.role ?? ""
        guard role == kAXTextFieldRole else { return false }

        let joinedText = [
            element.identifier ?? "",
            element.title ?? "",
            element.axDescription ?? "",
        ]
        .joined(separator: " ")
        .lowercased()

        if joinedText.contains("search") || joinedText.contains("검색") {
            return true
        }

        guard let windowFrame = window?.frame, let elementFrame = element.frame, windowFrame.height > 0 else {
            return false
        }

        if !isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
            return true
        }

        let relativeY = (elementFrame.midY - windowFrame.minY) / windowFrame.height
        return relativeY < 0.5
    }

    private func pickBestSearchResult(from candidates: [SearchCandidate]) -> SearchCandidate? {
        guard !candidates.isEmpty else { return nil }
        let best = candidates.max { lhs, rhs in
            scoreSearchResult(lhs) < scoreSearchResult(rhs)
        }
        if let best {
            runner.log(
                "search: best result role='\(best.element.role ?? "unknown")' title='\(best.element.title ?? "")' textScore=\(best.textScore) matched='\(best.matchedText)' clickPoint=\(best.clickPoint.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "none")"
            )
        }
        return best
    }

    private func scoreSearchResult(_ candidate: SearchCandidate) -> Int {
        var score = candidate.textScore * 4
        let element = candidate.element
        if supportsAction("AXPress", on: element) {
            score += 4_000
        }
        if supportsAction("AXConfirm", on: element) {
            score += 3_000
        }
        if element.role == kAXRowRole {
            score += 1_600
        } else if element.role == kAXCellRole {
            score += 1_200
        } else if element.role == kAXButtonRole {
            score += 800
        }
        if let title = element.title, !title.isEmpty {
            score += 300
        }
        if element.role == nil || element.role?.isEmpty == true {
            score -= 2_000
        }
        // Prefer a visible, clickable row: KakaoTalk emits a collapsed h=0 section header
        // that matches the same text but has no clickable area.
        if candidate.clickPoint != nil {
            score += 200
        } else {
            score -= 5_000
        }
        return score
    }

    private func triggerSearchResultOpen(
        _ candidate: SearchCandidate,
        searchField: UIElement,
        opened: () -> Bool
    ) -> Bool {
        let result = candidate.element
        var didTriggerAction = false

        if tryActivateSearchResult(result, label: "result") {
            didTriggerAction = true
            if runner.waitUntil(label: "search open confirm", timeout: 0.24, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                return true
            }
        }

        // Search-result rows only expose AXShowDefaultUI/AXShowAlternateUI and ignore
        // keyboard Enter, so a real double-click is the reliable way to open the chat.
        // Use the point captured at scan time; the AX handle is often stale by now.
        if let clickPoint = candidate.clickPoint ?? clickableCenter(of: result) {
            kakao.activate()
            runner.mouseDoubleClick(at: clickPoint, label: "search result")
            didTriggerAction = true
            if runner.waitUntil(label: "search open confirm (double-click)", timeout: 0.6, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                return true
            }
        } else {
            runner.log("search: double-click skipped (no clickable frame)")
        }
        runner.log("search: direct activate miss; skipping heavy neighbor scan for speed")

        let selected = trySelectSearchResult(result, label: "result")
        if !selected, let parent = result.parent {
            let parentSelected = trySelectSearchResult(parent, label: "result.parent")
            didTriggerAction = didTriggerAction || parentSelected
        }
        didTriggerAction = didTriggerAction || selected
        if selected,
           runner.waitUntil(label: "search open confirm", timeout: 0.14, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened)
        {
            return true
        }

        if selected {
            kakao.activate()
            if runner.focusWithVerification(searchField, label: "search field confirm", attempts: 1) {
                runner.log("search: fallback confirm via Enter")
                runner.pressEnterKey()
                didTriggerAction = true
                if runner.waitUntil(label: "search open confirm", timeout: 0.18, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                    return true
                }
            } else {
                runner.log("search: fallback confirm skipped (search field focus failed)")
            }
        } else {
            runner.log("search: skipping Enter fallback because result selection was not available")
        }

        kakao.activate()
        if searchField.isFocused || runner.focusWithVerification(searchField, label: "search field confirm", attempts: 1) {
            runner.log("search: fallback confirm via Down+Enter")
            runner.pressDownArrowKey()
            Thread.sleep(forTimeInterval: 0.03)
            runner.pressEnterKey()
            didTriggerAction = true
            if runner.waitUntil(label: "search open confirm", timeout: 0.22, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                return true
            }
        } else {
            runner.log("search: Down+Enter skipped (search field focus unavailable)")
        }

        return didTriggerAction
    }

    private func tryActivateSearchResult(_ element: UIElement, label: String) -> Bool {
        if let actions = try? element.actionNames(), !actions.isEmpty {
            runner.log("search: \(label) actions=\(actions.joined(separator: ","))")
        }

        do {
            if supportsAction("AXPress", on: element) {
                try element.press()
                runner.log("search: \(label) activated via AXPress")
                return true
            }
        } catch {
            runner.log("search: \(label) AXPress failed (\(error))")
        }

        do {
            if supportsAction("AXConfirm", on: element) {
                try element.performAction("AXConfirm")
                runner.log("search: \(label) activated via AXConfirm")
                return true
            }
        } catch {
            runner.log("search: \(label) AXConfirm failed (\(error))")
        }

        return false
    }

    private func trySelectSearchResult(_ element: UIElement, label: String) -> Bool {
        do {
            try element.setAttribute("AXSelected", value: true as CFBoolean)
            runner.log("search: \(label) selected via AXSelected=true")
            return true
        } catch {
            runner.log("search: \(label) select failed (\(error))")
            return false
        }
    }

    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        guard let actions = try? element.actionNames() else { return false }
        return actions.contains(action)
    }

    /// 방 신원은 **완전 일치**로만 판정한다.
    ///
    /// `scoreQueryMatch` 는 접두·포함·경칭 변형에도 점수를 주는 검색용 점수다. 그걸 창
    /// 매칭에 쓰면 '하린' 요청이 열려 있는 '차하린'/'류하린' 창을 잡는다(2026-08-15
    /// talkfriend 계정에 하린이 넷이었다). 요청 쪽 query 는 언제나 방의 정확한 표시 제목
    /// (레지스트리 displayName 또는 목록 행 제목)이므로 느슨할 이유가 없다.
    ///
    /// 정규화는 레지스트리와 같은 `normalizeForMatch` 다 — 기호뿐인 제목('.', '~.~')을
    /// 빈 문자열로 만들지 않는다. `normalizeSearchToken` 은 기호를 벗겨서 '.' 방의 점수가
    /// 항상 0 이었고, 그 방은 매번 아래 폴백으로 떨어져 아무 창이나 읽었다.
    private func titleMatchesExactly(query: String, candidate: String?) -> Bool {
        guard let candidate else { return false }
        let lhs = ChatTextNormalizer.normalizeForMatch(query)
        let rhs = ChatTextNormalizer.normalizeForMatch(candidate)
        guard !lhs.isEmpty else { return false }
        if lhs == rhs { return true }
        // 창 제목에는 목록 제목에 없는 꼬리가 붙을 수 있다 — 단톡의 멤버 수 " (3)" 같은 것.
        // 그 꼬리만 벗긴 값의 완전 일치는 받는다. 접두 일치가 아니다: '하린' 대 '하린이' 는
        // 여전히 다르다.
        //
        // **공백 뒤의 괄호만 꼬리다.** talkfriend 유저는 표시이름 끝에 연결 코드를 붙인다
        // ('박세은(5292)', 공백 없음). 그걸 꼬리로 벗기면 '박세은' 요청이 '박세은(5292)' 창을
        // 잡는다 — 다른 사람이다. 카톡이 붙이는 수는 이름과 띄어 쓴다.
        let trimmedCandidate = candidate.replacingOccurrences(
            of: #"\s+\(\d+\)\s*$"#, with: "", options: .regularExpression
        )
        return trimmedCandidate != candidate && lhs == ChatTextNormalizer.normalizeForMatch(trimmedCandidate)
    }

    private func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement? {
        windows.first { window in titleMatchesExactly(query: query, candidate: window.title) }
    }

    private func bestQueryMatch(
        query: String,
        in element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> (score: Int, matchedText: String?) {
        let candidateTexts = collectCandidateTexts(
            from: element,
            textLimit: textLimit,
            textNodeBudget: textNodeBudget
        )
        guard !candidateTexts.isEmpty else { return (0, nil) }

        var bestScore = 0
        var bestText: String?
        for candidateText in candidateTexts {
            let score = scoreQueryMatch(query: query, candidateText: candidateText)
            if score > bestScore {
                bestScore = score
                bestText = candidateText
            }
        }

        return (bestScore, bestText)
    }

    private func collectCandidateTexts(
        from element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> [String] {
        var texts: [String] = []

        func appendText(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            texts.append(trimmed)
        }

        appendText(element.title)
        appendText(element.stringValue)
        appendText(element.axDescription)

        let staticTexts = element.findAll(
            role: kAXStaticTextRole,
            limit: textLimit,
            maxNodes: textNodeBudget
        )
        for staticText in staticTexts {
            appendText(staticText.stringValue)
        }

        let textAreas = element.findAll(
            role: kAXTextAreaRole,
            limit: max(2, textLimit / 2),
            maxNodes: textNodeBudget
        )
        for textArea in textAreas {
            appendText(textArea.stringValue)
        }

        return deduplicateStringsPreservingOrder(texts)
    }

    private func scoreQueryMatch(query: String, candidateText: String) -> Int {
        let queryNormalized = normalizeSearchToken(query)
        let candidateNormalized = normalizeSearchToken(candidateText)
        guard !queryNormalized.isEmpty, !candidateNormalized.isEmpty else { return 0 }

        if queryNormalized == candidateNormalized {
            return 12_000
        }
        if candidateNormalized.hasPrefix(queryNormalized) {
            return 10_500
        }
        if candidateNormalized.contains(queryNormalized) {
            return 9_800
        }
        if queryNormalized.contains(candidateNormalized), candidateNormalized.count >= 2 {
            return 8_800
        }

        let queryVariants = honorificVariants(of: queryNormalized)
        let candidateVariants = honorificVariants(of: candidateNormalized)
        var best = 0

        for queryVariant in queryVariants where !queryVariant.isEmpty {
            for candidateVariant in candidateVariants where !candidateVariant.isEmpty {
                if queryVariant == candidateVariant {
                    best = max(best, 8_700)
                    continue
                }
                if candidateVariant.hasPrefix(queryVariant) {
                    best = max(best, 8_400)
                    continue
                }
                if candidateVariant.contains(queryVariant) {
                    best = max(best, 8_200)
                    continue
                }
                if queryVariant.contains(candidateVariant), candidateVariant.count >= 2 {
                    best = max(best, 7_900)
                }
            }
        }

        if best > 0 {
            return best
        }

        let minLength = min(queryNormalized.count, candidateNormalized.count)
        if minLength >= 2 {
            let shortest = queryNormalized.count <= candidateNormalized.count ? queryNormalized : candidateNormalized
            let longest = queryNormalized.count > candidateNormalized.count ? queryNormalized : candidateNormalized
            if longest.contains(shortest) {
                return 6_600
            }
        }

        return 0
    }

    private func normalizeSearchToken(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    private func honorificVariants(of text: String) -> [String] {
        let suffixes = ["선생님", "님", "씨"]
        var variants = Set<String>([text])
        for suffix in suffixes where text.hasSuffix(suffix) {
            let candidate = String(text.dropLast(suffix.count))
            if !candidate.isEmpty {
                variants.insert(candidate)
            }
        }
        return Array(variants)
    }

    private func deduplicateSearchCandidates(_ candidates: [SearchCandidate]) -> [SearchCandidate] {
        var unique: [SearchCandidate] = []
        unique.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let index = unique.firstIndex(where: { existing in
                areSameAXElement(existing.element, candidate.element)
            }) {
                if candidate.textScore > unique[index].textScore {
                    unique[index] = candidate
                }
                continue
            }
            unique.append(candidate)
        }

        return unique
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)
        for element in elements {
            if unique.contains(where: { existing in
                areSameAXElement(existing, element)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }

    private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            if seen.contains(value) {
                continue
            }
            seen.insert(value)
            unique.append(value)
        }

        return unique
    }

    /// Center of a frame, or nil if the frame is missing or too small to click reliably.
    private func centerPoint(of frame: CGRect?) -> CGPoint? {
        guard let frame, frame.width >= 4, frame.height >= 4 else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Live re-read fallback for a clickable screen point. Collapsed/zero-area rows
    /// (e.g. KakaoTalk's hidden section header) have no usable center, so descend to the
    /// first visible descendant before giving up. Prefer the point captured at scan time.
    private func clickableCenter(of element: UIElement) -> CGPoint? {
        if let point = centerPoint(of: element.frame) {
            return point
        }
        if let visible = element.findFirst(where: { child in
            centerPoint(of: child.frame) != nil
        }) {
            return centerPoint(of: visible.frame)
        }
        return nil
    }

    private func activationTarget(for element: UIElement) -> UIElement {
        if isSearchActivationRole(element.role) {
            return element
        }

        var cursor = element.parent
        var hops = 0
        while let current = cursor, hops < 4 {
            if isSearchActivationRole(current.role) {
                return current
            }
            cursor = current.parent
            hops += 1
        }

        return element
    }

    private func isSearchActivationRole(_ role: String?) -> Bool {
        switch role {
        case kAXRowRole, kAXCellRole, kAXButtonRole, kAXGroupRole:
            return true
        default:
            return false
        }
    }

    private func pickSearchField(from fields: [UIElement]) -> UIElement? {
        fields
            .filter { $0.isEnabled }
            .sorted { lhs, rhs in
                let lhsY = lhs.position?.y ?? .greatestFiniteMagnitude
                let rhsY = rhs.position?.y ?? .greatestFiniteMagnitude
                return lhsY < rhsY
            }
            .first
    }

    private func tryRaiseWindow(_ window: UIElement) -> Bool {
        if supportsAction(kAXRaiseAction, on: window) {
            do {
                try window.performAction(kAXRaiseAction)
                runner.log("window: raised via AXRaise")
                return true
            } catch {
                runner.log("window: AXRaise failed (\(error))")
            }
        }
        return false
    }

    private func findCloseButton(in window: UIElement) -> UIElement? {
        let buttons = window.findAll(role: kAXButtonRole, limit: 6, maxNodes: 80)
        if let match = buttons.first(where: { button in
            let joined = [
                button.identifier ?? "",
                button.title ?? "",
                button.axDescription ?? "",
            ].joined(separator: " ").lowercased()
            return joined.contains("close") || joined.contains("닫기")
        }) {
            return match
        }

        return buttons.first
    }

    private func waitForWindowClosed(_ window: UIElement, label: String) -> Bool {
        runner.waitUntil(label: label, timeout: 0.9, pollInterval: 0.06, evaluateAfterTimeout: false) {
            !kakao.windows.contains { candidate in
                areSameAXElement(candidate, window)
            }
        }
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)
        return expandedWindow.intersects(elementFrame)
    }
}
