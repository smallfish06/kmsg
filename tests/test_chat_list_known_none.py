"""Actual scanner and raw AX decoder, with only IPC/trees replaced.

The frozen v7 scanner is a comparison, not an alternate policy oracle. Tests
retain the cost of changed-tree fallback and the non-atomic sampling boundary.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import block, swiftc_command
from test_chat_list_title_hint import STUBS

ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / 'Sources/kmsg/KakaoTalk/ChatListScanner.swift'
EVIDENCE = ROOT / 'Sources/kmsg/KakaoTalk/ChatListHintEvidence.swift'
UI = ROOT / 'Sources/kmsg/Accessibility/UIElement.swift'
REFERENCE = ROOT / 'tests/fixtures/chat_list_hint_reference.swift'


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def stubs():
    source = STUBS
    start = source.index('    func batchAttributes(_ names: [String])')
    end = source.index('    func findAll(role expected:', start)
    ui = UI.read_text()
    methods = '\n'.join(method(ui, sig) for sig in (
        'public func batchAttributes(_ names:',
        'func batchAttributes(\n        _ names: [String], observingRaw:',
        'private func batchAttributes('))
    source = source[:start] + methods + '\n' + source[end:]
    source = source.replace('struct UIElement {', 'public struct UIElement {')
    source = source.replace('final class Node {', 'public final class Node: NSObject {')
    source = source.replace('typealias AXUIElement = Node', 'public typealias AXUIElement = Node')
    source = source.replace('var batchFails = false', '''var batchFails = false
    var rawSlots: [String: AnyObject] = [:]
    var malformed: String?
    var batches = 0''')
    source = source.replace('counts.role += 1; return', 'counts.role += 1; tick("role:" + axElement.id); return')
    source = source.replace('counts.children += 1; return', 'counts.children += 1; tick("children:" + axElement.id); return')
    return source + r'''
final class AuthReadDiagnostics {
    enum Kind { case batch }
    static var current: AuthReadDiagnostics? { nil }
    func beginRead(_ kind: Kind) -> UInt64 { 0 }
    func endRead(_ time: UInt64, failed: Bool) {}
    func recordStructure(error: AXError, raw: [AnyObject]?, roleIsString: Bool, childrenAreElements: Bool) {}
}
final class SearchDiscoveryDiagnostics {
    static var currentPass: SearchDiscoveryDiagnostics? { nil }
    func beginRead() -> UInt64 { 0 }
    func endRead(_ time: UInt64, batch: Bool, error: AXError) {}
    func recordStructure(element: Node, error: AXError, raw: [AnyObject]?) {}
}
var ipc: [String] = [], mutation: (() -> Void)?
func tick(_ label: String) { ipc.append(label); mutation?() }
func absent(_ error: AXError = .noValue) -> AnyObject {
    var value = error
    return AXValueCreate(.axError, &value)!
}
func AXUIElementCopyMultipleAttributeValues(
    _ node: Node, _ names: CFArray, _ options: AXCopyMultipleAttributeOptions,
    _ output: UnsafeMutablePointer<CFArray?>
) -> AXError {
    let names = names as! [String]
    tick("batch:" + node.id + ":" + names.joined(separator: ","))
    counts.batch += 1; node.batches += 1; node.beforeBatch?()
    if node.batchFails { return .cannotComplete }
    if node.malformed == "nil" { return .success }
    if node.malformed == "count" { output.pointee = ["PRIVATE"] as CFArray; return .success }
    let raw: [AnyObject] = names.map { name in
        if let override = node.rawSlots[name] { return override }
        switch name {
        case kAXRoleAttribute: return node.role.map { $0 as NSString } ?? absent()
        case kAXChildrenAttribute: return node.children as NSArray
        case kAXTitleAttribute: return node.title.map { $0 as NSString } ?? absent()
        case kAXValueAttribute: return node.value.map { $0 as NSString } ?? absent()
        case kAXIdentifierAttribute: return node.identifier.map { $0 as NSString } ?? absent()
        default: return absent(.attributeUnsupported)
        }
    }
    output.pointee = raw as CFArray
    return .success
}
'''


CASES = r'''
let expected = "Synthetic Target"
func regular(_ index: Int, title: String? = nil) -> Node {
    Node("row-\(index)", kAXRowRole, children: [Node("cell-\(index)", kAXCellRole, children: [
        Node("icon-\(index)", kAXButtonRole),
        Node("title-\(index)", kAXStaticTextRole, value: title ?? "Synthetic Room \(index)"),
        Node("badge-\(index)", kAXStaticTextRole, value: "1", identifier: "Count Label"),
        Node("clock-\(index)", kAXStaticTextRole, value: "오후 1:23"),
        Node("preview-\(index)", kAXTextAreaRole, value: "PRIVATE customer body token")])])
}
func label(_ node: Node) -> Node { node.children[0].children[1] }
func nothing(_ index: Int, nodes: Int = 100) -> Node {
    Node("row-\(index)", kAXRowRole, children: (0..<(nodes - 1)).map { Node("empty-\(index)-\($0)", kAXButtonRole) })
}
func run(_ name: String, _ mode: String) -> [String: Any] {
    ipc = []; mutation = nil; counts = Counts()
    var rows = (0..<413).map { regular($0, title: $0 == 245 ? expected : nil) }
    rows[0].children[0].children.append(Node("extra", kAXButtonRole))
    rows[245].children[0].children.removeFirst()
    rows[192] = nothing(192)
    let noTitle = rows[192]
    var query = expected
    var timed = name == "live-shaped" || name == "live-cut" || name == "deadline-retry" || name.hasSuffix("-budget")
    let scenario = name.hasSuffix("-budget") ? String(name.dropLast(7)) : name
    let container = Node("container", kAXTableRole, children: rows)
    var header = Node("header", kAXButtonRole, title: "채팅")
    switch scenario {
    case "valid": rows[192] = regular(192)
    case "numeric": rows[192] = Node("row-192", kAXRowRole, children: [Node("number", kAXStaticTextRole, value: "12345")])
    case "time": rows[192] = Node("row-192", kAXRowRole, children: [Node("clock", kAXStaticTextRole, value: "1:23")])
    case "korean-clock": rows[192] = Node("row-192", kAXRowRole, children: [Node("clock", kAXStaticTextRole, value: "오후 1:23")])
    case "empty-frontier": rows[192] = nothing(192, nodes: 1)
    case "children-no-value": rows[192] = nothing(192, nodes: 1); rows[192].rawSlots[kAXChildrenAttribute] = absent()
    case "children-unsupported": rows[192] = nothing(192, nodes: 1); rows[192].rawSlots[kAXChildrenAttribute] = absent(.attributeUnsupported)
    case "live-cut", "node-cut": rows[192].children.append(Node("unvisited", kAXStaticTextRole, value: query))
    case "text-cut": rows[192] = Node("row-192", kAXRowRole, children: (0..<25).map { Node("n\($0)", kAXStaticTextRole, value: "123") })
    case "exact-text-quota": rows[192] = Node("row-192", kAXRowRole, children: (0..<24).map { Node("n\($0)", kAXStaticTextRole, value: "123") })
    case "request-error": rows[192].batchFails = true
    case "nil-array": rows[192].malformed = "nil"
    case "wrong-count": rows[192].malformed = "count"
    case "null": rows[192].rawSlots[kAXTitleAttribute] = NSNull()
    case "wrong-type": rows[192].rawSlots[kAXValueAttribute] = NSNumber(value: 9)
    case "role-absent": rows[192].rawSlots[kAXRoleAttribute] = absent()
    case "children-transient": rows[192].rawSlots[kAXChildrenAttribute] = absent(.cannotComplete)
    case "children-mixed": rows[192].rawSlots[kAXChildrenAttribute] = [Node("ok",kAXButtonRole), "PRIVATE"] as NSArray
    case "duplicate-before": rows[50] = regular(50, title: query)
    case "duplicate-after": rows[300] = regular(300, title: query)
    case "literal-sentinel": rows[192] = regular(192, title: "(Unknown Chat)")
    case "sentinel-query": query = "(Unknown Chat)"; rows[245] = regular(245, title: query)
    case "many-none": for index in 50...60 { rows[index] = nothing(index, nodes: 20) }
    case "no-direct-order":
        container.children = [Node("wrapper", kAXGroupRole, children: rows)]
    case "unknown-header": header = Node("header", kAXStaticTextRole, value: "Synthetic unknown")
    case "friends": header = Node("header", kAXStaticTextRole, value: "친구")
    case "late-none-title": mutation = { if ipc.count >= 1400 { noTitle.title = query } }
    case "late-none-child": mutation = {
        if ipc.count >= 1400 && noTitle.children.count == 99 {
            noTitle.children.insert(Node("late", kAXStaticTextRole, value: query), at: 0)
        }
    }
    case "earlier-persistent":
        let early = label(rows[50]); mutation = { if ipc.count >= 1000 { early.value = query } }
    case "during-second-pass":
        let early = label(rows[100]); mutation = { if ipc.count >= 1800 { early.value = query } }
    case "retry-transient":
        let early = rows[20]; early.beforeBatch = { if early.batches >= 2 { early.batchFails = true } }
    case "target-changed-before-guard":
        let target = rows[245]
        target.beforeBatch = { if target.batches >= 3 { target.children = []; target.title = "Renamed" } }
    case "order-changed": mutation = {
        if ipc.count == 1400 { container.children.swapAt(0, 245) }
    }
    case "guard-order-error": container.beforeBatch = { container.batchFails = true }
    case "deadline-retry": timed = true
    default: break
    }
    if name != "no-direct-order" { container.children = rows }
    let window = UIElement(Node("window", "window", children: [header, container]))
    let deadline = name == "deadline-retry" ? 1600 : 2400
    let result: ChatListTitleScanResult
    if mode == "legacy" {
        result = LegacyChatListScanner().scanUntilTitle(query, in: window, limit: 500,
            preferredIndex: 245, shouldStop: { timed && ipc.count >= deadline })
    } else {
        result = ChatListScanner().scanUntilTitle(query, in: window, limit: 500,
            preferredIndex: mode == "full" ? nil : 245, shouldStop: { timed && ipc.count >= deadline })
    }
    return ["case": name, "mode": mode, "match": result.match?.axElement.id ?? "none",
        "hint": result.usedTitleHint, "gate": result.hintGate.rawValue,
        "titleNodes": result.titleNodes, "contentNodes": result.contentNodes,
        "scanned": result.rowsScanned, "cut": result.stoppedEarly,
        "calls": ipc.count, "ipc": ipc,
        "snapshots": result.snapshots.map { s in
            "\(s.element.axElement.id)|\(s.discovery.title)|\(s.discovery.lastMessage ?? "nil")|\(s.discovery.unread ?? -1)|\(s.sawClockText)"
        }]
}
let names = ["valid", "live-shaped", "numeric", "time", "korean-clock", "empty-frontier",
    "children-no-value", "children-unsupported", "live-cut", "node-cut", "text-cut", "exact-text-quota",
    "request-error", "nil-array", "wrong-count", "null", "wrong-type", "role-absent", "children-transient",
    "children-mixed", "duplicate-before", "duplicate-after", "literal-sentinel", "sentinel-query",
    "many-none", "no-direct-order", "unknown-header", "friends", "late-none-title", "late-none-child",
    "earlier-persistent", "during-second-pass", "retry-transient", "target-changed-before-guard",
    "order-changed", "guard-order-error", "deadline-retry", "many-none-budget", "order-changed-budget"]
var records: [[String: Any]] = []
for name in names { for mode in ["legacy", "candidate", "full"] { records.append(run(name, mode)) } }
let slotNames = ["empty", "no-value", "unsupported", "cannot-complete", "invalid-element", "null", "wrong-type",
    "mixed-array", "role-absent", "role-wrong-type", "role-error", "text-null", "text-wrong-type",
    "text-unsupported", "text-no-value", "text-transient", "text-nonerror-axvalue", "request-error", "nil-array", "wrong-count"]
func valueShape(_ value: Any?) -> String {
    guard let value else { return "nil" }
    if value is String { return "string" }
    if let children = value as? [Node] { return "nodes:\(children.count)" }
    if value is NSNumber { return "number" }
    return "other"
}
var slots: [[String: Any]] = []
for name in slotNames {
    mutation = nil
    let node = Node("decoder", kAXRowRole)
    switch name {
    case "no-value": node.rawSlots[kAXChildrenAttribute] = absent()
    case "unsupported": node.rawSlots[kAXChildrenAttribute] = absent(.attributeUnsupported)
    case "cannot-complete": node.rawSlots[kAXChildrenAttribute] = absent(.cannotComplete)
    case "invalid-element": node.rawSlots[kAXChildrenAttribute] = absent(.invalidUIElement)
    case "null": node.rawSlots[kAXChildrenAttribute] = NSNull()
    case "wrong-type": node.rawSlots[kAXChildrenAttribute] = "PRIVATE" as NSString
    case "mixed-array": node.rawSlots[kAXChildrenAttribute] = [Node("child",kAXButtonRole), "PRIVATE"] as NSArray
    case "role-absent": node.rawSlots[kAXRoleAttribute] = absent()
    case "role-wrong-type": node.rawSlots[kAXRoleAttribute] = NSNumber(value: 3)
    case "role-error": node.rawSlots[kAXRoleAttribute] = absent(.cannotComplete)
    case "text-null": node.rawSlots[kAXTitleAttribute] = NSNull()
    case "text-wrong-type": node.rawSlots[kAXTitleAttribute] = NSNumber(value: 3)
    case "text-unsupported": node.rawSlots[kAXTitleAttribute] = absent(.attributeUnsupported)
    case "text-no-value": node.rawSlots[kAXTitleAttribute] = absent()
    case "text-transient": node.rawSlots[kAXTitleAttribute] = absent(.cannotComplete)
    case "text-nonerror-axvalue":
        var point = CGPoint.zero; node.rawSlots[kAXTitleAttribute] = AXValueCreate(.cgPoint, &point)!
    case "request-error": node.batchFails = true
    case "nil-array": node.malformed = "nil"
    case "wrong-count": node.malformed = "count"
    default: break
    }
    let attributes = [kAXRoleAttribute, kAXChildrenAttribute, kAXValueAttribute, kAXTitleAttribute, kAXIdentifierAttribute]
    let element = UIElement(node)
    ipc = []; let ordinary = element.batchAttributes(attributes); let originalIPC = ipc
    var observed = ChatListTitleObservation(), callbacks = 0
    ipc = []
    let withObserver = element.batchAttributes(attributes) { error, raw in
        callbacks += 1; observed.observe(error: error, raw: raw)
    }
    slots.append(["case": name, "ordinary": ordinary.map(valueShape), "observed": withObserver.map(valueShape),
        "ordinaryIPC": originalIPC, "observedIPC": ipc, "callbacks": callbacks,
        "issues": observed.issues, "nv": observed.noValue, "uns": observed.unsupported])
}
var clocks = 0
let off = ChatListHintEvidence.make(enabled: false, now: { clocks += 1; return 0 })
var time: UInt64 = 0
let bound = ChatListHintEvidence(sequence: 64, now: { time += 100_000_000_000_000; return time })
bound.gate = 11; bound.reads = Int.max; bound.none = Int.max; bound.unknown = Int.max
bound.literal = Int.max; bound.issues = 63; bound.noValue = Int.max; bound.unsupported = Int.max
bound.cuts = Int.max; bound.admitted = Int.max; bound.restarts = 1; bound.guardRows = Int.max
bound.guardNodes = Int.max; bound.guardFailure = 6; bound.order = 1; bound.target = 1
let maxLine = bound.line()
Thread.current.threadDictionary.removeObject(forKey: "kmsg.hint.numeric-sequence.v1")
let made = (0..<80).compactMap { _ in ChatListHintEvidence.make(enabled: true, now: { 0 }) }.count
print(String(decoding: try JSONSerialization.data(withJSONObject: ["scans": records, "slots": slots,
    "bounds": ["offClockCalls": clocks, "offIsNil": off == nil, "made": made, "line": maxLine]],
    options: [.sortedKeys]), as: UTF8.self))
'''


class ChatListKnownNoneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        reference = REFERENCE.read_text()
        legacy = reference[reference.index('struct ChatListScanner {'):].replace(
            'struct ChatListScanner {', 'struct LegacyChatListScanner {', 1)
        source = stubs() + EVIDENCE.read_text() + SCANNER.read_text() + legacy + CASES
        cls.temp = tempfile.TemporaryDirectory(prefix='known-none-test-')
        folder = Path(cls.temp.name)
        (folder / 'main.swift').write_text(source)
        binary = folder / 'fixture'
        build = subprocess.run(swiftc_command() + [str(folder / 'main.swift'), '-o', str(binary)], capture_output=True, text=True)
        if build.returncode:
            cls.temp.cleanup()
            raise AssertionError(build.stderr)
        runs = []
        for enabled in (False, True):
            run = subprocess.run([str(binary)], capture_output=True, text=True,
                env={**os.environ, 'KMSG_READ_TIMING_ENABLED': str(enabled).lower()})
            if run.returncode:
                raise AssertionError(run.stderr)
            runs.append((json.loads(run.stdout), run.stderr))
        off, cls.quiet = runs[0]
        on, cls.lines = runs[1]
        cls.rows, cls.on_rows = off['scans'], on['scans']
        cls.slots, cls.bounds = off['slots'], off['bounds']
        cls.on_slots, cls.on_bounds = on['slots'], on['bounds']
        cls.by = {(x['case'], x['mode']): x for x in cls.rows}
        if os.environ.get('KMSG_KNOWN_NONE_REPORT'):
            output = Path(os.environ['KMSG_KNOWN_NONE_REPORT'])
            output.write_text(json.dumps({'records': cls.rows, 'slots': cls.slots, 'bounds': cls.bounds,
                'lines': cls.lines.splitlines()}, indent=2) + '\n')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_all_static_and_before_retry_changes_preserve_first_exact(self):
        excluded = {'live-shaped', 'live-cut', 'deadline-retry', 'during-second-pass', 'target-changed-before-guard',
                    'many-none-budget', 'order-changed-budget'}
        for (name, mode), candidate in self.by.items():
            if mode != 'candidate' or name in excluded:
                continue
            with self.subTest(case=name):
                self.assertEqual(candidate['match'], self.by[name, 'legacy']['match'])
                if name not in {'earlier-persistent', 'retry-transient'}:
                    self.assertEqual(candidate['match'], self.by[name, 'full']['match'])
                if not candidate['hint']:
                    self.assertEqual(candidate['snapshots'], self.by[name, 'legacy']['snapshots'])

    def test_live_shaped_none_and_true_frontier_are_distinguished(self):
        a, b = self.by['live-shaped', 'legacy'], self.by['live-cut', 'legacy']
        for field in ('gate', 'titleNodes', 'contentNodes', 'scanned', 'calls', 'cut'):
            self.assertEqual(a[field], b[field])
        self.assertEqual([a[k] for k in ('gate', 'titleNodes', 'contentNodes', 'scanned')], [5, 871, 1226, 175])
        candidate = self.by['live-shaped', 'candidate']
        self.assertEqual(candidate['match'], 'row-245')
        self.assertTrue(candidate['hint'])
        self.assertLess(candidate['calls'], a['calls'])
        self.assertEqual(self.by['live-cut', 'candidate']['ipc'], b['ipc'])

    def test_unknown_does_not_gain_fast_authority(self):
        names = ['request-error', 'nil-array', 'wrong-count', 'null', 'wrong-type', 'role-absent',
                 'children-transient', 'children-mixed', 'node-cut', 'text-cut', 'literal-sentinel', 'sentinel-query']
        for name in names:
            with self.subTest(case=name):
                self.assertEqual(self.by[name, 'candidate']['ipc'], self.by[name, 'legacy']['ipc'])
                self.assertFalse(self.by[name, 'candidate']['hint'])

    def test_normal_and_wrong_tab_paths_do_not_add_ax(self):
        for name in ['valid', 'korean-clock', 'duplicate-before', 'friends']:
            with self.subTest(case=name):
                self.assertEqual(self.by[name, 'candidate']['ipc'], self.by[name, 'legacy']['ipc'])

    def test_changed_guard_and_many_none_keep_fallback_cost(self):
        for name in ['many-none', 'no-direct-order', 'retry-transient', 'order-changed', 'guard-order-error']:
            self.assertFalse(self.by[name, 'candidate']['hint'], name)
        for name in ['many-none', 'retry-transient', 'order-changed', 'guard-order-error']:
            self.assertGreater(self.by[name, 'candidate']['calls'], self.by[name, 'legacy']['calls'], name)
        self.assertEqual(self.by['target-changed-before-guard', 'candidate']['match'], 'none')
        self.assertFalse(self.by['target-changed-before-guard', 'candidate']['hint'])

    def test_persistent_change_before_restart_is_reobserved(self):
        for name, expected in [('earlier-persistent', 'row-50'), ('late-none-title', 'row-192'), ('late-none-child', 'row-192')]:
            self.assertEqual(self.by[name, 'candidate']['match'], expected)
            self.assertEqual(self.by[name, 'legacy']['match'], expected)

    def test_during_fresh_walk_timing_is_not_claimed_identical(self):
        # A later mutation after this fresh pass read row100 can precede the
        # slower full pass's row100 read. Preserve this non-atomic difference.
        self.assertEqual(self.by['during-second-pass', 'legacy']['match'], 'row-100')
        self.assertEqual(self.by['during-second-pass', 'candidate']['match'], 'row-245')

    def test_diagnostics_do_not_change_ipc_result_or_order(self):
        self.assertEqual(self.rows, self.on_rows)
        self.assertEqual(self.slots, self.on_slots)
        self.assertEqual(self.bounds, self.on_bounds)
        self.assertEqual(self.quiet, '')
        self.assertTrue(self.lines)
        for line in self.lines.splitlines():
            self.assertLess(len(line.encode()), 500)
            self.assertNotIn('PRIVATE', line)
            self.assertNotIn('Synthetic', line)
            self.assertRegex(line, r'^\[kmsg\] hint-evidence total=\d+\.\d{3} status=ok schema=1 ')
            for field in line.split()[4:]:
                key, value = field.split('=')
                self.assertTrue(value.isdigit(), key)

    def test_real_axvalue_status_decoder_preserves_values_and_one_call(self):
        expected = {'empty': 0, 'no-value': 0, 'unsupported': 0, 'cannot-complete': 8,
            'invalid-element': 8, 'null': 8, 'wrong-type': 8, 'mixed-array': 8,
            'role-absent': 4, 'role-wrong-type': 4, 'role-error': 4, 'text-null': 16,
            'text-wrong-type': 16, 'text-unsupported': 0, 'text-no-value': 0,
            'text-transient': 16, 'text-nonerror-axvalue': 16, 'request-error': 1,
            'nil-array': 2, 'wrong-count': 2}
        for row in self.slots:
            with self.subTest(case=row['case']):
                self.assertEqual(row['ordinary'], row['observed'])
                self.assertEqual(row['ordinaryIPC'], row['observedIPC'])
                self.assertEqual(len(row['observedIPC']), 1)
                self.assertEqual(row['callbacks'], 1)
                self.assertEqual(row['issues'], expected[row['case']])

    def test_output_and_factory_bounds(self):
        self.assertEqual(self.bounds['offClockCalls'], 0)
        self.assertTrue(self.bounds['offIsNil'])
        self.assertEqual(self.bounds['made'], 64)
        self.assertLess(len(self.bounds['line'].encode()), 500)
        self.assertIn('total=86400.000', self.bounds['line'])
        self.assertIn('clip=1', self.bounds['line'])

    def test_compact_failure_keeps_guard_verdict_without_dropping_fields(self):
        # Production compactErrorMessage joins stderr then keeps 400 chars.
        # Four natural failures had 314/316 chars before this diagnostic.
        # Reproduce only the measured length; never retain the source prefix.
        prefix = 'SYNTHETIC_EXEC_PREFIX '.ljust(316, 'x')
        line = self.bounds['line']
        fields = dict(token.split('=', 1) for token in line.split()[2:])
        expected = {'total', 'status', 'schema', 'seq', 'gate', 'reads', 'none',
                    'unknown', 'literal', 'issues', 'nv', 'uns', 'cuts',
                    'admitted', 'restart', 'guardRows', 'guardNodes',
                    'guardFail', 'order', 'target', 'clip'}
        self.assertEqual(set(fields), expected)
        self.assertEqual(len(line.split()[2:]), len(expected))
        compact = (prefix + line)[:400]
        self.assertIn(' guardFail=6 ', compact)
        # This recovers the guard verdict, not a complete diagnostic group.
        self.assertNotIn(' target=1 ', compact)
        old_order = ('total status schema seq gate reads none unknown literal '
                     'issues nv uns cuts admitted restart guardRows guardNodes '
                     'guardFail order target clip').split()
        old_line = '[kmsg] hint-evidence ' + ' '.join(f'{k}={fields[k]}' for k in old_order)
        self.assertNotIn(' guardFail=6 ', (prefix + old_line)[:400])

    def test_budget_failures_are_bounded_by_existing_full_prefix(self):
        for name in ['many-none-budget', 'order-changed-budget', 'deadline-retry']:
            candidate = self.by[name, 'candidate']
            self.assertTrue(candidate['cut'], name)
            self.assertEqual(candidate['match'], 'none', name)
            # Common 5ms/request model, not shouldStop invocation count. A
            # stopped retry still enters the unchanged full 25-row prefix.
            self.assertLessEqual(candidate['calls'], 2400 + 25 * 7 + 100 + 1, name)


if __name__ == '__main__':
    unittest.main()
