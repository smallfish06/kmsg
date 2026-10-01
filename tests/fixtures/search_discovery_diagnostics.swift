import Foundation
import ApplicationServices.HIServices

enum AccessibilityError: Error { case axError(AXError), typeMismatch }
final class Node: NSObject {
    let id: String
    var role: String? = "AXGroup", children: [Node] = []
    var enabled = true, value = "", title = "PRIVATE_TITLE", identifier = "PRIVATE_IDENTIFIER"
    var y = 100.0, kind = "ordinary", childStatus = 0, roleError = false, batchError = false
    init(_ id: String, role: String? = "AXGroup", children: [Node] = []) {
        self.id = id; self.role = role; self.children = children
    }
}
typealias AXUIElement = Node
var calls: [String] = [], actions: [String] = [], scenario = "", fired = false
func axErrorValue(_ error: AXError) -> AnyObject { var value = error; return AXValueCreate(.axError, &value)! }
func tick(_ label: String) {
    calls.append(label)
    if !fired, (scenario == "timed-role" && calls.count == 160) {
        let node = world.root.children[0]
        node.role = kAXTextFieldRole; node.kind = "search"; node.value = "PRIVATE_TOKEN"
        fired = true
    }
    if !fired, scenario == "timed-descendant", calls.count == 90 {
        _ = world.field(in: world.root.children[0], id: "late")
        fired = true
    }
}
func AXUIElementCopyAttributeValue(_ node: Node, _ name: CFString, _ output: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    let name = name as String
    tick("scalar:\(node.id):\(name)")
    switch name {
    case kAXRoleAttribute:
        if node.roleError { return .cannotComplete }
        output.pointee = node.role.map { $0 as NSString }
        return node.role == nil ? .noValue : .success
    case kAXChildrenAttribute:
        if node.childStatus == 1 { return .noValue }
        if node.childStatus == 2 { return .attributeUnsupported }
        if node.childStatus == 3 { return .cannotComplete }
        if node.childStatus == 4 { output.pointee = NSNull() }
        else if node.childStatus == 5 { output.pointee = "wrong type" as NSString }
        else { output.pointee = node.children as NSArray }
    case kAXEnabledAttribute: output.pointee = NSNumber(value: node.enabled)
    case kAXValueAttribute: output.pointee = node.value as NSString
    case kAXTitleAttribute: output.pointee = node.title as NSString
    case kAXIdentifierAttribute: output.pointee = node.identifier as NSString
    case kAXPositionAttribute:
        var point = CGPoint(x: 0, y: node.y); output.pointee = AXValueCreate(.cgPoint, &point)
    default: return .attributeUnsupported
    }
    return .success
}
func AXUIElementCopyMultipleAttributeValues(_ node: Node, _ names: CFArray, _ options: AXCopyMultipleAttributeOptions, _ output: UnsafeMutablePointer<CFArray?>) -> AXError {
    let names = names as! [String]
    tick("batch:\(node.id):\(names.joined(separator: ","))")
    if node.batchError { return .cannotComplete }
    let values: [AnyObject] = names.map { name in
        if name == kAXRoleAttribute { return node.roleError ? axErrorValue(.cannotComplete) : (node.role.map { $0 as NSString } ?? axErrorValue(.noValue)) }
        if name == kAXChildrenAttribute {
            switch node.childStatus {
            case 1: return axErrorValue(.noValue)
            case 2: return axErrorValue(.attributeUnsupported)
            case 3: return axErrorValue(.cannotComplete)
            case 4: return NSNull()
            case 5: return "wrong type" as NSString
            default: return node.children as NSArray
            }
        }
        return axErrorValue(.attributeUnsupported)
    }
    output.pointee = (node.childStatus == 6 ? [values[0]] : values) as CFArray
    return .success
}
final class UIElement {
    let axElement: Node
    init(_ node: Node) { axElement = node }
    var role: String? { attributeOptional(kAXRoleAttribute) }
    var isEnabled: Bool { let enabled: Bool? = attributeOptional(kAXEnabledAttribute); return enabled ?? false }
    var stringValue: String? { attributeOptional(kAXValueAttribute) }
    var children: [UIElement] { let values: [AXUIElement]? = attributeOptional(kAXChildrenAttribute); return values?.map(UIElement.init) ?? [] }
    var position: CGPoint? {
        guard let value: AXValue = attributeOptional(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }
// UI_METHODS
}
final class World {
    let root: Node, other: Node, third: Node
    var focus: Node?, main: Node?, cached: Node?, cachePath = true, focusedField: Node?
    init(_ count: Int) {
        root = Node("root", role: kAXWindowRole, children: (0..<count).map { Node("n\($0)") })
        other = Node("other", role: kAXWindowRole, children: (0..<count).map { Node("o\($0)") })
        third = Node("third", role: kAXWindowRole, children: (0..<count).map { Node("t\($0)") })
        focus = root; main = root
    }
    @discardableResult func field(in parent: Node? = nil, id: String = "search", kind: String = "search", y: Double = 10) -> Node {
        let field = Node(id, role: kAXTextFieldRole)
        field.kind = kind; field.value = "PRIVATE_CUSTOMER_BODY"; field.y = y
        (parent ?? root).children.insert(field, at: 0)
        return field
    }
}
var world: World!
func anchorEvent(_ kind: String) {
    guard !fired else { return }
    if scenario == "late-focus" && kind == "focus" || scenario == "late-main" && kind == "main" {
        world.field(id: "late"); fired = true
    } else if scenario == "late-enabled" && kind == "main" {
        world.root.children[0].enabled = true; fired = true
    } else if scenario == "window-change" && kind == "main" {
        world.main = world.other; world.field(in: world.other, id: "other-search"); fired = true
    }
}
final class KakaoTalkApp {
    var focusedWindow: UIElement? { tick("anchor:focus"); anchorEvent("focus"); return world.focus.map(UIElement.init) }
    var mainWindow: UIElement? { tick("anchor:main"); anchorEvent("main"); return world.main.map(UIElement.init) }
    func activate() { actions.append("activate") }
}
final class AXActionRunner {
    func log(_ text: String) {}
    func focusWithVerification(_ field: UIElement, label: String, attempts: Int) -> Bool {
        actions.append("focus:\(field.axElement.id)"); world.focusedField = field.axElement; return true
    }
    func pressCommandA() { actions.append("select-all") }
    func pressDeleteKey() { actions.append("delete:\(world.focusedField?.id ?? "none")"); world.focusedField?.value = "" }
    func pressEscapeKey() { actions.append("escape"); world.focusedField?.value = "" }
    func waitUntil(label: String, timeout: Double, pollInterval: Double, evaluateAfterTimeout: Bool, condition: () -> Bool) -> Bool { condition() }
}
enum ChatWindowInteractionMode { case backgroundSafe, allowUIAutomation }
enum AXPathSlot { case searchField }
func fixtureSleep(forTimeInterval _: Double) {}

// RESOLVER_CLASSES

// BEGIN CASES
scenario = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
world = World(["timed-descendant", "deep"].contains(scenario) ? 60 : (["small", "repeat"].contains(scenario) ? 1 : 140))
switch scenario {
case "two-roots": world.focus = world.other
case "three-roots": world.focus = world.other; world.main = world.third
case "only-root": world.focus = nil; world.main = nil
case "foreign": world.focus = world.other; world.field(in: world.other, id: "other-search")
case "positive", "cache-hit", "cache-stale-role", "cache-stale-path", "title", "empty", "disabled", "late-enabled":
    let field = world.field()
    if scenario == "cache-hit" { world.cached = field }
    if scenario == "cache-stale-role" { world.cached = Node("stale"); world.cached?.role = kAXButtonRole }
    if scenario == "cache-stale-path" { world.cached = field; world.cachePath = false }
    if scenario == "title" { world.field(id: "title", kind: "title", y: 0) }
    if scenario == "empty" { field.value = "" }
    if scenario == "disabled" || scenario == "late-enabled" { field.enabled = false }
case "no-value": world.root.children[42].childStatus = 1
case "unsupported": world.root.children[42].childStatus = 2
case "transient": world.root.children[42].childStatus = 3
case "null": world.root.children[42].childStatus = 4
case "type": world.root.children[42].childStatus = 5
case "malformed": world.root.children[42].childStatus = 6
case "role-missing": world.root.children[42].role = nil
case "role-error": world.root.children[42].roleError = true
case "request-failure": world.root.children[42].batchError = true
case "root-error": world.root.childStatus = 3
case "limit": for index in 0..<9 { world.field(id: "field\(index)", y: Double(index)) }
case "budget": let field = world.field(); world.root.children.removeFirst(); world.root.children.append(field)
case "table-rows":
    let table = Node("table", role: kAXTableRole)
    let row = Node("row", role: kAXRowRole)
    table.children = [row]; row.children = world.root.children
    world.root.children = [Node("header"), table]
case "table-field":
    let table = Node("table", role: kAXTableRole)
    world.root.children = [table]; world.field(in: table)
case "deep":
    var parent = world.root
    for index in 0..<170 { let child = Node("deep\(index)"); parent.children = [child]; parent = child }
case "cycle":
    let node = world.root.children[0]; node.children = [node]; world.root.children = [node]
case "wide": world.root.children = (0..<33000).map { Node("wide\($0)") }
default: break
}
var cleared = false
if mode == "reference" { cleared = ReferenceResolver().run() }
else { cleared = CandidateResolver().run() }
let result: [String: Any] = ["calls": calls, "actions": actions, "cleared": cleared, "observerRestored": SearchDiscoveryDiagnostics.currentPass == nil]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
