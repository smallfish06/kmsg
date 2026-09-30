import Foundation

/// One extra observation of the same transcript, never an author inference.
/// In particular, a full-sized parse can still have unreadable bubble bounds.
enum TranscriptAttributionRecovery {
    struct Row: Equatable {
        let identity: [String]
        /// nil is unresolved. Known peer names remain part of the verdict so a
        /// fresh snapshot cannot silently replace one identified author with another.
        let owner: String?
        let isSystem: Bool
    }

    static func unresolvedTail(_ rows: [Row]) -> Int {
        let lastOwn = rows.lastIndex { !$0.isSystem && $0.owner == "self" }
        return rows.dropFirst(lastOwn.map { $0 + 1 } ?? 0)
            .filter { !$0.isSystem && $0.owner == nil }.count
    }

    static func recover<Message>(
        _ messages: [Message],
        evidence: (Message) -> Row,
        reread: () -> [Message]
    ) -> (messages: [Message], attempted: Bool, accepted: Bool, unresolvedBefore: Int, unresolvedAfter: Int) {
        let before = messages.map(evidence)
        let tail = unresolvedTail(before)
        guard tail > 0 else { return (messages, false, false, 0, 0) }

        // Exactly one fresh parse. Persistent ambiguity belongs to the caller's
        // paced retry, not a native loop holding the desktop indefinitely.
        let candidate = reread()
        let after = candidate.map(evidence)
        // A disappeared row is not a resolved author. Do not combine snapshots
        // or accept a changed window, ordering, content, or known owner. Dates
        // and body/kind participate in identity; guessed minute labels do not.
        let sameWindow = before.count == after.count && zip(before, after).allSatisfy { old, new in
            old.identity == new.identity && old.isSystem == new.isSystem
                && (old.owner == nil || old.owner == new.owner)
        }
        let improved = after.filter { !$0.isSystem && $0.owner == nil }.count
            < before.filter { !$0.isSystem && $0.owner == nil }.count
        let accepted = sameWindow && improved && unresolvedTail(after) < tail
        return (accepted ? candidate : messages, true, accepted, tail, unresolvedTail(after))
    }
}
