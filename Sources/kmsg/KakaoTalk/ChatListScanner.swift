import ApplicationServices.HIServices
import Foundation

enum ChatTextNormalizer {
    static func normalize(_ text: String) -> String {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    /// Identity-matching normalizer. Names made entirely of punctuation or
    /// symbols (e.g. "~.~") strict-normalize to the empty string, which used to
    /// abort friend-add identity confirmation after the first message had
    /// already been sent. Fall back to a lenient form that keeps those scalars
    /// and only strips whitespace and zero-width characters, so both sides of a
    /// comparison stay non-empty and still match exactly.
    static func normalizeForMatch(_ text: String) -> String {
        let strict = normalize(text)
        if !strict.isEmpty { return strict }

        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)
        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    static func isTimeLikeValue(_ value: String) -> Bool {
        // Reject only complete timestamp formats. A suffix such as "일" is
        // also part of names (성일, 전창일); dropping those names let the next
        // cell ("오후 8:45") become the room title and broke code connections.
        isClockLikeValue(value)
    }

    /// Complete row-timestamp formats shared by title filtering and the
    /// friends-tab fallback. A name or status ending in "일" is not a date.
    /// Accepts exactly what the chat list renders in its timestamp cell,
    /// measured live: "오후 11:47", "어제", "1월 10일", "2020. 1. 20.".
    static func isClockLikeValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "어제" || trimmed == "그저께" { return true }
        for pattern in clockPatterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static let clockPatterns = [
        // 오후 11:47 / 오전 3:12 / 11:47
        "^((오전|오후) ?)?[0-9]{1,2}:[0-9]{2}$",
        // 1월 10일 / 2026년 8월 3일
        "^([0-9]{4}년 ?)?[0-9]{1,2}월 ?[0-9]{1,2}일$",
        // 2020. 1. 20.
        "^[0-9]{4}\\. ?[0-9]{1,2}\\. ?[0-9]{1,2}\\.?$",
    ]

    static func isUnreadCountLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isNumber || $0 == "+" || $0 == "," }
    }
}

struct ChatListDiscovery {
    let title: String
    let lastMessage: String?
    let listIndex: Int
    /// Unread badge count from the chat row ("300+" reads as 300); nil when
    /// the row shows no badge.
    let unread: Int?
}

struct ChatListEntry: Codable, Equatable {
    let title: String
    let chatID: String?
    let lastMessage: String?
    let unread: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case chatID = "chat_id"
        case lastMessage = "last_message"
        case unread
    }
}

struct ChatListSnapshotItem {
    let element: UIElement
    let discovery: ChatListDiscovery
    /// Whether the row carried a clock-like static text ("오후 3:12", "어제").
    /// Captured during the row walk so looksLikeFriendsList costs zero extra
    /// AX round-trips.
    let sawClockText: Bool
}

/// Fixed numeric diagnostics; never include a title, preview or AX attribute.
enum ChatListTitleHintGate: Int {
    case noHint = 0, shallow = 1, outOfRange = 2, wrongTab = 3
    case titleMismatch = 4, prefixUnreadable = 5, deadline = 6, changed = 7
    case hit = 8, hitUnknownTab = 9, containerUnavailable = 10, hintUnreadable = 11
}

struct ChatListTitleScanResult {
    let match: UIElement?
    /// Complete snapshots are needed only when exact-title lookup misses and
    /// the caller continues with registry matching. A title-only hit has none.
    let snapshots: [ChatListSnapshotItem]
    let stoppedEarly: Bool
    let rowsScanned: Int
    let usedTitleHint: Bool
    let titleNodes: Int
    let contentNodes: Int
    let hintGate: ChatListTitleHintGate
    let availableRows: Int
}

