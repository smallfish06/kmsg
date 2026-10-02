

setenv("KMSG_NATIVE_OBSERVATION_ENABLED", "true", 1)
let parser = Parser()
let costEnabled = CommandLine.arguments.contains("on")
setenv("KMSG_READ_TIMING_ENABLED", "true", 1)
let reference = Date(timeIntervalSince1970: 1_790_827_200)
func makeRow(_ index: Int, _ body: String, owner: String = "peer") -> UIElement {
    let y = CGFloat(index * 60), x: CGFloat = owner == "peer" ? 20 : 260
    let text = UIElement(kAXTextAreaRole, CGRect(x:x,y:y+24,width:100,height:20),body)
    let time = UIElement(kAXStaticTextRole, CGRect(x:x,y:y+44,width:80,height:12),"오후 12:00")
    time.helpText = "2026. 10. 1."
    var children = [text,time]
    if owner == "peer" { children.insert(UIElement(kAXStaticTextRole,CGRect(x:x,y:y+4,width:80,height:16),"peer fixture"),at:0) }
    return UIElement(kAXRowRole,CGRect(x:0,y:y,width:400,height:60),children:[
        UIElement(kAXCellRole,CGRect(x:0,y:y,width:400,height:60),children:children)])
}
func baseline() -> [UIElement] { (0..<11).map { makeRow($0,$0 == 10 ? "previous own reply" : "synthetic own \($0)",owner:"self") } + [makeRow(11,"repeat")] }
func appended() -> [UIElement] { baseline() + [makeRow(12,"repeat")] }
func extract(_ rows: [UIElement], fresh: [UIElement]? = nil, rootRows: [UIElement]? = nil, enabled: Bool = true, limit: Int = 10) -> [String:Any] {
    if enabled { setenv("KMSG_NATIVE_OBSERVATION_ENABLED", "true", 1) }
    else { unsetenv("KMSG_NATIVE_OBSERVATION_ENABLED") }
    let root = UIElement(kAXScrollAreaRole,CGRect(x:0,y:-10,width:400,height:1500),children:rootRows ?? fresh ?? rows)
    let cache = FrameCache()
    cache.readEvidence = TranscriptReadEvidenceDiagnostics()
    cache.lastCollectedRow = rows.last?.axElement
    cache.readEvidence?.setCollection([rows.count,rows.count,rows.count,rows.count,0,0,0,0,0,0,0])
    let eventStart = AXEvents.count, clockStart = ParseFixtureClock.calls
    var phases: [String] = []
    let phase: ((String) -> Void)? = costEnabled ? { phases.append($0) } : nil
    var recollections = 0, distinctSources = true, distinctCaches = true
    let result = parser.extractMessages(from:rows,transcriptRoot:root,limit:limit,includeSystemMessages:false,
        referenceDate:reference,frameCache:cache,recollectRows:{ freshCache in
            recollections += 1
            distinctSources = distinctSources && cache.observationSources !== freshCache.observationSources
            distinctCaches = distinctCaches && cache !== freshCache
            let chosen = fresh ?? rows
            freshCache.lastCollectedRow = chosen.last?.axElement
            freshCache.readEvidence?.setCollection([chosen.count,chosen.count,chosen.count,chosen.count,0,0,0,0,0,0,0])
            return chosen
        }, readPhase: phase)
    try! FileHandle.standardError.write(contentsOf: Data("[kmsg] read-detail total=99.99 status=ok\n".utf8))
    var payload = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(result.messages)) as! [[String:Any]]
    let observationIDs = Set(result.messages.compactMap { $0.nativeObservation?.id })
    precondition(observationIDs.count <= 1)
    for index in payload.indices {
        if var observation = payload[index]["native_observation"] as? [String:Any] {
            precondition(UUID(uuidString: observation["id"] as! String) != nil)
            observation["id"] = "read-local-uuid"; payload[index]["native_observation"] = observation
        }
    }
    let sourceRefs = result.messages.map { message -> String in
        guard let s=message.nativeSource else { return "none" }
        return "\(s.row ?? -1)/\(s.body ?? -1)/\(s.origin)/\(s.ambiguous)"
    }
    var seen = Set<ObjectIdentifier>(), calls = [0,0,0,0]
    func count(_ node: UIElement) {
        guard seen.insert(ObjectIdentifier(node)).inserted else { return }
        calls[0] += node.frameReads; calls[1] += node.childReads
        calls[2] += node.searches; calls[3] += node.attributeReads
        node.nodes.forEach(count)
    }
    ([root] + rows + (fresh ?? [])).forEach(count)
    return ["messages":payload,"calls":calls,"recollections":recollections,
        "sourceRefs":sourceRefs,"axEvents":Array(AXEvents[eventStart...]),"clockCalls":ParseFixtureClock.calls-clockStart,"phases":phases,
        "freshSourcesDistinct":distinctSources,"freshCachesDistinct":distinctCaches,"notes":Dictionary(uniqueKeysWithValues:result.notes.map{($0.key,$0.value)}),
        "repeatRows":result.messages.filter{$0.body == "repeat"}.count,
        "order":result.messages.first?.nativeObservation?.order.rawValue ?? "empty",
        "multiplicity":result.messages.first?.nativeObservation?.multiplicity.rawValue ?? "empty"]
}
let dead = (0..<30).map{_ in UIElement(kAXRowRole)}
var results:[String:[String:Any]] = [:]
results["baseline"] = extract(baseline())
results["direct-fresh-append"] = extract(appended())
results["sparse-full-replacement"] = extract(dead,fresh:appended())
results["sparse-partial-fresh"] = extract((0..<30).map{_ in UIElement(kAXRowRole)},fresh:[makeRow(11,"repeat"),makeRow(12,"repeat")])
results["sparse-empty-fresh"] = extract((0..<30).map{_ in UIElement(kAXRowRole)},fresh:[])
let shared = makeRow(11,"repeat")
results["same-ax-row-twice"] = extract(Array(baseline().prefix(11))+[shared,shared])
let sameGeometry = baseline()+[makeRow(11,"repeat")]
results["different-ax-same-geometry"] = extract(sameGeometry)
let unknown = appended()
unknown[12].bounds = nil
unknown[12].nodes[0].nodes = [UIElement(kAXTextAreaRole,nil,"repeat"),UIElement(kAXStaticTextRole,nil,"오후 12:00")]
results["attribution-fresh-replacement"] = extract(unknown,fresh:appended())
let changed = appended(); changed[11].nodes[0].nodes[0].stringValue = "other peer fixture"
results["attribution-known-owner-changed"] = extract(unknown,fresh:changed)
let shifted = baseline() + [makeRow(12,"different last input")]
results["attribution-window-changed"] = extract(unknown,fresh:shifted)
let ambiguous = appended()
ambiguous[12].nodes[0].nodes.append(UIElement(kAXTextAreaRole,CGRect(x:20,y:744,width:100,height:20),"repeat"))
results["ambiguous-body-node"] = extract(ambiguous)

