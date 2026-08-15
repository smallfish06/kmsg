import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatWindowResolver.swift"


class ChatListRowOpenLadderContractTests(unittest.TestCase):
    """Opening a matched chat-list row must be a confirm-as-you-go ladder, not one AXPress.

    2026-08-16 (talkfriend bridge Mac): list rows answered AXPress as supported but
    only *selected* the row. The resolver then waited the full title timeout,
    logged WRONG_WINDOW and fell back to name search — 46% of read/send took that
    detour (+3~5s), and symbol-only titles ('.', '☆・・・・・☆'), which the search
    field cannot take, failed 100%: three reply attempts died on one room.

    The search-result path already climbs activate → confirm → select → Enter with
    a short wait between rungs; the row path must do the same, and it must record
    which rung opened the window (`res.open`) because the bridge cannot see
    runner.log."""

    def setUp(self) -> None:
        self.source = RESOLVER.read_text(encoding="utf-8")

    def _body(self, start: str, end: str) -> str:
        return self.source.split(start, 1)[1].split(end, 1)[0]

    def test_row_open_confirms_after_press_before_giving_up(self) -> None:
        body = self._body("private func triggerChatListRowOpen(", "private func standardizeReadableWindow")
        self.assertIn("tryActivateSearchResult(row", body)
        press_index = body.index("tryActivateSearchResult(row")
        confirm_index = body.index("chat list row open confirm (press)")
        self.assertLess(press_index, confirm_index)
        # AXPress that did not open a window must NOT end the ladder.
        press_branch = body[press_index:confirm_index]
        self.assertNotIn("return true", press_branch)

    def test_row_open_falls_through_to_select_and_enter(self) -> None:
        body = self._body("private func triggerChatListRowOpen(", "private func standardizeReadableWindow")
        self.assertIn("trySelectSearchResult(row", body)
        self.assertIn("runner.pressEnterKey()", body)
        self.assertIn("chat list row open confirm (enter)", body)

    def test_enter_targets_the_raised_list_window(self) -> None:
        body = self._body("private func triggerChatListRowOpen(", "private func standardizeReadableWindow")
        raise_index = body.index("tryRaiseWindow(chatListWindow)")
        enter_index = body.index("runner.pressEnterKey()")
        self.assertLess(raise_index, enter_index)

    def test_no_double_click_on_list_rows(self) -> None:
        body = self._body("private func triggerChatListRowOpen(", "private func standardizeReadableWindow")
        self.assertNotIn("mouseDoubleClick", body)

    def test_which_rung_opened_is_recorded(self) -> None:
        body = self._body("private func triggerChatListRowOpen(", "private func standardizeReadableWindow")
        self.assertIn('note("res.open", "press")', body)
        self.assertIn('note("res.open", "enter")', body)

    def test_open_matched_row_passes_the_opened_probe(self) -> None:
        body = self._body("private func openMatchedRow(", "private func triggerChatListRowOpen(")
        self.assertIn("resolveOpenedChatWindowFast(query: query) != nil", body)


if __name__ == "__main__":
    unittest.main()
