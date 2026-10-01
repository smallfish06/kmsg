"""Exercise pure source reconciliation and the actual parser on in-memory AX trees.

No Accessibility calls, Kakao UI interaction, or messages are sent by these tests.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "Sources/kmsg/KakaoTalk"
READER = NATIVE / "TranscriptReader.swift"
HELPER = NATIVE / "TranscriptNativeObservation.swift"


def swift_run(program, helpers):
    with tempfile.TemporaryDirectory() as tmp:
        main = Path(tmp) / "main.swift"
        main.write_text(program)
        binary = Path(tmp) / "observation-check"
        sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True, check=True)
            sdk_args = ["-sdk", sdk.stdout.strip()]
        compiled = subprocess.run(["swiftc", *sdk_args, *map(str, helpers), str(main), "-o", str(binary)], capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stdout + compiled.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


def production_harness(source):
    adapter = (ROOT / "tests/fixtures/read_text_background.swift").read_text().split("// BEGIN CASES")[0]
    messages = source[source.index("struct TranscriptMessage:"):source.index("struct TranscriptSnapshot:")]
    parser = source[source.index("    private func extractMessages("):source.index("\nfunc messageFingerprint(")]
    tail = source[source.index("\nfunc messageFingerprint("):]
    return (adapter + messages + "\nstruct Parser {\n let runner = Runner()\n" + parser + tail).replace("private ", "")


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class NativeObservationTests(unittest.TestCase):
    def test_pure_observation_reconciliation(self):
        output = swift_run((ROOT / "tests/fixtures/native_observation_policy.swift").read_text(), [HELPER])
        self.assertIn("OK:", output)

    def test_production_extraction_and_default_off(self):
        harness = production_harness(READER.read_text())
        fixture = (ROOT / "tests/fixtures/native_observation_parser.swift").read_text()
        helpers = [NATIVE / f"{name}.swift" for name in ["TranscriptAuthorEvidence", "TranscriptRightEdgeAlignment", "TranscriptAttributionRecovery", "TranscriptNativeObservation"]]
        output = swift_run(harness + fixture, helpers)
        self.assertIn("OK:", output)
