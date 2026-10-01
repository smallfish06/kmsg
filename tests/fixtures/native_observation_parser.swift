
var checks = 0
func check(_ label: String, _ value: @autoclosure () -> Bool) {
    checks += 1
    if !value() { fatalError(label) }
}
let parser = Parser()
let reference = Date(timeIntervalSince1970: 1_790_827_200)
func makeRow(_ index: Int, _ body: String, owner: String = "peer", day: String = "2026. 10. 1.") -> UIElement {
    let y = CGFloat(index * 60)
    let x: CGFloat = owner == "peer" ? 20 : 260
    let text = UIElement(kAXTextAreaRole, CGRect(x: x, y: y + 24, width: 100, height: 20), body)
    let time = UIElement(kAXStaticTextRole, CGRect(x: x, y: y + 44, width: 80, height: 12), "오후 12:00")
    time.helpText = day
    var children = [text, time]
    if owner == "peer" { children.insert(UIElement(kAXStaticTextRole, CGRect(x: x, y: y + 4, width: 80, height: 16), "Peer"), at: 0) }
    return UIElement(kAXRowRole, CGRect(x: 0, y: y, width: 400, height: 60), children: [
        UIElement(kAXCellRole, CGRect(x: 0, y: y, width: 400, height: 60), children: children)
    ])
}
func fixture() -> [UIElement] {
    [makeRow(0, "first"), makeRow(1, "second", owner: "self"), makeRow(2, "third"),
     makeRow(3, "repeat"), makeRow(4, "repeat"), makeRow(5, "last", owner: "self")]
}
func run(_ rows: [UIElement], enabled: Bool, limit: Int = 10, recollect: [UIElement]? = nil) -> [TranscriptMessage] {
    if enabled { setenv("KMSG_NATIVE_OBSERVATION_ENABLED", "true", 1) }
    else { unsetenv("KMSG_NATIVE_OBSERVATION_ENABLED") }
    let root = UIElement(kAXScrollAreaRole, CGRect(x: 0, y: -10, width: 400, height: 1200), children: rows)
    return parser.extractMessages(from: rows, transcriptRoot: root, limit: limit,
        includeSystemMessages: false, referenceDate: reference, frameCache: FrameCache(),
        recollectRows: { _ in recollect ?? rows }).messages
}
func json(_ message: TranscriptMessage) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
}
func calls(_ rows: [UIElement]) -> [Int] {
    var result = [0, 0, 0, 0]
    func visit(_ node: UIElement) {
        result[0] += node.frameReads; result[1] += node.childReads
        result[2] += node.searches; result[3] += node.attributeReads
        for child in node.nodes { visit(child) }
    }
    rows.forEach(visit)
    return result
}
let offRows = fixture(), onRows = fixture()
let off = run(offRows, enabled: false), on = run(onRows, enabled: true)
check("default-off retains content dedup", off.map(\.body) == ["first", "second", "third", "repeat", "last"])
check("default-off emits no new JSON key", off.allSatisfy { json($0)["native_observation"] == nil })
check("distinct equal text rows survive actual extraction", on.map(\.body) == ["first", "second", "third", "repeat", "repeat", "last"])
check("normal parser certifies mixed-side same-minute order", on.allSatisfy { $0.nativeObservation?.order == .verified })
check("no extra AX work on normal parse", calls(onRows) == calls(offRows))
check("physical multiplicity declared", on.allSatisfy { $0.nativeObservation?.multiplicity == .physicalRow })
check("one UUID across returned read", Set(on.compactMap { $0.nativeObservation?.id }).count == 1)
check("UUID parses", UUID(uuidString: on[0].nativeObservation!.id) != nil)
check("final indices consecutive", on.map { $0.nativeObservation!.index } == Array(0..<on.count))
check("final counts exact", on.allSatisfy { $0.nativeObservation?.count == on.count })
let encoded = json(on[3])["native_observation"] as! [String: Any]
check("only bounded contract exported", Set(encoded.keys) == Set(["version", "id", "index", "count", "order", "multiplicity"]))
check("no native source encoded", json(on[3])["nativeSource"] == nil && json(on[3])["native_source"] == nil)
check("capture preserves observation metadata", on[3].withCapturedImages(paths: ["/tmp/test.png"], sha256: ["test"]).nativeObservation == on[3].nativeObservation)
check("separate reads never reuse observation UUID", run(fixture(), enabled: true)[0].nativeObservation!.id != on[0].nativeObservation!.id)
let repeatedSource = fixture()
let duplicate = run(Array(repeatedSource.prefix(4)) + [repeatedSource[3]] + Array(repeatedSource.suffix(2)), enabled: true)
check("same physical row duplicate exposure removed", duplicate.count == 6)
check("same source duplicate preserves two real repeat bubbles", duplicate.filter { $0.body == "repeat" }.count == 2)
let dayRows = fixture()
dayRows[4].nodes[0].nodes.last!.helpText = "2026. 10. 2."
let dates = run(dayRows, enabled: true).filter { $0.body == "repeat" }
check("distinct dates retained with physical multiplicity", dates.count == 2 && dates[0].date == "2026-10-01" && dates[1].date == "2026-10-02")
let tied = fixture(); tied[4].bounds = tied[3].bounds
check("tied row bounds fall back to legacy", run(tied, enabled: true).filter { $0.body == "repeat" }.count == 1)
let missing = fixture(); missing[4].bounds = nil
check("missing row bounds never certify", run(missing, enabled: true).allSatisfy { $0.nativeObservation?.order == .uncertain })
let fallbackRows = [makeRow(0, "only row")]
let fallback = run(fallbackRows, enabled: true)
check("actual parser fallback overlap remains one message", fallback.count == 1 && fallback[0].body == "only row")
check("fallback is uncertain", fallback[0].nativeObservation?.order == .uncertain)
let longFallbackRoot = UIElement(kAXScrollAreaRole, CGRect(x: 0, y: -10, width: 400, height: 1200),
    children: (0..<12).map { makeRow($0, "history \($0)") })
