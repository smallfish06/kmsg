"""Run real auth input decisions/BFS against frozen v2 methods, with fake AX."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import block, swiftc_command

ROOT = Path(__file__).resolve().parents[1]
AUTH = ROOT / 'Sources/kmsg/Auth/KakaoTalkAuthenticator.swift'
REFERENCE = ROOT / 'tests/fixtures/auth_input_reference.swift'

STUB = r'''
import Foundation
let kAXTextFieldRole = "field", kAXTextAreaRole = "area", kAXButtonRole = "button"
let kAXStaticTextRole = "static", kAXCheckBoxRole = "check"
var events: [[String:String]] = [], walks: [[String]] = []
var ticks: UInt64 = 0, clockReads = 0
func event(_ node: Node, _ field: String, _ value: String = "") {
    events.append(["node": node.id, "field": field, "value": value]); ticks += 5_000_000
}
func now() -> UInt64 { clockReads += 1; return ticks }
final class Node {
    let id: String
    var rawRole: Any?, rawEnabled: Any?, children: [Node], badChildren = false
    var title: String? = nil, description: String? = nil, value: String? = nil, identifier: String? = nil
    var point: CGPoint? = nil, roleReads = 0, beforeRole: ((Node) -> Void)?
    init(_ id: String, _ role: Any?, enabled: Any? = true, children: [Node] = []) {
        self.id = id; rawRole = role; rawEnabled = enabled; self.children = children
    }
}
func CFEqual(_ lhs: Node, _ rhs: Node) -> Bool { lhs === rhs }
final class AXTraversalReadScope {
    func children(atRoot root: UIElement) -> [UIElement] { root.children }
    func roleAndChildren(of element: UIElement) -> (role: String?, children: [UIElement]) { element.roleAndChildren() }
}
final class UIElement {
    let axElement: Node
    init(_ node: Node) { axElement = node }
    var role: String? {
        axElement.roleReads += 1; axElement.beforeRole?(axElement)
        let value = axElement.rawRole as? String
        event(axElement, "role", value ?? "nil"); return value
    }
    var isEnabled: Bool {
        let value = axElement.rawEnabled as? Bool ?? false
        event(axElement, "enabled", value ? "true" : "false"); return value
    }
    var children: [UIElement] {
        event(axElement, "children"); return axElement.badChildren ? [] : axElement.children.map(UIElement.init)
    }
    var title: String? { event(axElement, "title"); return axElement.title }
    var axDescription: String? { event(axElement, "description"); return axElement.description }
    var stringValue: String? { event(axElement, "value"); return axElement.value }
    var identifier: String? { event(axElement, "identifier"); return axElement.identifier }
    var position: CGPoint? { event(axElement, "position"); return axElement.point }
    func roleAndChildren() -> (role: String?, children: [UIElement]) {
        event(axElement, "batch"); return (axElement.rawRole as? String,
            axElement.badChildren ? [] : axElement.children.map(UIElement.init))
    }
// UI_METHODS
}
private struct LoginForm {
    let window: UIElement, usernameField: UIElement, passwordField: UIElement
}
final class Authenticator {
    let phaseDiagnostics: AuthPhaseDiagnostics?
    init(enabled: Bool) {
        phaseDiagnostics = enabled ? AuthPhaseDiagnostics(now: now) : nil
        phaseDiagnostics?.fullCheck = true
    }
// AUTH_METHODS
    func inspect(_ window: UIElement, _ mode: String) -> [String:Any] {
        let start = phaseDiagnostics?.begin()
        let result: String
        if mode == "classify" { result = isLikelyLoginWindow(window) ? "login" : "other" }
        else if let form = buildLoginForm(from: window) {
            result = form.usernameField.axElement.id + ":" + form.passwordField.axElement.id
        } else { result = "none" }
        if let start { phaseDiagnostics?.end(.total, since: start) }
        return ["result": result, "events": events, "walks": walks, "clockReads": clockReads,
                "syntheticAXms": Double(ticks) / 1_000_000,
                "phase": phaseDiagnostics?.line() ?? ""]
    }
}
'''

CASES = r'''
let scenarios = ["negative200", "negative240", "mixed", "disabled", "enabled-error",
    "enabled-type", "role-error", "role-type", "children-error", "secure",
    "textarea", "quota", "beyond200", "beyond240", "role-changes", "sorted",
    "missing-position", "title-login", "marker-login", "button-login", "password-metadata"]
var output: [[String:Any]] = []
for scenario in scenarios {
    for mode in ["classify", "form"] {
        for enabled in [false, true] {
            let root = Node("root", "window")
            let user = Node("username", "field"), password = Node("password", "AXSecureTextField")
            user.point = CGPoint(x: 10, y: 10); password.point = CGPoint(x: 10, y: 20)
            root.children = [Node("noninput", "group"), user, password]
            switch scenario {
            case "negative200", "negative240":
                root.children = (0..<300).map { Node("leaf\($0)", "text") }
            case "mixed": root.children.insert(contentsOf: (0..<40).map { Node("leaf\($0)", "text") }, at: 0)
            case "disabled": user.rawEnabled = false
            case "enabled-error": user.rawEnabled = nil; password.rawEnabled = nil
            case "enabled-type": user.rawEnabled = "true"; password.rawEnabled = 123
            case "role-error": user.rawRole = nil
            case "role-type": user.rawRole = 123
            case "children-error": root.badChildren = true
            case "secure": user.rawRole = "AXSecureTextField"
            case "textarea": user.rawRole = "area"
            case "quota": root.children = (0..<20).map { Node("input\($0)", "field") }
            case "beyond200": root.children = (0..<200).map { Node("leaf\($0)", "text") } + [user, password]
            case "beyond240": root.children = (0..<240).map { Node("leaf\($0)", "text") } + [user, password]
            case "role-changes": user.beforeRole = { node in node.rawRole = node.roleReads == 1 ? "field" : "group" }
            case "sorted": user.point = CGPoint(x: 20, y: 10); password.point = CGPoint(x: 10, y: 10)
            case "missing-position": user.point = nil; password.point = nil
            case "title-login": root.title = "Login"
            case "marker-login":
                let marker = Node("marker", "static"); marker.value = "QR code"; root.children.insert(marker, at: 0)
            case "button-login":
                root.children = [Node("login-button", "button")]; root.children[0].title = "Login"
            case "password-metadata":
                root.children = [user]; user.title = "Password"
            default: break
            }
            events = []; walks = []; ticks = 0; clockReads = 0
            var result = Authenticator(enabled: enabled).inspect(UIElement(root), mode)
            result["scenario"] = scenario; result["mode"] = mode; result["enabled"] = enabled
            output.append(result)
        }
    }
}
print(String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!)
'''


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class AuthInputRoleGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        source = AUTH.read_text()
        names = ['buildLoginForm', 'isLikelyLoginWindow', 'authPhase', 'collectLoginMarkerText',
                 'containsLoginMarkers', 'looksLikePasswordField', 'normalizedText']
        methods = '\n'.join(block(source, re.search(r'    private func '+name+r'\b', source).start()) for name in names)
        ui = (ROOT/'Sources/kmsg/Accessibility/UIElement.swift').read_text()
        selectors = ['    public func findAll(where predicate: (UIElement) -> Bool, limit:', '    public func findAll(\n        roles:',
                     '    public func findAll(role: String, limit: Int']
        ui_methods = []
        for i, needle in enumerate(selectors):
            method = block(ui, ui.index(needle))
            if i == 0:
                method = method.replace('        var results:', '        let walk = walks.count\n        walks.append([])\n        var results:')
                method = method.replace('            let current = queue[index]',
                    '            let current = queue[index]\n            walks[walk].append(current.axElement.id)')
            ui_methods.append(method)
        template = STUB.replace('// UI_METHODS', '\n'.join(ui_methods))
        phase = (ROOT/'Sources/kmsg/Auth/AuthPhaseDiagnostics.swift').read_text()
        phase += '\n' + (ROOT/'Sources/kmsg/Auth/AuthReadDiagnostics.swift').read_text()
        cls.results = {}
        for label, auth in [('reference', REFERENCE.read_text()), ('candidate', methods)]:
            p = Path(cls.temp.name)/(label+'.swift')
            p.write_text(phase + template.replace('// AUTH_METHODS', auth) + CASES)
            binary = p.with_suffix('')
            build = subprocess.run([*swiftc_command(), str(p), '-o', str(binary)], capture_output=True, text=True)
            if build.returncode: raise AssertionError(build.stderr)
            cls.results[label] = json.loads(subprocess.check_output([str(binary)], text=True))
        if report := os.environ.get('KMSG_AUTH_INPUT_FIXTURE_REPORT'):
            Path(report).write_text(json.dumps({'referenceSHA256': hashlib.sha256(REFERENCE.read_bytes()).hexdigest(),
                'syntheticOnly': True, 'results': cls.results}, indent=2)+'\n')

    @staticmethod
    def key(row): return row['scenario'], row['mode'], row['enabled']

    def test_full_login_classification_and_form_selection_match(self):
        reference = {self.key(r): r for r in self.results['reference']}
        for c in self.results['candidate']:
            with self.subTest(key=self.key(c)):
                a = reference[self.key(c)]
                self.assertEqual(c['result'], a['result'])
                self.assertEqual(c['walks'], a['walks'])

    def test_only_unused_enabled_reads_are_removed(self):
        reference = {self.key(r): r for r in self.results['reference']}
        for c in self.results['candidate']:
            a = reference[self.key(c)]
            roles, expected = {}, []
            for event in a['events']:
                if event['field'] == 'role': roles[event['node']] = event['value']
                if event['field'] == 'enabled' and roles.get(event['node']) not in ['field', 'area', 'AXSecureTextField']:
                    continue
                expected.append(event)
            with self.subTest(key=self.key(c)):
                self.assertEqual(c['events'], expected)

    def test_negative_search_saves_one_call_per_noninput_with_same_budget(self):
        by_variant = {k:{self.key(r):r for r in v} for k,v in self.results.items()}
        for mode, budget in [('classify',200),('form',240)]:
            key = ('negative200',mode,True)
            a,b = (by_variant[v][key] for v in ['reference','candidate'])
            self.assertEqual(len(a['events'])-len(b['events']), budget)
            self.assertEqual(len(b['walks'][0]), budget)
            self.assertEqual(a['syntheticAXms']-b['syntheticAXms'], budget*5)
            if mode == 'classify':
                fields = [dict(pair.split('=') for pair in r['phase'].split()[2:]) for r in [a,b]]
                self.assertAlmostEqual(float(fields[0]['inputs'])-float(fields[1]['inputs']), budget*.005)

    def test_quotas_errors_and_timing_off_keep_contract(self):
        for c in self.results['candidate']:
            self.assertTrue(all(len(w)<= (200 if c['mode']=='classify' else 240) for w in c['walks']))
            if c['scenario']=='quota': self.assertEqual(len(c['walks'][0]),6 if c['mode']=='classify' else 8)
            if not c['enabled']:
                self.assertEqual(c['clockReads'],0)
                self.assertEqual(c['phase'],'')


if __name__ == '__main__': unittest.main()
