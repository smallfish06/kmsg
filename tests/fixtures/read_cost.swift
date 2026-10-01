import ApplicationServices.HIServices
import CoreGraphics
import Foundation
let kAXEditableAttribute = "AXEditable"

enum ChatWindowInteractionMode { case backgroundSafe, allowUIAutomation }
enum AXPathSlot: String { case messageInput, transcriptRoot }
final class Probe {
    var calls: [String] = []
    func record(_ key: String, _ id: Int) { calls.append("\(key):\(id)") }
}
final class UIElement {
    let id: Int, roleValue: String, bounds: CGRect?, probe: Probe
    let axElement: NSObject
    var nodes: [UIElement], enabled: Bool
    weak var parent: UIElement?
    var focused: UIElement?
    init(_ id: Int, _ role: String, _ box: CGRect?, _ nodes: [UIElement], _ probe: Probe, _ enabled: Bool = true) {
        self.id = id; roleValue = role; bounds = box; self.nodes = nodes; self.probe = probe; self.enabled = enabled
        axElement = NSNumber(value: id)
        for child in nodes { child.parent = self }
    }
    var children: [UIElement] { probe.record("children", id); return nodes }
    var role: String? { probe.record("role", id); return roleValue }
    var frame: CGRect? { probe.record("frame", id); return bounds }
    var position: CGPoint? { probe.record("position", id); return bounds?.origin }
    var size: CGSize? { probe.record("size", id); return bounds?.size }
    var isEffectivelyEnabled: Bool { probe.record("enabled", id); return enabled }
    var isFocused: Bool { probe.record("focused", id); return roleValue == kAXTextAreaRole }
    var focusedUIElement: UIElement? { probe.record("focusedUI", id); return focused }
    var identifier: String? { probe.record("identifier", id); return "CUSTOMER_SECRET_SENTINEL" }
    var title: String? { probe.record("title", id); return "CUSTOMER_SECRET_SENTINEL" }
    var axDescription: String? { probe.record("description", id); return "CUSTOMER_SECRET_SENTINEL" }
    func attributeOptional<T>(_ key: String) -> T? {
        probe.record("optional", id)
        return (key == kAXEditableAttribute ? roleValue == kAXTextAreaRole : false) as? T
    }
    func findAll(where predicate: (UIElement) -> Bool, limit: Int, maxNodes: Int) -> [UIElement] {
        probe.record("find-predicate", id)
        var queue = children, index = 0, result: [UIElement] = []
        while index < queue.count && index < maxNodes && result.count < limit {
            let node = queue[index]; index += 1
            if predicate(node) { result.append(node) }
            queue.append(contentsOf: node.children)
        }
        return result
    }
    func findAll(roles: Set<String>, roleLimits: [String: Int], maxNodes: Int) -> [String: [UIElement]] {
        probe.record("find-roles", id)
        var result: [String: [UIElement]] = [:], queue = children, index = 0
        while index < queue.count && index < maxNodes {
            let node = queue[index]; index += 1
            if let role = node.role, roles.contains(role), result[role, default: []].count < roleLimits[role, default: .max] {
                result[role, default: []].append(node)
            }
            queue.append(contentsOf: node.children)
        }
        return result
    }
    func findAll(role: String, limit: Int, maxNodes: Int) -> [UIElement] {
        findAll(roles: [role], roleLimits: [role: limit], maxNodes: maxNodes)[role] ?? []
    }
}
struct AXActionRunner {
    func log(_ message: String) {}
    func focusWithVerification(_ element: UIElement, label: String, attempts: Int) -> Bool { element.probe.record("focus-action", element.id); return true }
}
struct KakaoTalkApp {
    let applicationElement: UIElement
    var focusedWindow: UIElement? { applicationElement.nodes.first }
    func activate() { applicationElement.probe.record("activate", applicationElement.id) }
}
final class AXPathCacheStore {
    static let shared = AXPathCacheStore()
    var elements: [AXPathSlot: UIElement] = [:]
    func resolve(slot: AXPathSlot, root: UIElement, validate: (UIElement) -> Bool, trace: ((String) -> Void)?) -> UIElement? {
        root.probe.record("cache-resolve", root.id)
        guard let node = elements[slot], validate(node) else { return nil }
        return node
    }
    func remember(slot: AXPathSlot, root: UIElement, element: UIElement, trace: ((String) -> Void)?) {
        root.probe.record("cache-remember", root.id); elements[slot] = element
    }
}
final class FrameCache {
    private var seen = Set<Int>(), values = [Int: CGRect]()
    func frame(of element: UIElement) -> CGRect? {
        if seen.contains(element.id) { return values[element.id] }
        seen.insert(element.id); let value = element.frame; values[element.id] = value; return value
    }
}

