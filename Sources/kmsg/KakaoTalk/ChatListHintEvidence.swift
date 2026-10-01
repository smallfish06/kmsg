import ApplicationServices.HIServices
import Foundation

/// Completeness of one title walk, using only its existing five-slot batches.
/// Typed absence is local evidence, never global structure/cache authority.
struct ChatListTitleObservation {
    // First five bits describe the raw batch; bit 5 is an unvisited frontier.
    var issues = 0
    var noValue = 0
    var unsupported = 0

    mutating func observe(error: AXError, raw: [AnyObject]?) {
        guard error == .success else { issues |= 1; return }
        guard let raw, raw.count == 5 else { issues |= 2; return }
        if !(raw[0] is String) { issues |= 4 }
        if !(raw[1] is [AXUIElement]), !observedAbsence(raw[1]) { issues |= 8 }
        for slot in 2...4 {
            if !(raw[slot] is String), !observedAbsence(raw[slot]) { issues |= 16 }
        }
    }

    private mutating func observedAbsence(_ value: AnyObject) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        let typed = unsafeDowncast(value, to: AXValue.self)
        var error = AXError.success
        guard AXValueGetType(typed) == .axError, AXValueGetValue(typed, .axError, &error) else { return false }
        if error == .noValue { noValue += 1; return true }
        if error == .attributeUnsupported { unsupported += 1; return true }
        return false
    }
}

/// Fixed numeric evidence for the deep title-hint path, with no label values.
final class ChatListHintEvidence {
    private static let key = "kmsg.hint.numeric-sequence.v1"
    private static let enabled = ProcessInfo.processInfo.environment["KMSG_READ_TIMING_ENABLED"]?.lowercased() == "true"
    private let sequence: Int
    private let now: () -> UInt64
    private let started: UInt64
    var gate = 0, reads = 0, none = 0, unknown = 0, literal = 0, issues = 0
    var noValue = 0, unsupported = 0, cuts = 0, admitted = 0, restarts = 0
    var guardRows = 0, guardNodes = 0, guardFailure = 0, order = 0, target = 0

    static func make(
        enabled: Bool = enabled, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> ChatListHintEvidence? {
        guard enabled else { return nil }
        let previous = (Thread.current.threadDictionary[key] as? NSNumber)?.intValue ?? 0
        guard previous < 64 else { return nil }
        Thread.current.threadDictionary[key] = NSNumber(value: previous + 1)
        return ChatListHintEvidence(sequence: previous + 1, now: now)
    }

    init(sequence: Int, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.sequence = sequence; self.now = now; started = now()
    }

    func record(_ value: ChatListTitleObservation, candidate: String?) {
        reads += 1; issues |= value.issues
        noValue += value.noValue; unsupported += value.unsupported
        if value.issues & 32 != 0 { cuts += 1 }
        if candidate == nil {
            if value.issues == 0 { none += 1 } else { unknown += 1 }
        } else if candidate == "(Unknown Chat)" { literal += 1 }
    }

    func line() -> String {
        var clipped = sequence >= 64
        func number(_ value: Int) -> String {
            let bounded = min(max(value, 0), 999999)
            if value != bounded { clipped = true }
            return String(bounded)
        }
        let end = now()
        let seconds = Double(end >= started ? end - started : 0) / 1_000_000_000
        let elapsed = min(seconds, 86400)
        if elapsed != seconds { clipped = true }
        var output = "[kmsg] hint-evidence total=\(String(format: "%.3f", elapsed)) status=ok schema=1 seq=\(number(sequence))"
        output += " gate=\(number(gate)) reads=\(number(reads)) none=\(number(none)) unknown=\(number(unknown)) literal=\(number(literal))"
        output += " issues=\(number(issues)) nv=\(number(noValue)) uns=\(number(unsupported)) cuts=\(number(cuts)) admitted=\(number(admitted)) restart=\(number(restarts))"
        output += " guardRows=\(number(guardRows)) guardNodes=\(number(guardNodes)) guardFail=\(number(guardFailure)) order=\(number(order)) target=\(number(target))"
        output += " clip=\(clipped ? 1 : 0)"
        return output
    }

    func emit() {
        // Quiet for shallow/non-hint calls. Status is diagnostic formatting,
        // not native operation success; fallback failures retain evidence.
        guard reads > 0 else { return }
        let output = line()
        guard output.utf8.count < 500 else { return }
        try? FileHandle.standardError.write(contentsOf: Data((output + "\n").utf8))
    }
}
