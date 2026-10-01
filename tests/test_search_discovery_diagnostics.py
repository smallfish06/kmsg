"""Existing search discovery/actions remain identical with bounded numeric logs."""
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
from test_auth_read_diagnostics import select_methods

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTICS = ROOT / 'Sources/kmsg/KakaoTalk/SearchDiscoveryDiagnostics.swift'
REFERENCE = ROOT / 'tests/fixtures/search_discovery_reference.swift'

BASE = '''
final class NAME {
    let kakao = KakaoTalkApp(), runner = AXActionRunner()
    let interactionMode = ChatWindowInteractionMode.allowUIAutomation
    func resolveCachedElement(slot: AXPathSlot, root: UIElement, validate: (UIElement) -> Bool) -> UIElement? {
        guard world.cachePath, let cached = world.cached else { return nil }
        let field = UIElement(cached); return validate(field) ? field : nil
    }
    func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement) {}
    func tryRaiseWindow(_ root: UIElement) -> Bool { actions.append("raise:" + root.axElement.id); return true }
    func run() -> Bool {
        if scenario == "direct" { return !discoverSearchFieldCandidates(in: UIElement(world.root)).isEmpty }
        if scenario == "repeat" {
            var result = false
            for _ in 0..<66 { result = clearChatListSearchIfDirty(in: UIElement(world.root)) }
            return result
        }
        return clearChatListSearchIfDirty(in: UIElement(world.root))
    }
    // METHODS
}
'''

CHECKS = '''
world = World(1)
var offClocks = 0
let off = SearchDiscoveryDiagnostics.make(enabled: false, now: { offClocks += 1; return 0 })
var clock: UInt64 = 0
let measured = SearchDiscoveryDiagnostics(sequence: 1, now: { clock += 1_000_000; return clock })
let root = UIElement(world.root)
measured.scan(slot: 0, root: root) { _ = root.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140) }
let measuredLines = measured.lines()
let measuredCalls = calls
enum FixtureFailure: Error { case stopped }
let auth = AuthReadDiagnostics()
let previousAuth = AuthReadDiagnostics.install(auth)
let outer = SearchDiscoveryDiagnostics(sequence: 2)
let inner = SearchDiscoveryDiagnostics(sequence: 3)
var nestedRestored = false
outer.scan(slot: 0, root: root) {
    let active = SearchDiscoveryDiagnostics.currentPass
    do { try inner.scan(slot: 1, root: root) { throw FixtureFailure.stopped } }
    catch {}
    nestedRestored = SearchDiscoveryDiagnostics.currentPass === active
}
let authUnchanged = AuthReadDiagnostics.current === auth
AuthReadDiagnostics.install(previousAuth)
let restored = SearchDiscoveryDiagnostics.currentPass == nil
let unknown = SearchDiscoveryDiagnostics(sequence: 4)
unknown.scan(slot: 0, root: root) { _ = UIElement(world.other).roleAndChildrenRead() }
var groups: [[String]] = []
for _ in 0..<66 {
    if let value = SearchDiscoveryDiagnostics.make(enabled: true) { groups.append(value.lines()) }
}
var backwardsClock = UInt64.max
let backwards = SearchDiscoveryDiagnostics(sequence: 5, now: { backwardsClock -= 1; return backwardsClock })
backwards.scan(slot: 0, root: root) { _ = root.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140) }
let backwardsLines = backwards.lines()
let clamped = SearchDiscoveryDiagnostics(sequence: Int.max, now: {
    let value = backwardsClock == 0 ? UInt64.max : 0; backwardsClock = value; return value
})
let clampedLines = clamped.lines()

var samples: [[String: Any]] = []
world = World(140)
for index in 0..<60 {
    for enabled in (index % 2 == 0 ? [false, true] : [true, false]) {
        calls = []
        let start = DispatchTime.now().uptimeNanoseconds
        let diagnostics = enabled ? SearchDiscoveryDiagnostics(sequence: 1) : nil
        for slot in 0..<3 {
            let root = UIElement(world.root)
            if let diagnostics { diagnostics.scan(slot: slot, root: root) { _ = root.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140) } }
            else { _ = root.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140) }
        }
        _ = diagnostics?.lines()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        samples.append(["enabled": enabled, "ms": elapsed, "calls": calls.count])
    }
}
let result: [String: Any] = ["offNil": off == nil, "offClocks": offClocks,
    "measuredLines": measuredLines, "measuredCalls": measuredCalls, "clockCalls": clock / 1_000_000,
    "nestedRestored": nestedRestored, "restored": restored, "authUnchanged": authUnchanged,
    "outer": outer.lines(), "partial": inner.lines(), "unknown": unknown.lines(),
    "capGroups": groups, "backwards": backwardsLines, "clamped": clampedLines,
    "overheadSamples": samples]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
'''