// BEGIN CASES
func check(_ condition: Bool, _ label: String) { precondition(condition, label) }
func layout(_ count: Int = 30, enabled: Bool = true) -> (KakaoTalkApp, UIElement, UIElement, UIElement, Probe) {
    let p = Probe()
    let rows = (1...count).map { UIElement($0, kAXRowRole, CGRect(x: 0, y: $0 * 10, width: 780, height: 8), [], p, enabled) }
    let table = UIElement(1001, kAXTableRole, CGRect(x: 0, y: 0, width: 800, height: 450), rows, p, enabled)
    let scroll = UIElement(1002, kAXScrollAreaRole, CGRect(x: 0, y: 0, width: 800, height: 450), [table], p, enabled)
    let input = UIElement(1003, kAXTextAreaRole, CGRect(x: 0, y: 500, width: 800, height: 80), [], p, enabled)
    let pane = UIElement(1004, kAXGroupRole, CGRect(x: 0, y: 0, width: 800, height: 600), [scroll, input], p, enabled)
    let window = UIElement(1005, kAXWindowRole, CGRect(x: 0, y: 0, width: 800, height: 600), [pane], p, enabled)
    let app = UIElement(1006, kAXApplicationRole, nil, [window], p, enabled)
    app.focused = enabled ? input : nil
    return (KakaoTalkApp(applicationElement: app), window, input, scroll, p)
}
func contextRun(_ mode: String, _ on: Bool) -> (Int?, [String], [String: String]) {
    let (app, window, input, scroll, p) = layout(enabled: mode != "failure")
    AXPathCacheStore.shared.elements = mode == "cached" ? [.messageInput: input, .transcriptRoot: scroll] : [:]
    var notes: [String: String] = [:]
    let cost = on ? TranscriptReadCost { notes[$0] = $1 } : nil
    let resolver = MessageContextResolver(kakao: app, runner: AXActionRunner(), interactionMode: .backgroundSafe, readCost: cost)
    let result = resolver.resolve(in: window)
    cost?.emit(); cost?.emit()
    return (result?.transcriptRoot.id, p.calls, notes)
}
var cases: [[String: Any]] = []
for mode in ["cold", "cached", "failure"] {
    let off = contextRun(mode, false), on = contextRun(mode, true)
    check(off.0 == on.0 && off.1 == on.1, "context ON/OFF result and AX order")
    check(off.2.isEmpty && on.2.count == 2, "cost is optional and fixed notes")
    check((mode == "failure") == (on.0 == nil), "context failure unchanged")
    cases.append(["kind": "context", "mode": mode, "sameResult": true, "sameAXCallsAndOrder": true, "calls": on.1.count, "notes": on.2])
}
func collectionRun(_ mode: String, _ on: Bool) -> ([Int], [String], [String: String]) {
    let p = Probe(), count = mode == "empty" ? 0 : 300
    let rows = (0..<count).map { UIElement($0 + 1, kAXRowRole, CGRect(x: 0, y: $0 * 30, width: 600, height: 25), [], p) }.reversed()
    let table = UIElement(2001, kAXTableRole, nil, Array(rows), p)
    let children = mode == "fallback" ? [UIElement(2004, "AXUnknown", nil, [table], p)] : [table]
    let root = UIElement(2002, kAXScrollAreaRole, nil, children, p)
    let input = UIElement(2003, kAXTextAreaRole, CGRect(x: 0, y: mode == "cut" ? 200 : 10000, width: 600, height: 40), [], p)
    var notes: [String: String] = [:]
    let cost = on ? TranscriptReadCost { notes[$0] = $1 } : nil
    let result = CostCollector().collectTranscriptRows(from: root, inputElement: input, messageLimit: 10, frameCache: FrameCache(), readCost: cost)
    cost?.emit()
    return (result.rows.map(\.id), p.calls, notes)
}
for mode in ["shallow", "fallback", "cut", "empty"] {
    let off = collectionRun(mode, false), on = collectionRun(mode, true)
    check(off.0 == on.0 && off.1 == on.1, "collection ON/OFF result and AX order")
    check(off.2.isEmpty && on.2.count == 2, "cost is optional")
    if mode == "shallow" { check(on.0.count == 80 && on.0.first == 221 && on.0.last == 300, "geometry ordering preserved") }
    cases.append(["kind": "collection", "mode": mode, "sameResult": true, "sameAXCallsAndOrder": true, "calls": on.1.count, "notes": on.2])
}
var capped: [String: String] = [:]
let huge = TranscriptReadCost { capped[$0] = $1 }
for slice in TranscriptReadCost.Slice.allCases { huge.end(slice, 0) }
for count in TranscriptReadCost.Count.allCases { huge.add(count, Int.max); huge.add(count, Int.max) }
huge.emit()
check(capped["costclip"] == "1", "saturation explicit")
func windowRun(_ mode: String, _ on: Bool) -> (Bool, [String], [String: String]) {
    let (app, window, _, _, p) = layout(enabled: mode != "context-failure")
    AXPathCacheStore.shared.elements = [:]
    var notes: [String: String] = [:]
    let callback: ((String, String) -> Void)? = on ? { notes[$0] = $1 } : nil
    let reader = WindowCostReader(kakao: app, runner: AXActionRunner(), interactionMode: .backgroundSafe,
                                  failAfterContext: mode == "collection-failure")
    var failed = false
    do { _ = try reader.readSnapshot(from: window, fallbackChatTitle: "CUSTOMER_SECRET_SENTINEL", limit: 10, readNote: callback) }
    catch { failed = true }
    return (failed, p.calls, notes)
}
var windowCases: [[String: Any]] = []
for mode in ["ok", "context-failure", "collection-failure"] {
    let off = windowRun(mode, false), on = windowRun(mode, true)
    check(off.0 == on.0 && off.1 == on.1, "window ON/OFF failure and AX order")
    check(off.2.isEmpty && on.2.count == 2, "window emits fixed costs on every exit")
    windowCases.append(["mode": mode, "failed": on.0, "sameAXCallsAndOrder": true, "notes": on.2])
}
let data = try JSONSerialization.data(withJSONObject: ["cases": cases, "windowCases": windowCases, "cappedNotes": capped], options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
