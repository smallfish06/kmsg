"""Pure shadow estimates from synthetic snapshots; no AX request API exists."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import swiftc_command

ROOT = Path(__file__).resolve().parents[1]

FIXTURE = r'''
import Foundation
final class Node: NSObject {}
final class UIElement {
    let axElement: Node
    init(_ value: Node = Node()) { axElement = value }
}
func snapshot(_ roots: [UIElement], _ children: [UIElement], known: [UIElement]) -> AuthShadowPlanner.Snapshot {
    AuthShadowPlanner.Snapshot(nodes: known.map { ($0, "known", []) }, roots: roots.map { ($0, children) })
}
var output: [[String: Any]] = []
for scenario in ["typed", "unknown", "role-missing", "removed", "bounded", "budget", "quota", "invalid", "wrong-root", "discard"] {
    let current = UIElement(), knownRoot = UIElement(), absence = UIElement()
    let leaves = (0..<3).map { _ in UIElement() }
    let planner = AuthShadowPlanner(maxHints: scenario == "bounded" ? 0 : 4096)
    planner.observe(absence, role: scenario == "role-missing" ? nil : "absence", typedAbsence: scenario != "unknown")
    if scenario == "removed" { planner.observe(absence, role: "absence", typedAbsence: false) }
    if scenario == "discard" { planner.discard() }
    let children = [absence] + leaves
    let roots = [current, knownRoot, knownRoot]
    let roles: Set<String> = scenario == "quota" ? ["absence"] : ["absent-role"]
    planner.beforeRoot(roots: roots[...], roles: roles, limits: ["absence": 1],
        maxNodes: scenario == "budget" ? 2 : 260, guardCost: 50,
        snapshot: snapshot([knownRoot], children, known: leaves))
    planner.afterRoot(scenario == "wrong-root" ? knownRoot : current,
        snapshot: snapshot([current, knownRoot], children, known: leaves), valid: scenario != "invalid")
    // Discarding snapshots/hints must retain only numeric results for emission.
    planner.discard()
    let diagnostics = AuthReadDiagnostics()
    planner.record(into: diagnostics)
    output.append(["scenario": scenario, "lines": diagnostics.lines(total: 1)])
}
let merged = AuthReadDiagnostics()
merged.recordShadow(.base, plans: 0, bestNet: 0, hits: 0, nodes: 0, guardCost: 0, rootMissing: 0, unknownBreaks: 0)
merged.recordShadow(.base, plans: 1, bestNet: 0, hits: 3, nodes: 3, guardCost: 50, rootMissing: 1, unknownBreaks: 2)
merged.recordShadow(.base, plans: 1, bestNet: 4, hits: 9, nodes: 5, guardCost: 55, rootMissing: 1, unknownBreaks: 1)
merged.recordShadow(.base, plans: 0, bestNet: 0, hits: 0, nodes: 0, guardCost: 0, rootMissing: 0, unknownBreaks: 0)
output.append(["scenario": "merge", "lines": merged.lines(total: 1)])
let bounded = AuthReadDiagnostics()
for variant in AuthReadDiagnostics.ShadowVariant.allCases {
    bounded.recordShadow(variant, plans: .max, bestNet: .max, hits: .max, nodes: .max,
        guardCost: .max, rootMissing: .max, unknownBreaks: .max)
}
output.append(["scenario": "clipping", "lines": bounded.lines(total: 86400)])
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
'''


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class AuthShadowPlannerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix='auth-shadow-') as tmp:
            path = Path(tmp) / 'fixture.swift'
            source = (ROOT/'Sources/kmsg/Auth/AuthReadDiagnostics.swift').read_text()
            source += '\n' + (ROOT/'Sources/kmsg/Accessibility/AuthShadowPlanner.swift').read_text() + '\n' + FIXTURE
            path.write_text(source)
            binary = path.with_suffix('')
            result = subprocess.run([*swiftc_command(), str(path), '-o', str(binary)], capture_output=True, text=True)
            if result.returncode: raise AssertionError(result.stderr)
            cls.rows = json.loads(subprocess.check_output([str(binary)], text=True))
        if report := os.environ.get('KMSG_AUTH_SHADOW_FIXTURE_REPORT'):
            Path(report).write_text(json.dumps({'systemAXInvoked': False, 'rows': cls.rows}, indent=2) + '\n')

    @classmethod
    def values(cls, scenario):
        lines = next(r['lines'] for r in cls.rows if r['scenario'] == scenario)
        return {f['variant']: f for line in lines if line.startswith('[kmsg] auth-shadow ')
                for f in [dict(p.split('=', 1) for p in line.split()[2:])]}

    def test_a_only_crosses_typed_absence_with_zero_read_credit_b_only_uses_fresh_root(self):
        values = self.values('typed')
        self.assertEqual((values['base']['hits'], values['base']['rootMissing'], values['base']['unknownBreaks']), ('0','1','2'))
        self.assertEqual((values['a']['hits'], values['a']['nodes'], values['a']['bestNet']), ('6','3','3'))
        self.assertEqual((values['b']['hits'], values['b']['rootMissing'], values['b']['unknownBreaks']), ('0','0','3'))
        self.assertEqual((values['ab']['hits'], values['ab']['nodes'], values['ab']['bestNet']), ('9','3','6'))

    def test_uncertain_missing_role_removed_or_bounded_hint_has_no_credit(self):
        for scenario in ['unknown', 'role-missing', 'removed', 'bounded', 'discard']:
            for variant in self.values(scenario).values(): self.assertEqual(variant['hits'], '0', scenario)

    def test_original_node_budget_and_role_quota_apply_to_hints_too(self):
        self.assertEqual(self.values('budget')['ab']['hits'], '3')
        self.assertEqual(self.values('budget')['ab']['nodes'], '1')
        for variant in self.values('quota').values(): self.assertEqual(variant['hits'], '0')

    def test_b_does_not_use_invalid_or_different_root(self):
        for scenario in ['invalid', 'wrong-root']:
            self.assertEqual(self.values(scenario)['base']['plans'], '1')
            self.assertEqual(self.values(scenario)['b']['plans'], '0')
            self.assertEqual(self.values(scenario)['ab']['plans'], '0')

    def test_group_merge_keeps_paired_best_prediction_and_ignores_zero_plan_scope(self):
        value = self.values('merge')['base']
        self.assertEqual([value[k] for k in ['plans','bestNet','hits','nodes','guard','keys','rootMissing','unknownBreaks']],
                         ['2','4','9','5','55','5','2','3'])

    def test_optional_fixed_shadow_lines_precede_legacy_triplet_and_are_bounded(self):
        fields = {'total','status','schema','variant','plans','bestNet','hits','nodes','guard','keys','rootMissing','unknownBreaks','clip'}
        for row in self.rows:
            lines = row['lines']
            self.assertEqual([line.split()[1] for line in lines[-3:]], ['auth-plan','auth-shape','auth-io'])
            variants = []
            for line in lines[:-3]:
                self.assertLess(len(line.encode()), 500)
                value = dict(p.split('=',1) for p in line.split()[2:])
                self.assertEqual(set(value), fields)
                variants.append(value['variant'])
                for key, item in value.items():
                    if key not in ['status','variant']: self.assertRegex(item, r'^\d+(?:\.\d+)?$')
            if row['scenario'] != 'merge': self.assertEqual(variants, ['base','a','b','ab'])
        self.assertTrue(all(v['clip'] == '1' for v in self.values('clipping').values()))


if __name__ == '__main__': unittest.main()
