import ApplicationServices.HIServices
import Foundation

/// Optional, thread-confined counters for one synchronous authentication call.
/// Stores only fixed enums, counts and elapsed time; never AX values or handles.
final class AuthReadDiagnostics: NSObject {
    enum Bucket: String, CaseIterable { case ack, marker, input, other }
    enum ReadKind { case scalar, batch }
    struct ReadTicket { let started: UInt64; let bucket: Bucket; let kind: ReadKind }
    private struct IO {
        var scalar = 0, batch = 0, errors = 0
        var seconds = 0.0, maximum = 0.0
    }
    private static let threadKey = "kmsg.auth.numeric-read-diagnostics.v1"
    static var current: AuthReadDiagnostics? {
        Thread.current.threadDictionary[threadKey] as? AuthReadDiagnostics
    }
    @discardableResult
    static func install(_ value: AuthReadDiagnostics?) -> AuthReadDiagnostics? {
        let previous = current
        if let value { Thread.current.threadDictionary[threadKey] = value }
        else { Thread.current.threadDictionary.removeObject(forKey: threadKey) }
        return previous
    }

    private let now: () -> UInt64
    private var bucket: Bucket = .other
    private var io: [Bucket: IO] = [:]
    private var shape: [String: Int] = [:]
    private var plan: [String: Int] = [:]
    private var planSeconds = 0.0

    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
        super.init()
    }

    func enterPhase(_ name: String) -> Bucket {
        let previous = bucket
        switch name {
        case "dismiss": bucket = .ack
        case "markers": bucket = .marker
        case "inputs": bucket = .input
        default: bucket = .other
        }
        return previous
    }
    func restorePhase(_ value: Bucket) { bucket = value }
    func beginRead(_ kind: ReadKind) -> ReadTicket { ReadTicket(started: now(), bucket: bucket, kind: kind) }
    func endRead(_ ticket: ReadTicket, failed: Bool) {
        let elapsed = seconds(since: ticket.started)
        var value = io[ticket.bucket, default: IO()]
        switch ticket.kind { case .scalar: value.scalar += 1; case .batch: value.batch += 1 }
        if failed { value.errors += 1 }
        value.seconds += elapsed
        value.maximum = max(value.maximum, elapsed)
        io[ticket.bucket] = value
    }
    func beginPlan() -> UInt64 { now() }
    func endPlan(since start: UInt64) { planSeconds += seconds(since: start) }
    private func seconds(since start: UInt64) -> Double {
        let finish = now()
        return Double(finish >= start ? finish - start : 0) / 1_000_000_000
    }

    func recordScope(
        invalid: Int, firstInvalidVisit: Int, skipMask: Int, rejects: Int,
        evaluatedPlans: Int,
        bestNet: Int, bestHits: Int, bestNodes: Int, bestGuard: Int,
        rootMissing: Int, unknownBreaks: Int, rootIncomplete: Int
    ) {
        if invalid != 0, plan["invalid", default: 0] == 0 { plan["firstInvalidVisit"] = firstInvalidVisit }
        plan["invalid", default: 0] |= invalid
        plan["skipMask", default: 0] |= skipMask
        for (key, value) in [("rejects", rejects), ("rootMissing", rootMissing),
                             ("unknownBreaks", unknownBreaks), ("rootIncomplete", rootIncomplete)] {
            plan[key, default: 0] += value
        }
        if evaluatedPlans > 0, plan["bestNet"] == nil || bestNet > plan["bestNet", default: 0] {
            plan["bestNet"] = bestNet; plan["bestHits"] = bestHits
            plan["bestNodes"] = bestNodes; plan["bestGuard"] = bestGuard
        }
    }

    /// Called only with the raw result already returned by the original read.
    /// AXValue decoding is local; it does not send another request to the app.
    func recordStructure(
        error: AXError, raw: [AnyObject]?, roleIsString: Bool, childrenAreElements: Bool
    ) {
        guard bucket == .ack else { return }
        shape["reads", default: 0] += 1
        guard error == .success else {
            shape["roleMissing", default: 0] += 1
            shape["childrenMissing", default: 0] += 1
            shape["requestFailure", default: 0] += 1
            return
        }
        guard let raw, raw.count == 2 else {
            shape["roleMissing", default: 0] += 1
            shape["childrenMissing", default: 0] += 1
            shape["malformed", default: 0] += 1
            return
        }
        if !roleIsString { shape["roleMissing", default: 0] += 1 }
        guard !childrenAreElements else { return }
        shape["childrenMissing", default: 0] += 1
        let value = raw[1]
        let reason: String
        if value is NSNull { reason = "null" }
        else if CFGetTypeID(value) == AXValueGetTypeID(),
                AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .axError {
            var error = AXError.success
            if AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .axError, &error) {
                switch error {
                case .attributeUnsupported: reason = "unsupported"
                case .noValue: reason = "noValue"
                case .cannotComplete: reason = "cannotComplete"
                default: reason = "otherAXError"
                }
            } else { reason = "malformed" }
        } else { reason = "wrongType" }
        shape[reason, default: 0] += 1
    }

    /// Three fixed numeric lines precede the existing phase/detail sequence.
    /// IO tuples are scalar calls,batch calls,AX-copy seconds,max seconds,errors.
    /// The residual wall time is not a measurement of Swift CPU time.
    func lines(total: Double) -> [String] {
        guard total.isFinite, total >= 0, total <= 86400 else { return [] }
        var clipped = false
        func number(_ value: Double, time: Bool = false) -> String {
            let bound = time ? 86400.0 : 999999.0
            let safe = value.isFinite ? min(max(value, 0), bound) : 0
            if safe != value { clipped = true }
            return String(format: time ? "%.3f" : "%.0f", safe)
        }
        func header(_ kind: String) -> String {
            String(format: "[kmsg] auth-%@ total=%.3f status=done schema=1", kind, total)
        }
        var planLine = header("plan")
        for key in ["invalid", "firstInvalidVisit", "skipMask", "rejects", "bestNet", "bestHits",
                    "bestNodes", "bestGuard", "rootMissing", "unknownBreaks", "rootIncomplete"] {
            planLine += " \(key)=\(number(Double(plan[key, default: 0])))"
        }
        let planMs = planSeconds * 1000
        let safePlanMs = planMs.isFinite ? min(max(planMs, 0), 999999) : 0
        if safePlanMs != planMs { clipped = true }
        planLine += " planMs=" + String(format: "%.3f", safePlanMs) + " clip=\(clipped ? 1 : 0)"
        clipped = false
        var shapeLine = header("shape")
        for key in ["reads", "roleMissing", "childrenMissing", "unsupported", "noValue", "cannotComplete",
                    "otherAXError", "null", "wrongType", "malformed", "requestFailure"] {
            shapeLine += " \(key)=\(number(Double(shape[key, default: 0])))"
        }
        shapeLine += " clip=\(clipped ? 1 : 0)"
        clipped = false
        var ioLine = header("io")
        for bucket in Bucket.allCases {
            let value = io[bucket, default: IO()]
            let tuple = [number(Double(value.scalar)), number(Double(value.batch)),
                         number(value.seconds, time: true), number(value.maximum, time: true), number(Double(value.errors))]
            ioLine += " \(bucket.rawValue)=" + tuple.joined(separator: ",")
        }
        ioLine += " clip=\(clipped ? 1 : 0)"
        let lines = [planLine, shapeLine, ioLine]
        return lines.allSatisfy { $0.utf8.count < 500 } ? lines : []
    }
}
