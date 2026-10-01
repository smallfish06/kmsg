import Foundation

/// Diagnostic estimates from values already read by the real ACK traversal.
/// This object cannot serve a traversal result or grant reuse permission.
final class AuthShadowPlanner {
    fileprivate struct Key: Hashable {
        let element: UIElement
        static func == (lhs: Key, rhs: Key) -> Bool {
            CFEqual(lhs.element.axElement, rhs.element.axElement)
        }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element.axElement)) }
    }
    struct Snapshot {
        fileprivate var nodes: [Key: (role: String, children: [UIElement])] = [:]
        fileprivate var roots: [Key: [UIElement]] = [:]

        init(nodes: [(UIElement, String, [UIElement])], roots: [(UIElement, [UIElement])]) {
            for (element, role, children) in nodes {
                self.nodes[Key(element: element)] = (role, children)
            }
            for (element, children) in roots { self.roots[Key(element: element)] = children }
        }
    }
    private struct Request {
        let roots: ArraySlice<UIElement>
        let roles: Set<String>
        let limits: [String: Int]
        let maxNodes: Int
        let guardCost: Int
    }
    private struct Totals {
        var plans = 0, bestNet = 0, hits = 0, nodes = 0, guardCost = 0
        var rootMissing = 0, unknownBreaks = 0
    }

    private let maxHints: Int
    private var leafHints: [Key: String] = [:]
    private var pending: Request?
    private var totals: [AuthReadDiagnostics.ShadowVariant: Totals] = [:]

    init(maxHints: Int = 4096) { self.maxHints = maxHints }

    func observe(_ element: UIElement, role: String?, typedAbsence: Bool) {
        let key = Key(element: element)
        if typedAbsence, let role {
            if leafHints[key] == nil, leafHints.count < maxHints { leafHints[key] = role }
        } else { leafHints.removeValue(forKey: key) }
    }

    /// Called only when the real planner passes its existing entry gates.
    func beforeRoot(
        roots: ArraySlice<UIElement>, roles: Set<String>, limits: [String: Int],
        maxNodes: Int, guardCost: Int, snapshot: Snapshot
    ) {
        let request = Request(roots: roots, roles: roles, limits: limits,
                              maxNodes: maxNodes, guardCost: guardCost)
        pending = request
        evaluate(.base, request: request, snapshot: snapshot, includeHints: false)
        evaluate(.a, request: request, snapshot: snapshot, includeHints: true)
    }

    /// Uses the one existing root-children read, after its original bookkeeping.
    /// A new real activation does not hide this estimate; a real fault does.
    func afterRoot(_ root: UIElement, snapshot: @autoclosure () -> Snapshot, valid: Bool) {
        let request = pending
        pending = nil
        guard valid, let request, let expected = request.roots.first,
              CFEqual(root.axElement, expected.axElement) else { return }
        let current = snapshot()
        evaluate(.b, request: request, snapshot: current, includeHints: false)
        evaluate(.ab, request: request, snapshot: current, includeHints: true)
    }

    private func evaluate(
        _ variant: AuthReadDiagnostics.ShadowVariant, request: Request,
        snapshot: Snapshot, includeHints: Bool
    ) {
        var total = totals[variant, default: Totals()]
        total.plans += 1
        var hits = 0
        var keys = Set<Key>()
        for root in request.roots {
            let rootKey = Key(element: root)
            guard let children = snapshot.roots[rootKey] ?? snapshot.nodes[rootKey]?.children else {
                total.rootMissing += 1
                continue
            }
            var queue = Array(children.prefix(request.maxNodes))
            var index = 0, saturated = 0
            var matches: [String: Int] = [:]
            while index < queue.count, index < request.maxNodes, saturated < request.roles.count {
                let key = Key(element: queue[index])
                let known = snapshot.nodes[key]
                let hint = includeHints ? leafHints[key] : nil
                guard known != nil || hint != nil else { total.unknownBreaks += 1; break }
                index += 1
                if known != nil { hits += 1; keys.insert(key) }
                let role = known?.role ?? hint!
                if request.roles.contains(role) {
                    let limit = request.limits[role] ?? .max
                    if matches[role, default: 0] < limit {
                        matches[role, default: 0] += 1
                        if matches[role] == limit { saturated += 1 }
                    }
                }
                if saturated < request.roles.count, index < request.maxNodes {
                    queue.append(contentsOf: (known?.children ?? []).prefix(request.maxNodes - queue.count))
                }
            }
        }
        let net = hits - keys.count
        if total.plans == 1 || net > total.bestNet {
            total.bestNet = net; total.hits = hits
            total.nodes = keys.count; total.guardCost = request.guardCost
        }
        totals[variant] = total
    }

    func discard() {
        leafHints.removeAll(keepingCapacity: false)
        pending = nil
    }

    func record(into diagnostics: AuthReadDiagnostics) {
        for variant in AuthReadDiagnostics.ShadowVariant.allCases {
            let value = totals[variant, default: Totals()]
            diagnostics.recordShadow(variant, plans: value.plans, bestNet: value.bestNet,
                hits: value.hits, nodes: value.nodes, guardCost: value.guardCost,
                rootMissing: value.rootMissing, unknownBreaks: value.unknownBreaks)
        }
    }
}
