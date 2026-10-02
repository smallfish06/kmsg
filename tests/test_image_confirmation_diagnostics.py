"""Execute the numeric image confirmation formatter; no app/GUI access."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import swiftc_command

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Sources/kmsg/KakaoTalk/ImageConfirmationDiagnostics.swift'


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc unavailable')
class ImageConfirmationDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix='image-confirmation-diagnostics-') as tmp:
            source = Path(tmp) / 'main.swift'
            binary = Path(tmp) / 'fixture'
            source.write_text(SOURCE.read_text() + r'''
var ticks: UInt64 = 0, calls = 0
func now() -> UInt64 { calls += 1; return ticks }
let disabled = ImageConfirmationDiagnostics.make(enabled:false,now:now)
let disabledCalls = calls
let d = ImageConfirmationDiagnostics.make(enabled:true,now:now)!
let one = d.beginLookup()
d.directUnknown += 1; d.fallbackWalks += 1; d.fallbackVisits += 1000
d.fallbackBatchReads=1000;d.fallbackRoleScalarReads=7;d.fallbackChildrenScalarReads=29
ticks = 10_010_000_000; d.endLookup(one)
let two = d.beginContains()
d.containsVisits += 1000
ticks = 15_015_000_000; d.endContains(two)
let ordinary = d.line()
d.lookups = Int.max; d.fallbackVisits = -1; d.containsVisits = Int.max
d.fallbackBatchReads=Int.max;d.fallbackRoleScalarReads = -1;d.fallbackChildrenScalarReads=Int.max
ticks = 172_800_000_000_000
let clipped = d.line()
let backwards = ImageConfirmationDiagnostics(now:now)
let start = backwards.beginLookup();ticks=0;backwards.endLookup(start)
let output:[String:Any] = ["disabled":disabled == nil,"disabledClockCalls":disabledCalls,
                          "ordinary":ordinary,"clipped":clipped,"backwards":backwards.line()]
print(String(data:try! JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
''')
            build = subprocess.run([*swiftc_command(), str(source), '-o', str(binary)], text=True, capture_output=True)
            if build.returncode:
                raise AssertionError(build.stderr)
            run = subprocess.run([str(binary)], check=True, text=True, capture_output=True)
            cls.output = json.loads(run.stdout)

    def fields(self, name):
        return dict(token.split('=', 1) for token in self.output[name].split()[2:])

    def test_disabled_has_no_clock_work(self):
        self.assertTrue(self.output['disabled'])
        self.assertEqual(self.output['disabledClockCalls'], 0)

    def test_nested_durations_are_separate(self):
        fields = self.fields('ordinary')
        self.assertEqual(fields['total'], '15.015')
        self.assertEqual(fields['lookup'], '10.010')
        self.assertEqual(fields['containment'], '5.005')
        self.assertEqual(fields['unknown'], '1')
        self.assertEqual(fields['visits'], '1000')
        self.assertEqual(fields['cfound'], '0')
        self.assertEqual(fields['schema'], '2')
        self.assertEqual([fields[k] for k in ['batch','rfallback','cfallback']], ['1000','7','29'])
        self.assertEqual(fields['clip'], '0')

    def test_counts_and_times_saturate_with_visible_clip(self):
        fields = self.fields('clipped')
        self.assertEqual(fields['lookups'], '999999')
        self.assertEqual(fields['visits'], '0')
        self.assertEqual(fields['cvisits'], '999999')
        self.assertEqual(fields['total'], '86400.000')
        self.assertEqual(fields['clip'], '1')
        self.assertEqual([fields[k] for k in ['batch','rfallback','cfallback']], ['999999','0','999999'])

    def test_clock_rollback_cannot_underflow(self):
        fields = self.fields('backwards')
        self.assertEqual(fields['lookup'], '0.000')
        self.assertEqual(fields['total'], '0.000')

    def test_closed_numeric_schema_fits_compact_log_line(self):
        expected = {'total', 'status', 'schema', 'lookups', 'direct', 'empty', 'unknown',
                    'walks', 'visits', 'roles', 'found', 'contains', 'cvisits', 'cfound',
                    'lookup', 'containment', 'clip', 'batch', 'rfallback', 'cfallback'}
        for name in ['ordinary', 'clipped', 'backwards']:
            self.assertLess(len(self.output[name].encode()), 500)
            self.assertTrue(self.output[name].isascii())
            fields = self.fields(name)
            self.assertEqual(set(fields), expected)
            self.assertEqual(fields.pop('status'), 'done')
            for value in fields.values():
                self.assertRegex(value, r'^[0-9]+(?:\.[0-9]{3})?$')


if __name__ == '__main__':
    unittest.main()
