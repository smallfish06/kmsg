import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TRANSCRIPT_READER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptReader.swift"
READ_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ReadCommand.swift"


class ReadTimeInheritanceContractTests(unittest.TestCase):
    """An unlabelled bubble's minute lives on a LATER row, not an earlier one.

    KakaoTalk prints the time label only on the last bubble of a same-minute,
    same-sender run. `parseMessages` used to fill a missing time from the
    previous row (`lastTimeBySide` / `lastKnownTime`), so the leading bubbles
    of a burst were stamped with the previous run's minute — right after we
    replied, that is our own reply's minute. talkfriend measured it over
    2026-08-14~21: of 549 inbound rows that looked ">5 min late", 66% carried
    exactly the minute of our last outbox send, and the same bubble received
    two different minutes across two reads (정희 "씻고 왔어?" 17:54 / 17:55),
    which defeats the server's (conversation, body, spoken-minute) replay
    dedup and produced a second reply 61 minutes later.

    The contract: a bottom-up pass hands each unlabelled row the time of the
    next labelled row on the same side ("group-tail") before any backward
    guess is consulted, every row reports how its time was decided
    (`time_source`), and the read summary counts the rows that are still a
    backward guess so the bridge can distrust them without --trace-ax."""

    def setUp(self) -> None:
        self.reader_source = TRANSCRIPT_READER.read_text(encoding="utf-8")
        self.read_command_source = READ_COMMAND.read_text(encoding="utf-8")

    def parse_body(self) -> str:
        return self.reader_source.split("private func parseMessages", 1)[1].split(
            "private func resolveGroupTailTimes", 1
        )[0]

    def tail_pass_body(self) -> str:
        return self.reader_source.split("private func resolveGroupTailTimes", 1)[1].split(
            "private func", 1
        )[0]

    def test_group_tail_wins_over_backward_guess(self) -> None:
        body = self.parse_body()
        explicit_at = body.index('timeSource = "explicit"')
        tail_at = body.index('timeSource = "group-tail"')
        prev_side_at = body.index('timeSource = "prev-side"')
        prev_any_at = body.index('timeSource = "prev-any"')
        self.assertLess(explicit_at, tail_at)
        self.assertLess(tail_at, prev_side_at)
        self.assertLess(prev_side_at, prev_any_at)
        # The tail pass must run over the full analysed window before the
        # per-row loop consumes it — it looks at rows that come LATER.
        self.assertIn("let groupTailTimes = resolveGroupTailTimes(analyses)", body)
        self.assertIn("groupTailTimes[offset]", body)

    def test_tail_pass_walks_bottom_up_and_respects_run_boundaries(self) -> None:
        body = self.tail_pass_body()
        self.assertIn("stride(from: analyses.count - 1, through: 0, by: -1)", body)
        # A date separator / system row ends every run.
        self.assertIn("carry.removeAll()", body)
        # A labelled row of one side ends the other side's run: the bubble
        # before a sender change is always labelled, so an unlabelled bubble
        # above it is a missed label, not a continuation.
        self.assertIn("carry[side == .left ? .right : .left] = nil", body)
        # Unknown-side rows neither carry nor break a run.
        self.assertIn("guard side != .unknown else { continue }", body)

    def test_time_source_rides_every_encoded_row(self) -> None:
        self.assertIn('case timeSource = "time_source"', self.reader_source)
        self.assertIn(
            "try container.encodeIfPresent(timeSource, forKey: .timeSource)",
            self.reader_source,
        )
        # --capture-images rebuilds messages; the verdict must survive the copy.
        capture_body = self.reader_source.split("func withCapturedImages", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("timeSource: timeSource", capture_body)

    def test_summary_line_counts_backward_guesses(self) -> None:
        self.assertIn('"timeguess"', self.read_command_source)
        self.assertIn('$0.timeSource == "prev-side" || $0.timeSource == "prev-any"', self.read_command_source)


class ReadAuthorAnchorAtWindowEdgeContractTests(unittest.TestCase):
    """The other party's name label anchors a run even when its row has no frame.

    Consecutive bubbles from the same sender carry the name only on the first
    one. Rows above the rendered viewport come back with static text but no
    AX frame (`side == .unknown`), and `parseMessages` (a) only set the left
    anchor when `side == .left`, and (b) reset the anchor on every non-left
    row — so a burst whose first bubble sat above the viewport lost its name
    and the rest shipped as "left-unresolved". The contract: a labelled
    non-system row anchors the run unless it is ours (`.right`), and only a
    `.right` row or a system row clears the anchor."""

    def setUp(self) -> None:
        reader_source = TRANSCRIPT_READER.read_text(encoding="utf-8")
        self.parse_body = reader_source.split("private func parseMessages", 1)[1].split(
            "private func resolveGroupTailTimes", 1
        )[0]

    def test_unknown_side_does_not_reset_the_anchor(self) -> None:
        self.assertIn("if side == .right || analysis.isSystemLikeRow {", self.parse_body)
        self.assertNotIn("if side != .left || analysis.isSystemLikeRow {", self.parse_body)

    def test_labelled_unknown_side_row_anchors_the_run(self) -> None:
        anchor_block = self.parse_body.split("let explicitAuthor = analysis.explicitAuthor,", 1)[0]
        self.assertTrue(anchor_block.rstrip().endswith("if side != .right,"), anchor_block[-120:])


if __name__ == "__main__":
    unittest.main()
