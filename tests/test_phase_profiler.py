import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PhaseProfilerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        main = folder / "main.swift"
        main.write_text('''
import Foundation

enum ProbeError: Error { case expected }
func run(_ fail: Bool) throws {
    let profiler = PhaseProfiler(command: "send-image", phaseMarkerKey: "step")
    var failed = true
    defer {
        profiler.begin("cleanup")
        Thread.sleep(forTimeInterval: 0.02)
        profiler.emitSummary(status: failed ? "fail" : "ok")
        profiler.emitSummary(status: "duplicate")
    }
    profiler.begin("auth")
    Thread.sleep(forTimeInterval: 0.02)
    try profiler.phase("click") {
        Thread.sleep(forTimeInterval: 0.02)
        if fail { throw ProbeError.expected }
    }
    failed = false
}
do { try run(CommandLine.arguments.contains("fail")) } catch {}
let text = PhaseProfiler(command: "send")
text.begin("auth")
text.emitSummary(status: "ok")
''', encoding="utf-8")
        cls.binary = folder / "profiler-test"
        # setup-swift's standalone toolchain does not discover the macOS SDK
        # automatically, unlike Xcode's swiftc used by local development.
        sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                 check=True, capture_output=True, text=True)
            sdk_args = ["-sdk", sdk.stdout.strip()]
        build = subprocess.run([
            "swiftc", *sdk_args, str(ROOT / "Sources/kmsg/Accessibility/PhaseProfiler.swift"),
            str(main), "-o", str(cls.binary),
        ], capture_output=True, text=True)
        if build.returncode:
            raise RuntimeError(f"Profiler harness compilation failed:\n{build.stdout}{build.stderr}")

    def test_success_and_failure_keep_cleanup_and_emit_one_summary(self):
        for mode, status in [("ok", "ok"), ("fail", "fail")]:
            with self.subTest(mode=mode):
                result = subprocess.run([str(self.binary), mode], check=True,
                                        capture_output=True, text=True)
                self.assertEqual(result.stdout, "")
                lines = result.stderr.splitlines()
                summaries = [s for s in lines if s.startswith("[kmsg] send-image total=")]
                self.assertEqual(len(summaries), 1)
                self.assertIn(f"status={status}", summaries[0])
                fields = dict(re.findall(r"(\w+)=([0-9.]+)", summaries[0]))
                parts = [float(fields[name]) for name in ["auth", "click", "cleanup"]]
                self.assertTrue(all(value >= 0.01 for value in parts))
                self.assertAlmostEqual(float(fields["total"]), sum(parts), delta=0.03)
                self.assertTrue(any("send-image step=cleanup start" in line for line in lines))

    def test_image_marks_do_not_enable_text_pre_dispatch_retry_rules(self):
        result = subprocess.run([str(self.binary), "fail"], check=True,
                                capture_output=True, text=True)
        self.assertIn("[kmsg] send-image step=auth start", result.stderr)
        self.assertNotRegex(result.stderr, r"\[kmsg\] send-image phase=\w+ start")
        self.assertIn("[kmsg] send phase=auth start", result.stderr)


if __name__ == "__main__":
    unittest.main()
