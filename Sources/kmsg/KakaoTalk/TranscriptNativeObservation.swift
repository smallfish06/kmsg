import Foundation
import CoreGraphics

/// Evidence about one returned native read, never a durable message identity.
/// Source identities and geometry remain process-local and are not encoded.
enum TranscriptNativeObservation {
    enum Order: String, Encodable, Sendable { case verified, uncertain }
    enum Multiplicity: String, Encodable, Sendable { case physicalRow = "physical-row", legacy }
    enum Origin: Sendable { case rowParser, fallback }

    struct Metadata: Encodable, Equatable, Sendable {
        let version = 1
        let id: String
        let index: Int
        let count: Int
        let order: Order
        let multiplicity: Multiplicity
    }

    struct Source: Equatable, Sendable {
        let row: Int?
        let body: Int?
        let rowFrame: CGRect?
        let bodyFrame: CGRect?
        let origin: Origin
        let ambiguous: Bool
    }

    struct Candidate {
        let source: Source?
        let legacyKey: String
        /// Exact semantic fields distinguish a changed exposure of one source.
        let signature: [String]
    }

    struct Selection {
        let indices: [Int]
        let order: Order
        let multiplicity: Multiplicity
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KMSG_NATIVE_OBSERVATION_ENABLED"] == "true"
    }

    /// Pure within-observation reconciliation. Equality of a row/body source
    /// can merge exposures; equality of text cannot prove a physical identity.
    /// Missing or ambiguous source/geometry evidence retains legacy behavior.
    static func select(_ candidates: [Candidate], limit: Int, stable: Bool) -> Selection {
        guard !candidates.isEmpty, limit > 0 else {
            return Selection(indices: [], order: .uncertain, multiplicity: .legacy)
        }

        var parents = Array(candidates.indices)
        func root(_ index: Int) -> Int {
            var cursor = index
            while parents[cursor] != cursor { cursor = parents[cursor] }
            return cursor
        }
        var rowOwners: [Int: Int] = [:]
        var bodyOwners: [Int: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            for (identity, owners) in [(candidate.source?.row, rowOwners), (candidate.source?.body, bodyOwners)] {
                guard let identity, let prior = owners[identity] else { continue }
                let first = root(prior), second = root(index)
                parents[max(first, second)] = min(first, second)
            }
            if let row = candidate.source?.row { rowOwners[row] = index }
            if let body = candidate.source?.body { bodyOwners[body] = index }
        }

        var groups: [Int: [Int]] = [:]
        for index in candidates.indices { groups[root(index), default: []].append(index) }
        let physicalIndices = groups.keys.sorted()
        let recent = Array(physicalIndices.suffix(limit))
        let coherent = recent.allSatisfy { index in
            let group = groups[index]!
            guard let source = candidates[index].source,
                  source.row != nil, source.body != nil, !source.ambiguous,
                  valid(source.rowFrame), valid(source.bodyFrame),
                  source.rowFrame!.contains(source.bodyFrame!) else { return false }
            // A fallback can expose another text node inside the same row.
            // Collapse that proven same-row exposure, but do not certify it.
            return group.allSatisfy { other in
                guard let otherSource = candidates[other].source else { return false }
                return otherSource.row == source.row && otherSource.body == source.body
                    && !otherSource.ambiguous && candidates[other].signature == candidates[index].signature
                    && (otherSource.origin == .fallback
                        || (otherSource.rowFrame == source.rowFrame && otherSource.bodyFrame == source.bodyFrame))
            }
        }
        let ordered = coherent && zip(recent, recent.dropFirst()).allSatisfy { left, right in
            let lhs = candidates[left].source!, rhs = candidates[right].source!
            return lhs.rowFrame!.maxY <= rhs.rowFrame!.minY
                && lhs.bodyFrame!.maxY <= rhs.bodyFrame!.minY
        }
        if ordered {
            let singleParser = candidates.allSatisfy { $0.source?.origin == .rowParser }
            return Selection(indices: recent, order: stable && singleParser ? .verified : .uncertain,
                             multiplicity: .physicalRow)
        }

        // Exact source duplicates were already removed, including exposures
        // whose author/body changed. Do not create two messages for one row.
        var seen = Set<String>()
        let legacy = physicalIndices.filter { seen.insert(candidates[$0].legacyKey).inserted }
        return Selection(indices: Array(legacy.suffix(limit)), order: .uncertain, multiplicity: .legacy)
    }

    private static func valid(_ frame: CGRect?) -> Bool {
        guard let frame else { return false }
        return frame.origin.x.isFinite && frame.origin.y.isFinite && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0 && frame.maxX.isFinite && frame.maxY.isFinite
    }
}