let legacyFallback = parser.extractFallbackMessages(from: longFallbackRoot, limit: 3, referenceDate: reference)
let observedFallback = parser.extractFallbackMessages(from: longFallbackRoot, limit: 3, referenceDate: reference,
    observationSources: TranscriptObservationSources())
check("fallback limit remains unchanged", observedFallback.count == 3 && observedFallback.map(\.body) == legacyFallback.map(\.body))
let recovered = run((0..<30).map { _ in UIElement(kAXRowRole) }, enabled: true, recollect: fixture())
check("sparse recollection keeps real repeated rows", recovered.filter { $0.body == "repeat" }.count == 2)
check("sparse recollection cannot certify stable observation", recovered.allSatisfy { $0.nativeObservation?.order == .uncertain })
let unknownTail = fixture()
unknownTail[5].bounds = nil
unknownTail[5].nodes[0].nodes[0].bounds = nil
let attributed = run(unknownTail, enabled: true, recollect: fixture())
check("attribution recollection resolves existing unknown author", attributed.last?.authorSource == "default-me")
check("attribution recollection cannot certify stable observation", attributed.allSatisfy { $0.nativeObservation?.order == .uncertain })
let limited = run(fixture(), enabled: true, limit: 4)
check("limit metadata follows actual final array", limited.count == 4 && limited.map { $0.nativeObservation!.index } == [0, 1, 2, 3]
    && limited.allSatisfy { $0.nativeObservation?.count == 4 })
// No source identity is available for an unmeasured alternate body: keep the
// old content fallback instead of claiming it is another physical message.
let ambiguous = fixture()
ambiguous[4].nodes[0].nodes.append(UIElement(kAXTextAreaRole, CGRect(x: 20, y: 264, width: 100, height: 20), "repeat"))
check("ambiguous multiple body nodes retain legacy count", run(ambiguous, enabled: true).filter { $0.body == "repeat" }.count == 1)
unsetenv("KMSG_NATIVE_OBSERVATION_ENABLED")
print("OK: \(checks) production parser observation assertions")
