
func makeContext(_ mode: String) -> (KakaoTalkApp, UIElement, UIElement, UIElement, Probe) {
    let p = Probe(), enabled = mode != "no-input"
    let rows = (1...(mode == "empty-descendants" ? 1 : 20)).map { UIElement($0, mode == "empty-descendants" ? "AXGroup" : kAXRowRole, CGRect(x: 0,y: $0 * 10,width: 780,height: 8), [], p, enabled) }
    let texts = (1...20).map { UIElement($0 + 100, mode == "empty-descendants" ? "AXGroup" : kAXStaticTextRole, nil, [], p, enabled) }
    let others = (1...300).map { UIElement($0 + 500, "AXGroup", nil, [], p, enabled) }
    let group = UIElement(1000, kAXGroupRole, CGRect(x: 0,y: 0,width: 800,height: 450), rows + texts + others, p, enabled)
    let table = UIElement(1001, kAXTableRole, CGRect(x: 0,y: 0,width: 800,height: 450), [group], p, enabled)
    let scroll = UIElement(1002, kAXScrollAreaRole, CGRect(x: 0,y: 0,width: 800,height: 450), [table], p, enabled)
    let input = UIElement(1003, kAXTextAreaRole, CGRect(x: 0,y: 500,width: 800,height: 80), [], p, enabled)
    let pane = UIElement(1004, kAXGroupRole, CGRect(x: 0,y: 0,width: 800,height: 600), [scroll, input], p, enabled)
    let window = UIElement(1005, kAXWindowRole, CGRect(x: 0,y: 0,width: 800,height: 600), [pane], p, enabled)
    let app = UIElement(1006, kAXApplicationRole, nil, [window], p, enabled)
    app.focused = mode == "predicate-input" || !enabled ? nil : input
    return (KakaoTalkApp(applicationElement: app), window, input, scroll, p)
}
func run(_ mode: String, _ optimized: Bool) -> ([Int], [String], [String:String]) {
    let (app,window,input,scroll,p) = makeContext(mode)
    AXPathCacheStore.shared.elements = mode == "cached" ? [.messageInput: input, .transcriptRoot: scroll] : [:]
    var notes = [String:String]()
    let cost = TranscriptReadCost { notes[$0] = $1 }
    let found: MessageTranscriptContext?
    if optimized {
        found = MessageContextResolver(kakao: app, runner: AXActionRunner(), useCache: mode == "cached", interactionMode: .backgroundSafe, readCost: cost).resolve(in: window)
    } else {
        found = BaselineMessageContextResolver(kakao: app, runner: AXActionRunner(), useCache: mode == "cached", interactionMode: .backgroundSafe, readCost: cost).resolve(in: window)
    }
    cost.emit()
    return (found.map { [$0.inputElement.id, $0.chatPaneRoot?.id ?? -1, $0.transcriptRoot.id] } ?? [], p.calls, notes)
}
func summarize(_ r: ([Int], [String], [String:String])) -> [String:Any] {
    ["contextIdentities": r.0, "allAXQueries": r.1.count,
     "roleAndChildrenBatches": r.1.filter { $0.hasPrefix("batch:") }.count,
     "childrenQueries": r.1.filter { $0.hasPrefix("children:") }.count,
     "contextCosts": r.2["costctx"]!]
}
var results = [[String:Any]]()
for mode in ["cold-nested", "cached", "empty-descendants", "predicate-input", "no-input"] {
    let before = run(mode, false), after = run(mode, true)
    precondition(before.0 == after.0, "actual resolver identity")
    precondition(after.1.count <= before.1.count, "actual resolver cost increase")
    // Queries before the first child bonus remain exactly the same, including
    // focused/predicate input discovery and spatial scoring. When no suffix is
    // pruned (cache or no-input), the complete call stream is unchanged.
    let firstBatchBefore = before.1.firstIndex { $0.hasPrefix("batch:") } ?? before.1.endIndex
    let firstBatchAfter = after.1.firstIndex { $0.hasPrefix("batch:") } ?? after.1.endIndex
    precondition(Array(before.1[..<firstBatchBefore]) == Array(after.1[..<firstBatchAfter]))
    if mode == "cached" || mode == "no-input" || mode == "empty-descendants" {
        precondition(before.1 == after.1, "unchanged no-benefit path")
    }
    results.append(["mode": mode,"sameSelectedContext": true,"before": summarize(before),"after": summarize(after)])
}
print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), encoding: .utf8)!)
