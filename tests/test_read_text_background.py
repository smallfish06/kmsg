"""Execute production row extraction, alignment and author resolution on AX trees.

Only UIElement's OS boundary and logging are replaced. Geometry reproduces the
Sep 30 two false photos; synthetic bodies keep customer content out of fixtures.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / 'Sources/kmsg/KakaoTalk/TranscriptReader.swift'
FIXTURE = ROOT / 'tests/fixtures/read_text_background.swift'


def production_harness(source=None):
    source = source or READER.read_text()
    messages = source[source.index('struct TranscriptMessage:'):source.index('struct TranscriptSnapshot:')]
    parser = source[source.index('    private func parseMessages('):source.index('\nfunc messageFingerprint(')]
    tail = source[source.index('\nfunc messageFingerprint('):]
    adapter, cases = FIXTURE.read_text().split('// BEGIN CASES', 1)
    return (adapter + messages + '\nstruct Parser {\n let runner = Runner()\n' + parser + tail + cases).replace('private ', '')


@unittest.skipIf(shutil.which('swiftc') is None, 'swiftc not available')
class ReadTextBackgroundTests(unittest.TestCase):
    def test_production_extraction_and_attribution(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / 'main.swift'
            main.write_text(production_harness())
            binary = Path(tmp) / 'check'
            args = []
            if sys.platform == 'darwin' and not os.environ.get('SDKROOT'):
                sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True)
                if sdk.returncode == 0:
                    args = ['-sdk', sdk.stdout.strip()]
            helpers = [ROOT / f'Sources/kmsg/KakaoTalk/{name}.swift' for name in ['TranscriptAuthorEvidence', 'TranscriptRightEdgeAlignment']]
            build = subprocess.run(['swiftc', *args, *map(str, helpers), str(main), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('OK:', run.stdout)
