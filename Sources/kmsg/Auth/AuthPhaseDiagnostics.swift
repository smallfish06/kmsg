import Foundation

/// Optional numeric timing of the existing authentication decisions. These
/// nested spans never inspect AX values or alter the verification cache.
final class AuthPhaseDiagnostics {
    enum Phase: String, CaseIterable {
        case total, cache, reopen, state, dismiss, list, main, login
        case title, markers, inputs, buttons, password, reset
    }

    private let now: () -> UInt64
    private var elapsed: [Phase: Double] = [:]
    private var calls: [Phase: Int] = [:]
    var fullCheck = false
    var totalSeconds: Double { elapsed[.total, default: 0] }

    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    func reset() {
        elapsed.removeAll(keepingCapacity: true)
        calls.removeAll(keepingCapacity: true)
        fullCheck = false
    }

    func begin() -> UInt64 { now() }

    func end(_ phase: Phase, since start: UInt64) {
        let finish = now()
        elapsed[phase, default: 0] += Double(finish >= start ? finish - start : 0) / 1_000_000_000
        calls[phase, default: 0] += 1
    }

    func measure<T>(_ phase: Phase, _ action: () throws -> T) rethrows -> T {
        let diagnostics = AuthReadDiagnostics.current
        let previous = diagnostics?.enterPhase(phase.rawValue)
        defer { if let previous { diagnostics?.restorePhase(previous) } }
        let start = begin()
        defer { end(phase, since: start) }
        return try action()
    }

    func line() -> String? {
        guard fullCheck else { return nil }
        var values: [String] = []
        for phase in Phase.allCases {
            let value = elapsed[phase, default: 0]
            guard value.isFinite, value >= 0, value <= 86400 else { return nil }
            values.append("\(phase.rawValue)=" + String(format: "%.3f", value))
        }
        let states = calls[.state, default: 0], checks = calls[.login, default: 0]
        guard states <= 1_000_000, checks <= 1_000_000 else { return nil }
        let line = "[kmsg] auth-phase " + values.joined(separator: " ") +
            " status=done schema=1 states=\(states) checks=\(checks)"
        return line.utf8.count < 500 ? line : nil
    }
}
