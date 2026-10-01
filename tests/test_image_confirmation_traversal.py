"""Compare real image-confirmation methods before/after numeric instrumentation."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import block, swiftc_command

ROOT = Path(__file__).resolve().parents[1]

STUB = r'''
import Foundation
enum Clock {
    static var seconds = 0.0, axCalls = 0, visits = 0
    static func read() { seconds += 0.005; axCalls += 1 }
    static func reset() { seconds=0;axCalls=0;visits=0 }
}
struct Date {
    let value = Clock.seconds
    func timeIntervalSince(_ prior: Date) -> Double { Clock.seconds-prior.value }
}
enum Thread { static func sleep(forTimeInterval s: Double) { Clock.seconds += s } }
let kAXSheetRole="AXSheet",kAXSheetsAttribute="AXSheets"
typealias AXUIElement=Node
final class Node {
    let id:Int;var role:String?;var children:[Node]=[];var sheets:Any?=nil
    var childrenFail=false
    init(_ id:Int,_ role:String?="AXStaticText") {self.id=id;self.role=role}
}
func CFEqual(_ a:Node,_ b:Node)->Bool {a === b}
final class UIElement {
    let axElement:Node
    init(_ node:Node){axElement=node}
    var role:String?{Clock.read();return axElement.role}
    var children:[UIElement]{Clock.read();return axElement.childrenFail ? []:axElement.children.map(UIElement.init)}
    func attributeOptional<T>(_ name:String)->T?{Clock.read();return axElement.sheets as? T}
    // FIND_FIRST
}
struct AXActionRunner {
    func log(_ value:@autoclosure()->String){}
    // WAIT_UNTIL
}
struct Command {
    // METHODS
    func run(_ root:UIElement,_ target:UIElement,_ mode:String,_ diagnostics:ImageConfirmationDiagnostics?)->Bool{
        if mode=="wait" {return waitForConfirmationSheet(in:root,runner:AXActionRunner() DIAGNOSTICS_ARG) != nil}
        return waitForSendCompletion(in:root,confirmationSheet:target,runner:AXActionRunner() DIAGNOSTICS_ARG)
    }
}
var output:[[String:Any]]=[]
for name in ["small-absent","large-absent","deep-sheet","direct-sheet","stale-sheet",
             "failed-children","direct-failed-children","empty-array","malformed-sheets","missing-roles"]{
 for mode in ["wait","complete"]{
  for enabled in [false,true]{
    let root=Node(0,"AXWindow"),target=Node(2001,kAXSheetRole)
    root.children=(1...(name=="small-absent" ? 4:1000)).map{Node($0)}
    switch name{
    case "deep-sheet":root.children.append(target)
    case "direct-sheet":root.children.append(target);root.sheets=[target]
    case "stale-sheet":root.sheets=[target]
    case "failed-children":root.children.append(target);root.childrenFail=true
    case "direct-failed-children":root.children.append(target);root.sheets=[target];root.childrenFail=true
    case "empty-array":root.sheets=[Node]()
    case "malformed-sheets":root.sheets="invalid"
    case "missing-roles":for n in root.children{n.role=nil}
    default:break
    }
    Clock.reset()
    let d=ImageConfirmationDiagnostics.make(enabled:enabled,now:{UInt64((Clock.seconds*1_000_000_000).rounded())})
    let result=Command().run(UIElement(root),UIElement(target),mode,d)
    output.append(["case":name,"mode":mode,"enabled":enabled,"result":result,
                   "axCalls":Clock.axCalls,"visits":Clock.visits,"seconds":Clock.seconds,
                   "diagnostic":d?.line() ?? ""])
  }
 }
}
print(String(data:try! JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
'''


def render(variant):
    command = (ROOT / 'Sources/kmsg/Commands/SendImageCommand.swift').read_text()
    if variant == 'baseline':
        methods = (ROOT / 'tests/fixtures/image_confirmation_reference.swift').read_text()
    else:
        methods = '\n'.join(block(command, command.index('    private func ' + n + '(')) for n in [
            'waitForConfirmationSheet', 'locateConfirmationSheet', 'waitForSendCompletion',
            'windowContainsElement', 'areSameAXElement'])
    ui = (ROOT / 'Sources/kmsg/Accessibility/UIElement.swift').read_text()
    find = block(ui, ui.index('    public func findFirst(where predicate:'))
    find = find.replace('            let current = queue[index]', '            let current = queue[index]\n            Clock.visits += 1')
    runner = (ROOT / 'Sources/kmsg/Accessibility/AXActionRunner.swift').read_text()
    wait = block(runner, runner.index('    func waitUntil('))
    fixture = STUB.replace('// FIND_FIRST', find).replace('// WAIT_UNTIL', wait).replace('// METHODS', methods)
    fixture = fixture.replace(' DIAGNOSTICS_ARG', '' if variant == 'baseline' else ',diagnostics:diagnostics')
    return (ROOT / 'Sources/kmsg/KakaoTalk/ImageConfirmationDiagnostics.swift').read_text() + fixture


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class ImageConfirmationTraversalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.results = {}
        with tempfile.TemporaryDirectory(prefix='image-confirmation-parity-') as tmp:
            for variant in ['baseline', 'candidate']:
                source = Path(tmp) / (variant + '.swift')
                binary = source.with_suffix('')
                source.write_text(render(variant))
                build = subprocess.run([*swiftc_command(), str(source), '-o', str(binary)], text=True, capture_output=True)
                if build.returncode:
                    raise AssertionError(build.stderr)
                run = subprocess.run([str(binary)], text=True, capture_output=True, check=True)
                cls.results[variant] = json.loads(run.stdout)

    def test_all_40_results_and_existing_ax_work_are_identical(self):
        self.assertEqual(len(self.results['baseline']), 40)
        fields = ['case', 'mode', 'enabled', 'result', 'axCalls', 'visits', 'seconds']
        for old, new in zip(self.results['baseline'], self.results['candidate']):
            self.assertEqual({k: old[k] for k in fields}, {k: new[k] for k in fields})

    def test_disabled_diagnostics_are_absent(self):
        for row in self.results['candidate']:
            if not row['enabled']:
                self.assertEqual(row['diagnostic'], '')

    def test_metadata_distinguishes_direct_empty_unknown_and_fallback(self):
        def fields(name):
            row = next(x for x in self.results['candidate'] if x['case'] == name and x['mode'] == 'wait' and x['enabled'])
            return dict(t.split('=', 1) for t in row['diagnostic'].split()[2:])
        self.assertEqual(fields('direct-sheet')['direct'], '1')
        self.assertEqual(fields('direct-sheet')['walks'], '0')
        self.assertGreater(int(fields('empty-array')['empty']), 0)
        self.assertEqual(fields('empty-array')['unknown'], '0')
        self.assertGreater(int(fields('malformed-sheets')['unknown']), 0)
        self.assertGreater(int(fields('missing-roles')['roles']), 0)
        self.assertEqual(fields('deep-sheet')['found'], '1')

    def test_current_deadline_and_uncertainty_defects_are_preserved_not_fixed(self):
        rows = self.results['candidate']
        def row(name, mode):
            return next(x for x in rows if x['case'] == name and x['mode'] == mode and x['enabled'])
        self.assertGreater(row('large-absent', 'wait')['seconds'], 20)
        self.assertTrue(row('failed-children', 'complete')['result'])
        self.assertTrue(row('direct-failed-children', 'complete')['result'])


if __name__ == '__main__':
    unittest.main()
