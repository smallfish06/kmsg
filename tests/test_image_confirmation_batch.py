"""Real image methods and raw AX decoder on synthetic trees; no GUI access.

The reference retains the pre-batch lookup/completion/action methods. Stable
input result/BFS order and diagnostics ON/OFF are compared separately from
intentional observation-time changes. This is not an image delivery proof or a
fix for the existing unbounded timeout, nil-as-completion, or AXPress retry.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import block, swiftc_command

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    'small-absent', 'large-absent', 'live-shaped', 'deep-sheet', 'direct-sheet',
    'duplicate-sheets', 'nested-bfs-order', 'direct-unknown', 'direct-malformed',
    'root-children-error', 'group-modal', 'stale-direct', 'batch-request-error',
    'batch-unsupported', 'batch-nil', 'batch-count', 'role-error', 'role-null',
    'role-wrong', 'child-error', 'child-null', 'child-wrong', 'child-mixed',
    'child-no-value', 'child-unsupported', 'role-and-child-error',
    'matching-child-error', 'matching-role-error', 'matching-batch-unsupported', 'raw-role-error', 'raw-child-error', 'raw-role-wrong',
    'raw-child-wrong', 'late-sheet', 'retired-sheet', 'substitution-before-first',
    'late-child-between-slots', 'earlier-role-late', 'false-click-retired',
    'false-click-unsent', 'false-click-still-live', 'false-click-unknown-children',
    'nested-role-error', 'nested-child-error', 'nested-child-no-value',
    'nested-child-unsupported', 'nested-role-and-child-error',
    'nested-raw-child-error', 'role-retry-late-child', 'representative-553',
    'representative-628', 'representative-649', 'representative-628-partial',
    'representative-628-absence',
]
DYNAMIC = {
    'late-sheet', 'retired-sheet', 'substitution-before-first',
    'late-child-between-slots', 'earlier-role-late', 'role-retry-late-child',
}
METHODS = ['waitForConfirmationSheet', 'locateConfirmationSheet', 'findSendButton',
           'waitForSendCompletion', 'windowContainsElement', 'areSameAXElement']


def extract(source, signature):
    return block(source, source.index(signature))


def render():
    source = (ROOT / 'Sources/kmsg/Commands/SendImageCommand.swift').read_text()
    ui = (ROOT / 'Sources/kmsg/Accessibility/UIElement.swift').read_text()
    runner = (ROOT / 'Sources/kmsg/Accessibility/AXActionRunner.swift').read_text()
    fixture = (ROOT / 'tests/fixtures/image_confirmation_batch.swift').read_text()
    mapping = {
        'ATTRIBUTE': '    public func attribute<T>',
        'OPTIONAL': '    public func attributeOptional<T>',
        'ROLE': '    public var role: String?',
        'TITLE': '    public var title: String?',
        'CHILDREN': '    public var children: [UIElement]',
        'BATCH_PUBLIC': '    public func batchAttributes(_ names:',
        'BATCH_OBSERVE': '    func batchAttributes(\n        _ names: [String], observingRaw:',
        'BATCH_PRIVATE': '    private func batchAttributes(',
        'FIRST': '    public func findFirst(where predicate:',
        'ALL': '    public func findAll(where predicate:',
        'ALL_ROLE': '    public func findAll(role: String) ->',
        'PERFORM': '    public func performAction(',
        'PRESS': '    public func press()',
    }
    for token, signature in mapping.items():
        fixture = fixture.replace('// ' + token + '\n', extract(ui, signature) + '\n')
    fixture = fixture.replace('// WAIT\n', extract(runner, '    func waitUntil(') + '\n')
    fixture = fixture.replace('// CLICK\n', extract(runner, '    func clickWithRetry(') + '\n')
    methods = '\n'.join(extract(source, '    private func ' + name + '(')
                        for name in METHODS + ['findConfirmationSheetInDescendants'])
    methods = methods.replace('diagnostics?.fallbackVisits += 1',
                              'world.visits.append(current.axElement.id)\n            diagnostics?.fallbackVisits += 1')
    flow_start = source.index('        // 4. Confirmation sheet')
    flow_end = source.index('\n    }\n\n    // Remove anything', flow_start)
    flow = source[flow_start:flow_end].replace('print(', 'fixturePrint(')
    candidate = 'struct Candidate {\nlet targetDescription="SYNTHETIC"\n' + methods + r'''
    func run(_ mode:String)->String {
        let root=UIElement(world.root),target=UIElement(world.target),runner=AXActionRunner()
        switch mode {
        case "locate": return locateConfirmationSheet(in:root,diagnostics:world.diagnostics).map{String($0.axElement.id)} ?? "nil"
        case "wait": return waitForConfirmationSheet(in:root,runner:runner,diagnostics:world.diagnostics).map{String($0.axElement.id)} ?? "nil"
        case "complete": return waitForSendCompletion(in:root,confirmationSheet:target,runner:runner,diagnostics:world.diagnostics) ? "complete":"incomplete"
        default: do {try flow(root);return "native-success"} catch{return "native-failure"}
        }
    }
    func flow(_ window:UIElement)throws {
        let runner=AXActionRunner(),profiler=PhaseProfiler(),confirmationDiagnostics=world.diagnostics
''' + flow + '\n    }\n}\n'
    reference = (ROOT / 'tests/fixtures/image_confirmation_batch_reference.swift').read_text()
    fixture = fixture.replace('// COMMANDS', reference + candidate)
    tail = '\nlet cases=' + json.dumps(CASES) + r'''
var output:[[String:Any]]=[]
for variant in ["baseline","batch"] {
 for name in cases {for mode in ["locate","wait","complete","flow"] {for enabled in [false,true] {for cost in [0.005,0.05] {
  world.reset(name,cost,enabled)
  let outcome=variant=="baseline" ? Baseline().run(mode):Candidate().run(mode)
  output.append(["variant":variant,"case":name,"mode":mode,"enabled":enabled,"cost":cost,"result":outcome,
   "scalarCalls":Clock.scalar,"batchCalls":Clock.batch,"actionCalls":Clock.actions,"seconds":Clock.seconds,"sleepSeconds":Clock.sleepSeconds,
   "visits":world.visits.count,"visitHash":hash(world.visits.map(String.init)),"ipcHash":hash(world.ipc),
   "syntheticEffects":world.effects,"wrongEffects":world.wrongEffects,"diagnostic":world.diagnostics?.line() ?? ""])
 }}}}
}
print(String(data:try! JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),encoding:.utf8)!)
'''
    return (ROOT / 'Sources/kmsg/KakaoTalk/ImageConfirmationDiagnostics.swift').read_text() + '\n' + fixture + tail


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class ImageConfirmationBatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix='image-confirmation-batch-') as tmp:
            source, binary = Path(tmp) / 'main.swift', Path(tmp) / 'fixture'
            source.write_text(render())
            build = subprocess.run([*swiftc_command(), str(source), '-o', str(binary)],
                                   text=True, capture_output=True)
            if build.returncode:
                raise AssertionError(build.stderr)
            run = subprocess.run([str(binary)], check=True, text=True, capture_output=True)
            cls.rows = json.loads(run.stdout)
        cls.by = {(r['variant'], r['case'], r['mode'], r['enabled'], r['cost']): r for r in cls.rows}
        if destination := os.environ.get('KMSG_IMAGE_BATCH_REPORT'):
            Path(destination).write_text(json.dumps(cls.rows, indent=2) + '\n')

    def row(self, name, variant='batch', mode='locate', enabled=True, cost=0.005):
        return self.by[(variant, name, mode, enabled, cost)]

    @staticmethod
    def reads(row):
        return row['scalarCalls'] + row['batchCalls']

    @staticmethod
    def fields(row):
        return dict(token.split('=', 1) for token in row['diagnostic'].split()[2:])

    def test_static_result_first_sheet_and_action_effects_match_reference(self):
        self.assertEqual(len(self.rows), len(CASES) * 32)
        fields = ['result', 'actionCalls', 'syntheticEffects', 'wrongEffects']
        for new in self.rows:
            if new['variant'] != 'batch' or new['case'] in DYNAMIC:
                continue
            old = self.row(new['case'], 'baseline', new['mode'], new['enabled'], new['cost'])
            with self.subTest(case=new['case'], mode=new['mode'], cost=new['cost']):
                self.assertEqual({k: old[k] for k in fields}, {k: new[k] for k in fields})

    def test_static_single_lookup_bfs_order_matches_reference(self):
        for name in set(CASES) - DYNAMIC:
            for cost in [.005, .05]:
                old, new = self.row(name, 'baseline', cost=cost), self.row(name, cost=cost)
                self.assertEqual((old['visits'], old['visitHash']), (new['visits'], new['visitHash']), name)

    def test_diagnostics_off_on_have_identical_raw_ipc_results_and_actions(self):
        for on in self.rows:
            if not on['enabled']:
                self.assertEqual(on['diagnostic'], '')
                continue
            off = self.row(on['case'], on['variant'], on['mode'], False, on['cost'])
            fields = set(on) - {'enabled', 'diagnostic'}
            self.assertEqual({k: off[k] for k in fields}, {k: on[k] for k in fields})

    def test_existing_direct_lookup_uses_no_batches(self):
        row = self.row('direct-sheet')
        self.assertEqual((row['result'], row['scalarCalls'], row['batchCalls']), ('2001', 1, 0))
        self.assertEqual([self.fields(row)[k] for k in ['batch','rfallback','cfallback']], ['0'] * 3)

    def test_supported_and_partial_support_request_counts(self):
        self.assertEqual((self.reads(self.row('live-shaped', 'baseline')), self.reads(self.row('live-shaped'))), (1108, 555))
        for name, expected in [('representative-553', 563), ('representative-628', 638),
                               ('representative-649', 659), ('representative-628-partial', 951),
                               ('representative-628-absence', 1265)]:
            self.assertEqual(self.reads(self.row(name, mode='flow')), expected, name)
        self.assertEqual(self.reads(self.row('representative-628', 'baseline', mode='flow')), 1265)

    def test_whole_batch_or_role_failure_pays_extra_call_and_uses_scalar(self):
        for name in ['batch-request-error','batch-unsupported','batch-nil','batch-count',
                     'role-error','role-null','role-wrong','role-and-child-error']:
            row = self.row(name)
            self.assertEqual((row['result'], self.reads(row)), ('2001', 27), name)
            self.assertEqual([self.fields(row)[k] for k in ['batch','rfallback','cfallback']], ['9','8','8'], name)
            self.assertEqual(self.reads(self.row(name, 'baseline')), 19)

    def test_child_slot_uncertainty_always_rereads_original_scalar(self):
        for name in ['child-error','child-null','child-wrong','child-mixed',
                     'child-no-value','child-unsupported']:
            row = self.row(name)
            self.assertEqual((row['result'], self.reads(row)), ('2001', 19), name)
            self.assertEqual([self.fields(row)[k] for k in ['rfallback','cfallback']], ['0','8'])
        for name in ['nested-child-error','nested-child-no-value','nested-child-unsupported',
                     'nested-role-error','nested-role-and-child-error']:
            self.assertEqual(self.row(name)['result'], '2001', name)
        self.assertEqual(self.row('nested-raw-child-error')['result'], 'nil')

    def test_role_retry_discards_earlier_children_snapshot(self):
        row = self.row('role-retry-late-child')
        self.assertEqual((row['result'], row['scalarCalls'], row['batchCalls']), ('2001', 4, 2))
        self.assertEqual([self.fields(row)[k] for k in ['rfallback','cfallback']], ['1','1'])

    def test_matching_sheet_does_not_reread_unused_child_slot(self):
        row = self.row('matching-child-error')
        self.assertEqual((row['result'], row['scalarCalls'], row['batchCalls']), ('2001', 2, 9))
        self.assertEqual(self.fields(row)['cfallback'], '0')

    def test_matching_sheet_scalar_role_retry_still_skips_children(self):
        for name in ['matching-role-error', 'matching-batch-unsupported']:
            row = self.row(name)
            self.assertEqual((row['result'], row['scalarCalls'], row['batchCalls']), ('2001', 3, 9))
            self.assertEqual([self.fields(row)[k] for k in ['rfallback','cfallback']], ['1','0'])

    def test_schema2_counts_match_actual_batch_reads_with_no_extra_ax(self):
        for row in self.rows:
            if row['variant'] != 'batch' or not row['enabled']:
                continue
            fields = self.fields(row)
            self.assertEqual(fields['schema'], '2')
            self.assertEqual(int(fields['batch']), row['batchCalls'])
            self.assertEqual(int(fields['batch']), int(fields['visits']))
            self.assertLessEqual(int(fields['rfallback']), int(fields['batch']))
            self.assertLessEqual(int(fields['cfallback']), int(fields['batch']) - int(fields['found']))
            self.assertEqual(fields['clip'], '0')
            self.assertLess(len(row['diagnostic'].encode()), 500)
            self.assertTrue(row['diagnostic'].isascii())

    def test_captured_temporal_divergences_are_not_claimed_equivalent(self):
        old, new = self.row('late-child-between-slots','baseline'), self.row('late-child-between-slots')
        self.assertEqual((old['result'], new['result']), ('2001','nil'))
        self.assertLess(new['seconds'], .020)  # Candidate ends before the modeled child appears.
        self.assertGreater(old['seconds'], .020)
        old, new = self.row('earlier-role-late','baseline'), self.row('earlier-role-late')
        self.assertEqual((old['result'], new['result']), ('2','2001'))
        self.assertAlmostEqual(old['seconds'], new['seconds'])
        self.assertEqual(self.row('earlier-role-late','baseline',mode='flow')['actionCalls'], 0)
        self.assertEqual(self.row('earlier-role-late',mode='flow')['actionCalls'], 1)

    def test_existing_uncertainty_and_retry_defects_are_preserved(self):
        for variant in ['baseline','batch']:
            for name in ['root-children-error','false-click-unknown-children']:
                row = self.row(name,variant,mode='flow')
                self.assertEqual((row['result'],row['syntheticEffects']), ('native-success',0))
            row = self.row('false-click-still-live',variant,mode='flow')
            self.assertEqual((row['result'],row['actionCalls'],row['syntheticEffects']), ('native-failure',3,3))
            self.assertEqual(self.row('substitution-before-first',variant,mode='flow')['wrongEffects'], 1)
            self.assertGreater(self.row('large-absent',variant,mode='wait')['seconds'], 1.5)

    def test_completion_button_containment_and_wait_methods_unchanged(self):
        reference = (ROOT / 'tests/fixtures/image_confirmation_batch_reference.swift').read_text()
        source = (ROOT / 'Sources/kmsg/Commands/SendImageCommand.swift').read_text()
        for name in set(METHODS) - {'locateConfirmationSheet'}:
            signature = '    private func ' + name + '('
            self.assertEqual(extract(source, signature), extract(reference, signature), name)


if __name__ == '__main__':
    unittest.main()
