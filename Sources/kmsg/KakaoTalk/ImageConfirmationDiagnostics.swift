import Foundation

/// Numeric costs of the existing confirmation lookups. A missing/failed AX
/// value is diagnostic uncertainty, never permission to infer image delivery.
final class ImageConfirmationDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["KMSG_READ_TIMING_ENABLED"]?.lowercased() == "true"
    private let now: () -> UInt64
    private let started: UInt64
    var lookups = 0, directPresent = 0, directEmpty = 0, directUnknown = 0
    var fallbackWalks = 0, fallbackVisits = 0, fallbackUnknownRoles = 0, fallbackFound = 0
    var containsWalks = 0, containsVisits = 0, containsFound = 0
    private var lookupSeconds = 0.0, containsSeconds = 0.0

    static func make(
        enabled: Bool = enabled, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> ImageConfirmationDiagnostics? {
        enabled ? ImageConfirmationDiagnostics(now: now) : nil
    }

    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
        started = now()
    }

    func beginLookup() -> UInt64 { lookups += 1; return now() }
    func endLookup(_ start: UInt64) { lookupSeconds += elapsed(since: start) }
    func beginContains() -> UInt64 { containsWalks += 1; return now() }
    func endContains(_ start: UInt64) { containsSeconds += elapsed(since: start) }

    private func elapsed(since start: UInt64) -> Double {
        let end = now()
        return Double(end >= start ? end - start : 0) / 1_000_000_000
    }

    func line() -> String {
        var clipped = false
        func count(_ value: Int) -> String {
            let bounded = min(max(value, 0), 999999)
            if bounded != value { clipped = true }
            return String(bounded)
        }
        func seconds(_ value: Double) -> String {
            let bounded = value.isFinite ? min(max(value, 0), 86400) : 86400
            if bounded != value { clipped = true }
            return String(format: "%.3f", bounded)
        }
        var output = "[kmsg] image-confirmation total=\(seconds(elapsed(since: started))) status=done schema=1"
        output += " lookups=\(count(lookups)) direct=\(count(directPresent)) empty=\(count(directEmpty)) unknown=\(count(directUnknown))"
        output += " walks=\(count(fallbackWalks)) visits=\(count(fallbackVisits)) roles=\(count(fallbackUnknownRoles)) found=\(count(fallbackFound))"
        output += " contains=\(count(containsWalks)) cvisits=\(count(containsVisits)) cfound=\(count(containsFound))"
        output += " lookup=\(seconds(lookupSeconds)) containment=\(seconds(containsSeconds)) clip=\(clipped ? 1 : 0)"
        return output
    }

    func emit() {
        guard lookups > 0 || containsWalks > 0 else { return }
        let output = line()
        guard output.utf8.count < 500 else { return }
        try? FileHandle.standardError.write(contentsOf: Data((output + "\n").utf8))
    }
}
