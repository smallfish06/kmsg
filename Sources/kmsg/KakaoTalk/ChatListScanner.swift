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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        if parts.count == 2,
           parts[0].count <= 2, parts[1].count == 2,
           parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        {
            return true
        }

        if trimmed.hasSuffix("일") || trimmed == "어제" || trimmed == "그저께" {
            return true
        }

        return false
    }

    /// Row-timestamp detector for friends-tab detection: accepts the bare
    /// "3:12" form of isTimeLikeValue plus the chat list's rendered
    /// "오전 3:12" / "오후 11:47" form.
    static func isClockLikeValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTimeLikeValue(trimmed) { return true }
        return trimmed.range(of: "^(오전|오후) ?[0-9]{1,2}:[0-9]{2}$", options: .regularExpression) != nil
    }

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

    /// Title-only row lookup with early exit: walks each row only until its
    /// title resolves and stops at the first match, skipping the rest of the
    /// row's subtree. Titles compare exactly because the expected title itself
    /// came from a previous full scan's extractTitle.
    func firstRow(titled expected: String, in window: UIElement, limit: Int, trace: ((String) -> Void)? = nil) -> UIElement? {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            trace?("chats: chat list container unavailable")
            return nil
        }
        let rows = collectChatItems(from: container, limit: limit)
        for (index, row) in rows.enumerated() {
            let content = collectRowContent(from: row, titleOnly: true)
            if extractTitle(from: content) == expected {
                trace?("chats: title fast path matched row \(index + 1)")
                return row
            }
        }
        return nil
    }

    /// The friends tab masquerades as a chat list: same row container, same
    /// titles (friend names), and a non-empty scan — but the "preview" is the
    /// friend's STATUS MESSAGE, which never changes with new messages
    /// (observed live: a bound chat's preview frozen for 7+ hours while
    /// messages piled up unread). Chat rows always carry a per-row timestamp
    /// ("오후 3:12", "어제"); friends rows never do. A non-empty list with no
    /// timestamp anywhere is the friends tab. The verdict reads the clock
    /// flags the scan walk already collected — no extra AX round-trips.
    func looksLikeFriendsList(_ snapshots: [ChatListSnapshotItem], trace: ((String) -> Void)? = nil) -> Bool {
        guard !snapshots.isEmpty else { return false }
        for snapshot in snapshots.prefix(10) where snapshot.sawClockText {
            return false
        }
        trace?("chats: no row timestamps in \(min(snapshots.count, 10)) scanned rows — friends list suspected")
        return true
    }

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

    private func collectChatItems(from container: UIElement, limit: Int) -> [UIElement] {
        let role = container.role ?? ""

        if role == kAXListRole {
            let children = Array(container.children.prefix(limit))
            return deduplicateElements(children)
        }

        // Each role check is one AX round-trip, so stop at `limit` rows
        // instead of classifying the whole children array: a 361-chat list
        // scanned at limit 20 used to pay all 361.
        let children = container.children
        var directRows: [UIElement] = []
        directRows.reserveCapacity(min(limit, children.count))
        var sawDirectRow = false
        for child in children {
            guard child.role == kAXRowRole else { continue }
            sawDirectRow = true
            if directRows.contains(where: { CFEqual($0.axElement, child.axElement) }) { continue }
            directRows.append(child)
            if directRows.count >= limit { break }
        }
        if sawDirectRow {
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
        let rowValues = row.batchAttributes(Self.rowAttributeNames)
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
                textNodes: [], sawClockText: false, nodesVisited: visited
            )
        }

        var queue = rowChildren
        var index = 0

        while index < queue.count, visited < maxNodes, textNodes.count < maxTextNodes {
            let current = queue[index]
            index += 1
            visited += 1

            let values = current.batchAttributes(Self.rowAttributeNames)
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

        return RowContent(
            rowRole: rowRole, rowValue: rowValue, rowTitle: rowTitle, rowIdentifier: rowIdentifier,
            textNodes: textNodes, sawClockText: sawClockText, nodesVisited: visited
        )
    }

    // MARK: - Classification (no AX round-trips past this point)

    private func extractTitle(from content: RowContent) -> String {
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
        return "(Unknown Chat)"
    }

    private func extractPreview(from content: RowContent, title: String) -> String? {
        for node in content.textNodes where node.role == kAXTextAreaRole {
            if let preview = previewCandidate(value: node.value, nodeTitle: node.title, identifier: node.identifier, rowTitle: title) {
                return preview
            }
        }
        for node in content.textNodes where node.role == kAXStaticTextRole {
            if let preview = previewCandidate(value: node.value, nodeTitle: node.title, identifier: node.identifier, rowTitle: title) {
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

    private func previewCandidate(value: String?, nodeTitle: String?, identifier: String?, rowTitle: String) -> String? {
        guard let value = normalizedText(value) ?? normalizedText(nodeTitle) else {
            return nil
        }
        if identifier == "Count Label" {
            return nil
        }
        if ChatTextNormalizer.isTimeLikeValue(value) || ChatTextNormalizer.isUnreadCountLike(value) {
            return nil
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
