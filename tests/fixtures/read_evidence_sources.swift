setenv("KMSG_READ_TIMING_ENABLED", CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "true", 1)
setenv("KMSG_NATIVE_OBSERVATION_ENABLED", "true", 1)
let parser = Parser()
let reference = Date(timeIntervalSince1970: 1_790_827_200)
func makeRow(_ index: Int, body: String? = nil) -> UIElement {
    let y=CGFloat(index * 60)
    let name=UIElement(kAXStaticTextRole, CGRect(x:20,y:y+4,width:80,height:16), "synthetic peer")
    let text=UIElement(kAXTextAreaRole, CGRect(x:20,y:y+24,width:180,height:20), body ?? "synthetic message \(index)")
    let time=UIElement(kAXStaticTextRole, CGRect(x:20,y:y+44,width:80,height:12), "오후 12:00")
    time.helpText="2026. 10. 1."
    return UIElement(kAXRowRole,CGRect(x:0,y:y,width:400,height:60),children:[
        UIElement(kAXCellRole,CGRect(x:0,y:y,width:400,height:60),children:[name,text,time])])
}
let scenario=CommandLine.arguments[1]
var rows=(0..<52).map{makeRow($0)}
if ["empty-last","fresh-empty-last","row-children-incomplete"].contains(scenario) {
    rows[51]=UIElement(kAXRowRole,CGRect(x:0,y:3060,width:400,height:60))
    if scenario == "row-children-incomplete" { rows[51].childrenReadComplete=false }
}
if scenario == "cell-empty-last" {
    rows[51]=UIElement(kAXRowRole,CGRect(x:0,y:3060,width:400,height:60),children:[UIElement(kAXCellRole)])
}
if scenario == "date-last" {
    rows[51]=UIElement(kAXRowRole,CGRect(x:0,y:3060,width:400,height:60),children:[
        UIElement(kAXCellRole,CGRect(x:0,y:3060,width:400,height:60),children:[
            UIElement(kAXTextAreaRole,CGRect(x:20,y:3084,width:180,height:20),"2026-10-01 목요일")])])
}
if scenario == "time-last" {
    rows[51]=UIElement(kAXRowRole,CGRect(x:0,y:3060,width:400,height:60),children:[
        UIElement(kAXCellRole,CGRect(x:0,y:3060,width:400,height:60),children:[
            UIElement(kAXStaticTextRole,CGRect(x:20,y:3084,width:100,height:20),"오후 12:00")])])
}
if scenario == "last-legacy-repeat" {
    rows[51]=makeRow(51,body:"synthetic message 50")
    rows[51].bounds=CGRect(x:0,y:3000,width:400,height:120)
}
if scenario == "identifier-failure-last" {
    func fail(_ node: UIElement) {
        UIElement.identifierErrors[ObjectIdentifier(node.axElement)] = .cannotComplete
        node.nodes.forEach(fail)
    }
    rows.forEach(fail)
}
let root=UIElement(kAXScrollAreaRole,CGRect(x:0,y:0,width:400,height:3200),children:[
    UIElement(kAXTableRole,CGRect(x:0,y:0,width:400,height:3200),children:rows)])
let input=UIElement(kAXTextAreaRole,CGRect(x:0,y:3250,width:400,height:80))
let cache=FrameCache(); if TranscriptReadEvidenceDiagnostics.enabled { cache.readEvidence=TranscriptReadEvidenceDiagnostics() }
let collected=parser.collectTranscriptRows(from:root,inputElement:input,messageLimit:10,frameCache:cache)
var initialRows=collected.rows
if scenario == "fresh-empty-last" {
    initialRows=(0..<52).map{_ in UIElement(kAXRowRole)}
    cache.lastCollectedRow=initialRows.last?.axElement
}
let result=parser.extractMessages(from:initialRows,transcriptRoot:root,limit:10,
    includeSystemMessages:scenario == "date-last-included", referenceDate:reference,frameCache:cache,
    recollectRows:{ fresh in
        parser.collectTranscriptRows(from:root,inputElement:input,messageLimit:10,frameCache:fresh).rows
    })
let last=result.messages.last
func semantic(_ message: TranscriptMessage) -> [String:Any] {
    var row=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(message)) as! [String:Any]
    if var observation=row["native_observation"] as? [String:Any] { observation["id"]="read-local"; row["native_observation"]=observation }
    return row
}
let semanticBytes=try JSONSerialization.data(withJSONObject:result.messages.map(semantic),options:[.sortedKeys])
let semanticDigest=semanticBytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
func ordinaryCounts(_ node:UIElement)->[Int] {
    var result=[node.frameReads,node.childReads,node.searches,node.attributeReads]
    for child in node.nodes { let sub=ordinaryCounts(child);for i in 0..<4 { result[i]+=sub[i] } }
    return result
}

let data:[String:Any] = ["scenario":scenario,"collected":collected.rows.count,
    "returned":result.messages.count,"semanticDigest":String(semanticDigest),"ordinaryCalls":ordinaryCounts(root),"identifierCalls":UIElement.identifierReads,"order":last?.nativeObservation?.order.rawValue ?? "missing",
    "multiplicity":last?.nativeObservation?.multiplicity.rawValue ?? "missing",
    "lastBodyIsFinalSyntheticMessage":last?.body == "synthetic message 51",
    "lastBodyIsPriorSyntheticMessage":last?.body == "synthetic message 50",
    "notes":Dictionary(result.notes.map{($0.key,$0.value)},uniquingKeysWith:{$1})]
print(String(data:try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]),encoding:.utf8)!)
