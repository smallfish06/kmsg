import CryptoKit
import Foundation

struct ChatIdentityRecord: Codable {
    var chatID: String
    var displayName: String
    var normalizedName: String
    var lastPreviewNormalized: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastSeenIndex: Int?
}

private struct ChatIdentityRegistryDocument: Codable {
    var schemaVersion: Int
    var records: [ChatIdentityRecord]
    var updatedAt: Date
}

final class ChatIdentityRegistryStore: @unchecked Sendable {
    static let shared = ChatIdentityRegistryStore()
    static let schemaVersion = 1

    let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedDocument: ChatIdentityRegistryDocument?

    init(fileURL: URL = ChatIdentityRegistryStore.defaultURL()) {
        self.fileURL = fileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func assignChatIDs(for discoveries: [ChatListDiscovery]) -> [String] {
        var document = loadDocument()
        var records = document.records
        let now = Date()
        var assignedIDs = Array(repeating: "", count: discoveries.count)

        // 신원 그룹 키는 lenient 정규화를 쓴다. strict `normalize` 는 구두점·기호를
        // 전부 걷어내므로 "~.~" 나 "-.--..-..--..-" 같은 이름이 통째로 빈 문자열이
        // 되고, 그러면 서로 다른 사람들이 한 그룹에 묶여 같은 chat id 를 나눠 갖는다
        // (sha256("") = e3b0c44298fc…). 실제로 두 사용자의 방이 하나로 합쳐져
        // 수신이 남의 대화로 라우팅되고 답장에 남의 대화 맥락이 실려 나갔다
        // (2026-08-06). normalizeForMatch 는 strict 결과가 비면 기호를 남기는
        // 형태로 떨어져 이런 이름들도 서로 다른 non-empty 키가 된다.
        let groupedCurrent = Dictionary(grouping: discoveries.indices) { index in
            ChatTextNormalizer.normalizeForMatch(discoveries[index].title)
        }
        let groupedExisting = Dictionary(grouping: records.indices) { index in
            records[index].normalizedName
        }

        for (normalizedName, currentIndices) in groupedCurrent {
            var unmatchedCurrent = currentIndices.sorted { discoveries[$0].listIndex < discoveries[$1].listIndex }
            var unmatchedRecords = (groupedExisting[normalizedName] ?? []).sorted { lhs, rhs in
                let lhsPreview = records[lhs].lastPreviewNormalized ?? ""
                let rhsPreview = records[rhs].lastPreviewNormalized ?? ""
                if lhsPreview == rhsPreview {
                    return (records[lhs].lastSeenIndex ?? .max) < (records[rhs].lastSeenIndex ?? .max)
                }
                return lhsPreview < rhsPreview
            }

            for currentIndex in currentIndices {
                let preview = normalizePreview(discoveries[currentIndex].lastMessage)
                guard let preview, !preview.isEmpty else { continue }
                guard let matchOffset = unmatchedRecords.firstIndex(where: { records[$0].lastPreviewNormalized == preview }) else {
                    continue
                }
                let recordIndex = unmatchedRecords.remove(at: matchOffset)
                unmatchedCurrent.removeAll { $0 == currentIndex }
                records[recordIndex] = updatedRecord(records[recordIndex], with: discoveries[currentIndex], preview: preview, now: now)
                assignedIDs[currentIndex] = records[recordIndex].chatID
            }

            let sortedRemainingRecords = unmatchedRecords.sorted { lhs, rhs in
                (records[lhs].lastSeenIndex ?? .max) < (records[rhs].lastSeenIndex ?? .max)
            }
            let zippedCount = min(unmatchedCurrent.count, sortedRemainingRecords.count)
            if zippedCount > 0 {
                for offset in 0..<zippedCount {
                    let currentIndex = unmatchedCurrent[offset]
                    let recordIndex = sortedRemainingRecords[offset]
                    let preview = normalizePreview(discoveries[currentIndex].lastMessage)
                    records[recordIndex] = updatedRecord(records[recordIndex], with: discoveries[currentIndex], preview: preview, now: now)
                    assignedIDs[currentIndex] = records[recordIndex].chatID
                }
                unmatchedCurrent.removeFirst(zippedCount)
            }

            for currentIndex in unmatchedCurrent {
                let preview = normalizePreview(discoveries[currentIndex].lastMessage)
                let chatID = nextChatID(for: normalizedName, existingRecords: records)
                let record = ChatIdentityRecord(
                    chatID: chatID,
                    displayName: discoveries[currentIndex].title,
                    normalizedName: normalizedName,
                    lastPreviewNormalized: preview,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    lastSeenIndex: discoveries[currentIndex].listIndex
                )
                records.append(record)
                assignedIDs[currentIndex] = chatID
            }
        }

        document.records = records
        document.updatedAt = now
        cachedDocument = document
        try? persist(document)
        return assignedIDs
    }

    func record(for chatID: String) -> ChatIdentityRecord? {
        let document = loadDocument()
        return document.records.first(where: { $0.chatID == chatID })
    }

    private func updatedRecord(
        _ record: ChatIdentityRecord,
        with discovery: ChatListDiscovery,
        preview: String?,
        now: Date
    ) -> ChatIdentityRecord {
        var updated = record
        updated.displayName = discovery.title
        updated.lastSeenAt = now
        updated.lastSeenIndex = discovery.listIndex
        if let preview, !preview.isEmpty {
            updated.lastPreviewNormalized = preview
        }
        return updated
    }

    private func nextChatID(for normalizedName: String, existingRecords: [ChatIdentityRecord]) -> String {
        let base = shortHash(normalizedName)
        let prefix = "chat_\(base)"
        let existingIDs = Set(existingRecords.map(\.chatID))

        if !existingIDs.contains(prefix) {
            return prefix
        }

        var suffix = 2
        while existingIDs.contains("\(prefix)_\(suffix)") {
            suffix += 1
        }
        return "\(prefix)_\(suffix)"
    }

    private func shortHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizePreview(_ preview: String?) -> String? {
        guard let preview else { return nil }
        let normalized = ChatTextNormalizer.normalize(preview)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private func loadDocument(forceReload: Bool = false) -> ChatIdentityRegistryDocument {
        if !forceReload, let cachedDocument {
            return cachedDocument
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let document = emptyDocument()
            cachedDocument = document
            return document
        }

        do {
            let data = try Data(contentsOf: fileURL)
            var document = try decoder.decode(ChatIdentityRegistryDocument.self, from: data)
            guard document.schemaVersion == Self.schemaVersion else {
                let reset = emptyDocument()
                cachedDocument = reset
                return reset
            }
            // 저장된 normalizedName 을 현재 규칙으로 다시 계산한다. strict 정규화로
            // 적힌 옛 레코드가 그대로 남으면 lenient 로 묶인 현재 그룹과 만나지 못해
            // 멀쩡한 방들이 전부 새 chat id 를 받는다 — schemaVersion 을 올려
            // 레지스트리를 통째로 버리는 것과 같은 결과다. 여기서 제자리 치유하면
            // 이름이 정상인 방(대다수)은 strict 결과가 그대로라 id 가 유지되고,
            // 빈 문자열로 뭉쳐 있던 기호 이름들만 서로 다른 그룹으로 갈라진다.
            document.records = document.records.map { record in
                var healed = record
                healed.normalizedName = ChatTextNormalizer.normalizeForMatch(record.displayName)
                return healed
            }
            cachedDocument = document
            return document
        } catch {
            let reset = emptyDocument()
            cachedDocument = reset
            return reset
        }
    }

    private func persist(_ document: ChatIdentityRegistryDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private func emptyDocument() -> ChatIdentityRegistryDocument {
        ChatIdentityRegistryDocument(
            schemaVersion: Self.schemaVersion,
            records: [],
            updatedAt: Date()
        )
    }

    private static func defaultURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".kmsg", isDirectory: true)
            .appendingPathComponent("chat-registry.json")
    }
}