struct ChatListScanner {
    func scan(in window: UIElement, limit: Int, trace: ((String) -> Void)? = nil) -> [ChatListSnapshotItem] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            trace?("chats: chat list container unavailable")
            return []
        }

        let rows = collectChatItems(from: container, limit: limit)
        guard !rows.isEmpty else {
            trace?("chats: chat list container found but no rows/items resolved")
            return []
        }

        var snapshots: [ChatListSnapshotItem] = []
        snapshots.reserveCapacity(rows.count)
        var nodesVisited = 0

        for (index, row) in rows.enumerated() {
            let content = collectRowContent(from: row)
            nodesVisited += content.nodesVisited
            let title = extractTitle(from: content)
            let preview = extractPreview(from: content, title: title)
            let unread = extractUnread(from: content)
            let discovery = ChatListDiscovery(title: title, lastMessage: preview, listIndex: index, unread: unread)
            snapshots.append(ChatListSnapshotItem(element: row, discovery: discovery, sawClockText: content.sawClockText))
        }

        trace?("chats: resolved rows=\(snapshots.count) axNodes=\(nodesVisited)")
        return snapshots
    }

    /// Exact-title lookup with complete snapshots on a miss.
    ///
    /// 제목이 정확히 맞는 행을 만나면 거기서 멈추고(흔한 경우 — 방금 메시지를 받은 방은
    /// 목록 최상단에 있다), 끝까지 못 만나면 걸으면서 모은 스냅샷을 그대로 돌려준다.
    /// 호출자는 그걸로 chat id 판정을 이어가면 되고, 목록을 다시 걸을 필요가 없다.
    ///
    /// 종전에는 제목 훑기(titleOnly)와 레지스트리 스캔이 **같은 200행을 각각 한 번씩**
    /// 걸었다. 미스 경로가 400 walk 였고, 미스야말로 이 사다리를 끝까지 내려가는
    /// 경로다 — 프로덕션 실측(2026-08-09)에서 목록 구간이 resolve 비용의 대부분이었다
    /// (res.list 합 568s / res.search 합 116s, n=102 vs 44).
    ///
    /// A currently validated deep registry index enables a title-only prefix
    /// walk. It still starts at the first row, so duplicate titles keep their
    /// original ordering. Invalid hints and uncertain prefix reads fall back
    /// to the full-content path below; partial title data never reaches the
    /// registry. A tree change during that prefix can therefore require two
    /// walks. No new AX element or identity cache is retained between calls.
    /// `shouldStop` 은 `stopCheckStride` 행마다 한 번만 묻는다.
    ///
    /// 종전에는 스캔 한 번을 통째로 블로킹으로 두고 예산은 스캔 **앞**에서만 끊었다.
    /// 근거는 "행마다 시계를 보게 된다"였는데, 지평선이 목록보다 짧던 동안에는 walk 의
    /// 최악값이 지평선에 묶여 있어서 그 선택이 안전했다. 지평선을 목록 길이까지 열면
    /// 그 상한이 같이 풀리므로(200행 ≈ 5.8s → 500행 ≈ 14.5s, 기본 예산 8초를 넘긴다)
    /// 안쪽에도 끊을 자리가 있어야 한다. 25행에 한 번이면 시계 비용은 행당 비용의
    /// 1/25 이라 무시할 수 있고, 끊긴 walk 는 지금까지 모은 스냅샷을 그대로 돌려주므로
    /// 호출자의 id 판정은 접두부에 대해 그대로 성립한다 — 지평선에 잘린 walk 와 같은
    /// 상태이고, 그건 이 코드가 이미 다루던 경우다.
    static let stopCheckStride = 25

    // Header/hint validation has fixed AX cost. Shallow lookups keep the
    // original single walk; the fast path is for a previously deep row.
    static let minimumTitleHintIndex = 25

    // A new title-only retry accepts at most one existing full-row bound of
    // title-less content. Discovering the first excess row still costs its
    // bounded read before falling back. No second retry is possible.
    static let maximumKnownNoneNodes = 100

    func scanUntilTitle(
        _ expected: String,
        in window: UIElement,
        limit: Int,
        preferredIndex: Int? = nil,
        shouldStop: (() -> Bool)? = nil,
        trace: ((String) -> Void)? = nil
    ) -> ChatListTitleScanResult {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            trace?("chats: chat list container unavailable")
            return ChatListTitleScanResult(match: nil, snapshots: [], stoppedEarly: false,
                rowsScanned: 0, usedTitleHint: false, titleNodes: 0, contentNodes: 0,
                hintGate: .containerUnavailable, availableRows: 0)
        }
        var directOrder: (role: String, children: [UIElement])?
        let rows = collectChatItems(from: container, limit: limit) { role, children in
            directOrder = (role, children)
        }
        var titleNodes = 0
        var contentNodes = 0
        var hintGate: ChatListTitleHintGate = .noHint
        let evidence = preferredIndex.map { $0 >= Self.minimumTitleHintIndex } == true
            ? ChatListHintEvidence.make() : nil
        defer { evidence?.gate = hintGate.rawValue; evidence?.emit() }

        func titleRead(_ row: UIElement) -> RowContent {
            let content = collectRowContent(from: row, titleOnly: true)
            titleNodes += content.nodesVisited
            evidence?.record(content.titleObservation, candidate: extractTitleCandidate(from: content))
            return content
        }

        // Do not continue using earlier title observations after newly proving
        // a semantic none. Restart at row zero, just as the old full fallback
        // does, but gather only title evidence. Thus a duplicate that appeared
        // during the first prefix is reconsidered before the deep target.
        func retryKnownNonePrefix(through lastIndex: Int) -> Int? {
            guard let directOrder else { evidence?.guardFailure = 2; return nil }
            evidence?.restarts = 1
            var noneNodes = 0
            for index in 0...lastIndex {
                if shouldStop?() == true {
                    hintGate = .deadline; evidence?.guardFailure = 3; return nil
                }
                let checked = titleRead(rows[index])
                evidence?.guardRows += 1
                evidence?.guardNodes += checked.nodesVisited
                let candidate = extractTitleCandidate(from: checked)
                guard checked.titleObservation.issues == 0 else {
                    evidence?.guardFailure = 4; return nil
                }
                if candidate == nil {
                    noneNodes += checked.nodesVisited
                    guard noneNodes <= Self.maximumKnownNoneNodes else {
                        evidence?.guardFailure = 1; return nil
                    }
                    evidence?.admitted += 1
                    continue
                }
                guard candidate == expected else { continue }
                if shouldStop?() == true {
                    hintGate = .deadline; evidence?.guardFailure = 3; return nil
                }
                // The original direct-child sequence was already read while
                // collecting rows. One fresh batch rejects reorder/replacement
                // without another row-role traversal or new identity authority.
                evidence?.order = 1
                let current = container.batchAttributes([kAXRoleAttribute, kAXChildrenAttribute])
                guard current[0] as? String == directOrder.role,
                      let children = current[1] as? [AXUIElement],
                      children.count >= directOrder.children.count,
                      zip(directOrder.children, children).allSatisfy({ CFEqual($0.0.axElement, $0.1) })
                else { hintGate = .changed; evidence?.guardFailure = 5; return nil }
                if shouldStop?() == true {
                    hintGate = .deadline; evidence?.guardFailure = 3; return nil
                }
                evidence?.target = 1
                let target = titleRead(rows[index])
                guard target.titleObservation.issues == 0, extractTitleCandidate(from: target) == expected else {
                    hintGate = .changed; evidence?.guardFailure = 6; return nil
                }
                if shouldStop?() == true {
                    hintGate = .deadline; evidence?.guardFailure = 3; return nil
                }
                return index
            }
            return nil
        }

        // The registry position is only a performance hint. Validate it on the
        // current rows, then still find the FIRST exact title from the
        // beginning. Unknown tab headers are not evidence of a wrong window:
        // the ordinary full walk also accepts the first exact title before
        // its friends-tab fallback. Known friends/more tabs keep that fallback.
        // Never open the hinted row directly; duplicate order stays unchanged.
        var hintTab: MainWindowTab?
        if let preferredIndex {
            if preferredIndex < Self.minimumTitleHintIndex {
                hintGate = .shallow
            } else if preferredIndex >= rows.count {
                hintGate = .outOfRange
            } else {
                hintTab = Self.detectMainWindowTab(in: window)
                hintGate = hintTab == .friends || hintTab == .more ? .wrongTab : .titleMismatch
            }
        }
        if let preferredIndex, hintGate == .titleMismatch {
            let hintedContent = titleRead(rows[preferredIndex])
            let hintedTitle = extractTitle(from: hintedContent)
            if hintedTitle == "(Unknown Chat)" { hintGate = .hintUnreadable }
            if hintedTitle == expected {
                hintGate = .changed
                for index in 0...preferredIndex {
                    if let shouldStop, index > 0, index % Self.stopCheckStride == 0, shouldStop() {
                        // The caller may use complete prefix snapshots for
                        // registry matching after a budget cut. Keep that
                        // contract: fall back to the original bounded walk.
                        hintGate = .deadline
                        break
                    }
                    // Re-read even the hinted row: its first validation is not
                    // authority to accept a stale title after the prefix walk.
                    let content = titleRead(rows[index])
                    let title = extractTitle(from: content)
                    // Missing AX title data cannot certify this prefix as
                    // containing no earlier exact match. Re-read it through
                    // the original path instead of trusting the hint.
                    if title == "(Unknown Chat)" {
                        hintGate = .prefixUnreadable
                        if expected != "(Unknown Chat)", extractTitleCandidate(from: content) == nil,
                           content.titleObservation.issues == 0,
                           let matchedIndex = retryKnownNonePrefix(through: preferredIndex) {
                            hintGate = hintTab == nil ? .hitUnknownTab : .hit
                            return ChatListTitleScanResult(match: rows[matchedIndex], snapshots: [], stoppedEarly: false,
                                rowsScanned: matchedIndex + 1, usedTitleHint: true, titleNodes: titleNodes, contentNodes: 0,
                                hintGate: hintGate, availableRows: rows.count)
                        }
                        break
                    }
                    if title == expected {
                        trace?("chats: validated title hint matched first row \(index + 1)")
                        hintGate = hintTab == nil ? .hitUnknownTab : .hit
                        return ChatListTitleScanResult(match: rows[index], snapshots: [], stoppedEarly: false,
                            rowsScanned: index + 1, usedTitleHint: true, titleNodes: titleNodes, contentNodes: 0,
                            hintGate: hintGate, availableRows: rows.count)
                    }
                }
                // AX rows may have changed while walking. Discard the partial
                // title data; the original path gathers complete snapshots.
            }
        }

        var snapshots: [ChatListSnapshotItem] = []
        snapshots.reserveCapacity(rows.count)

        for (index, row) in rows.enumerated() {
            if let shouldStop, index > 0, index % Self.stopCheckStride == 0, shouldStop() {
                trace?("chats: title walk stopped early at row \(index) of \(rows.count)")
                return ChatListTitleScanResult(match: nil, snapshots: snapshots, stoppedEarly: true,
                    rowsScanned: snapshots.count, usedTitleHint: false, titleNodes: titleNodes, contentNodes: contentNodes,
                    hintGate: hintGate, availableRows: rows.count)
            }
            let content = collectRowContent(from: row)
            contentNodes += content.nodesVisited
            let title = extractTitle(from: content)
            let preview = extractPreview(from: content, title: title)
            let unread = extractUnread(from: content)
            snapshots.append(
                ChatListSnapshotItem(
                    element: row,
                    discovery: ChatListDiscovery(title: title, lastMessage: preview, listIndex: index, unread: unread),
                    sawClockText: content.sawClockText
                )
            )
            // 제목은 정확히 비교한다 — 기대값 자체가 이전 스캔의 extractTitle 에서 왔다.
            if title == expected {
                trace?("chats: title fast path matched row \(index + 1)")
                return ChatListTitleScanResult(match: row, snapshots: snapshots, stoppedEarly: false,
                    rowsScanned: snapshots.count, usedTitleHint: false, titleNodes: titleNodes, contentNodes: contentNodes,
                    hintGate: hintGate, availableRows: rows.count)
            }
        }
        return ChatListTitleScanResult(match: nil, snapshots: snapshots, stoppedEarly: false,
            rowsScanned: snapshots.count, usedTitleHint: false, titleNodes: titleNodes, contentNodes: contentNodes,
            hintGate: hintGate, availableRows: rows.count)
    }

    /// The friends tab masquerades as a chat list: same row container, same
    /// titles (friend names), and a non-empty scan — but the "preview" is the
    /// friend's STATUS MESSAGE, which never changes with new messages
    /// (observed live: a bound chat's preview frozen for 7+ hours while
    /// messages piled up unread). Nothing errors, so the mistake surfaces only
    /// as silence downstream — 2026-08-09 talkfriend: 수신이 5분 48초 통째로
    /// 멈추는 동안 `chats` 는 매 tick `status=done rows=25` 를 돌려줬다.
    ///
    /// Two tiers, strongest evidence first.
    ///
    /// 1. **The window header**, which names the tab outright. Deterministic.
    /// 2. The row-timestamp heuristic, for windows whose header we cannot read.
    ///    Chat rows carry a per-row timestamp ("오후 3:12", "어제"); friends rows
    ///    never do, so a non-empty list with no timestamp is the friends tab.
    ///    It costs no extra AX round-trips (the scan walk already collected the
    ///    clock flags) but it is **absence-based**, and absence is exactly what
    ///    breaks quietly in both directions: one clock-like status message
    ///    certifies the friends tab as a chat list, and a chat list whose top
    ///    rows are all rendered in a form we do not recognize is reported as no
    ///    chats at all. Tier 1 exists because tier 2 cannot be made safe.
    func looksLikeFriendsList(
        _ snapshots: [ChatListSnapshotItem],
        in window: UIElement,
        trace: ((String) -> Void)? = nil
    ) -> Bool {
        guard !snapshots.isEmpty else { return false }

        // Ask the window which tab it is showing before reading tea leaves in
        // the rows. Both directions of the row heuristic are wrong sometimes
        // and both failures are silent, so a direct answer wins whenever there
        // is one.
        //
        // `window` is deliberately NOT optional with a nil default: every call
        // site has one, and a default would let the next one silently fall
        // through to tier 2 — the failure this whole change exists to remove.
        if let tab = Self.detectMainWindowTab(in: window) {
            if tab == .chats { return false }
            trace?("chats: main window header says the '\(tab.rawValue)' tab is showing, not the chat list")
            return true
        }

        for snapshot in snapshots.prefix(10) where snapshot.sawClockText {
            return false
        }
        trace?("chats: no row timestamps in \(min(snapshots.count, 10)) scanned rows — friends list suspected")
        return true
    }

    /// Which tab the KakaoTalk main window is showing.
    enum MainWindowTab: String {
        case chats
        case friends
        case more
    }

    /// Positive identification of the selected tab, from the window's direct
    /// children only (~11 nodes — a rounding error next to a 25-row walk).
    ///
    /// The nav buttons carry no selection state: `inspect --show-attributes`
    /// on `id: chatrooms` returns AXEnabled / AXFrame / AXHelp / AXPosition and
    /// nothing that says whether it is the active one. What each tab DOES draw
    /// as a direct child of the window is its own header (measured live):
    ///
    ///     채팅   → AXButton     title "채팅" (alongside "오픈채팅")
    ///     친구   → AXStaticText value "친구"
    ///     더보기 → AXStaticText value "더보기"
    ///
    /// Returns nil when nothing matches, and callers must read that as
    /// "unknown", never as "wrong tab" — a KakaoTalk build that renames the
    /// header would otherwise stop every scan, which is a far worse failure
    /// than the one this detects. The row heuristic stays as the net there.
    static func detectMainWindowTab(in window: UIElement) -> MainWindowTab? {
        for child in window.children.prefix(headerScanLimit) {
            let values = child.batchAttributes([kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute])
            let role = values[0] as? String ?? ""
            let title = (values[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (values[2] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if role == kAXButtonRole, let title, chatsTabHeaders.contains(title) {
                return .chats
            }
            if role == kAXStaticTextRole, let value {
                if friendsTabHeaders.contains(value) { return .friends }
                if moreTabHeaders.contains(value) { return .more }
            }
        }
        return nil
    }

    /// The header sits within the window's first handful of children; the tab's
    /// scroll area follows it. Stop before descending into that subtree.
    private static let headerScanLimit = 16
    private static let chatsTabHeaders: Set<String> = ["채팅", "Chats"]
    private static let friendsTabHeaders: Set<String> = ["친구", "Friends"]
    private static let moreTabHeaders: Set<String> = ["더보기", "More"]

    func warmup(in window: UIElement, trace: ((String) -> Void)? = nil) -> [AXPathSlot] {
        guard resolveChatListContainer(in: window, trace: trace) != nil else {
            return []
        }
        // Row title/preview no longer use cached per-row paths: resolving and
        // validating two paths per row cost more round-trips than the batched
        // row walk that replaced them, so the container is the only slot left
        // worth warming.
        return [.chatListContainer]
    }

    private func resolveChatListContainer(in window: UIElement, trace: ((String) -> Void)? = nil) -> UIElement? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatListContainer,
            root: window,
            validate: isLikelyChatListContainer,
            trace: trace
        ) {
            trace?("chats: container fast path hit")
            return cached
        }

        trace?("chats: container fast path miss, scanning")
        let tables = window.findAll(role: kAXTableRole, limit: 1, maxNodes: 220)
        let outlines = window.findAll(role: kAXOutlineRole, limit: 1, maxNodes: 220)
        let lists = window.findAll(role: kAXListRole, limit: 1, maxNodes: 220)
        let container = tables.first ?? outlines.first ?? lists.first

        if let container {
            AXPathCacheStore.shared.remember(slot: .chatListContainer, root: window, element: container, trace: trace)
        }

        return container
    }

    private func isLikelyChatListContainer(_ element: UIElement) -> Bool {
        switch element.role {
        case kAXTableRole, kAXOutlineRole, kAXListRole:
            return true
        default:
            return false
        }
    }

    private func collectChatItems(
        from container: UIElement, limit: Int,
        observeDirectOrder: ((String, [UIElement]) -> Void)? = nil
    ) -> [UIElement] {
        let role = container.role ?? ""

        if role == kAXListRole {
            let children = Array(container.children.prefix(limit))
            observeDirectOrder?(role, children)
            return deduplicateElements(children)
        }

        // Each role check is one AX round-trip, so stop at `limit` rows
        // instead of classifying the whole children array: a 361-chat list
        // scanned at limit 20 used to pay all 361.
        let children = container.children
        var directRows: [UIElement] = []
        directRows.reserveCapacity(min(limit, children.count))
        var sawDirectRow = false
        var prefixCount = 0
        for child in children {
            prefixCount += 1
            guard child.role == kAXRowRole else { continue }
            sawDirectRow = true
            if directRows.contains(where: { CFEqual($0.axElement, child.axElement) }) { continue }
            directRows.append(child)
            if directRows.count >= limit { break }
        }
        if sawDirectRow {
            // Retain no more handles than the existing 500-row fallback's
            // 8x traversal horizon. Large mixed containers simply cannot use
            // the new known-none retry; their original result is unchanged.
            if prefixCount <= 4000 { observeDirectOrder?(role, Array(children.prefix(prefixCount))) }
            return directRows
        }

        let discoveredRows = container.findAll(role: kAXRowRole, limit: limit, maxNodes: max(80, limit * 8))
        return deduplicateElements(discoveredRows)
    }

    // MARK: - Batched row walk

    /// One text-bearing node observed while walking a row's subtree. All four
    /// attributes arrive in the same batched round-trip that discovered the
    /// node, so title/preview/unread classification below is pure CPU.
    private struct RowTextNode {
        let role: String
        let value: String?
        let title: String?
        let identifier: String?
    }

    /// Everything scan needs from one chat row. Gathered by a single
    /// breadth-first walk paying exactly one AX round-trip per visited node —
    /// the separate title/preview/unread lookups this replaced re-walked the
    /// same ~7-node subtree three times and re-read each attribute
    /// individually, which is where the old ~0.1s/row went.
    private struct RowContent {
        let rowRole: String?
        let rowValue: String?
        let rowTitle: String?
        let rowIdentifier: String?
        let textNodes: [RowTextNode]
        let sawClockText: Bool
        let nodesVisited: Int
        let titleObservation: ChatListTitleObservation
    }

    private static let rowAttributeNames = [
        kAXRoleAttribute,
        kAXChildrenAttribute,
        kAXValueAttribute,
        kAXTitleAttribute,
        kAXIdentifierAttribute,
    ]

    private func collectRowContent(
        from row: UIElement,
        titleOnly: Bool = false,
        maxNodes: Int = 100,
        maxTextNodes: Int = 24
    ) -> RowContent {
        var titleObservation = ChatListTitleObservation()
        func read(_ node: UIElement) -> [Any?] {
            if titleOnly {
                return node.batchAttributes(Self.rowAttributeNames) { error, raw in
                    titleObservation.observe(error: error, raw: raw)
                }
            }
            return node.batchAttributes(Self.rowAttributeNames)
        }
        let rowValues = read(row)
        let rowRole = rowValues[0] as? String
        let rowChildren = (rowValues[1] as? [AXUIElement])?.map { UIElement($0) } ?? []
        let rowValue = rowValues[2] as? String
        let rowTitle = rowValues[3] as? String
        let rowIdentifier = rowValues[4] as? String

        var textNodes: [RowTextNode] = []
        var sawClockText = false
        var visited = 1

        // The row itself can satisfy a title-only lookup without any walk.
        if titleOnly, titleCandidate(title: rowTitle, value: rowValue, role: rowRole, identifier: rowIdentifier) != nil {
            return RowContent(
                rowRole: rowRole, rowValue: rowValue, rowTitle: rowTitle, rowIdentifier: rowIdentifier,
                textNodes: [], sawClockText: false, nodesVisited: visited, titleObservation: titleObservation
            )
        }

        var queue = rowChildren
        var index = 0

        while index < queue.count, visited < maxNodes, textNodes.count < maxTextNodes {
            let current = queue[index]
            index += 1
            visited += 1

            let values = read(current)
            let role = values[0] as? String ?? ""
            let children = (values[1] as? [AXUIElement])?.map { UIElement($0) } ?? []

            if role == kAXStaticTextRole || role == kAXTextAreaRole {
                let node = RowTextNode(
                    role: role,
                    value: values[2] as? String,
                    title: values[3] as? String,
                    identifier: values[4] as? String
                )
                textNodes.append(node)
                if role == kAXStaticTextRole, !sawClockText {
                    let candidates = [node.value, node.title].compactMap { $0 }
                    sawClockText = candidates.contains(where: { ChatTextNormalizer.isClockLikeValue($0) })
                }
                if titleOnly, role == kAXStaticTextRole,
                   titleCandidate(title: node.title, value: node.value, role: node.role, identifier: node.identifier) != nil
                {
                    break
                }
            }

            queue.append(contentsOf: children)
        }

        // A successful title hit deliberately leaves a frontier. Only a
        // title-less result needs exhaustive evidence; quota/cut is unknown.
        if titleOnly {
            let hasTitle = textNodes.contains { node in
                node.role == kAXStaticTextRole && titleCandidate(
                    title: node.title, value: node.value, role: node.role, identifier: node.identifier
                ) != nil
            }
            if !hasTitle, (index < queue.count || visited > maxNodes) { titleObservation.issues |= 32 }
        }
        return RowContent(
            rowRole: rowRole, rowValue: rowValue, rowTitle: rowTitle, rowIdentifier: rowIdentifier,
            textNodes: textNodes, sawClockText: sawClockText, nodesVisited: visited, titleObservation: titleObservation
        )
    }

    // MARK: - Classification (no AX round-trips past this point)

    private func extractTitle(from content: RowContent) -> String {
        extractTitleCandidate(from: content) ?? "(Unknown Chat)"
    }

    private func extractTitleCandidate(from content: RowContent) -> String? {
        if let title = titleCandidate(
            title: content.rowTitle, value: content.rowValue,
            role: content.rowRole, identifier: content.rowIdentifier
        ) {
            return title
        }
        for node in content.textNodes where node.role == kAXStaticTextRole {
            if let title = titleCandidate(title: node.title, value: node.value, role: node.role, identifier: node.identifier) {
                return title
            }
        }
        return nil
    }

    private func extractPreview(from content: RowContent, title: String) -> String? {
        // The preview is the row's AXTextArea; the unread badge and the timestamp
        // are AXStaticTexts (badge id "Count Label"). A text area can therefore
        // never be the badge, and rejecting digit-only text there drops real
        // messages: a row whose last message was "123456" reported its TIMESTAMP
        // ("오후 6:06") as the preview (measured 2026-09-17) — which is exactly the
        // shape of a talkfriend connect code, so the bridge could never see one.
        for node in content.textNodes where node.role == kAXTextAreaRole {
            if let preview = previewCandidate(
                value: node.value, nodeTitle: node.title, identifier: node.identifier,
                rowTitle: title, fromTextArea: true
            ) {
                return preview
            }
        }
        for node in content.textNodes where node.role == kAXStaticTextRole {
            if let preview = previewCandidate(
                value: node.value, nodeTitle: node.title, identifier: node.identifier,
                rowTitle: title, fromTextArea: false
            ) {
                return preview
            }
        }
        return nil
    }

    /// The unread badge is a bare AXStaticText holding only the count (e.g.
    /// "1", "300+"); title and timestamp texts never match isUnreadCountLike.
    private func extractUnread(from content: RowContent) -> Int? {
        for node in content.textNodes where node.role == kAXStaticTextRole {
            guard let value = normalizedText(node.value) ?? normalizedText(node.title),
                  ChatTextNormalizer.isUnreadCountLike(value)
            else { continue }
            let digits = value.filter(\.isNumber)
            guard let count = Int(digits), count > 0 else { continue }
            return count
        }
        return nil
    }

    private func titleCandidate(title: String?, value: String?, role: String?, identifier: String?) -> String? {
        if let title = normalizedText(title), !ChatTextNormalizer.isTimeLikeValue(title), !ChatTextNormalizer.isUnreadCountLike(title) {
            return title
        }

        if identifier == "Count Label" {
            return nil
        }

        switch role {
        case kAXRowRole, kAXCellRole, kAXGroupRole, kAXListRole, kAXTableRole, kAXOutlineRole:
            return nil
        default:
            break
        }

        if let value = normalizedText(value), !ChatTextNormalizer.isTimeLikeValue(value), !ChatTextNormalizer.isUnreadCountLike(value) {
            return value
        }

        return nil
    }

    private func previewCandidate(
        value: String?, nodeTitle: String?, identifier: String?, rowTitle: String, fromTextArea: Bool
    ) -> String? {
        guard let value = normalizedText(value) ?? normalizedText(nodeTitle) else {
            return nil
        }
        if identifier == "Count Label" {
            return nil
        }
        if !fromTextArea {
            // Static-text fallback only: here a bare number is the badge and a
            // clock string is the row's timestamp cell.
            if ChatTextNormalizer.isClockLikeValue(value)
                || ChatTextNormalizer.isUnreadCountLike(value)
            {
                return nil
            }
        }
        if ChatTextNormalizer.normalize(value) == ChatTextNormalizer.normalize(rowTitle) {
            return nil
        }
        return value
    }

    private func normalizedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)

        for element in elements {
            if unique.contains(where: { existing in
                CFEqual(existing.axElement, element.axElement)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }

    private func deduplicateSlots(_ slots: [AXPathSlot]) -> [AXPathSlot] {
        var seen = Set<AXPathSlot>()
        return slots.filter { seen.insert($0).inserted }
    }
}