let heldMessages = (0..<26).map{_ in UIElement(kAXRowRole)} + (26..<30).map{ makeRow($0,"retained first \($0)") }
results["held-rows-reparse-empty-recollection"] = extract(heldMessages,fresh:[],rootRows:heldMessages)
results["fresh-worse-retains-first"] = extract(heldMessages,fresh:[makeRow(28,"worse fresh 1"),makeRow(29,"worse fresh 2")])
let sharedBodyRows = appended()
sharedBodyRows[12].nodes[0].nodes[1] = sharedBodyRows[11].nodes[0].nodes[1]
results["shared-ax-body-distinct-rows"] = extract(sharedBodyRows)

results["direct-fresh-off"] = extract(appended(),enabled:false)
results["sparse-full-replacement-off"] = extract((0..<30).map{_ in UIElement(kAXRowRole)},fresh:appended(),enabled:false)

// Additional hot-path and structure/error shapes. All values are synthetic.
let longRows = (0..<53).map { makeRow($0,"CUSTOMER_SECRET_SENTINEL \($0)",owner:"self") }
results["fifty-three-rows-early-stop"] = extract(longRows, limit:50)
let deepRows=(0..<12).map { i -> UIElement in
    let r=makeRow(i,"deep \(i)",owner:"self")
    let content=r.nodes[0].nodes
    r.nodes[0].nodes=[UIElement(kAXGroupRole, children: (0..<80).map { _ in UIElement(kAXGroupRole) } + content)]
    return r
}
results["deep-role-backfill"] = extract(deepRows)
let rich=(0..<12).map { i -> UIElement in
    let r=makeRow(i,"https://example.test/path...",owner:"self")
    let cell=r.nodes[0]
    let link=UIElement(kAXLinkRole,CGRect(x:260,y:CGFloat(i*60+24),width:100,height:20))
    link.title="SYNTHETIC_LINK_TITLE"
    cell.nodes.append(link)
    cell.nodes.append(UIElement(kAXImageRole,CGRect(x:260,y:CGFloat(i*60+20),width:120,height:100)))
    let button=UIElement(kAXButtonRole);button.title="save"
    cell.nodes.append(button)
    return r
}
results["rich-links-images-buttons"] = extract(rich)
let errors=appended()
errors[12].childrenReadComplete=false
errors[12].nodes[0].nodes.append(UIElement(kAXGroupRole,children:[UIElement(kAXStaticTextRole,nil,"static fault")]))
results["incomplete-row-children"] = extract(errors)
let early=(0..<12).map { makeRow($0,"plain \($0)",owner:"self") }
early[11].nodes[0].nodes.append(UIElement(kAXStaticTextRole,nil,""))
results["empty-static-continue"] = extract(early)

let data=try! JSONSerialization.data(withJSONObject:results,options:[.sortedKeys])
print(String(data:data,encoding:.utf8)!)

