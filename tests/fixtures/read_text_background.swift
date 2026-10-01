import ApplicationServices.HIServices
import Foundation
let kAXLinkRole = "AXLink"
// Minimal in-memory AX boundary. Parser, FrameCache, and attribution helpers
// are the actual production source, not reimplementations of their decisions.
typealias AXUIElement = NSObject
enum AccessibilityError: Error { case axError(AXError); case typeMismatch }
struct Runner { func log(_ message: String) {} }
final class UIElement {
    var axElement = NSObject()
    static var identifierValues: [ObjectIdentifier: String] = [:]
    static var identifierErrors: [ObjectIdentifier: AXError] = [:]
    static var identifierReads = 0
    let role: String?
    var title: String?
    var stringValue: String?
    var helpText: String?
    weak var parent: UIElement?
    var nodes: [UIElement] { didSet { for node in nodes { node.parent = self } } }
    var bounds: CGRect?
    var frameReads = 0
    var childReads = 0
    var searches = 0
    var attributeReads = 0
    var childrenError: AXError?
    var invalidChildrenType = false
    var children: [UIElement] { childReads += 1; return nodes }
    var childrenReadComplete = true
    func childrenRead() -> (children: [UIElement], complete: Bool) { (children, childrenReadComplete) }
    var frame: CGRect? { frameReads += 1; return bounds }
    init(_ role: String, _ frame: CGRect? = nil, _ value: String? = nil, children: [UIElement] = []) {
        self.role = role; bounds = frame; stringValue = value; nodes = children
        for node in nodes { node.parent = self }
    }
    convenience init(_ element: AXUIElement) { self.init("AXRow"); axElement = element }
    func attribute<T>(_ name: String) throws -> T {
        attributeReads += 1
        if name == kAXIdentifierAttribute {
            Self.identifierReads += 1
            if let error = Self.identifierErrors[ObjectIdentifier(axElement)] { throw AccessibilityError.axError(error) }
            guard let value = Self.identifierValues[ObjectIdentifier(axElement)] else { throw AccessibilityError.axError(.attributeUnsupported) }
            return value as! T
        }
        if invalidChildrenType { throw AccessibilityError.typeMismatch }
        if let error = childrenError { throw AccessibilityError.axError(error) }
        precondition(name == kAXChildrenAttribute)
        return nodes.map(\.axElement) as! T
    }
    func valueAndHelp() -> (String?, String?) { (stringValue, helpText) }
    func findAll(roles: Set<String>, roleLimits: [String:Int], maxNodes: Int) -> [String:[UIElement]] {
        searches += 1
        var result: [String:[UIElement]] = [:]
        var queue = nodes; var visits = 0
        while !queue.isEmpty && visits < maxNodes {
            let node = queue.removeFirst(); visits += 1
            if let role = node.role, roles.contains(role), result[role, default:[]].count < roleLimits[role, default: .max] {
                result[role, default:[]].append(node)
            }
            queue += node.nodes
        }
        return result
    }
    func findAll(role: String, limit: Int, maxNodes: Int) -> [UIElement] {
        findAll(roles:[role], roleLimits:[role:limit], maxNodes:maxNodes)[role] ?? []
    }
    func findAll(where predicate: (UIElement) -> Bool, limit: Int, maxNodes: Int) -> [UIElement] {
        searches += 1
        var result: [UIElement] = []; var queue = nodes; var visits = 0
        while !queue.isEmpty && visits < maxNodes && result.count < limit {
            let node = queue.removeFirst(); visits += 1
            if predicate(node) { result.append(node) }
            queue += node.nodes
        }
        return result
    }
}
// BEGIN CASES
func check(_ label: String, _ condition: Bool) { if !condition { fatalError(label) } }
let parser = Parser()
let root = UIElement(kAXScrollAreaRole, CGRect(x:769,y:323,width:382,height:434))
let reference = Date(timeIntervalSince1970: 1_790_773_000)
func row(_ children: [UIElement], y: CGFloat = 405) -> UIElement {
    UIElement(kAXRowRole, CGRect(x:770,y:y,width:380,height:89), children:[
        UIElement(kAXCellRole, CGRect(x:770,y:y,width:380,height:89), children:children)
    ])
}
func bubble(_ id: String, image: CGRect = CGRect(x:848,y:415,width:292,height:79),
            text: CGRect = CGRect(x:853,y:423,width:279,height:64), extras: [UIElement] = []) -> UIElement {
    row([UIElement(kAXButtonRole), UIElement(kAXButtonRole), UIElement(kAXImageRole,image),
         UIElement(kAXTextAreaRole,text,id)] + extras, y:image.minY-10)
}
func anchor(_ id: String, x: CGFloat, width: CGFloat) -> UIElement {
    bubble(id, image:CGRect(x:x-5,y:499,width:width+13,height:31), text:CGRect(x:x,y:507,width:width,height:16))
}
func parse(_ target: UIElement) -> [TranscriptMessage] {
    parser.parseMessages(from:[anchor("first anchor",x:1066,width:66), anchor("second anchor",x:930,width:202), target],
        transcriptRoot:root, limit:20, includeSystemMessages:false, referenceDate:reference, frameCache:FrameCache())
}
func last(_ target: UIElement) -> TranscriptMessage { parse(target).last! }
let first = bubble("fixture first long plain body")
let second = bubble("fixture second long plain body", image:CGRect(x:850,y:571,width:290,height:79), text:CGRect(x:855,y:579,width:277,height:64))
for (i,target) in [first,second].enumerated() {
    let result = last(target)
    check("actual row \(i) loses false image", result.imageCount == 0 && result.imageFrames.isEmpty && !result.hasImage)
    check("actual row \(i) passes full own attribution", result.author == nil && result.authorSource == "default-me" && result.authorRightAligned)
    let children = target.nodes[0].nodes
    check("one shallow image query only", children[2].attributeReads == 1)
    check("cached image frame reused", children[2].frameReads == 1)
    check("cached text frame reused", children[3].frameReads == 1)
    check("no new discovery walk", target.nodes[0].searches == 1)
    let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String:Any]
    check("consumer payload corrected", json["has_image"] as? Bool == false && json["author_source"] as? String == "default-me")
}
let short = anchor("short plain body", x:1066, width:66)
_ = last(short)
check("small background requires no new query", short.nodes[0].nodes[2].attributeReads == 0)
let malformed = bubble("malformed children")
malformed.nodes[0].nodes[2].invalidChildrenType = true
check("malformed AX children retain image", last(malformed).imageCount == 1)
let photoFrame = CGRect(x:848,y:415,width:292,height:180)
let photo = row([UIElement(kAXImageRole,photoFrame)])
check("image-only photo preserved", last(photo).imageCount == 1 && last(photo).body == "[사진]")
let caption = bubble("photo caption", image:photoFrame, text:CGRect(x:853,y:602,width:279,height:32))
check("separate caption preserved", last(caption).imageCount == 1)
let nested = bubble("duplicate caption text")
nested.nodes[0].nodes[2].nodes = [UIElement(kAXTextAreaRole,CGRect(x:853,y:423,width:279,height:64),"embedded image text")]
check("nested image text plus direct caption preserved", last(nested).imageCount == 1 && !last(nested).authorRightAligned)
let embeddedOnly = row([UIElement(kAXImageRole,CGRect(x:848,y:415,width:292,height:79), children:[UIElement(kAXTextAreaRole,CGRect(x:853,y:423,width:279,height:64),"embedded only")])])
check("backfilled image text not sibling evidence", last(embeddedOnly).imageCount == 1)
let linked = bubble("linked card", extras:[UIElement(kAXLinkRole,CGRect(x:853,y:423,width:279,height:64))])
check("link role preserved", last(linked).imageCount == 1 && !last(linked).authorRightAligned)
check("body URL preserved", last(bubble("https://example.test/full")).imageCount == 1)
let attachment = UIElement(kAXButtonRole); attachment.title = "저장"
check("attachment action preserved", last(bubble("report text", extras:[attachment])).imageCount == 1)
check("attachment metadata preserved", last(bubble("report text", extras:[UIElement(kAXStaticTextRole,nil,"size: 1 MB")])).imageCount == 1)
check("filename body preserved", last(bubble("report.pdf")).imageCount == 1)
check("photo label preserved", last(bubble("[사진]")).imageCount == 1)
check("sticker label preserved", last(bubble("[이모티콘]")).imageCount == 1)
let foreign = UIElement(kAXRowRole,CGRect(x:770,y:405,width:380,height:89),children:[
    UIElement(kAXCellRole,children:[UIElement(kAXImageRole,CGRect(x:848,y:415,width:292,height:79))]),
    UIElement(kAXCellRole,children:[UIElement(kAXTextAreaRole,CGRect(x:853,y:423,width:279,height:64),"foreign cell text")])])