def methods(source, names):
    out = []
    for name in names:
        match = re.search(r'    (?:public |private )?func ' + name + r'\b', source)
        out.append(block(source, match.start()))
    return '\n'.join(out)


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class SearchDiscoveryDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='search-diagnostics-')
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        resolver = (ROOT / 'Sources/kmsg/KakaoTalk/ChatWindowResolver.swift').read_text()
        ui = (ROOT / 'Sources/kmsg/Accessibility/UIElement.swift').read_text()
        names = ['findExistingSearchField', 'discoverSearchFieldCandidates', 'pickSearchField',
                 'clearChatListSearchIfDirty', 'clearChatListSearch']
        classes = []
        for name, source in [('ReferenceResolver', REFERENCE.read_text()), ('CandidateResolver', methods(resolver, names))]:
            classes.append(BASE.replace('NAME', name).replace('// METHODS', source.replace(
                'Thread.sleep(forTimeInterval:', 'fixtureSleep(forTimeInterval:')))
        ui_methods = select_methods(ui) + '\n' + methods(ui, ['roleAndChildren'])
        ui_methods += '\n' + block(ui, ui.index('    public func findAll(role: String, limit: Int'))
        fixture = (ROOT / 'tests/fixtures/search_discovery_diagnostics.swift').read_text()
        source = fixture.replace('// UI_METHODS', ui_methods).replace('// RESOLVER_CLASSES', '\n'.join(classes))
        source = DIAGNOSTICS.read_text() + '\n' + (ROOT / 'Sources/kmsg/Auth/AuthReadDiagnostics.swift').read_text() + '\n' + source
        cls.source = source
        path = folder / 'fixture.swift'; path.write_text(source)
        cls.binary = folder / 'fixture'
        build = subprocess.run([*swiftc_command(), str(path), '-o', str(cls.binary)], capture_output=True, text=True)
        if build.returncode:
            raise AssertionError(build.stderr)
        cls.rows = {}
        cls.cases = ['negative', 'small', 'direct', 'two-roots', 'three-roots', 'only-root', 'foreign', 'positive',
                     'cache-hit', 'cache-stale-role', 'cache-stale-path', 'title', 'empty', 'disabled',
                     'late-enabled', 'late-focus', 'late-main', 'window-change', 'timed-role',
                     'timed-descendant', 'no-value', 'unsupported', 'transient', 'null', 'type',
                     'malformed', 'role-missing', 'role-error', 'request-failure', 'root-error',
                     'limit', 'budget', 'table-rows', 'table-field', 'deep', 'cycle', 'wide']
        for case in cls.cases:
            for mode in ['reference', 'off', 'on']:
                run = subprocess.run([str(cls.binary), case, mode], env={**os.environ,
                    'KMSG_READ_TIMING_ENABLED': 'true' if mode == 'on' else 'false'}, capture_output=True, text=True)
                if run.returncode:
                    raise AssertionError(run.stderr)
                cls.rows[case, mode] = {'result': json.loads(run.stdout), 'lines': run.stderr.splitlines()}
        check_path = folder / 'checks.swift'
        check_path.write_text(source.split('// BEGIN CASES')[0] + CHECKS)
        check_binary = folder / 'checks'
        built = subprocess.run([*swiftc_command(), str(check_path), '-o', str(check_binary)], capture_output=True, text=True)
        if built.returncode:
            raise AssertionError(built.stderr)
        cls.checks = json.loads(subprocess.check_output([str(check_binary)], text=True))
        if report := os.environ.get('KMSG_SEARCH_DIAGNOSTICS_REPORT'):
            Path(report).write_text(json.dumps({'caseCount': len(cls.cases), 'referenceSha256': hashlib.sha256(REFERENCE.read_bytes()).hexdigest(),
                'sourceSha256': hashlib.sha256(source.encode()).hexdigest(), 'systemAXInvoked': False,
                'rows': [{'case': k[0], 'mode': k[1], **v} for k, v in cls.rows.items()], 'checks': cls.checks}, indent=2) + '\n')

    @staticmethod
    def parsed(lines):
        return [dict(re.findall(r'([A-Za-z]+)=([^ ]+)', line)) for line in lines]

    def test_exact_full_ipc_and_action_order_matches_frozen_reference_on_and_off(self):
        for case in self.cases:
            reference = self.rows[case, 'reference']['result']
            for mode in ['off', 'on']:
                self.assertEqual(self.rows[case, mode]['result'], reference, (case, mode))

    def test_three_original_lazy_passes_even_identical_root(self):
        row = self.rows['negative', 'on']
        lines = self.parsed(row['lines'])
        self.assertEqual([p['pass'] for p in lines[1:]], ['0', '1', '2'])
        self.assertEqual([p['alias'] for p in lines[1:]], ['0', '0', '0'])
        self.assertEqual(lines[0]['roots'], '3'); self.assertEqual(lines[0]['unique'], '1')
        self.assertEqual(lines[0]['aliases'], '7')
        calls = row['result']['calls']
        self.assertEqual(calls.index('anchor:focus'), 141)
        self.assertEqual(calls.index('anchor:main'), 283)
        self.assertEqual(len(calls), 425)

    def test_off_has_no_diagnostic_output_and_no_title_identifier_reads(self):
        for case in self.cases:
            self.assertEqual(self.rows[case, 'off']['lines'], [])
            for call in self.rows[case, 'on']['result']['calls']:
                self.assertNotIn('AXTitle', call)
                self.assertNotIn('AXIdentifier', call)
                self.assertNotIn('AXSubrole', call)

    def test_cache_hit_has_no_walk(self):
        lines = self.parsed(self.rows['cache-hit', 'on']['lines'])
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]['cache'], '1'); self.assertEqual(lines[0]['roots'], '0')
        self.assertEqual(len(self.rows['cache-hit', 'on']['result']['calls']), 6)

    def test_actual_typed_absence_and_fault_counters_preserve_incomplete(self):
        for case, key in [('no-value', 'noValue'), ('unsupported', 'unsupported'), ('transient', 'otherFault'),
                          ('null', 'otherFault'), ('type', 'otherFault'), ('malformed', 'otherFault'),
                          ('role-missing', 'otherFault'), ('role-error', 'otherFault'), ('request-failure', 'otherFault')]:
            for line in self.parsed(self.rows[case, 'on']['lines'])[1:]:
                self.assertEqual(line[key], '1', case)
                self.assertEqual(line['complete'], '139', case)
                self.assertEqual(line['prefix'], '42', case)

    def test_role_ancestry_only_follows_original_visited_edges(self):
        passes = self.parsed(self.rows['table-rows', 'on']['lines'])[1:]
        for p in passes:
            self.assertEqual((p['visits'], p['table'], p['row'], p['underTable'], p['underRow'], p['depth']),
                             ('140', '1', '1', '138', '137', '3'))
            self.assertEqual(p['unknownPath'], '0')
        for p in self.parsed(self.rows['table-field', 'on']['lines'])[1:]:
            self.assertEqual(p['tableFields'], '1')
        for case in ['cycle', 'wide', 'deep']:
            for p in self.parsed(self.rows[case, 'on']['lines'])[1:]:
                self.assertEqual(p['visits'], '140')
                self.assertEqual(p['unknownPath'], '0')

    def test_bounded_numeric_wire_and_same_lookup_total(self):
        for case in self.cases:
            lines = self.rows[case, 'on']['lines']; parsed = self.parsed(lines)
            self.assertEqual(len(lines), 1 + int(parsed[0]['roots']))
            for line, data in zip(lines, parsed):
                self.assertLess(len(line.encode()), 500)
                self.assertNotIn('PRIVATE_', line)
                self.assertEqual(data['total'], parsed[0]['total'])
                self.assertEqual(data['seq'], '1'); self.assertEqual(data['status'], 'ok')
                self.assertIn(' total=', line)
                for key, value in data.items():
                    if key != 'status':
                        self.assertRegex(value, r'^\d+(?:\.\d{3})?(?:,\d+(?:\.\d{3})?)*$', (case, key))

    def test_scoped_observer_restored_on_nested_throw_and_auth_untouched(self):
        for field in ['nestedRestored', 'restored', 'authUnchanged']:
            self.assertTrue(self.checks[field], field)
        partial = self.parsed(self.checks['partial'])
        self.assertEqual(partial[0]['roots'], '1')
        self.assertEqual(partial[0]['returned'], '0')
        self.assertEqual(partial[1]['returned'], '0')
        self.assertEqual(self.parsed(self.checks['outer'])[0]['returned'], '1')

    def test_actual_copy_time_not_confused_with_whole_pass_time(self):
        lines = self.parsed(self.checks['measuredLines'])
        self.assertEqual(lines[0]['total'], '0.007')
        self.assertEqual(lines[1]['wall'], '0.005')
        self.assertEqual(lines[1]['ax'], '1,1,0.002,0.001,0')
        self.assertEqual(self.checks['clockCalls'], 8)
        self.assertEqual(len(self.checks['measuredCalls']), 2)
        self.assertTrue(self.checks['offNil']); self.assertEqual(self.checks['offClocks'], 0)

    def test_lookup_cap_and_clock_bounds_do_not_add_queries(self):
        groups = self.checks['capGroups']
        self.assertEqual(len(groups), 64)
        self.assertEqual([self.parsed(g)[0]['seq'] for g in groups], [str(i) for i in range(1, 65)])
        self.assertEqual(self.parsed(groups[-1])[0]['clip'], '1')
        for g in groups:
            self.assertEqual(len(g), 1)
            self.assertEqual(self.parsed(g)[0]['roots'], '0')
        backwards = self.parsed(self.checks['backwards'])
        self.assertEqual(backwards[0]['total'], '0.000'); self.assertEqual(backwards[1]['wall'], '0.000')
        self.assertEqual(self.parsed(self.checks['clamped'])[0]['clip'], '1')
        self.assertEqual(self.parsed(self.checks['unknown'])[1]['unknownPath'], '1')

    def test_fake_ipc_overhead_samples_reported_without_timing_threshold(self):
        samples = self.checks['overheadSamples']
        self.assertEqual(len(samples), 120)
        self.assertEqual({x['calls'] for x in samples}, {423})
        self.assertTrue(all(x['ms'] >= 0 for x in samples))

    def test_direct_discovery_emits_one_group_without_claiming_cache_lookup(self):
        lines = self.parsed(self.rows['direct', 'on']['lines'])
        self.assertEqual(lines[0]['cache'], '2')
        self.assertEqual(len(lines), 4)

    def test_real_lookup_cap_preserves_all_later_calls(self):
        outputs = {}
        for mode in ['reference', 'off', 'on']:
            run = subprocess.run([str(self.binary), 'repeat', mode], env={**os.environ,
                'KMSG_READ_TIMING_ENABLED': 'true' if mode == 'on' else 'false'}, capture_output=True, text=True, check=True)
            outputs[mode] = json.loads(run.stdout)
            if mode == 'on':
                lines = self.parsed(run.stderr.splitlines())
                headers = [p for p in lines if 'cache' in p]
                self.assertEqual(len(headers), 64)
                self.assertEqual(len(lines), 256)
                self.assertEqual(headers[-1]['clip'], '1')
        self.assertEqual(outputs['on'], outputs['reference'])
        self.assertEqual(outputs['off'], outputs['reference'])

    @unittest.skipUnless(os.name == 'posix', 'POSIX stderr close required')
    def test_failed_diagnostic_sink_does_not_change_result_or_repeat_actions(self):
        run = subprocess.run([str(self.binary), 'positive', 'on'], env={**os.environ,
            'KMSG_READ_TIMING_ENABLED': 'true'}, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, preexec_fn=lambda: os.close(2))
        self.assertEqual(run.returncode, 0)
        self.assertEqual(json.loads(run.stdout), self.rows['positive', 'reference']['result'])


if __name__ == '__main__':
    unittest.main()
