import Foundation
import ApplicationServices.HIServices

/// Diagnostic availability only. None of these counters is a message identity,
/// a latest-conversation-end certificate, or permission to admit an input.
final class TranscriptReadEvidenceDiagnostics {
    /// Fixed, type-only buckets. Successful nil bridges to CFNull through the
    /// generic attribute API, so neither is evidence of a present identifier.
    enum IdentifierStatus: Int, CaseIterable {
        case string, unsupported, noValue, number, boolean, nullOrMissing
        case array, dictionary, data, date, axValue, otherType
        case cannotComplete, invalidElement, apiDisabled, illegalArgument
        case axFailure, otherAXError, unexpectedFailure, oversized
    }
    enum IdentifierSample {
        case value(String), unsupported, noValue, failed, oversized
        case classified(IdentifierStatus)

        var status: IdentifierStatus {
            switch self {
            case .value: return .string
            case .unsupported: return .unsupported
            case .noValue: return .noValue
            case .failed: return .unexpectedFailure
            case .oversized: return .oversized
            case .classified(let status): return status
            }
        }
    }
    enum LastRowDisposition: Int { case unvisited, unknown, noBody, systemFiltered, emitted }
    struct Snapshot {
        var collection = Array(repeating: 0, count: 11)
        var help = Array(repeating: 0, count: 7)
        var helpNanos: UInt64 = 0
        var lastRowDisposition = LastRowDisposition.unvisited
        var lastRowChildrenState = 0 // unknown / complete / incomplete
    }
    private var data = Snapshot()

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["KMSG_READ_TIMING_ENABLED"]?.lowercased() == "true"
            && ProcessInfo.processInfo.environment["KMSG_NATIVE_OBSERVATION_ENABLED"] == "true"
    }

    func setCollection(_ counts: [Int]) { data.collection = counts }
    func resetParsing() {
        data.help = Array(repeating: 0, count: 7); data.helpNanos = 0
        data.lastRowDisposition = .unvisited; data.lastRowChildrenState = 0
    }
    func recordLastRowAnalysis(childrenComplete: Bool) {
        data.lastRowDisposition = .unknown
        data.lastRowChildrenState = childrenComplete ? 1 : 2
    }
    func recordLastRowDisposition(_ disposition: LastRowDisposition) {
        data.lastRowDisposition = disposition
    }
    func snapshot() -> Snapshot { data }
    func recordHelp(_ value: String?) {
        let started = DispatchTime.now().uptimeNanoseconds
        let index = Self.helpShape(value)
        data.help[index] = min(99_999, data.help[index] + 1)
        let ended = DispatchTime.now().uptimeNanoseconds
        data.helpNanos = min(99_999_000_000, data.helpNanos + (ended >= started ? ended - started : 0))
    }

    /// Reuse the help value already read with AXValue; never read more metadata
    /// or retain the value. Seconds-shaped text is not a verified send timestamp.
    static func helpShape(_ value: String?) -> Int {
        guard let value else { return 0 }
        guard value.utf8.count <= 512 else { return 6 }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 1 }
        if text.range(of: #"^\d{4}[./-]\s*\d{1,2}[./-]\s*\d{1,2}\.?$"#, options: .regularExpression) != nil { return 2 }
        if text.range(of: #"^\d{4}[./-]\s*\d{1,2}[./-]\s*\d{1,2}[T ]\d{1,2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?$"#,
                      options: .regularExpression) != nil { return 3 }
        if text.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return 4 }
        return 5
    }

    /// Decode the result of the same single AXIdentifier read. Never stringify
    /// numbers/objects or inspect their members; only String values enter the
    /// existing bounded shape classifier and command-local distinct counter.
    static func identifierSample(_ value: AnyObject) -> IdentifierSample {
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID(), let string = value as? String {
            return string.utf8.count <= 512 ? .value(string) : .oversized
        }
        if type == CFBooleanGetTypeID() { return .classified(.boolean) }
        if type == CFNumberGetTypeID() { return .classified(.number) }
        if type == CFNullGetTypeID() { return .classified(.nullOrMissing) }
        if type == CFArrayGetTypeID() { return .classified(.array) }
        if type == CFDictionaryGetTypeID() { return .classified(.dictionary) }
        if type == CFDataGetTypeID() { return .classified(.data) }
        if type == CFDateGetTypeID() { return .classified(.date) }
        if type == AXValueGetTypeID() { return .classified(.axValue) }
        return .classified(.otherType)
    }

    static func identifierError(_ error: AXError) -> IdentifierSample {
        switch error {
        case .attributeUnsupported, .notImplemented: return .unsupported
        case .noValue: return .noValue
        case .cannotComplete: return .classified(.cannotComplete)
        case .invalidUIElement: return .classified(.invalidElement)
        case .apiDisabled: return .classified(.apiDisabled)
        case .illegalArgument: return .classified(.illegalArgument)
        case .failure: return .classified(.axFailure)
        default: return .classified(.otherAXError)
        }
    }

    /// Only fixed schema/counts reach stderr. Values, hashes, AX references,
    /// phone-like identifiers and error strings never leave this function.
    static func emit(snapshot: Snapshot, pass: Int, sources: [(row: Int?, body: Int?)],
                     lastRowSourcePresent: Bool, lastBodySourcePresent: Bool,
                     lastCollectedRowCompared: Bool, lastCollectedRowMatches: Bool,
                     lastCollectedRowSelection: Int = 0,
                     readIdentifier: (Int) -> IdentifierSample,
                     write: (String) -> Void = { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) }) {
        let started = DispatchTime.now().uptimeNanoseconds
        var cache: [Int: IdentifierSample] = [:]
        // schema/calls/rowSampled/rowSupported/rowDistinct/bodySampled/
        // bodySupported/bodyDistinct/unsupported/noValue/failed/empty/
        // uuidLike/hexLike/numericAmbiguous/other/oversized/redacted/costMs/budgetSkipped
        var counts = Array(repeating: 0, count: 19)
        let statusCount = IdentifierStatus.allCases.count
        var statuses = Array(repeating: 0, count: statusCount * 2)
        var rowValues = Set<String>(), bodyValues = Set<String>()
        for source in sources.suffix(3) {
            for (kind, id) in [(0, source.row), (1, source.body)] {
                guard let id else { continue }
                counts[kind == 0 ? 1 : 4] += 1
                let sample: IdentifierSample
                if let cached = cache[id] { sample = cached }
                else {
                    guard counts[0] < 6 else { continue }
                    // Do not start another synchronous AX call once the
                    // diagnostic launch budget is spent. An in-flight call
                    // still has the existing native AX timeout.
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now >= started, now - started < 100_000_000 else { counts[18] += 1; continue }
                    counts[0] += 1
                    sample = readIdentifier(id)
                    cache[id] = sample
                }
                statuses[kind * statusCount + sample.status.rawValue] += 1
                switch sample {
                case .unsupported: counts[7] += 1
                case .noValue: counts[8] += 1
                case .failed: counts[9] += 1
                case .oversized: counts[15] += 1
                // Preserve the v1 aggregate meaning: a successfully returned
                // non-string or an AX failure was formerly `failed`. The new
                // type/status tuple distinguishes those cases without making
                // them string-supported or durable identity evidence.
                case .classified: counts[9] += 1
                case .value(let value):
                    counts[kind == 0 ? 2 : 5] += 1
                    guard value.utf8.count <= 512 else { counts[15] += 1; continue }
                    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { counts[10] += 1; continue }
                    // A generic identifier may contain a phone number. Do not
                    // emit or hash it, or include it in distinct-ID evidence.
                    if text.range(of: #"^(?:\+?[0-9][0-9 ()-]{6,}[0-9])$"#, options: .regularExpression) != nil {
                        counts[16] += 1; continue
                    }
                    let shape: Int
                    if text.range(of: #"^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil { shape = 11 }
                    else if text.range(of: #"^[0-9a-fA-F]{16,128}$"#, options: .regularExpression) != nil { shape = 12 }
                    else if text.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { shape = 13 }
                    else { shape = 14 }
                    counts[shape] += 1
                    if kind == 0 { rowValues.insert(text) } else { bodyValues.insert(text) }
                }
            }
        }
        counts[3] = rowValues.count; counts[6] = bodyValues.count
        let ended = DispatchTime.now().uptimeNanoseconds
        counts[17] = Int(min(99_999, ended >= started ? (ended - started) / 1_000_000 : 0))
        func tuple(_ values: [Int]) -> String { ([2] + values.map { min(99_999, max(0, $0)) }).map(String.init).joined(separator: "/") }
        let end = snapshot.collection + [lastRowSourcePresent ? 1 : 0, lastBodySourcePresent ? 1 : 0,
                                         lastCollectedRowCompared ? 1 : 0, lastCollectedRowMatches ? 1 : 0, 0,
                                         snapshot.lastRowDisposition.rawValue, snapshot.lastRowChildrenState,
                                         min(3, max(0, lastCollectedRowSelection))]
        let helpMs = Int(min(99_999, snapshot.helpNanos / 1_000_000))
        let elapsed = String(format: "%.3f", Double(counts[17] + helpMs) / 1000)
        // Separate bounded lines keep the existing read-detail summary within
        // the bridge's line budget. Both parts describe this one selected pass.
        write("[kmsg] read-evidence total=\(elapsed) status=ok part=1 schema=2 pass=\(pass) help=\(tuple(snapshot.help + [helpMs])) end=\(tuple(end))")
        write("[kmsg] read-evidence total=\(elapsed) status=ok part=2 schema=2 ident=\(tuple(counts)) idstat=\(tuple(statuses))")
    }
}
