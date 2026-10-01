"""Actual resolver and score loop: skip only provably losing child searches."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def part(source, start, end):
    index = source.index(start)
    return source[index:source.index(end, index)]


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ContextBonusBoundTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.folder = Path(cls.temp.name)
        cls.sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                 check=True, capture_output=True, text=True)
            cls.sdk_args = ["-sdk", sdk.stdout.strip()]
        context = (ROOT / "Sources/kmsg/KakaoTalk/MessageContextResolver.swift").read_text()
        ui = (ROOT / "Sources/kmsg/Accessibility/UIElement.swift").read_text()
        bfs = part(ui, "    public func findAll(\n        roles:", "\n    /// Find elements by role")
        predicate = part(ui, "    public func findAll(where predicate: (UIElement) -> Bool, limit:", "\n    /// Find first descendant")
        # The pre-optimization loop is the behavioral reference. All discovery,
        # spatial scoring, bonuses, quotas and sorting come from current source.
        old_loop = """        for i in 0..<topCount {
            guard phase1[i].score > 0 else { continue }
            phase1[i].score += scoreTranscriptContainerChildBonus(phase1[i].candidate)
        }
"""
        guard_start = context.index("        // Only skip a strict loser")
        guard_end = context.index("        let scored = phase1.sorted", guard_start)
        candidate_loop = context[guard_start:guard_end]
        baseline = context[context.index("struct MessageContextResolver {"):].replace(
            "struct MessageContextResolver {", "struct BaselineMessageContextResolver {", 1)
        baseline = baseline.replace(candidate_loop, old_loop, 1)

        stub = (ROOT / "tests/fixtures/read_cost.swift").read_text().split("// BEGIN CASES")[0]
        old_predicate = part(stub, "    func findAll(where predicate:", "    func findAll(roles:")
        stub = stub.replace(old_predicate, predicate.replace("public func", "func") + "\n")
        old_bfs = part(stub, "    func findAll(roles:", "    func findAll(role:")
        stub = stub.replace(old_bfs, bfs.replace("public func", "func") + "\n")
        stub = stub.replace("    weak var parent: UIElement?", """    weak var parentValue: UIElement?
    var parent: UIElement? {
        get { probe.record("parent", id); return parentValue }
        set { parentValue = newValue }
    }""")
        stub = stub.replace("    func findAll(where predicate:", """    func roleAndChildren() -> (String?, [UIElement]) {
        probe.record("batch", id)
        return (roleValue, nodes)
    }
    func findAll(where predicate:""", 1)
        stub += """
final class AXTraversalReadScope {
    func children(atRoot root: UIElement) -> [UIElement] { root.children }
    func roleAndChildren(of element: UIElement) -> (String?, [UIElement]) { element.roleAndChildren() }
}
"""
        evidence = (ROOT / "Sources/kmsg/KakaoTalk/TranscriptReadEvidenceDiagnostics.swift").read_text()
        whole = stub + evidence + context + "\n" + baseline + (ROOT / "tests/fixtures/context_bonus_bound.swift").read_text()
        cls.whole, whole_raw = cls.compile_and_run("context", whole)

        rank = part(context, "        var phase1 = candidates.map", "\n        if let top = scored.first")
        old_rank = rank.replace(candidate_loop, old_loop, 1)
        rank = rank.replace("                continue\n", "                phase1[i].candidate.c.skipped.append(phase1[i].candidate.id)\n                continue\n", 1)
        bonus = part(context, "    private func scoreTranscriptContainerChildBonus(", "\n    private func isLikelyTranscriptRoot(")
        bonus = bonus.replace("private func", "func").replace("        let started = readCost?.mark()", "        candidate.c.bonusCalls += 1; candidate.c.called.append(candidate.id)\n        let started = readCost?.mark()", 1)
        rankers = ""
        for name, loop in [("Original", old_rank), ("Bounded", rank)]:
            rankers += "\nstruct " + name + """ {
    let readCost: TranscriptReadCost? = nil
    func scoreTranscriptContainerSpatial(_ candidate: UIElement, chatWindow: UIElement, inputElement: UIElement) -> Double { candidate.spatial }
    func select(_ candidates: [UIElement]) -> (Int?, Double?) {
        let chatWindow = candidates[0], inputElement = candidates[0]
""" + loop + """
        let winner = scored.first(where: { $0.score > 0 })
        return (winner?.candidate.id, winner?.score)
    }
""" + bonus + "\n}\n"
        ranking = (ROOT / "tests/fixtures/context_bonus_ranking.swift").read_text()
        ranking = ranking.replace("// PRODUCTION_BFS", bfs.replace("public func", "func"))
        ranking = ranking.replace("// PRODUCTION_RANKERS", rankers)
        ranking = context[:context.index("\nstruct MessageTranscriptContext")] + ranking
        cls.ranking, ranking_raw = cls.compile_and_run("ranking", ranking)
        cls.raw = whole_raw + ranking_raw

    @classmethod
    def compile_and_run(cls, name, source):
        main = cls.folder / (name + ".swift")
        binary = cls.folder / name
        main.write_text(source)
        result = subprocess.run(["swiftc", *cls.sdk_args, "-O", str(main), "-o", str(binary)],
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return json.loads(result.stdout), result.stdout

    def test_whole_production_resolver_keeps_input_pane_root_and_failure(self):
        self.assertEqual(len(self.whole), 5)
        for case in self.whole:
            with self.subTest(mode=case["mode"]):
                self.assertEqual(case["before"]["contextIdentities"], case["after"]["contextIdentities"])
                self.assertLessEqual(case["after"]["allAXQueries"], case["before"]["allAXQueries"])
        empty = next(c for c in self.whole if c["mode"] == "no-input")
        self.assertEqual(empty["after"]["contextIdentities"], [])

    def test_common_nested_bfs_is_removed_but_cache_and_empty_work_are_unchanged(self):
        cases = {c["mode"]: c for c in self.whole}
        self.assertEqual(cases["cold-nested"]["before"]["roleAndChildrenBatches"], 123)
        self.assertEqual(cases["cold-nested"]["after"]["roleAndChildrenBatches"], 42)
        for mode in ["cached", "empty-descendants", "no-input"]:
            self.assertEqual(cases[mode]["before"], cases[mode]["after"])

    def test_actual_ranking_has_same_winner_score_and_evaluated_prefix(self):
        self.assertEqual(self.ranking["generated"], 2187)
        self.assertEqual(self.ranking["generatedWinnerMismatch"], 0)
        self.assertEqual(self.ranking["generatedAXIncrease"], 0)
        self.assertGreater(self.ranking["generatedWithPruning"], 0)
        for case in self.ranking["cases"]:
            with self.subTest(case=case["case"]):
                before, after = case["before"], case["after"]
                self.assertEqual(before["winner"], after["winner"])
                self.assertEqual(before["winningScore"], after["winningScore"])
                self.assertEqual(after["calledCandidates"], before["calledCandidates"][:after["bonusCalls"]])

    def test_strict_ties_float_rounding_and_all_nonfinite_fall_back(self):
        cases = {c["case"]: c for c in self.ranking["cases"]}
        self.assertIn(2, cases["strict-bound-tie"]["after"]["calledCandidates"])
        self.assertEqual(cases["tied-winners-pruned-suffix"]["after"]["winner"], 1)
        self.assertEqual(cases["tied-winner-follows-spatial-order"]["after"]["winner"], 2)
        for label in ["nan-no-prune", "infinity-no-prune", "negative-infinity-no-prune",
                      "fourth-nan-no-prune", "fourth-negative-infinity-no-prune"]:
            self.assertEqual(cases[label]["before"], cases[label]["after"])

    def test_dynamic_render_can_change_time_without_claiming_snapshot_equivalence(self):
        case = next(c for c in self.ranking["cases"] if c["case"] == "render-timing-not-snapshot-equivalence")
        self.assertEqual(case["before"]["winner"], case["after"]["winner"])
        self.assertNotEqual(case["before"]["renderEpoch"], case["after"]["renderEpoch"])
        self.assertFalse(case["wholeTranscriptSnapshotEquivalenceClaimed"])

    def test_no_customer_text_enters_numeric_results(self):
        self.assertNotIn("CUSTOMER_SECRET_SENTINEL", self.raw)


if __name__ == "__main__":
    unittest.main()
