"""Exercise the production read timing wrapper without touching KakaoTalk."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ReadTimingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        source = (ROOT / "Sources/kmsg/Commands/ReadCommand.swift").read_text()
        start = source.index('            snapshot = try profiler.phase("read") {')
        end = source.index('            profiler.note("rows"', start)
        wrapper = source[start:end]
        main = folder / "main.swift"
        main.write_text(r'''
import Foundation
enum ProbeError: Error { case expected }
struct Resolution { let effectiveChatTitle: String? = nil; let chatTitle: String? = nil }
struct Reader {
    func readSnapshot(from: Int, fallbackChatTitle: String, limit: Int,
                      chatTitleOverride: String?, readPhase: ((String) -> Void)?) throws -> String {
        for step in ["context", "collect", "parse"] {
            readPhase?(step)
            Thread.sleep(forTimeInterval: 0.02)
        }
        if CommandLine.arguments.contains("fail") { throw ProbeError.expected }
        return "unchanged payload"
    }
}
let profiler = PhaseProfiler(command: "read")
let transcriptReader = Reader(), resolution = Resolution()
let window = 0, limit = 50, requestedChat = "fixture"
var snapshot = ""
do {
''' + wrapper + r'''
    print(snapshot)
    profiler.emitSummary(status: "ok")
} catch {
    print("same read failure")
    profiler.emitSummary(status: "fail")
}
''')
        sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                 check=True, capture_output=True, text=True)
            sdk_args = ["-sdk", sdk.stdout.strip()]
        cls.binary = folder / "read-timing-check"
        build = subprocess.run([
            "swiftc", *sdk_args,
            str(ROOT / "Sources/kmsg/Accessibility/PhaseProfiler.swift"),
            str(main), "-o", str(cls.binary),
        ], capture_output=True, text=True)
        if build.returncode:
            raise RuntimeError(build.stdout + build.stderr)

    def invoke(self, flag, mode="ok"):
        env = os.environ.copy()
        env.pop("KMSG_READ_TIMING_ENABLED", None)
        if flag is not None:
            env["KMSG_READ_TIMING_ENABLED"] = flag
        return subprocess.run([str(self.binary), mode], env=env, check=True,
                              capture_output=True, text=True)

    def test_default_and_disabled_preserve_output_and_outer_timing(self):
        for flag in [None, "false", ""]:
            with self.subTest(flag=flag):
                result = self.invoke(flag)
                self.assertEqual(result.stdout, "unchanged payload\n")
                self.assertNotIn("read-detail", result.stderr)
                self.assertRegex(result.stderr, r"\[kmsg\] read total=[0-9.]+ status=ok read=[0-9.]+")

    def test_enabled_details_keep_payload_and_outer_slice(self):
        result = self.invoke("true")
        self.assertEqual(result.stdout, "unchanged payload\n")
        self.assertIn("[kmsg] read phase=read start", result.stderr)
        for step in ["context", "collect", "parse"]:
            self.assertIn(f"[kmsg] read-detail step={step} start", result.stderr)
        self.assertNotIn("read-detail phase=", result.stderr)
        summary = next(line for line in result.stderr.splitlines() if line.startswith("[kmsg] read-detail total="))
        fields = dict(re.findall(r"(\w+)=([0-9.]+)", summary))
        self.assertIn("status=ok", summary)
        self.assertAlmostEqual(float(fields["total"]), sum(float(fields[p]) for p in ["context", "collect", "parse"]), delta=0.03)
        self.assertRegex(result.stderr, r"\[kmsg\] read total=[0-9.]+ status=ok read=[0-9.]+")

    def test_failure_remains_failure_with_one_detail_summary(self):
        disabled = self.invoke("false", "fail")
        enabled = self.invoke("true", "fail")
        self.assertEqual(enabled.stdout, disabled.stdout)
        self.assertEqual(enabled.stdout, "same read failure\n")
        self.assertEqual(enabled.stderr.count("[kmsg] read-detail total="), 1)
        self.assertRegex(enabled.stderr, r"\[kmsg\] read-detail total=[0-9.]+ status=fail")
        self.assertRegex(enabled.stderr, r"\[kmsg\] read total=[0-9.]+ status=fail")


if __name__ == "__main__":
    unittest.main()
