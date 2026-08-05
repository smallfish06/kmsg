import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TRANSCRIPT_READER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptReader.swift"


class BubbleStatusAuthorContractTests(unittest.TestCase):
    """A bubble's status label is not a sender name.

    `parseRowMetadata` takes the first metadata token that is not a time, count,
    system, or attachment token as the row's author. KakaoTalk exposes labels
    like "수정됨" as their own AXStaticText inside the row, so on a bubble with
    no name label of its own — every message after the first in a run by the
    same person — the label became the author. A peer editing one message made
    read/watch emit `"author":"수정됨"`, and a consumer that trusts author as the
    freshly-read peer name overwrote a stored chat title with it (talkfriend,
    2026-08-06)."""

    def setUp(self) -> None:
        self.source = TRANSCRIPT_READER.read_text(encoding="utf-8")

    def test_bubble_status_filter_runs_before_the_author_is_taken(self) -> None:
        self.assertIn("private func isLikelyBubbleStatusToken(_ token: String) -> Bool", self.source)

        body = self.source.split("private func parseRowMetadata", 1)[1].split(
            "private func", 1
        )[0]
        # The guard must sit in the skip chain, above `if author == nil`.
        self.assertIn("|| isLikelyBubbleStatusToken(token)", body)
        skip_at = body.index("isLikelyBubbleStatusToken(token)")
        author_at = body.index("if author == nil")
        self.assertLess(skip_at, author_at)

    def test_known_status_labels_are_covered(self) -> None:
        labels = self.source.split("bubbleStatusLabels: Set<String> = [", 1)[1].split("]", 1)[0]

        for label in ("수정됨", "삭제된 메시지", "삭제된 메시지입니다", "안읽음", "읽지 않음"):
            self.assertIn(f'"{label}"', labels)
        # English UI carries the same labels.
        for label in ("edited", "deleted message", "unread"):
            self.assertIn(f'"{label}"', labels)

    def test_matching_is_case_insensitive(self) -> None:
        body = self.source.split("private func isLikelyBubbleStatusToken", 1)[1].split(
            "private static let", 1
        )[0]

        self.assertIn("trimmed.lowercased()", body)

    def test_dropping_the_label_falls_through_to_the_left_anchor(self) -> None:
        """Emptying the author is only safe because the anchor chain refills it.

        A bubble with no name label belongs to whoever owns the current run, so
        `resolveAuthorInSegment` must still hand back `leftAnchorAuthor` when the
        explicit author is absent."""
        body = self.source.split("private func resolveAuthorInSegment", 1)[1].split(
            "private func", 1
        )[0]

        self.assertIn("guard let anchorAuthor = leftAnchorAuthor else", body)
        self.assertIn('return (anchorAuthor, "left-chain")', body)


if __name__ == "__main__":
    unittest.main()