check("foreign cell body preserved", last(foreign).imageCount == 1)
let group = bubble("card-like group", extras:[UIElement(kAXGroupRole)])
check("unknown direct content retained", last(group).imageCount == 1)
let many = bubble("multiple images", extras:[UIElement(kAXImageRole,photoFrame)])
check("multiple images retained", last(many).imageCount == 2)
check("loose enclosure retained", last(bubble("loose",image:CGRect(x:840,y:410,width:305,height:90))).imageCount == 1)
for error in [AXError.cannotComplete, .failure, .noValue] {
    let target = bubble("AX failure \(error.rawValue)"); target.nodes[0].nodes[2].childrenError = error
    check("failed child query retains image", last(target).imageCount == 1)
}
for error in [AXError.attributeUnsupported] {
    let target = bubble("leaf \(error.rawValue)"); target.nodes[0].nodes[2].childrenError = error
    check("AX reports no children", last(target).imageCount == 0)
}
for bad in [CGRect.zero, CGRect.null, CGRect(x:853,y:423,width:0,height:64)] {
    let target = bubble("invalid text", text:bad)
    check("invalid body never excludes image", last(target).imageCount == 1)
}
let incoming = bubble("long peer text",image:CGRect(x:825,y:415,width:291,height:79),text:CGRect(x:830,y:423,width:278,height:64),extras:[UIElement(kAXStaticTextRole,CGRect(x:830,y:395,width:40,height:16),"Peer")])
let peerResult = last(incoming)
check("long peer retains explicit author", peerResult.author == "Peer" && peerResult.authorSource == "explicit" && !peerResult.authorRightAligned)
let overlapping = bubble("overlapping card name",extras:[UIElement(kAXStaticTextRole,CGRect(x:860,y:440,width:60,height:16),"Peer")])
check("overlapping metadata still never a sender", last(overlapping).author == nil)
let missingName = bubble("peer with unmeasured name",image:CGRect(x:825,y:415,width:291,height:79),text:CGRect(x:830,y:423,width:278,height:64),extras:[UIElement(kAXStaticTextRole,nil,"Peer")])
check("metadata guard unchanged for unmeasured name", last(missingName).author == nil)
print("OK: production analyzeRow -> image classification -> alignment -> author, media and AX safety")
