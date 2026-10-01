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
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'tests/fixtures/auth_ack_reference.swift'
AUTH = ROOT / 'Sources/kmsg/Auth/KakaoTalkAuthenticator.swift'
UI = ROOT / 'Sources/kmsg/Accessibility/UIElement.swift'
SCOPE = ROOT / 'Sources/kmsg/Accessibility/AXTraversalReadScope.swift'
DIAGNOSTICS = ROOT / 'Sources/kmsg/Auth/AuthAcknowledgementDiagnostics.swift'


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
let kAXRoleAttribute = "role", kAXChildrenAttribute = "children"
let kAXButtonRole = "button", kAXStaticTextRole = "static", kAXGroupRole = "group"
struct Counts { var batch = 0, single = 0; var total: Int { batch + single } }
struct Walk { var root: String; var nodes: [String] }
var counts = Counts(), walks: [Walk] = [], notes: [String:String] = [:], diagnosticLines: [String] = []
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
    var title: String? { counts.single += 1; return axElement.title }
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
        return nil
    }
    func batchAttributes(_ names: [String]) -> [Any?] {
        counts.batch += 1; axElement.batches += 1; axElement.beforeBatch?(axElement)
        return names.map { name in
            if name == kAXRoleAttribute { return axElement.role }
            if name == kAXChildrenAttribute { return axElement.childrenUnavailable ? nil : axElement.children }
            return nil
        }
    }
// UI_METHODS
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
counts = Counts(); walks = []; notes = [:]; diagnosticLines = []
let auth = FixtureAuthenticator()
var answer = auth.inspect()
if scenario == "scope-isolation" {
    world.addAck(); answer = FixtureAuthenticator().inspect()
}
let report: [String: Any] = [
    "scenario": scenario, "selected": answer, "batchCalls": counts.batch,
    "singleCalls": counts.single, "totalAXCalls": counts.total,
    "walks": walks.map { ["root": $0.root, "nodes": $0.nodes] },
    "notes": notes, "rootCollections": world.rootCollections, "mutated": world.mutated,
    "diagnostics": diagnosticLines,
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''

STATIC = ['small', 'overlapping', 'overlapping-260', 'no-focus', 'single-root', 'disjoint-roots',
          'first-ack', 'two-acks', 'tied-buttons', 'budget-260', 'role-error-children-valid',
          'role-wrong-type', 'children-error-role-valid', 'uncertain-leaves', 'empty-children',
          'hash-collision', 'scope-isolation', 'admission-below', 'admission-above', 'many-root-small',
          'partly-shared', 'cycle', 'large-children', 'limit-entries-before', 'limit-entries-after',
          'limit-children-before', 'limit-children-after']
DYNAMIC = ['late-child', 'late-role', 'late-text', 'positive-text-changes', 'window-added',
           'focus-changes', 'window-order-changes', 'root-child-changes']
TRANSIENT = ['transient-role-error', 'transient-children-error', 'children-order-changes']


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
                needles = ['    public func roleAndChildren()', '    func roleAndChildrenRead()',
                           '    func childrenRead()', '    public func findAll(\n        roles:',
                           '    public func findAll(role: String, limit: Int']
                ui_methods = '\n'.join(block(ui, ui.index(needle)) for needle in needles)
                scope = SCOPE.read_text() + '\n' + DIAGNOSTICS.read_text()
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
            path.write_text(source + '\n' + scope + '\n' + CASES)
            binary = path.with_suffix('')
            result = subprocess.run(['swiftc', '-O', str(path), '-o', str(binary)], capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(result.stderr)
            cls.binaries[candidate] = binary
        cls.results = {}
        for scenario in STATIC + DYNAMIC + TRANSIENT:
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
        for name in set(STATIC) - {'limit-entries-after', 'limit-children-after'}:
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
                self.assertEqual(a['totalAXCalls'], b['totalAXCalls'])
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
            2: {'hits', 'nodes', 'reused', 'live', 'validation', 'rootReads', 'rootValidation', 'unknown', 'fallbacks'},
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
                self.assertEqual(tokens.pop('schema'), '1')
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
            subprocess.run(['swiftc', '-O', str(source), '-o', str(binary)], check=True, capture_output=True)
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
            '[kmsg] auth-detail total=9.99 status=done schema=1 part=1',
            '[kmsg] auth-detail total=9.99 status=done schema=1 part=2', outer,
        ] if line.startswith('[kmsg] ') and ' total=' in line]
        self.assertEqual(forwarded[-1], outer)
        self.assertEqual(len(forwarded), 3)


if __name__ == '__main__':
    unittest.main()
