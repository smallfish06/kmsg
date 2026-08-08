import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
REGISTRY = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatIdentityRegistry.swift"


class ChatIdentityFlapContractTests(unittest.TestCase):
    """One room must never flap between two registry records.

    A scan that captures the same row twice (list reorder animation; observed
    2026-08-05 during the 석천 re-connect) leaves a second record for the same
    normalized name. The registry then holds two identities for one room, and
    the positional zip in assignChatIDs re-picked a winner on every preview
    change — the chat id ping-ponged between base and `_2`, the server swapped
    addresses to follow, and every dedup layer keyed on the chat id reset,
    double-ingesting the same inbound message (talkfriend, 2026-08-08: the
    phantom "방금 보냈는데 못 봤나" reply). Recency-first matching pins the id to
    the record that won the previous scan; the loser's lastSeenAt freezes and
    the stale sweep removes it."""

    def setUp(self) -> None:
        self.source = REGISTRY.read_text(encoding="utf-8")
        self.assign_body = self.source.split("func assignChatIDs", 1)[1].split("func record(", 1)[0]

    def test_zip_prefers_the_most_recently_matched_record(self) -> None:
        zip_block = self.assign_body.split("let sortedRemainingRecords", 1)[1].split("let zippedCount", 1)[0]

        self.assertIn("lastSeenAt > records[rhs].lastSeenAt", zip_block)
        # Position stays only as the tiebreak for records seen in the same scan
        # (real same-name rooms) — it must come after the recency comparison.
        self.assertLess(
            zip_block.index("lastSeenAt > records[rhs].lastSeenAt"),
            zip_block.index("lastSeenIndex ?? .max"),
        )

    def test_preview_tied_candidates_also_prefer_recency(self) -> None:
        candidates_block = self.assign_body.split("var unmatchedRecords", 1)[1].split("for currentIndex", 1)[0]

        self.assertIn("lastSeenAt > records[rhs].lastSeenAt", candidates_block)

    def test_stale_records_are_swept_before_persisting(self) -> None:
        self.assertIn("staleRecordTTL", self.assign_body)
        self.assertIn("records.removeAll { $0.lastSeenAt < staleCutoff }", self.assign_body)
        # The sweep must run after matching (new records carry lastSeenAt=now and
        # survive) and before the document is persisted.
        self.assertLess(
            self.assign_body.index("records.removeAll"),
            self.assign_body.index("document.records = records"),
        )
        self.assertIn("static let staleRecordTTL: TimeInterval = 30 * 24 * 60 * 60", self.source)


if __name__ == "__main__":
    unittest.main()
