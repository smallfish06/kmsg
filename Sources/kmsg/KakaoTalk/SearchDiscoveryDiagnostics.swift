import ApplicationServices.HIServices
import Foundation

/// Observes the existing search-field walks. No result or reuse authority is
/// derived from these counters. All handles are bounded and local to a lookup.
final class SearchDiscoveryDiagnostics {
    private static let passKey = "kmsg.search.numeric-pass.v1"
    private static let sequenceKey = "kmsg.search.numeric-sequence.v1"
    private static let enabled = ProcessInfo.processInfo.environment["KMSG_READ_TIMING_ENABLED"]?.lowercased() == "true"

    static var currentPass: Pass? { Thread.current.threadDictionary[passKey] as? Pass }
    @discardableResult
    private static func install(_ pass: Pass?) -> Pass? {
        let previous = currentPass
        if let pass { Thread.current.threadDictionary[passKey] = pass }
        else { Thread.current.threadDictionary.removeObject(forKey: passKey) }
        return previous
    }

    static func make(
        enabled: Bool = enabled,
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> SearchDiscoveryDiagnostics? {
        guard enabled else { return nil }
        let previous = (Thread.current.threadDictionary[sequenceKey] as? NSNumber)?.intValue ?? 0
        // One native command process may try several searches. Bound every
        // command to 64 groups; the last group's clip bit exposes saturation.
        guard previous < 64 else { return nil }
        let sequence = previous + 1
        Thread.current.threadDictionary[sequenceKey] = NSNumber(value: sequence)
        return SearchDiscoveryDiagnostics(sequence: sequence, now: now)
    }

    private let sequence: Int
    private let now: () -> UInt64
    private let started: UInt64
    private var cache = 2
    private var rawCandidates = 0, enabledCandidates = 0
    private var passes: [Pass] = []

    init(sequence: Int, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.sequence = sequence
        self.now = now
        started = now()
    }

    func recordCache(hit: Bool) { cache = hit ? 1 : 0 }
    func recordCandidates(raw: Int, enabled: Int) {
        rawCandidates = raw
        enabledCandidates = enabled
    }

    /// The caller still evaluates focused/main lazily between the original
    /// walks. This wrapper neither adds a walk nor changes its result.
    func scan<T>(slot: Int, root: UIElement, _ body: () throws -> T) rethrows -> T {
        guard passes.count < 3 else { return try body() }
        let alias = passes.first(where: { CFEqual($0.root, root.axElement) })?.slot ?? slot
        let pass = Pass(slot: slot, alias: alias, root: root.axElement, now: now)
        passes.append(pass)
        let previous = Self.install(pass)
        var returned = false
        defer {
            Self.install(previous)
            pass.finish(returned: returned)
        }
        let result = try body()
        returned = true
        return result
    }

    func lines() -> [String] {
        var clipped = sequence >= 64
        func count(_ value: Int) -> String {
            let bounded = min(max(value, 0), 999999)
            if value != bounded { clipped = true }
            return String(bounded)
        }
        func time(_ value: Double) -> String {
            let bounded = value.isFinite ? min(max(value, 0), 86400) : 0
            if value != bounded { clipped = true }
            return String(format: "%.3f", bounded)
        }
        var aliases = 0
        for (left, right, bit) in [(0, 1, 1), (0, 2, 2), (1, 2, 4)] {
            if let a = passes.first(where: { $0.slot == left }),
               let b = passes.first(where: { $0.slot == right }), CFEqual(a.root, b.root) {
                aliases |= bit
            }
        }
        let unique = passes.filter { $0.slot == $0.alias }.count
        let total = time(Self.seconds(started, now()))
        var line = "[kmsg] search-detail total=\(total) status=ok schema=1 seq=\(count(sequence)) cache=\(count(cache))"
        line += " roots=\(count(passes.count)) unique=\(count(unique)) aliases=\(count(aliases))"
        line += " raw=\(count(rawCandidates)) enabled=\(count(enabledCandidates))"
        line += " returned=\(count(passes.filter { $0.returned }.count))"
        line += " clip=\(clipped ? 1 : 0)"
        return [line] + passes.map { $0.line(sequence: sequence, total: total) }
    }

    func emit() {
        let rendered = lines()
        // A diagnostic failure must never change native command success.
        guard rendered.allSatisfy({ $0.utf8.count < 500 }) else { return }
        try? FileHandle.standardError.write(contentsOf: Data((rendered.joined(separator: "\n") + "\n").utf8))
    }

    private static func seconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000_000
    }

    final class Pass: NSObject {
        let slot: Int, alias: Int
        let root: AXUIElement
        private let now: () -> UInt64
        private let started: UInt64
        private var wall = 0.0, axSeconds = 0.0, axMaximum = 0.0
        private var scalar = 0, batch = 0, requestErrors = 0
        private var visits = 0, complete = 0, prefix = 0, prefixOpen = true
        private var noValue = 0, unsupported = 0, otherFault = 0, roleMissing = 0
        private var rootComplete = 0, maximumDepth = 0, direct = 0
        private var tables = 0, rows = 0, underTable = 0, underRow = 0
        private var fields = 0, tableFields = 0, unknownPath = 0
        private(set) var returned = false
        private struct Edge { let element: AXUIElement; let depth: Int; let ancestry: Int }
        // Only the first 140 queue entries can be visited by the real walk.
        // No parent query, extra traversal, or unbounded graph is retained.
        private var queue: [Edge] = []
        private var cursor = 0, rootObserved = false

