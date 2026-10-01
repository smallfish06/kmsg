import Foundation
let kAXRowRole = "AXRow", kAXStaticTextRole = "AXStaticText"
final class Counter {
    var children = 0, batches = 0, bonusCalls = 0
    var called: [Int] = [], skipped: [Int] = []
    var renderAt: Int? = nil
    var renderEpoch = 1
    var dynamic = false
}
final class AXTraversalReadScope {
    func children(atRoot root: UIElement) -> [UIElement] { root.children }
    func roleAndChildren(of node: UIElement) -> (String?, [UIElement]) { node.roleAndChildren() }
}
final class UIElement {
    let id: Int, role: String, spatial: Double, c: Counter
    var nodes: [UIElement]
    init(_ id: Int, _ role: String, _ nodes: [UIElement], _ c: Counter, spatial: Double = 0) {
        self.id = id; self.role = role; self.nodes = nodes; self.c = c; self.spatial = spatial
    }
    var children: [UIElement] { c.children += 1; return nodes }
    func roleAndChildren() -> (String?, [UIElement]) {
        c.batches += 1
        if let threshold = c.renderAt, c.batches >= threshold { c.renderEpoch = 2 }
        let observedRole: String? = c.dynamic && c.batches % 7 == 0 ? nil : role
        return (observedRole, nodes)
    }
// PRODUCTION_BFS

}

// PRODUCTION_RANKERS
struct Spec { let scores: [Double]; let rows: [Int]; let texts: [Int]; var dynamic = false }
func same(_ a: (Int?, Double?), _ b: (Int?, Double?)) -> Bool {
    a.0 == b.0 && (a.1 == b.1 || (a.1?.isNaN == true && b.1?.isNaN == true))
}
func nodes(_ id: Int, _ rowCount: Int, _ textCount: Int, _ c: Counter) -> [UIElement] {
    let rows = (0..<rowCount).map { UIElement(id + $0, kAXRowRole, [], c) }
    let texts = (0..<textCount).map { UIElement(id + 100 + $0, kAXStaticTextRole, [], c) }
    let other = (0..<300).map { UIElement(id + 1000 + $0, "AXGroup", [], c) }
    return rows + texts + other
}
func execute(_ spec: Spec, _ optimized: Bool) -> ((Int?, Double?), Counter) {
    let c = Counter(); c.dynamic = spec.dynamic
    let candidates = spec.scores.enumerated().map { i, score in
        UIElement(i + 1, "AXGroup", nodes((i + 1) * 10_000, spec.rows[i], spec.texts[i], c), c, spatial: score)
    }
    let outcome = optimized ? Bounded().select(candidates) : Original().select(candidates)
    return (outcome, c)
}
func safeScore(_ value: Double?) -> Any {
    guard let value else { return NSNull() }
    return value.isFinite ? value : value.isNaN ? "nan" : value > 0 ? "positive-infinity" : "negative-infinity"
}
func summary(_ value: ((Int?, Double?), Counter)) -> [String: Any] {
    ["winner": value.0.0 as Any? ?? NSNull(), "winningScore": safeScore(value.0.1),
     "bonusCalls": value.1.bonusCalls, "childrenQueries": value.1.children, "roleAndChildrenBatches": value.1.batches,
     "calledCandidates": value.1.called, "skippedCandidates": value.1.skipped, "renderEpoch": value.1.renderEpoch]
}
var output: [[String: Any]] = []
let fixtures: [(String, Spec)] = [
    ("all-max", Spec(scores: [8220, 7420, 5320], rows: [20,20,20], texts: [20,20,20])),
    ("first-empty-second-wins", Spec(scores: [8220,7420,5320], rows: [0,20,20], texts: [0,20,20])),
    ("persistent-empty-all-search", Spec(scores: [8220,7420,5320], rows: [0,0,0], texts: [0,0,0])),
    ("tied-winners-pruned-suffix", Spec(scores: [8000,7750,4000], rows: [0,5,20], texts: [20,0,20])),
    ("tied-winner-follows-spatial-order", Spec(scores: [7750,8000,4000], rows: [5,0,20], texts: [0,20,20])),
    ("strict-bound-tie", Spec(scores: [8000,5000,4000], rows: [0,20,20], texts: [20,20,20])),
    ("one-ulp-below-bound", Spec(scores: [8000,(5000.0).nextDown,4000], rows: [0,20,20], texts: [20,20,20])),
    ("one-ulp-above-bound", Spec(scores: [8000,(5000.0).nextUp,4000], rows: [0,20,20], texts: [20,20,20])),
    ("tiny-rounding-collapse", Spec(scores: [8000,5000.0.nextDown,5000.0.nextUp], rows: [0,20,20], texts: [20,20,20])),
    ("zero-negative-no-winner", Spec(scores: [0,-1,-Double.greatestFiniteMagnitude], rows: [20,20,20], texts: [20,20,20])),
    ("nan-no-prune", Spec(scores: [8220,Double.nan,5320], rows: [20,20,20], texts: [20,20,20])),
    ("fourth-nan-no-prune", Spec(scores: [8220,7420,5320,Double.nan], rows: [20,20,20,20], texts: [20,20,20,20])),
    ("fourth-negative-infinity-no-prune", Spec(scores: [8220,7420,5320,-Double.infinity], rows: [20,20,20,20], texts: [20,20,20,20])),
    ("infinity-no-prune", Spec(scores: [Double.infinity,7420,5320], rows: [20,20,20], texts: [20,20,20])),
    ("negative-infinity-no-prune", Spec(scores: [8220,7420,-Double.infinity], rows: [20,20,20], texts: [20,20,20])),
    ("overflow-upper-no-prune", Spec(scores: [Double.greatestFiniteMagnitude,Double.greatestFiniteMagnitude,Double.greatestFiniteMagnitude], rows: [20,20,20], texts: [20,20,20])),
    ("fourth-candidate-still-not-boosted", Spec(scores: [8220,7420,5320,5320], rows: [0,0,0,20], texts: [0,0,0,20])),
    ("dynamic-role-responses", Spec(scores: [8220,7420,5320], rows: [25,25,25], texts: [25,25,25], dynamic: true)),
]
for (label, spec) in fixtures {
    let before = execute(spec, false), after = execute(spec, true)
    precondition(same(before.0, after.0), label)
    precondition(after.1.called == Array(before.1.called.prefix(after.1.called.count)), "same evaluated prefix")
    if label == "tied-winners-pruned-suffix" { precondition(after.0.0 == 1) }
    if label == "tied-winner-follows-spatial-order" { precondition(after.0.0 == 2) }
    precondition(after.1.batches <= before.1.batches && after.1.children <= before.1.children, label)
    if label.contains("no-prune") { precondition(before.1.called == after.1.called, label) }
    if label == "strict-bound-tie" { precondition(after.1.called.contains(2)) }
    output.append(["case": label, "sameWinnerAndScore": true, "before": summary(before), "after": summary(after)])
}

