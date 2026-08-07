import Foundation

/// Sequential wall-clock slices for one command run, reported on stderr.
///
/// Two kinds of output, both prefixed "[kmsg] " so the bridge can lift them
/// into its own logs:
///
/// - A start mark the moment each phase begins. A process that hangs and gets
///   SIGKILLed never reaches its summary, but the killer captures stderr — the
///   last start mark in that tail names the phase it died in. That attribution
///   is the whole reason this file exists (60s read hangs whose phase we could
///   never identify).
/// - One summary line when the run ends (registered via defer by the caller),
///   with every slice's duration and the total.
///
/// Slices are strictly sequential: begin() closes the previous slice, so the
/// timeline is partitioned and the durations add up to ~total. Nested timers
/// would be easier to misread under SIGKILL, where only the marks survive.
final class PhaseProfiler {
    private let command: String
    private let startedAt = DispatchTime.now()
    private var slices: [(name: String, seconds: Double)] = []
    private var currentName: String?
    private var currentStart = DispatchTime.now()
    private var notes: [(key: String, value: String)] = []
    private var summaryEmitted = false

    init(command: String) {
        self.command = command
    }

    /// Start a new slice, closing the one in progress.
    func begin(_ name: String) {
        endCurrent()
        currentName = name
        currentStart = .now()
        emit("[kmsg] \(command) phase=\(name) start t=\(format(elapsedTotal))")
    }

    /// Close the slice in progress without starting another.
    func end() {
        endCurrent()
    }

    /// Run `body` as one named slice.
    func phase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        begin(name)
        defer { endCurrent() }
        return try body()
    }

    /// Attach a key=value fact (row counts, status) to the summary line.
    func note(_ key: String, _ value: String) {
        notes.append((key, value))
    }

    /// Print the one-line summary. Safe to call from defer on every exit path;
    /// only the first call prints.
    func emitSummary(status: String) {
        guard !summaryEmitted else { return }
        summaryEmitted = true
        endCurrent()
        var parts = ["[kmsg] \(command) total=\(format(elapsedTotal)) status=\(status)"]
        parts.append(contentsOf: slices.map { "\($0.name)=\(format($0.seconds))" })
        parts.append(contentsOf: notes.map { "\($0.key)=\($0.value)" })
        emit(parts.joined(separator: " "))
    }

    private func endCurrent() {
        guard let name = currentName else { return }
        slices.append((name, seconds(since: currentStart)))
        currentName = nil
    }

    private var elapsedTotal: Double {
        seconds(since: startedAt)
    }

    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }

    private func emit(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