        init(slot: Int, alias: Int, root: AXUIElement, now: @escaping () -> UInt64) {
            self.slot = slot; self.alias = alias; self.root = root; self.now = now
            started = now()
            super.init()
        }
        func beginRead() -> UInt64 { now() }
        func endRead(_ start: UInt64, batch isBatch: Bool, error: AXError) {
            let elapsed = SearchDiscoveryDiagnostics.seconds(start, now())
            if isBatch { batch += 1 } else { scalar += 1 }
            if error != .success { requestErrors += 1 }
            axSeconds += elapsed
            axMaximum = max(axMaximum, elapsed)
        }
        func finish(returned: Bool) {
            self.returned = returned
            wall = SearchDiscoveryDiagnostics.seconds(started, now())
        }

        func recordScalar(element: AXUIElement, name: String, error: AXError, raw: CFTypeRef?) {
            guard !rootObserved, name == kAXChildrenAttribute, CFEqual(root, element) else { return }
            rootObserved = true
            guard error == .success, let children = raw as? [AXUIElement] else { return }
            rootComplete = 1
            queue = children.prefix(140).map { Edge(element: $0, depth: 1, ancestry: 0) }
        }

        /// Decode only values already returned to roleAndChildrenRead. Typed
        /// absence is counted, never promoted to a complete/cached structure.
        func recordStructure(element: AXUIElement, error: AXError, raw: [AnyObject]?) {
            visits += 1
            let validRaw = error == .success && raw?.count == 2
            let role = validRaw ? raw?[0] as? String : nil
            let children = validRaw ? raw?[1] as? [AXUIElement] : nil
            let isComplete = role != nil && children != nil
            if isComplete { complete += 1; if prefixOpen { prefix += 1 } }
            else {
                prefixOpen = false
                if role == nil { roleMissing += 1 }
                var absence: AXError?
                if validRaw, role != nil, let value = raw?[1],
                   CFGetTypeID(value) == AXValueGetTypeID() {
                    let typed = unsafeDowncast(value, to: AXValue.self)
                    var status = AXError.success
                    if AXValueGetType(typed) == .axError, AXValueGetValue(typed, .axError, &status) { absence = status }
                }
                if absence == .noValue { noValue += 1 }
                else if absence == .attributeUnsupported { unsupported += 1 }
                else { otherFault += 1 }
            }

            let isTable = role == kAXTableRole || role == kAXOutlineRole || role == kAXListRole
            let isRow = role == kAXRowRole
            let isField = role == kAXTextFieldRole
            if isTable { tables += 1 }
            if isRow { rows += 1 }
            if isField { fields += 1 }

            guard cursor < queue.count, CFEqual(queue[cursor].element, element) else {
                unknownPath += 1
                // A mismatch cannot influence the real queue or return value.
                cursor = queue.count
                return
            }
            let edge = queue[cursor]
            cursor += 1
            maximumDepth = max(maximumDepth, edge.depth)
            if edge.depth == 1 { direct += 1 }
            if edge.ancestry & 1 != 0 { underTable += 1; if isField { tableFields += 1 } }
            if edge.ancestry & 2 != 0 { underRow += 1 }
            // Preserve the original enqueue boundary in the observer model.
            if visits < 140, fields < 8, let children {
                let ancestry = edge.ancestry | (isTable ? 1 : 0) | (isRow ? 2 : 0)
                for child in children.prefix(max(0, 140 - queue.count)) {
                    queue.append(Edge(element: child, depth: edge.depth + 1, ancestry: ancestry))
                }
            }
        }

        func line(sequence: Int, total: String) -> String {
            var clipped = false
            func count(_ value: Int) -> String {
                let bounded = min(max(value, 0), 999999)
                if bounded != value { clipped = true }
                return String(bounded)
            }
            func time(_ value: Double) -> String {
                let bounded = value.isFinite ? min(max(value, 0), 86400) : 0
                if bounded != value { clipped = true }
                return String(format: "%.3f", bounded)
            }
            var line = "[kmsg] search-pass total=\(total) status=ok schema=1 seq=\(count(sequence)) pass=\(count(slot)) alias=\(count(alias))"
            line += " returned=\(returned ? 1 : 0)"
            for (name, value) in [("visits", visits), ("complete", complete), ("prefix", prefix),
                                  ("noValue", noValue), ("unsupported", unsupported), ("otherFault", otherFault),
                                  ("roleMissing", roleMissing), ("rootComplete", rootComplete), ("depth", maximumDepth),
                                  ("direct", direct), ("table", tables), ("row", rows), ("underTable", underTable),
                                  ("underRow", underRow), ("fields", fields), ("tableFields", tableFields),
                                  ("unknownPath", unknownPath)] {
                line += " \(name)=\(count(value))"
            }
            line += " ax=\(count(scalar)),\(count(batch)),\(time(axSeconds)),\(time(axMaximum)),\(count(requestErrors))"
            line += " wall=\(time(wall)) clip=\(clipped ? 1 : 0)"
            return line
        }
    }
}
