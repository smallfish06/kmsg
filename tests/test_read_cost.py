"""Production context/collection methods with fake AX: numeric diagnostics only."""
import json
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
class ReadCostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        fixture = (ROOT / "tests/fixtures/read_cost.swift").read_text()
        stub, cases = fixture.split("// BEGIN CASES")
        source = (ROOT / "Sources/kmsg/KakaoTalk/TranscriptReader.swift").read_text()
        def part(start, end):
            return source[source.index(start):source.index(end, source.index(start))]
        methods = part("    private func collectTranscriptRows(", "\n    private func extractMessages(")
        methods += part("    private func directRowChildren(", "\n    private func analyzeRow(")
        methods += part("    private func deduplicateElements(", "\n    private func sortElementsByReadingOrder(")
        outer = part("    func readSnapshot(\n        from window:", "    func readSnapshot(\n        from context:")
        window_reader = r'''
struct TranscriptSnapshot {}
enum TranscriptReadError: Error { case transcriptContextUnavailable }
enum FixtureReadError: Error { case expectedCollectionFailure }
struct WindowCostReader {
    let kakao: KakaoTalkApp
    let runner: AXActionRunner
    let interactionMode: ChatWindowInteractionMode
    let failAfterContext: Bool
''' + outer + r'''
    func readSnapshot(from: MessageTranscriptContext, chatWindow: UIElement,
        fallbackChatTitle: String, limit: Int, includeSystemMessages: Bool,
        referenceDate: Date, chatTitleOverride: String?, readPhase: ((String) -> Void)?,
        readCost: TranscriptReadCost?) throws -> TranscriptSnapshot {
        readCost?.add(.collectCalls)
        if failAfterContext { throw FixtureReadError.expectedCollectionFailure }
        return TranscriptSnapshot()
    }
}
'''
        context = (ROOT / "Sources/kmsg/KakaoTalk/MessageContextResolver.swift").read_text()
        main = folder / "main.swift"
        main.write_text(stub + context + "\nstruct CostCollector { let runner = AXActionRunner()\n" + methods.replace("private ", "") + "\n}\n" + window_reader + cases)
        sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], check=True, capture_output=True, text=True)
            sdk_args = ["-sdk", sdk.stdout.strip()]
        binary = folder / "read-cost-check"
        evidence = ROOT / "Sources/kmsg/KakaoTalk/TranscriptReadEvidenceDiagnostics.swift"
        compiled = subprocess.run(["swiftc", *sdk_args, str(evidence), str(main), "-o", str(binary)], capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stdout + compiled.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        cls.data = json.loads(result.stdout)
        cls.raw = result.stdout

    def test_actual_context_and_collection_preserve_ax_call_order_and_results(self):
        self.assertEqual(len(self.data["cases"]), 12)
        self.assertTrue(all(c["sameResult"] and c["sameAXCallsAndOrder"] for c in self.data["cases"]))
        self.assertTrue(all(c["offClockCalls"] == 0 for c in self.data["cases"]))

    def test_numeric_fixed_schema_has_no_customer_or_ax_text(self):
        self.assertNotIn("CUSTOMER_SECRET_SENTINEL", self.raw)
        for case in self.data["cases"]:
            self.assertEqual(set(case["notes"]), {"costctx", "costcol", "costwalk"})
            for key, expected in [("costctx", 16), ("costcol", 14), ("costwalk", 5)]:
                value = case["notes"][key]
                self.assertRegex(value, r"^1(?:/\d{1,5})+$")
                self.assertEqual(len(value.split("/")), expected)

    def test_collection_counts_are_actual_rows_and_passes(self):
        cases = {c["mode"]: c for c in self.data["cases"] if c["kind"] == "collection"}
        values = list(map(int, cases["shallow"]["notes"]["costcol"].split("/")))
        self.assertEqual(values[7:], [1, 301, 0, 300, 300, 300, 80])
        fallback = list(map(int, cases["fallback"]["notes"]["costcol"].split("/")))
        self.assertEqual(fallback[9], 1)
        empty = list(map(int, cases["empty"]["notes"]["costcol"].split("/")))
        self.assertEqual(empty[9], 3)
        self.assertEqual(empty[10:], [0, 0, 0, 0])

    def test_walk_faults_are_observed_without_changing_collection_policy(self):
        cases = {c["mode"]: c for c in self.data["cases"] if c["kind"] == "collection"}
        expected = {
            "shallow": [0, 0, 0, 0], "empty": [0, 0, 0, 0],
            "fallback": [0, 0, 0, 1], "role-failure": [300, 0, 0, 0],
            "partial-role-failure": [150, 0, 0, 0], "children-failure": [0, 1, 0, 0],
            "depth": [0, 0, 1, 0], "target-at-depth": [0, 0, 0, 0],
        }
        for name, counters in expected.items():
            with self.subTest(name=name):
                self.assertEqual(list(map(int, cases[name]["notes"]["costwalk"].split("/"))), [1] + counters)
        # A partial unknown-role shallow pass still follows the old policy:
        # some rows are enough to avoid fallback. These counters do not repair it.
        partial = list(map(int, cases["partial-role-failure"]["notes"]["costcol"].split("/")))
        self.assertEqual(partial[9:11], [0, 150])

    def test_actual_window_wrapper_emits_costs_on_context_and_collection_failure(self):
        cases = self.data["windowCases"]
        self.assertEqual(len(cases), 3)
        for case in cases:
            self.assertTrue(case["sameAXCallsAndOrder"])
            self.assertEqual(set(case["notes"]), {"costctx", "costcol", "costwalk"})
            self.assertEqual(case["offClockCalls"], 0)
            self.assertEqual(case["failed"], case["mode"] != "ok")

    def test_saturation_is_explicit_and_detail_line_fits_forwarding_budget(self):
        notes = self.data["cappedNotes"]
        self.assertEqual(notes["costclip"], "1")
        phases = ["context", "collect", "parse", "sparse.wait", "sparse.probe", "sparse.collect", "sparse.parse", "attribution", "attr.wait", "attr.collect", "attr.parse", "fallback", "finalize"]
        # Every supported step at the 60s bridge read timeout is a deliberately
        # conservative shape; real sequential steps cannot all consume it.
        summary = "[kmsg] read-detail total=60.00 status=fail "
        summary += " ".join(f"{key}=60.00" for key in phases)
        summary += " " + " ".join(f"{key}={value}" for key, value in notes.items())
        self.assertLessEqual(len(summary), 500)


if __name__ == "__main__":
    unittest.main()
