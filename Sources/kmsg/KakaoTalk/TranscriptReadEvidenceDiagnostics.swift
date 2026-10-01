import Foundation

/// Diagnostic availability only. None of these counters is a message identity,
/// a latest-conversation-end certificate, or permission to admit an input.
final class TranscriptReadEvidenceDiagnostics {
    enum IdentifierSample {
        case value(String), unsupported, noValue, failed, oversized
    }
    struct Snapshot {
        var collection = Array(repeating: 0, count: 11)
        var help = Array(repeating: 0, count: 7)
        var helpNanos: UInt64 = 0
    }
    private var data = Snapshot()

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["KMSG_READ_TIMING_ENABLED"]?.lowercased() == "true"
            && ProcessInfo.processInfo.environment["KMSG_NATIVE_OBSERVATION_ENABLED"] == "true"
    }

    func setCollection(_ counts: [Int]) { data.collection = counts }
    func resetHelp() { data.help = Array(repeating: 0, count: 7); data.helpNanos = 0 }
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

    /// Only fixed schema/counts reach stderr. Values, hashes, AX references,
    /// phone-like identifiers and error strings never leave this function.
    static func emit(snapshot: Snapshot, pass: Int, sources: [(row: Int?, body: Int?)],
                     lastRowSourcePresent: Bool, lastBodySourcePresent: Bool,
                     lastCollectedRowCompared: Bool, lastCollectedRowMatches: Bool,
                     readIdentifier: (Int) -> IdentifierSample,
                     write: (String) -> Void = { try? FileHandle.standardError.write(contentsOf: Data(($0 + "\n").utf8)) }) {
        let started = DispatchTime.now().uptimeNanoseconds
        var cache: [Int: IdentifierSample] = [:]
        // schema/calls/rowSampled/rowSupported/rowDistinct/bodySampled/
        // bodySupported/bodyDistinct/unsupported/noValue/failed/empty/
        // uuidLike/hexLike/numericAmbiguous/other/oversized/redacted/costMs/budgetSkipped
        var counts = Array(repeating: 0, count: 19)
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
                switch sample {
                case .unsupported: counts[7] += 1
                case .noValue: counts[8] += 1
                case .failed: counts[9] += 1
                case .oversized: counts[15] += 1
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
        func tuple(_ values: [Int]) -> String { ([1] + values.map { min(99_999, max(0, $0)) }).map(String.init).joined(separator: "/") }
        let end = snapshot.collection + [lastRowSourcePresent ? 1 : 0, lastBodySourcePresent ? 1 : 0,
                                         lastCollectedRowCompared ? 1 : 0, lastCollectedRowMatches ? 1 : 0, 0]
        let helpMs = Int(min(99_999, snapshot.helpNanos / 1_000_000))
        let elapsed = String(format: "%.3f", Double(counts[17] + helpMs) / 1000)
        // Separate bounded lines keep the existing read-detail summary within
        // the bridge's line budget. Both parts describe this one selected pass.
        write("[kmsg] read-evidence total=\(elapsed) status=ok part=1 schema=1 pass=\(pass) help=\(tuple(snapshot.help + [helpMs])) end=\(tuple(end))")
        write("[kmsg] read-evidence total=\(elapsed) status=ok part=2 schema=1 ident=\(tuple(counts))")
    }
}