// A common real method shape: three nested candidates revisit overlapping
// descendants. The resulting counts are synthetic query costs only.
func nested(_ optimized: Bool, renderAt: Int? = nil) -> ((Int?, Double?), Counter) {
    let c = Counter(); c.renderAt = renderAt
    let group = UIElement(3, "AXGroup", nodes(10000,20,20,c), c, spatial: 5320)
    let table = UIElement(2, "AXTable", [group], c, spatial: 7420)
    let scroll = UIElement(1, "AXScrollArea", [table], c, spatial: 8220)
    return (optimized ? Bounded().select([scroll,table,group]) : Original().select([scroll,table,group]), c)
}
for label in ["nested-overlap", "render-timing-not-snapshot-equivalence"] {
    let threshold: Int? = label == "nested-overlap" ? nil : 50
    let before = nested(false, renderAt: threshold), after = nested(true, renderAt: threshold)
    precondition(same(before.0, after.0))
    if threshold != nil { precondition(before.1.renderEpoch == 2 && after.1.renderEpoch == 1) }
    output.append(["case": label, "sameWinnerAndScore": true, "before": summary(before), "after": summary(after),
                   "wholeTranscriptSnapshotEquivalenceClaimed": false])
}

var generated = 0, pruned = 0, maxReduction = 0
let values = [0, 5, 20]
for ra in values { for rb in values { for rc in values {
 for ta in values { for tb in values { for tc in values {
  for scores in [[8220.0,7420.0,5320.0], [8000.0,5000.0,4000.0], [2000.0,2000.0,2000.0]] {
    let spec = Spec(scores: scores, rows: [ra,rb,rc], texts: [ta,tb,tc])
    let before = execute(spec, false), after = execute(spec, true)
    precondition(same(before.0, after.0), "generated winner")
    precondition(after.1.called == Array(before.1.called.prefix(after.1.called.count)), "generated same evaluated prefix")
    precondition(after.1.batches <= before.1.batches, "generated query increase")
    generated += 1
    if after.1.bonusCalls < before.1.bonusCalls { pruned += 1 }
    maxReduction = max(maxReduction, before.1.batches - after.1.batches)
  }
 }}}}}}
// The exact production quota method must keep this bound valid even when
// hundreds of matching nodes are exposed by the fixture.
let cap = execute(Spec(scores: [100.0], rows: [100], texts: [100]), false)
precondition(cap.0.1 == 100.0 + TranscriptChildBonus.maximum)
let result: [String: Any] = ["cases": output, "generated": generated, "generatedWithPruning": pruned,
    "generatedWinnerMismatch": 0, "generatedAXIncrease": 0, "maxSyntheticBatchReduction": maxReduction,
    "exactProductionBonusUpperBound": TranscriptChildBonus.maximum, "rawContentExported": false]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
