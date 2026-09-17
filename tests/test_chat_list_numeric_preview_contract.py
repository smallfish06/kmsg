import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCANNER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatListScanner.swift"


class ChatListNumericPreviewContractTests(unittest.TestCase):
    """A digit-only last message must come back as the row's preview.

    2026-09-17 (talkfriend): a room whose last message was "123456" scanned as
    `last_message: "오후 6:06"` — the row's TIMESTAMP. previewCandidate rejected
    every digits-only value as an unread badge, the AXTextArea holding the real
    preview fell through, and the AXStaticText fallback then accepted the clock
    cell because isTimeLikeValue only knows bare "11:47", not "오후 6:06".

    talkfriend's connect code is exactly that shape (six digits), so the bridge
    could never have seen one. Measured row layout on a live client:

        AXRow > AXCell >
          AXButton
          AXStaticText            title
          AXStaticText id="Count Label"   unread badge (only when unread)
          AXStaticText            timestamp ("오후 6:09")
          AXScrollArea > AXTextArea       preview

    The preview is always the AXTextArea; the badge is always a static text.
    """

    def setUp(self) -> None:
        self.source = SCANNER.read_text(encoding="utf-8")

    def _body(self, start: str, end: str) -> str:
        return self.source.split(start, 1)[1].split(end, 1)[0]

    def test_text_area_previews_skip_the_badge_and_clock_filters(self) -> None:
        body = self._body("private func previewCandidate(", "private func normalizedText(")
        guard = body.index("if !fromTextArea {")
        count_like = body.index("ChatTextNormalizer.isUnreadCountLike(value)")
        self.assertLess(guard, count_like)
        # The count-like rejection must live INSIDE the static-text-only branch.
        branch_end = body.index("}", count_like)
        self.assertLess(count_like, branch_end)

    def test_extract_preview_marks_which_loop_a_node_came_from(self) -> None:
        body = self._body("private func extractPreview(", "/// The unread badge is a bare AXStaticText")
        area = body.index("node.role == kAXTextAreaRole")
        static = body.index("node.role == kAXStaticTextRole")
        self.assertLess(area, static)
        self.assertIn("fromTextArea: true", body[area:static])
        self.assertIn("fromTextArea: false", body[static:])

    def test_static_text_fallback_rejects_the_full_clock_format(self) -> None:
        body = self._body("private func previewCandidate(", "private func normalizedText(")
        self.assertIn("ChatTextNormalizer.isClockLikeValue(value)", body)

    def test_unread_still_reads_only_static_text(self) -> None:
        # A numeric preview must never be mistaken for the unread count.
        body = self._body("private func extractUnread(", "private func titleCandidate(")
        self.assertIn("node.role == kAXStaticTextRole", body)
        self.assertNotIn("kAXTextAreaRole", body)


if __name__ == "__main__":
    unittest.main()
