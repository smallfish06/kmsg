"""Run production input traversal/classifier/form against a frozen scalar reference.

No app, native process, credentials, or customer data is used.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import os
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / 'tests/fixtures/auth_input_traversal_reference.swift'
sys.path.insert(0,str(ROOT/'tests'))
spec=importlib.util.spec_from_file_location('input_fixture',ROOT/'tests/test_auth_input_role_guard.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

HELPER=r'''
func scalarAuthInputs(_ root: UIElement, limit: Int, maxNodes: Int) -> [UIElement] {
    root.findAll(where: { element in
        let role = element.role ?? ""
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == "AXSecureTextField" else { return false }
        return element.isEnabled
    }, limit: limit, maxNodes: maxNodes)
}
'''

EXTRA=r'''
typealias AXUIElement = Node
let kAXRoleAttribute = "role", kAXChildrenAttribute = "children"
var activeScenario = "", activeMode = "", currentPhase = ""
var phaseAX: [String:[Int]] = [:]
var rootNode: Node!, inputPairCalls = 0
'''

BATCH_STUB=r'''
    func batchAttributes(_ names:[String], diagnoseStructure:Bool,
                         observeAbsence:((Bool)->Void)? = nil) -> [Any?] {
        inputPairCalls += 1
        axElement.roleReads += 1; axElement.beforeRole?(axElement)
        event(axElement,"input-pair")
        let role = axElement.rawRole
        let children:Any? = axElement.badChildren ? nil : axElement.children
        axElement.afterBatch?(axElement)
        observeAbsence?(false)
        switch activeScenario {
        case "batch-error": return [nil,nil]
        case "batch-role-error": return [nil,children]
        case "batch-role-type": return [123,children]
        case "batch-child-error": return [role,nil]
        case "batch-child-type": return [role,"not-children"]
        case "transient-first-pair-error": if inputPairCalls == 1 { return [nil,nil] }
        default: break
        }
        return [role,children]
    }
'''

EXTRA_CASES=['one-input-negative','one-input-large','batch-error','batch-role-error','batch-role-type',
    'batch-child-error','batch-child-type','transient-first-pair-error','unknown-ancestor',
    'late-child-boundary','positive-fields-disappear','positive-password-disappears',
    'enabled-adds-child','disabled-adds-child','role-after-snapshot','cycle',
    'nested-order','at199-input','at200-input','form-disappears',
    'bound0','bound1','bound2','bound199','bound200','quota0','quota1','empty',
    'terminal-huge-children','quota-huge-children','root-is-input']

def render(variant):
    source=m.AUTH.read_text()
    names=['buildLoginForm','isLikelyLoginWindow','authPhase','collectLoginMarkerText',
           'containsLoginMarkers','looksLikePasswordField','normalizedText']
    methods='\n'.join(m.block(source,re.search(r'    private func '+n+r'\b',source).start()) for n in names)
    if variant == 'baseline': methods = REFERENCE.read_text()
    methods=methods.replace('    private func authPhase<T>(_ phase: AuthPhaseDiagnostics.Phase, _ action: () throws -> T) rethrows -> T {', '''    private func authPhase<T>(_ phase: AuthPhaseDiagnostics.Phase, _ action: () throws -> T) rethrows -> T {
        let before = events.count, prior = currentPhase; currentPhase = phase.rawValue
        defer { phaseAX[phase.rawValue, default: []].append(events.count-before); currentPhase = prior }''')
    ui=(ROOT/'Sources/kmsg/Accessibility/UIElement.swift').read_text()
    ui_methods=[]
    for i,needle in enumerate(['    public func findAll(where predicate: (UIElement) -> Bool, limit:',
                             '    public func findAll(\n        roles:',
                             '    public func findAll(role: String, limit: Int']):
        method=m.block(ui,ui.index(needle))
        if i==0:
            method=method.replace('        var results:', '        let walk = walks.count\n        walks.append([])\n        var results:')
            method=method.replace('            let current = queue[index]', '            let current = queue[index]\n            walks[walk].append(current.axElement.id)')
        ui_methods.append(method)
    ui_methods.append(m.block(ui,ui.index('    func roleAndChildrenRead(')))
    stub=m.STUB.replace('import Foundation','import Foundation\n'+EXTRA)
    pair_stub=m.block(stub,stub.index('    func roleAndChildrenRead()'))
    stub=stub.replace(pair_stub,'')
    stub=stub.replace('var point: CGPoint?', 'var afterRole: ((Node)->Void)?, afterBatch:((Node)->Void)?, afterEnabled:((Node)->Void)?\n    var point: CGPoint?')
    stub=stub.replace('event(axElement, "role", value ?? "nil"); return value', 'event(axElement, "role", value ?? "nil"); axElement.afterRole?(axElement); return value')
    stub=stub.replace('event(axElement, "enabled", value ? "true" : "false"); return value', 'event(axElement, "enabled", value ? "true" : "false"); axElement.afterEnabled?(axElement); return value')
    stub=stub.replace('event(axElement, "batch"); return (axElement.rawRole as? String,', 'axElement.roleReads += 1; axElement.beforeRole?(axElement)\n        event(axElement, "batch"); return (axElement.rawRole as? String,')
    stub=stub.replace('// UI_METHODS','\n'.join(ui_methods)+'\n'+BATCH_STUB)
    stub=stub.replace('        else if let form = buildLoginForm(from: window) {', '''        else if mode == "direct" {
            let budget = activeScenario.hasPrefix("bound") ? Int(activeScenario.dropFirst(5))! : (activeScenario == "terminal-huge-children" ? 2 : 200)
            let quota = activeScenario == "quota0" ? 0 : (activeScenario == "quota1" ? 1 : 6)
            let selected = DIRECT_FINDER(window, limit:quota, maxNodes:budget)
            result = selected.map { $0.axElement.id }.joined(separator:",")
        } else if mode == "chain" {
            let login = isLikelyLoginWindow(window)
            if activeScenario == "form-disappears" { rootNode.children = [] }
            if login, let form = buildLoginForm(from:window) { result = "login:" + form.usernameField.axElement.id + ":" + form.passwordField.axElement.id }
            else { result = login ? "login:no-form" : "other:no-form" }
        } else if let form = buildLoginForm(from: window) {''')
    stub=stub.replace('DIRECT_FINDER(window, limit:quota, maxNodes:budget)', 'scalarAuthInputs(window, limit:quota, maxNodes:budget)' if variant=='baseline' else 'AuthInputTraversal.find(in:window, limit:quota, maxNodes:budget)')
    stub=stub.replace('"phase": phaseDiagnostics?.line() ?? ""', '"phase": phaseDiagnostics?.line() ?? "", "phaseAX":phaseAX, "pairCalls":inputPairCalls')
    cases=m.CASES.replace('"password-metadata"]','"password-metadata", '+', '.join(json.dumps(n) for n in EXTRA_CASES)+']')
    cases=cases.replace('for mode in ["classify", "form"]','for mode in ["classify", "form", "direct", "chain"]')
    cases=cases.replace('let root = Node("root", "window")','activeScenario = scenario; activeMode = mode\n            let root = Node("root", "window"); rootNode = root')
    cases=cases.replace('            default: break',r'''
            case "one-input-negative": root.children = [user]
            case "one-input-large": root.children = (0..<160).map { Node("leaf\($0)", "text") } + [user]
            case "batch-error", "batch-role-error", "batch-role-type", "batch-child-error", "batch-child-type", "transient-first-pair-error":
                root.children = (0..<300).map { Node("leaf\($0)", "text") }
            case "unknown-ancestor": root.children = [Node("unknown",nil,children:[user,password])]
            case "late-child-boundary":
                let parent=Node("late-parent","group");root.children=[parent]
                parent.afterRole={ node in if !walks.isEmpty { node.children=[user,password] } }
                parent.afterBatch={ node in node.children=[user,password] }
            case "positive-fields-disappear":
                for n in [user,password] { n.beforeRole={ node in if walks.count>=2 { node.rawRole="text" } } }
            case "positive-password-disappears":
                root.children=[user];user.title="Password"
                user.beforeRole={ node in if walks.count>=2 { node.title=nil; node.rawRole="text" } }
            case "enabled-adds-child", "disabled-adds-child":
                let parent=Node("input-parent","field",enabled:scenario=="enabled-adds-child")
                parent.afterEnabled={ node in node.children=[user,password] };root.children=[parent]
            case "role-after-snapshot":
                user.afterRole={ node in node.rawRole="group" };user.afterBatch={ node in node.rawRole="group" }
            case "cycle":
                let cycle=Node("cycle","group");cycle.children=[cycle];root.children=[cycle]
            case "nested-order":
                root.children=[Node("left","group",children:[user]),Node("right","group",children:[password])]
            case "at199-input": root.children=(0..<198).map {Node("leaf\($0)","text")}+[user,password]
            case "at200-input": root.children=(0..<199).map {Node("leaf\($0)","text")}+[user,password]
            case "bound0","bound1","bound2","bound199","bound200":
                root.children=(0..<198).map {Node("leaf\($0)","text")}+[user,password]
            case "quota0","quota1": root.children=[user,password]
            case "empty":root.children=[]
            case "root-is-input":root.rawRole="field";root.children=[]
            case "terminal-huge-children":
                let terminal=Node("terminal","group",children:(0..<33000).map {Node("huge\($0)","text")})
                root.children=[Node("first","text"),terminal]
            case "quota-huge-children":
                root.children=(0..<6).map {Node("input\($0)","field")}
                root.children.last!.children=(0..<33000).map {Node("huge\($0)","text")}
            default: break''')
    cases=cases.replace('events = []; walks = []; ticks = 0; clockReads = 0','events = []; walks = []; ticks = 0; clockReads = 0; phaseAX=[:];inputPairCalls=0')
    phase=(ROOT/'Sources/kmsg/Auth/AuthPhaseDiagnostics.swift').read_text()+'\n'+(ROOT/'Sources/kmsg/Auth/AuthReadDiagnostics.swift').read_text()
    helper=(ROOT/'Sources/kmsg/Auth/AuthInputTraversal.swift').read_text()
    helper=helper.replace('        var results:', '        let walk = walks.count\n        walks.append([])\n        var results:')
    helper=helper.replace('            let current = queue[index]', '            let current = queue[index]\n            walks[walk].append(current.axElement.id)')
    return phase+stub.replace('// AUTH_METHODS',methods)+HELPER+helper+cases

@unittest.skipIf(shutil.which('swiftc') is None,'swiftc unavailable')
class AuthInputTraversalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.results={}
        for variant in ['baseline','candidate']:
            path=Path(cls.temp.name)/(variant+'.swift');path.write_text(render(variant))
            binary=path.with_suffix('')
            built=subprocess.run([*m.swiftc_command(),str(path),'-o',str(binary)],capture_output=True,text=True)
            if built.returncode: raise AssertionError(built.stderr)
            run=subprocess.run([str(binary)],capture_output=True,text=True,check=True)
            cls.results[variant]=json.loads(run.stdout)
        if report:=os.environ.get('KMSG_AUTH_INPUT_TRAVERSAL_REPORT'):
            Path(report).write_text(json.dumps({'referenceSHA256':hashlib.sha256(REFERENCE.read_bytes()).hexdigest(),
                'syntheticOnly':True,'results':cls.results},indent=2)+'\n')
        cls.by={name:{(x['scenario'],x['mode'],x['enabled']):x for x in rows} for name,rows in cls.results.items()}

    def test_results_and_walks_match_with_preserved_snapshot_boundary(self):
        for key,candidate in self.by['candidate'].items():
            with self.subTest(key=key):
                original=self.by['baseline'][key]
                if key[0]=='late-child-boundary' and key[1]!='form': continue
                self.assertEqual(candidate['result'],original['result'])
                self.assertEqual(candidate['walks'],original['walks'])
                self.assertLessEqual(len(candidate['events']),len(original['events'])+1)

    def test_final_form_is_original_scalar_sequence(self):
        for key,candidate in self.by['candidate'].items():
            if key[1]!='form': continue
            for field in ['result','events','walks','clockReads','phaseAX']:
                self.assertEqual(candidate[field],self.by['baseline'][key][field],(key,field))

    def test_observation_on_off_has_same_semantics_and_no_off_clock(self):
        for key,candidate in self.by['candidate'].items():
            other=self.by['candidate'][(key[0],key[1],not key[2])]
            for field in ['result','events','walks','phaseAX']:
                self.assertEqual(candidate[field],other[field],(key,field))
            if not key[2]:
                self.assertEqual(candidate['clockReads'],0)
                self.assertEqual(candidate['phase'],'')

    def test_bounds_quotas_root_exclusion_and_order(self):
        for name,budget in [('bound0',0),('bound1',1),('bound2',2),('bound199',199),('bound200',200),('cycle',200)]:
            row=self.by['candidate'][(name,'direct',False)]
            self.assertEqual(len(row['walks'][0]),budget,name)
            self.assertEqual(row['result'],self.by['baseline'][(name,'direct',False)]['result'])
        self.assertEqual(self.by['candidate'][('quota','direct',False)]['result'],','.join('input'+str(i) for i in range(6)))
        self.assertEqual(len(self.by['candidate'][('quota','form',False)]['walks'][0]),8)
        self.assertEqual(self.by['candidate'][('root-is-input','direct',False)]['result'],'')
        for key,row in self.by['candidate'].items():
            budget=240 if key[1] in ['form','chain'] else 200
            self.assertTrue(all(len(w)<=budget for w in row['walks']),key)

    def test_complete_negative_saves_one_ipc_per_nonterminal_node(self):
        a=self.by['baseline'][('negative200','classify',True)]
        b=self.by['candidate'][('negative200','classify',True)]
        self.assertEqual(a['phaseAX']['inputs'],[400])
        self.assertEqual(b['phaseAX']['inputs'],[201])
        self.assertEqual((len(a['events']),len(b['events'])),(863,664))
        for scenario in ['bound0','bound1','quota0','quota1']:
            k=(scenario,'direct',False)
            self.assertEqual(len(self.by['candidate'][k]['events']),len(self.by['baseline'][k]['events']))

    def test_role_failure_falls_back_once_and_children_failure_does_not_drop_nodes(self):
        for scenario in ['batch-error','batch-role-error','batch-role-type','transient-first-pair-error']:
            k=(scenario,'classify',False)
            self.assertEqual(len(self.by['candidate'][k]['events']),len(self.by['baseline'][k]['events'])+1,scenario)
            self.assertEqual(self.by['candidate'][k]['pairCalls'],1)
        for scenario in ['batch-child-error','batch-child-type']:
            k=(scenario,'classify',False)
            self.assertEqual(len(self.by['candidate'][k]['events']),len(self.by['baseline'][k]['events']),scenario)
        self.assertEqual(self.by['candidate'][('unknown-ancestor','direct',False)]['result'],'username,password')

    def test_enabled_is_fresh_and_children_follow_it(self):
        for scenario in ['enabled-adds-child','disabled-adds-child']:
            row=self.by['candidate'][(scenario,'direct',False)]
            self.assertEqual(row['result'],self.by['baseline'][(scenario,'direct',False)]['result'])
            events=[e['field'] for e in row['events'] if e['node']=='input-parent']
            self.assertEqual(events,['input-pair','enabled','children'])

    def test_terminal_budget_and_quota_do_not_fetch_unused_children(self):
        for scenario,node in [('terminal-huge-children','terminal'),('quota-huge-children','input5')]:
            row=self.by['candidate'][(scenario,'direct',False)]
            events=[e['field'] for e in row['events'] if e['node']==node]
            expected=['role'] if scenario=='terminal-huge-children' else ['role','enabled']
            self.assertEqual(events,expected)
            self.assertFalse(any(e['node'].startswith('huge') for e in row['events']))

    def test_dynamic_snapshot_boundary_is_explicit_and_final_forms_are_fresh(self):
        key=('late-child-boundary','classify',False)
        self.assertEqual(self.by['baseline'][key]['result'],'login')
        self.assertEqual(self.by['candidate'][key]['result'],'other')
        self.assertEqual(self.by['candidate'][('form-disappears','chain',False)]['result'],'login:no-form')

if __name__=='__main__':unittest.main()
