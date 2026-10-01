"""Compare production acknowledgement methods to frozen v4 methods on fake AX.

No app, account, GUI or native command is used. Reference methods are copied
verbatim from 4480afa in fixtures/auth_ack_reference.swift. Traversal-only
observation statements are injected into both methods to record BFS order.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'tests/fixtures/auth_ack_reference.swift'
AUTH = ROOT / 'Sources/kmsg/Auth/KakaoTalkAuthenticator.swift'
UI = ROOT / 'Sources/kmsg/Accessibility/UIElement.swift'
SCOPE = ROOT / 'Sources/kmsg/Accessibility/AXTraversalReadScope.swift'
DIAGNOSTICS = ROOT / 'Sources/kmsg/Auth/AuthAcknowledgementDiagnostics.swift'
TEXT_READER = ROOT / 'Sources/kmsg/Auth/AuthTextAttributeReader.swift'


def swiftc_command():
    command = ['swiftc', '-O']
    # The standalone Swift toolchain used by CI does not auto-select Xcode's
    # macOS SDK. Respect an explicit SDKROOT; otherwise resolve it with xcrun.
    if sys.platform == 'darwin' and not os.environ.get('SDKROOT'):
        sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                             check=True, capture_output=True, text=True).stdout.strip()
        if not sdk:
            raise AssertionError('xcrun returned an empty macOS SDK path')
        command += ['-sdk', sdk]
    return command


def block(text, start):
    index = text.index('{', start)
    depth, end = 1, index + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def methods(text, names):
    selected = []
    for name in names:
        for match in re.finditer(r'    private func ' + name + r'\b', text):
            selected.append((match.start(), block(text, match.start())))
    return '\n\n'.join(value for _, value in sorted(selected))


def instrument_walks(text):
    # Observe each original/candidate BFS visit, including a cache hit. Do not
    # replace any predicate, budget, collection, ordering or return statement.
    return text.replace('        var results:', '        let walkID = walks.count\n        walks.append(Walk(root: axElement.id, nodes: []))\n        var results:').replace(
        '            let current = queue[index]',
        '            let current = queue[index]\n            walks[walkID].nodes.append(current.axElement.id)')


STUBS = r'''
import Foundation
import ApplicationServices
let kAXRoleAttribute = "role", kAXChildrenAttribute = "children"
let kAXTitleAttribute = "title", kAXDescriptionAttribute = "description"
let kAXValueAttribute = "value", kAXIdentifierAttribute = "identifier"
let kAXButtonRole = "button", kAXStaticTextRole = "static", kAXGroupRole = "group"
struct Counts { var batch = 0, single = 0; var total: Int { batch + single } }
struct Walk { var root: String; var nodes: [String] }
var counts = Counts(), walks: [Walk] = [], notes: [String:String] = [:], diagnosticLines: [String] = []
var scalarTextReadNames: [String] = [], textBatchRequestNames: [[String]] = []
var hashCollision = false
public final class Node {
    let id: String
    var role: Any?, title: String?, description: String?, value: String?, identifier: String?
    var enabled = true, childrenUnavailable = false
    var children: [Node], parent: Node?
    var batches = 0, childReads = 0
    var beforeBatch: ((Node) -> Void)?, beforeChildren: ((Node) -> Void)?
    init(_ id: String, _ role: String, value: String? = nil, children: [Node] = []) {
        self.id = id; self.role = role; self.value = value; self.children = children
        for child in children { child.parent = self }
    }
    func append(_ child: Node) { child.parent = self; children.append(child) }
}
public typealias AXUIElement = Node
func CFEqual(_ lhs: Node, _ rhs: Node) -> Bool { lhs === rhs }
func CFHash(_ element: Node) -> UInt { hashCollision ? 7 : UInt(bitPattern: ObjectIdentifier(element)) }
public final class UIElement {
    public let axElement: Node
    public init(_ element: Node) { axElement = element }
    public static func systemWide() -> UIElement { UIElement(world.system) }
    var focusedUIElement: UIElement? {
        counts.single += 1
        return (axElement === world.system ? world.systemFocus : world.appFocus).map(UIElement.init)
    }
    var parent: UIElement? { counts.single += 1; return axElement.parent.map(UIElement.init) }
    var title: String? {
        counts.single += 1
        if CommandLine.arguments[1] == "text-negative-boundary", axElement === world.acknowledgement {
            world.mutated = true; axElement.value = "already logged in"
        }
        return axElement.title
    }
    var axDescription: String? { counts.single += 1; return axElement.description }
    var stringValue: String? { counts.single += 1; return axElement.value }
    var identifier: String? { counts.single += 1; return axElement.identifier }
    var isEnabled: Bool { counts.single += 1; return axElement.enabled }
    var children: [UIElement] {
        let raw: [AXUIElement]? = attributeOptional(kAXChildrenAttribute)
        return raw?.map(UIElement.init) ?? []
    }
    func attributeOptional<T>(_ name: String) -> T? {
        counts.single += 1
        if name == kAXChildrenAttribute {
            axElement.childReads += 1; axElement.beforeChildren?(axElement)
            return (axElement.childrenUnavailable ? nil : axElement.children) as? T
        }
        scalarTextReadNames.append(name)
        switch name {
        case kAXTitleAttribute: return axElement.title as? T
        case kAXDescriptionAttribute: return axElement.description as? T
        case kAXValueAttribute: return axElement.value as? T
        case kAXIdentifierAttribute: return axElement.identifier as? T
        default: return nil
        }
    }
    func batchAttributes(_ names: [String]) -> [Any?] {
        counts.batch += 1; axElement.batches += 1; axElement.beforeBatch?(axElement)
        return names.map { name in
            if name == kAXRoleAttribute { return axElement.role }
            if name == kAXChildrenAttribute { return axElement.childrenUnavailable ? nil : axElement.children }
            return nil
        }
    }
    private func batchAttributes(_ names: [String], diagnoseStructure: Bool, observeAbsence: ((Bool) -> Void)? = nil) -> [Any?] {
        observeAbsence?(false)
        return batchAttributes(names)
    }
// UI_METHODS
}
// These fake IPCs exercise the production batch classifier, including real
// AXValue error slots. No app process or AXUIElement is created by the fixture.
func textSlotError(_ code: AXError) -> AnyObject {
    var value = code
    return AXValueCreate(.axError, &value)!
}
func AXUIElementCopyMultipleAttributeValues(_ node: Node, _ names: CFArray,
    _ options: AXCopyMultipleAttributeOptions, _ values: UnsafeMutablePointer<CFArray?>) -> AXError {
    counts.batch += 1
    let scenario = CommandLine.arguments[1]
    let labels = names as! [String]
    textBatchRequestNames.append(labels)
    if scenario == "text-batch-failure" { return .cannotComplete }
    if scenario == "text-circuit-reset", textBatchRequestNames.count == 1 { return .cannotComplete }
    if scenario == "text-nil-array" { return .success }
    var raw: [AnyObject] = labels.map { label in
        let text: String?
        switch label {
        case kAXTitleAttribute: text = node.title
        case kAXDescriptionAttribute: text = node.description
        case kAXValueAttribute: text = node.value
        default: text = node.identifier
        }
        if let text { return text as NSString }
        return textSlotError(scenario == "text-no-value" ? .noValue : .attributeUnsupported)
    }
    if scenario == "text-wrong-length" { raw.removeLast() }
    if scenario == "text-slot-error" { raw[2] = textSlotError(.cannotComplete) }
    if scenario == "text-slot-type" { raw[2] = NSNumber(value: 123) }
    if scenario == "text-slot-null" { raw[2] = NSNull() }
    if scenario == "text-all-slot-error" { raw = raw.map { _ in textSlotError(.cannotComplete) } }
    if scenario == "text-negative-boundary", node === world.acknowledgement {
        world.mutated = true; node.value = "already logged in"
    }
    values.pointee = raw as CFArray
    return .success
}
final class KakaoTalkApp {
    var focusedWindow: UIElement? {
        counts.single += 1; world.rootCollections += 1
        world.beforeRoots?(world.rootCollections)
        return world.focusedWindow.map(UIElement.init)
    }
    var mainWindow: UIElement? { counts.single += 1; return world.mainWindow.map(UIElement.init) }
    var windows: [UIElement] { counts.single += 1; return world.windows.map(UIElement.init) }
    var applicationElement: UIElement { UIElement(world.app) }
}
final class World {
    let app = Node("app", "application"), system = Node("system", "application")
    let window: Node, table: Node, row: Node, focus: Node
    var focusedWindow: Node?, mainWindow: Node?, windows: [Node]
    var appFocus: Node?, systemFocus: Node?
    var beforeRoots: ((Int) -> Void)?, rootCollections = 0, mutated = false
    var acknowledgement: Node?, ok: Node?
    init(rows: Int) {
        let children = (0..<rows).map { i in Node("row-\(i)", "group", children: [
            Node("label-\(i)", "static", value: "ordinary fixture"),
            Node("leaf-\(i)", "text", value: "synthetic")]) }
        table = Node("table", "table", children: children)
        row = children.first ?? Node("unused", "group")
        focus = children.first?.children.last ?? table
        let pane = Node("pane", "pane", children: [table])
        window = Node("window", "window", children: [pane])
        windows = [window]; focusedWindow = window; mainWindow = window
        appFocus = focus; systemFocus = focus; app.append(window)
    }
    func addAck(to parent: Node? = nil, id: String = "ack") {
        let message = Node(id + "-message", "static", value: "already logged in")
        let button = Node(id + "-button", "button"); button.title = "OK"
        let dialog = Node(id, "group", children: [message, button])
        (parent ?? window).append(dialog); acknowledgement = message; ok = button
    }
    func mutate(_ scenario: String) {
        guard !mutated else { return }; mutated = true
        switch scenario {
        case "late-child": addAck(to: row)
        case "root-child-changes": addAck()
        case "late-role":
            row.children[0].role = "static"; row.children[0].value = "already logged in"
            row.children[1].role = "button"; row.children[1].title = "OK"
        case "late-text":
            row.children[0].value = "already logged in"; row.children[1].title = "OK"
        case "positive-text-changes": acknowledgement?.value = "unrelated prompt"; ok?.title = "Cancel"
        case "window-added":
            let dialog = Node("added-window", "window"); addAck(to: dialog, id: "new")
            windows.append(dialog); app.append(dialog)
        case "focus-changes":
            appFocus = table; systemFocus = table; focusedWindow = windows.last
        case "window-order-changes": windows.reverse()
        default: break
        }
    }
}
var world: World!
// AUTH_STRUCTS
final class FixtureAuthenticator {
    let kakao = KakaoTalkApp()
    let authDiagnostic: ((String) -> Void)? = { diagnosticLines.append($0) }
    var acknowledgementMetrics: [String: Double] = [:]
// AUTH_METHODS
    func inspect() -> [String: Any] {
        let answer = resolvePostLoginAcknowledgement()
        // EMIT_METRICS
        return ["root": answer?.root.axElement.id ?? "none", "button": answer?.button.axElement.id ?? "none"]
    }
}
'''

CASES = r'''
let scenario = CommandLine.arguments[1], finalReference = CommandLine.arguments[2] == "final"
let many = ["overlapping-260", "budget-260", "uncertain-leaves"].contains(scenario)
let fixtureRows: Int
switch scenario {
case "small", "many-root-small": fixtureRows = 1
case "admission-below": fixtureRows = 16
case "admission-above": fixtureRows = 17
default: fixtureRows = many ? 100 : 30
}
world = World(rows: fixtureRows)
hashCollision = scenario == "hash-collision"
switch scenario {
case "yui906-numeric-model":
    // Matches one measured numeric shape, not a captured production UI graph.
    let focused = Node("model-focused", "pane", children: (0..<126).map {
        Node("model-focus-leaf-\($0)", "static", value: "ordinary fixture")
    })
    let children = (0..<133).map { Node("model-parent-leaf-\($0)", "static", value: "ordinary fixture") }
    children[0].childrenUnavailable = true
    let parent = Node("model-parent", "pane", children: children + [focused])
    world.window.children = []
    for index in 0..<142 {
        let filler = Node("model-header-\(index)", "text")
        filler.childrenUnavailable = index < 13
        world.window.append(filler)
    }
    world.window.append(parent)
    world.appFocus = focused; world.systemFocus = focused
case "text-negative-boundary":
    world.addAck()
    world.appFocus = nil; world.systemFocus = nil; world.app.children = []
    world.acknowledgement?.value = finalReference ? "already logged in" : "ordinary fixture"
case "text-empty-strings":
    for row in world.table.children {
        for node in [row] + row.children {
            node.title = ""; node.description = ""; node.value = ""; node.identifier = ""
        }
    }
case "text-positive", "text-positive-changes":
    world.addAck()
    if scenario == "text-positive-changes" {
        if finalReference { world.acknowledgement?.value = "unrelated prompt"; world.ok?.title = "Cancel" }
        else { world.beforeRoots = { count in
            if count == 2 { world.mutated = true; world.acknowledgement?.value = "unrelated prompt"; world.ok?.title = "Cancel" }
        } }
    }
case "no-focus": world.appFocus = nil; world.systemFocus = nil
case "single-root":
    world.appFocus = nil; world.systemFocus = nil; world.focusedWindow = nil; world.mainWindow = nil
    world.windows = []; world.app.children = []
case "disjoint-roots":
    world.appFocus = nil; world.systemFocus = nil
    let second = Node("other-window", "window", children: [Node("other-leaf", "static", value: "ordinary")])
    world.windows.append(second); world.app.children = []
case "many-root-small", "partly-shared":
    for index in 0..<(scenario == "many-root-small" ? 64 : 12) {
        let extra = Node("extra-\(index)", "window")
        if scenario == "partly-shared" { extra.children = [world.row] }
        world.windows.append(extra); world.app.append(extra)
    }
case "cycle": world.row.children.append(world.row)
case "large-children":
    world.row.children = (0..<33000).map { Node("large-\($0)", "text") }
case "first-ack": world.addAck()
case "two-acks", "tied-buttons":
    world.addAck(id: "first"); world.addAck(id: "second")
case "budget-260": world.addAck(to: world.table.children.last)
case "role-error-children-valid": world.row.role = nil
case "role-wrong-type": world.row.role = 123
case "children-error-role-valid": world.row.childrenUnavailable = true
case "uncertain-leaves":
    for row in world.table.children { for leaf in row.children { leaf.childrenUnavailable = true } }
case "late-role":
    world.row.children[0].role = "text"; world.row.children[1].role = "text"
case "late-text": world.row.children[1].role = "button"
case "positive-text-changes":
    // The first root is negative and learns the graph. The final app root
    // sees a fresh acknowledgement text on the same shared handles; fresh
    // uncached selection must then reject their later unrelated prompt.
    world.row.children[1].role = "button"
    world.acknowledgement = world.row.children[0]; world.ok = world.row.children[1]
case "window-order-changes", "focus-changes":
    let extra = Node("extra-window", "window"); world.windows.append(extra); world.app.append(extra)
case "transient-role-error":
    world.row.beforeBatch = { node in node.role = node.batches == 2 ? nil : "group" }
case "transient-children-error":
    world.row.beforeBatch = { node in node.childrenUnavailable = node.batches == 2 }
case "children-order-changes":
    world.row.beforeBatch = { node in if node.batches == 2 { node.children.reverse(); world.mutated = true } }
case "scope-isolation": break
case "empty-children": world.row.children = []
default: break
}
let late = ["late-child", "late-role", "late-text"]
let guardMutations = ["positive-text-changes", "window-added", "focus-changes", "window-order-changes", "root-child-changes"]
if finalReference && (late + guardMutations).contains(scenario) { world.mutate(scenario) }
else if late.contains(scenario) {
    world.app.beforeChildren = { _ in world.mutate(scenario) }
} else if guardMutations.contains(scenario) {
    world.beforeRoots = { count in if count == 2 { world.mutate(scenario) } }
}
if scenario == "root-child-changes" && !finalReference {
    world.beforeRoots = nil
    world.window.beforeChildren = { node in if node.childReads == 2 { world.mutate(scenario) } }
}
if scenario == "positive-text-changes" && !finalReference {
    world.app.beforeChildren = { node in
        if node.childReads == 1 { world.acknowledgement?.value = "already logged in"; world.ok?.title = "OK" }
    }
}
// SET_READ_DIAGNOSTICS
counts = Counts(); walks = []; notes = [:]; diagnosticLines = []
let auth = FixtureAuthenticator()
var answer = auth.inspect()
if scenario == "scope-isolation" {
    world.addAck(); answer = FixtureAuthenticator().inspect()
}
if scenario == "text-circuit-reset" { answer = auth.inspect() }
let report: [String: Any] = [
    "scenario": scenario, "selected": answer, "batchCalls": counts.batch,
    "singleCalls": counts.single, "totalAXCalls": counts.total,
    "walks": walks.map { ["root": $0.root, "nodes": $0.nodes] },
    "notes": notes, "rootCollections": world.rootCollections, "mutated": world.mutated,
    "diagnostics": diagnosticLines,
    "scalarTextReadNames": scalarTextReadNames, "textBatchRequestNames": textBatchRequestNames,
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''

STATIC = ['small', 'overlapping', 'overlapping-260', 'no-focus', 'single-root', 'disjoint-roots',
          'first-ack', 'two-acks', 'tied-buttons', 'budget-260', 'role-error-children-valid',
          'role-wrong-type', 'children-error-role-valid', 'uncertain-leaves', 'empty-children',
          'hash-collision', 'scope-isolation', 'admission-below', 'admission-above', 'many-root-small',
          'partly-shared', 'cycle', 'large-children', 'limit-entries-before', 'limit-entries-after',
          'limit-children-before', 'limit-children-after', 'yui906-numeric-model', 'text-no-value',
          'text-batch-failure', 'text-wrong-length', 'text-slot-error', 'text-slot-type',
          'text-slot-null', 'text-all-slot-error', 'text-positive', 'text-nil-array',
          'text-empty-strings', 'text-circuit-reset']
DYNAMIC = ['late-child', 'late-role', 'late-text', 'positive-text-changes', 'window-added',
           'focus-changes', 'window-order-changes', 'root-child-changes', 'text-positive-changes']
TRANSIENT = ['transient-role-error', 'transient-children-error', 'children-order-changes']
TIMING_BOUNDARY = ['text-negative-boundary']


class AuthAcknowledgementScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('swiftc'):
            raise unittest.SkipTest('swiftc unavailable')
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binaries = {}
        frozen = BASE.read_text()
        cls.reference_hash = hashlib.sha256(frozen.encode()).hexdigest()
        for candidate in [False, True]:
            auth = AUTH.read_text()
            ui = UI.read_text()
            structs = block(auth, auth.index('private struct PostLoginAcknowledgement {'))
            if candidate:
                structs += '\n' + block(auth, auth.index('private struct PostLoginAcknowledgementRoots {'))
                names = ['resolvePostLoginAcknowledgement', 'collectPostLoginAcknowledgementRoots',
                         'collectPostLoginAcknowledgementText', 'containsPostLoginAcknowledgementMarkers',
                         'scoreAcknowledgementButton', 'buttonTextCandidates', 'normalizedText',
                         'appendUnique', 'appendFocusedElementAncestorChain', 'seconds', 'emitAcknowledgementMetrics']
                auth_methods = methods(auth, names)
                # Exercise the production memory bounds at small deterministic
                # values. Only constructor limits change; scope/resolver code
                # and the fresh fallback remain the actual production methods.
                auth_methods = auth_methods.replace('let scope = AXTraversalReadScope()', '''let scope = AXTraversalReadScope(
                    maxEntries: CommandLine.arguments[1] == "limit-entries-before" ? 2 :
                        (CommandLine.arguments[1] == "limit-entries-after" ? 96 : 4096),
                    maxChildReferences: CommandLine.arguments[1] == "limit-children-before" ? 2 :
                        (CommandLine.arguments[1] == "limit-children-after" ? 95 : 32768))''')
                needles = ['    public func roleAndChildren()', '    func roleAndChildrenRead(',
                           '    func optionalStringAttributesRead(',
                           '    func childrenRead()', '    public func findAll(\n        roles:',
                           '    public func findAll(role: String, limit: Int']
                ui_methods = '\n'.join(block(ui, ui.index(needle)) for needle in needles)
                scope = SCOPE.read_text() + '\n' + DIAGNOSTICS.read_text() + '\n' + TEXT_READER.read_text()
                scope += '\n' + (ROOT / 'Sources/kmsg/Auth/AuthReadDiagnostics.swift').read_text()
                scope += '\n' + (ROOT / 'Sources/kmsg/Accessibility/AuthShadowPlanner.swift').read_text()
            else:
                auth_methods = frozen.split('// BEGIN AUTH\n')[1].split('// END AUTH')[0]
                ui_methods = frozen.split('// BEGIN UI\n')[1].split('// END UI')[0]
                scope = ''
            source = STUBS.replace('// UI_METHODS', instrument_walks(ui_methods))
            source = source.replace('// AUTH_STRUCTS', structs).replace('// AUTH_METHODS', auth_methods)
            source = source.replace('// EMIT_METRICS', '''
                notes = acknowledgementMetrics.mapValues { String(format: "%.0f", $0) }
                emitAcknowledgementMetrics()''' if candidate else '')
            path = Path(cls.tmp.name) / ('candidate.swift' if candidate else 'reference.swift')
            cases = CASES.replace('// SET_READ_DIAGNOSTICS', '''
let enabledReadDiagnostics = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "on"
AuthReadDiagnostics.install(enabledReadDiagnostics ? AuthReadDiagnostics() : nil)
''' if candidate else '')
            if candidate:
                cases = cases.replace('"diagnostics": diagnosticLines,',
                    '"diagnostics": diagnosticLines, "readDetails": AuthReadDiagnostics.current?.lines(total: 0) ?? [],')
            path.write_text(source + '\n' + scope + '\n' + cases)
            binary = path.with_suffix('')
            result = subprocess.run([*swiftc_command(), str(path), '-o', str(binary)], capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(result.stderr)
            cls.binaries[candidate] = binary
        cls.results = {}
        for scenario in STATIC + DYNAMIC + TRANSIENT + TIMING_BOUNDARY:
            cls.results[scenario] = {key: json.loads(subprocess.check_output([str(cls.binaries[candidate]), scenario, mode], text=True))
                                     for key, candidate, mode in [('original', False, 'replay'), ('candidate', True, 'replay'), ('freshReference', False, 'final')]}
        report_path = os.environ.get('KMSG_AUTH_SCOPE_FIXTURE_REPORT')
        if report_path:
            def compact(x):
                return {key: value for key, value in x.items() if key != 'walks'} | {'walkLengths': [len(w['nodes']) for w in x['walks']]}
            Path(report_path).write_text(json.dumps({'referenceSha256': cls.reference_hash,
                'cases': {name: {key: compact(value) for key, value in values.items()} for name, values in cls.results.items()}}, indent=2) + '\n')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_static_results_and_original_bfs_prefix(self):
        for name in STATIC:
            with self.subTest(name=name):
                original, candidate = self.results[name]['original'], self.results[name]['candidate']
                self.assertEqual(candidate['selected'], original['selected'])
                self.assertEqual(candidate['walks'][:len(original['walks'])], original['walks'])

    def test_shadow_diagnostics_preserve_all_resolver_results_reads_and_walks(self):
        for name, values in self.results.items():
            on = json.loads(subprocess.check_output([str(self.binaries[True]), name, 'replay', 'on'], text=True))
            off = values['candidate']
            for field in ['selected', 'walks', 'batchCalls', 'singleCalls', 'rootCollections',
                          'scalarTextReadNames', 'textBatchRequestNames']:
                self.assertEqual(on[field], off[field], (name, field))
            self.assertEqual(off['readDetails'], [])
            details = {line.split()[1] + (':' + next((part.split('=')[1] for part in line.split() if part.startswith('variant=')), '')):
                       dict(part.split('=', 1) for part in line.split()[2:]) for line in on['readDetails']}
            base, real = details['auth-shadow:base'], details['auth-plan:']
            for a, b in [('bestNet','bestNet'),('hits','bestHits'),('nodes','bestNodes'),
                         ('guard','bestGuard'),('rootMissing','rootMissing'),('unknownBreaks','unknownBreaks')]:
                self.assertEqual(base[a], real[b], (name, 'base parity', a))

    def test_dynamic_fallback_matches_current_fresh_roots(self):
        for name in DYNAMIC:
            with self.subTest(name=name):
                original, candidate, fresh = (self.results[name][key] for key in ['original', 'candidate', 'freshReference'])
                self.assertTrue(candidate['mutated'])
                self.assertEqual(candidate['selected'], fresh['selected'])
                self.assertGreaterEqual(int(candidate['notes'].get('auth.ackfallbacks', '0')), 1)

    def test_all_traversals_keep_original_budgets(self):
        for name, values in self.results.items():
            for key, result in values.items():
                with self.subTest(name=name, variant=key):
                    self.assertTrue(all(len(walk['nodes']) <= 260 for walk in result['walks']))

    def test_overlapping_negative_tree_reduces_total_ax_including_guards(self):
        for name in ['overlapping', 'overlapping-260', 'hash-collision']:
            with self.subTest(name=name):
                original, candidate = self.results[name]['original'], self.results[name]['candidate']
                self.assertLess(candidate['totalAXCalls'], original['totalAXCalls'])
                self.assertGreater(int(candidate['notes']['auth.ackvbatch']), 0)
                self.assertGreater(int(candidate['notes']['auth.ackvrread']), 0)

    def test_static_cost_admission_preserves_or_reduces_all_ax_calls(self):
        # Bound-invalid cases intentionally redo fresh resolution for safety
        # after a reuse, and are not a steady-state performance promise.
        for name in set(STATIC) - {'limit-entries-after', 'limit-children-after',
                                   'first-ack', 'two-acks', 'tied-buttons', 'text-positive'}:
            with self.subTest(name=name):
                original, candidate = self.results[name]['original'], self.results[name]['candidate']
                self.assertLessEqual(candidate['totalAXCalls'], original['totalAXCalls'])
                notes = candidate['notes']
                if notes['auth.ackactive'] == '1':
                    self.assertGreater(int(notes['auth.ackcredit']) - int(notes['auth.ackplanodes']),
                                       int(notes['auth.ackguardmax']))
        for name in ['small', 'no-focus', 'disjoint-roots', 'first-ack', 'admission-below', 'many-root-small']:
            self.assertEqual(self.results[name]['candidate']['notes']['auth.ackactive'], '0', name)
        self.assertEqual(self.results['admission-above']['candidate']['notes']['auth.ackactive'], '1')

    def test_memory_limits_preserve_live_path_or_force_fresh_fallback(self):
        for name in ['limit-entries-before', 'limit-children-before', 'large-children']:
            with self.subTest(name=name):
                a, b = self.results[name]['original'], self.results[name]['candidate']
                # Structural reads remain live; fresh text now uses its own
                # batch calls, with no effect on the structural path/budget.
                self.assertEqual(a['batchCalls'], b['batchCalls'] - int(b['notes']['auth.acktextbatches']))
                self.assertEqual(b['notes']['auth.ackhits'], '0')
        for name in ['limit-entries-after', 'limit-children-after']:
            with self.subTest(name=name):
                c = self.results[name]['candidate']
                self.assertGreater(int(c['notes']['auth.ackhits']), 0)
                self.assertEqual(c['notes']['auth.ackreason'], '8')
                self.assertEqual(c['notes']['auth.ackfallbacks'], '1')

    def test_numeric_details_survive_unchanged_500_character_forwarder(self):
        fields = {
            1: {'walk', 'guard', 'fallback', 'runs', 'roots', 'active', 'plans', 'credit', 'planNodes', 'guardMax', 'reason'},
            2: {'hits', 'nodes', 'reused', 'live', 'validation', 'rootReads', 'rootValidation',
                'unknown', 'fallbacks', 'textBatchCalls', 'scalarFallbackSlots', 'positiveFresh'},
        }
        for name, values in self.results.items():
            lines = values['candidate']['diagnostics']
            self.assertGreaterEqual(len(lines), 2, name)
            self.assertEqual(len(lines) % 2, 0, name)
            for line in lines:
                self.assertLess(len(line.encode()), 500, name)
                self.assertEqual(line, line[:500])
                self.assertTrue(line.startswith('[kmsg] auth-detail total='))
                tokens = dict(item.split('=') for item in line.split()[2:])
                self.assertEqual(tokens.pop('status'), 'done')
                self.assertEqual(tokens.pop('schema'), '2')
                part = int(tokens.pop('part'))
                self.assertEqual(set(tokens), fields[part] | {'total'})
                self.assertTrue(all(re.fullmatch(r'\d+(?:\.\d+)?', n) for n in tokens.values()))

    def test_partial_error_preserves_descendant_walk(self):
        for name in ['role-error-children-valid', 'role-wrong-type']:
            candidate = self.results[name]['candidate']
            self.assertTrue(any('label-0' in walk['nodes'] for walk in candidate['walks']))
            self.assertGreater(int(candidate['notes']['auth.ackunknown']), 0)

    def test_transient_validation_errors_fall_back_without_wrong_result(self):
        for name in TRANSIENT:
            with self.subTest(name=name):
                candidate = self.results[name]['candidate']
                self.assertEqual(candidate['selected'], {'root': 'none', 'button': 'none'})
                self.assertGreaterEqual(int(candidate['notes'].get('auth.ackfallbacks', '0')), 1)

    def test_positive_text_change_never_returns_stale_action_target(self):
        case = self.results['positive-text-changes']
        self.assertNotEqual(case['original']['selected']['button'], 'none')
        self.assertEqual(case['candidate']['selected']['button'], 'none')

    def test_inactive_structure_model_still_reduces_text_ipc(self):
        a, b = (self.results['yui906-numeric-model'][k] for k in ['original', 'candidate'])
        self.assertEqual(b['notes']['auth.ackactive'], '0')
        self.assertEqual(b['notes']['auth.acklive'], '906')
        self.assertEqual(b['notes']['auth.acknodes'], '390')
        self.assertEqual(b['notes']['auth.ackunknown'], '29')
        self.assertEqual(b['notes']['auth.acktextbatches'], '64')
        self.assertEqual(b['notes']['auth.acktextscalars'], '0')
        self.assertEqual((a['totalAXCalls'], b['totalAXCalls']), (1181, 989))

    def test_uncertain_text_slots_retry_only_the_original_field(self):
        for name in ['text-slot-error', 'text-slot-type', 'text-slot-null']:
            b = self.results[name]['candidate']
            self.assertEqual(b['notes']['auth.acktextscalars'], b['notes']['auth.acktextbatches'])
            self.assertEqual(set(b['scalarTextReadNames']), {'value'})
            self.assertEqual(b['selected'], self.results[name]['original']['selected'])

    def test_repeated_failed_batches_cost_only_one_extra_attempt(self):
        for name in ['text-batch-failure', 'text-wrong-length', 'text-all-slot-error', 'text-nil-array']:
            b = self.results[name]['candidate']
            self.assertEqual(b['notes']['auth.acktextbatches'], '1')
            self.assertEqual(b['notes']['auth.acktextscalars'], '356')
            self.assertEqual(b['scalarTextReadNames'], ['title', 'description', 'value', 'identifier'] * 89)
            # Released scalar-text plus structure-sharing fixture cost 610.
            self.assertEqual(b['totalAXCalls'], 611)
            self.assertEqual(b['selected'], self.results[name]['original']['selected'])

    def test_batch_circuit_lifetime_is_one_inspection(self):
        b = self.results['text-circuit-reset']['candidate']
        # First inspection: one failed batch then scalars. Next inspection:
        # fresh reader tries batching again, and all 89 batches succeed.
        self.assertEqual(len(b['textBatchRequestNames']), 90)
        self.assertEqual(b['notes']['auth.acktextbatches'], '89')
        self.assertEqual(b['notes']['auth.acktextscalars'], '0')

    def test_text_field_order_and_absence_are_preserved(self):
        for name in ['text-no-value', 'text-empty-strings', 'overlapping']:
            b = self.results[name]['candidate']
            self.assertEqual(b['notes']['auth.acktextscalars'], '0')
            self.assertTrue(all(names == ['title', 'description', 'value', 'identifier']
                                for names in b['textBatchRequestNames']))
            self.assertEqual(b['selected'], self.results[name]['original']['selected'])

    def test_positive_batch_is_reselected_with_fresh_scalar_roots(self):
        for name in ['text-positive', 'text-positive-changes']:
            b = self.results[name]['candidate']
            self.assertEqual(b['notes']['auth.ackpositivefresh'], '1')
            self.assertEqual(b['selected'], self.results[name]['freshReference']['selected'])
        self.assertEqual(self.results['text-positive-changes']['candidate']['selected']['button'], 'none')

    def test_negative_time_boundary_is_not_claimed_equivalent(self):
        # A marker arrives after the element batch. The former scalar title
        # then value calls can observe the later state; a batch is one earlier
        # snapshot. Preserve this limit instead of asserting universal dynamic
        # equivalence or hiding it behind a second scalar negative sweep.
        a, b = (self.results['text-negative-boundary'][k] for k in ['original', 'candidate'])
        self.assertNotEqual(a['selected']['button'], 'none')
        self.assertEqual(b['selected']['button'], 'none')
        self.assertEqual(b['notes']['auth.ackpositivefresh'], '0')


class AuthAcknowledgementDiagnosticBoundaryTests(unittest.TestCase):
    def test_numeric_schema_worst_values_and_invalid_values(self):
        if not shutil.which('swiftc'):
            self.skipTest('swiftc unavailable')
        helper = DIAGNOSTICS.read_text()
        keys = sorted(set(re.findall(r'"(auth\.ack[a-z]*)"', helper)))
        times = {'auth.ack', 'auth.ackwalk', 'auth.ackguard', 'auth.ackfb'}
        metrics = ', '.join(f'"{key}": {86400 if key in times else 1000000000}' for key in keys)
        program = helper + '\n' + r'''
var values: [String: Double] = [METRICS]
values["customer-content-must-not-appear"] = 1
let valid = AuthAcknowledgementDiagnostics.lines(values)
var reports: [String: [String]] = ["valid": valid]
for (label, key, value) in [("negative", "auth.ackhits", -1.0),
                          ("fractional", "auth.acknodes", 1.5),
                          ("overflow", "auth.ack", 86401.0),
                          ("nonfinite", "auth.ackwalk", Double.nan)] {
    var invalid = values; invalid[key] = value
    reports[label] = AuthAcknowledgementDiagnostics.lines(invalid)
}
values.removeValue(forKey: "auth.ackhits")
reports["missing"] = AuthAcknowledgementDiagnostics.lines(values)
print(String(data: try JSONSerialization.data(withJSONObject: reports), encoding: .utf8)!)
'''.replace('METRICS', metrics)
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'diagnostics.swift'; source.write_text(program)
            binary = Path(folder) / 'diagnostics'
            subprocess.run([*swiftc_command(), str(source), '-o', str(binary)], check=True, capture_output=True)
            result = json.loads(subprocess.check_output([str(binary)], text=True))
        self.assertEqual(len(result['valid']), 2)
        for line in result['valid']:
            self.assertLess(len(line.encode()), 500)
            self.assertNotIn('customer-content', line)
            self.assertEqual(line, line[:500])
        for key in ['negative', 'fractional', 'overflow', 'nonfinite', 'missing']:
            self.assertEqual(result[key], [], key)

    def test_auth_details_do_not_grow_outer_command_summaries(self):
        for name in ['ChatsCommand', 'ReadCommand', 'SendCommand', 'SendImageCommand', 'FriendCommand']:
            source = (ROOT / f'Sources/kmsg/Commands/{name}.swift').read_text()
            self.assertNotIn('auth.ack', source)
            self.assertNotRegex(source, r'AuthBootstrap\.requireAuthenticated\([^\n]*note:')
        # A command at the existing forwarding limit remains intact; the
        # separate detail lines consume no bytes from that command's budget.
        outer = '[kmsg] read total=99.99 status=ok auth=9.99 resolve=9.99 read=9.99 '
        outer += 'x' * (500 - len(outer))
        forwarded = [line[:500] for line in [
            '[kmsg] auth-detail total=9.99 status=done schema=2 part=1',
            '[kmsg] auth-detail total=9.99 status=done schema=2 part=2', outer,
        ] if line.startswith('[kmsg] ') and ' total=' in line]
        self.assertEqual(forwarded[-1], outer)
        self.assertEqual(len(forwarded), 3)


if __name__ == '__main__':
    unittest.main()
