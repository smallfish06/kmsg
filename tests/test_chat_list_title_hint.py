"""Run the production scanner against fake AX trees, never a GUI or account.

The reference is the same method with no registry hint: that is the original
full-content walk. A hinted hit must choose the same first exact-title row;
a fallback must retain complete, ordered snapshots for registry matching.
Counters measure simulated AX work, not production latency.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/kmsg/KakaoTalk/ChatListScanner.swift"

STUBS = r'''
import Foundation
let kAXRoleAttribute = "role", kAXChildrenAttribute = "children"
let kAXValueAttribute = "value", kAXTitleAttribute = "title"
let kAXIdentifierAttribute = "identifier"
let kAXButtonRole = "button", kAXStaticTextRole = "static"
let kAXTextAreaRole = "text", kAXTableRole = "table"
let kAXOutlineRole = "outline", kAXListRole = "list"
let kAXRowRole = "row", kAXCellRole = "cell", kAXGroupRole = "group"
struct Counts {
    var batch = 0, role = 0, children = 0, preview = 0, badge = 0
    var rowBatches = 0, headerBatches = 0
    var axCalls: Int { batch + role + children }
    var json: [String: Int] { ["batch": batch, "role": role, "children": children,
        "preview": preview, "badge": badge, "rowBatches": rowBatches,
        "headerBatches": headerBatches, "axCalls": batch + role + children] }
}
var counts = Counts()
final class Node {
    let id: String
    var role: String?, title: String?, value: String?, identifier: String?
    var children: [Node]
    var batchFails = false
    var beforeBatch: (() -> Void)?
    init(_ id: String, _ role: String, title: String? = nil, value: String? = nil,
         identifier: String? = nil, children: [Node] = []) {
        self.id = id; self.role = role; self.title = title; self.value = value
        self.identifier = identifier; self.children = children
    }
}
typealias AXUIElement = Node
func CFEqual(_ a: Node, _ b: Node) -> Bool { a === b }
struct UIElement {
    let axElement: Node
    init(_ node: Node) { axElement = node }
    var role: String? { counts.role += 1; return axElement.role }
    var children: [UIElement] { counts.children += 1; return axElement.children.map(UIElement.init) }
    func batchAttributes(_ names: [String]) -> [Any?] {
        counts.batch += 1
        if axElement.id.hasPrefix("preview-") { counts.preview += 1 }
        if axElement.id.hasPrefix("badge-") { counts.badge += 1 }
        if axElement.id.hasPrefix("row-") { counts.rowBatches += 1 }
        if axElement.id == "header" { counts.headerBatches += 1 }
        axElement.beforeBatch?()
        if axElement.batchFails { return Array(repeating: nil, count: names.count) }
        return names.map { name in
            switch name {
            case kAXRoleAttribute: return axElement.role
            case kAXChildrenAttribute: return axElement.children
            case kAXTitleAttribute: return axElement.title
            case kAXValueAttribute: return axElement.value
            case kAXIdentifierAttribute: return axElement.identifier
            default: return nil
            }
        }
    }
    func findAll(role expected: String, limit: Int, maxNodes: Int) -> [UIElement] {
        var queue = [self], i = 0, result: [UIElement] = []
        while i < queue.count && i < maxNodes && result.count < limit {
            let current = queue[i]; i += 1
            if current.role == expected { result.append(current) }
            queue.append(contentsOf: current.children)
        }
        return result
    }
}
enum AXPathSlot: Hashable { case chatListContainer, chatRowTitle, chatRowPreview }
struct AXPathCacheStore {
    static let shared = Self()
    func resolve(slot: AXPathSlot, root: UIElement, validate: (UIElement) -> Bool,
                 trace: ((String) -> Void)?) -> UIElement? {
        guard let node = root.axElement.children.last, node.id == "container" else { return nil }
        let value = UIElement(node)
        return validate(value) ? value : nil
    }
    func remember(slot: AXPathSlot, root: UIElement, element: UIElement,
                  trace: ((String) -> Void)?) {}
}
'''

CASES = r'''
let expected = "Synthetic Target"
func row(_ index: Int, title: String? = nil, rootTitle: Bool = false) -> Node {
    let label = title ?? "Synthetic Room \(index)"
    return Node("row-\(index)", kAXRowRole, title: rootTitle ? label : nil,
        children: [Node("cell-\(index)", kAXCellRole, children: [
            Node("icon-\(index)", kAXButtonRole),
            Node("title-\(index)", kAXStaticTextRole, value: label),
            Node("badge-\(index)", kAXStaticTextRole, value: "300+", identifier: "Count Label"),
            Node("clock-\(index)", kAXStaticTextRole, value: "오후 1:23"),
            Node("scroll-\(index)", "scroll", children: [
                Node("preview-\(index)", kAXTextAreaRole, value: "123456")])])])
}
func titleNode(_ row: Node) -> Node { row.children[0].children[1] }
func fixture(_ label: String, hinted: Bool) -> (UIElement, Int?, Bool) {
    var rows = (0..<410).map { row($0, title: $0 == 242 ? expected : nil) }
    var hint: Int? = 242
    var header = Node("header", kAXButtonRole, title: "채팅")
    var stop = false
    var containerRole = kAXTableRole
    switch label {
    case "duplicate-before-hint": titleNode(rows[5]).value = expected
    case "duplicate-after-hint": titleNode(rows[300]).value = expected
    case "duplicate-order-changed":
        titleNode(rows[39]).value = expected
        rows.swapAt(39, 17)
    case "stale-hint": hint = 241
    case "reordered-earlier": rows.swapAt(242, 17)
    case "reordered-later": rows.swapAt(242, 300)
    case "renamed": titleNode(rows[242]).value = "Synthetic Renamed"
    case "normalized-only": titleNode(rows[242]).value = "synthetic-target"
    case "out-of-range": hint = 900
    case "negative-hint": hint = -2
    case "no-hint": hint = nil
    case "shallow-hint":
        rows.swapAt(242, 5); hint = 5
    case "friends-tab": header = Node("header", kAXStaticTextRole, value: "친구")
    case "more-tab": header = Node("header", kAXStaticTextRole, value: "더보기")
    case "unknown-window": header = Node("header", kAXStaticTextRole, value: "Synthetic chat window")
    case "wrong-header-role": header = Node("header", kAXStaticTextRole, title: "채팅")
    case "header-ax-error": header.batchFails = true
    case "hint-ax-error": rows[242].batchFails = true
    case "prefix-ax-error": rows[12].batchFails = true
    case "list-container": containerRole = kAXListRole
    case "root-title": rows = (0..<410).map { row($0, title: $0 == 242 ? expected : nil, rootTitle: true) }
    case "duplicate-element": rows.insert(rows[0], at: 6)
    case "budget-stop": stop = true
    case "hint-renamed-during-prefix":
        if hinted {
            rows[0].beforeBatch = { titleNode(rows[242]).value = "Synthetic Renamed" }
        } else { titleNode(rows[242]).value = "Synthetic Renamed" }
    default: break
    }
    let container = Node("container", containerRole, children: rows)
    return (UIElement(Node("window", "window", children: [header, container])), hint, stop)
}
struct Result {
    let match: String?, snapshots: [String], stopped: Bool, hintUsed: Bool
    let scanned: Int, titleNodes: Int, contentNodes: Int, counts: Counts
}
func run(_ label: String, hinted: Bool) -> Result {
    let (window, hint, stop) = fixture(label, hinted: hinted)
    counts = Counts()
    let result = ChatListScanner().scanUntilTitle(expected, in: window, limit: 500,
        preferredIndex: hinted ? hint : nil, shouldStop: { stop })
    return Result(match: result.match?.axElement.id,
        snapshots: result.snapshots.map { snapshot in
            let d = snapshot.discovery
            return "\(snapshot.element.axElement.id)|\(d.title)|\(d.lastMessage ?? "nil")|\(d.listIndex)|\(d.unread ?? -1)|\(snapshot.sawClockText)"
        }, stopped: result.stoppedEarly, hintUsed: result.usedTitleHint,
        scanned: result.rowsScanned, titleNodes: result.titleNodes,
        contentNodes: result.contentNodes, counts: counts)
}
func check(_ condition: Bool, _ label: String) { if !condition { fatalError(label) } }
let labels = ["valid-deep", "duplicate-before-hint", "duplicate-after-hint", "duplicate-order-changed",
    "stale-hint", "reordered-earlier", "reordered-later", "renamed", "normalized-only",
    "out-of-range", "negative-hint", "no-hint", "shallow-hint", "friends-tab", "more-tab",
    "unknown-window", "wrong-header-role", "header-ax-error", "hint-ax-error", "prefix-ax-error",
    "list-container", "root-title", "duplicate-element", "budget-stop", "hint-renamed-during-prefix"]
var records: [[String: Any]] = []
for label in labels {
    let reference = run(label, hinted: false), candidate = run(label, hinted: true)
    check(candidate.match == reference.match, "\(label): first exact row changed")
    check(candidate.stopped == reference.stopped, "\(label): budget status changed")
    if candidate.match == nil || !candidate.hintUsed {
        check(candidate.snapshots == reference.snapshots, "\(label): incomplete fallback snapshots")
    }
    if candidate.hintUsed {
        check(candidate.counts.preview == 0 && candidate.counts.badge == 0,
              "\(label): title-only path read preview or badge")
        check(candidate.contentNodes == 0, "\(label): hint hit gathered full content")
    }
    if label == "valid-deep" {
        check(candidate.match == "row-242", "deep target")
        check(candidate.hintUsed && candidate.counts.axCalls < reference.counts.axCalls, "deep work not reduced")
    }
    if label == "duplicate-before-hint" { check(candidate.match == "row-5", "direct hint bypassed earlier duplicate") }
    if label == "normalized-only" {
        check(candidate.snapshots.count == 410 && candidate.snapshots[242].contains("|123456|242|300|true"),
              "normalized registry fallback lost numeric preview/badge/clock")
    }
    if label == "budget-stop" {
        check(candidate.match == nil && candidate.snapshots.count == 25, "budget fallback must retain complete prefix")
        check(candidate.contentNodes == reference.contentNodes, "budget fallback full walk exceeded original prefix")
    }
    records.append(["case": label, "match": candidate.match ?? "none", "snapshots": candidate.snapshots.count,
        "stoppedEarly": candidate.stopped, "hintUsed": candidate.hintUsed,
        "rowsScanned": candidate.scanned, "titleNodes": candidate.titleNodes,
        "contentNodes": candidate.contentNodes, "reference": reference.counts.json,
        "candidate": candidate.counts.json])
}
let output = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
print(String(decoding: output, as: UTF8.self))
'''


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ChatListTitleHintTests(unittest.TestCase):
    def test_production_scanner_preserves_order_and_fallback(self):
        source = SOURCE.read_text().replace("import ApplicationServices.HIServices\n", "")
        sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True)
            if sdk.returncode == 0 and sdk.stdout.strip():
                sdk_args = ["-sdk", sdk.stdout.strip()]
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / "main.swift"
            main.write_text(STUBS + source + CASES)
            binary = Path(tmp) / "scannercheck"
            build = subprocess.run(["swiftc", *sdk_args, str(main), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            records = json.loads(run.stdout)
            self.assertEqual(len(records), 25)
            if os.environ.get("KMSG_SYNTHETIC_SCANNER_REPORT"):
                Path(os.environ["KMSG_SYNTHETIC_SCANNER_REPORT"]).write_text(json.dumps(records, indent=2) + "\n")


if __name__ == "__main__":
    unittest.main()
