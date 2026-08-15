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


class ChatListPaneAcceptanceContractTests(unittest.TestCase):
    """A wide chat-list window opens rows as an in-window pane, not a titled window.

    2026-08-16 03:20 KST (bridge Mac, v1.260816.1 diagnostics): every WRONG_WINDOW
    read logged `res.wrongkind=list+input res.wins=3` — the focused window was the
    chat-list window itself and it contained a message input. The pre-5d5c946
    resolver accepted that window title-blind (and once read another user's pane).

    The list window may be accepted only when the pane HEADER title matches the
    query exactly, and the header must be told apart from list rows / transcript
    rows carrying the same string; the read result must then report the header
    title as `chat`, not the window title."""

    def setUp(self) -> None:
        self.source = RESOLVER.read_text(encoding="utf-8")
        self.body = self.source.split("private func verifiedListPaneTitle(", 1)[1].split("\n    private func ", 1)[0]

    def test_header_match_is_exact(self) -> None:
        self.assertIn("titleMatchesExactly(query: query, candidate: candidate)", self.body)
        self.assertNotIn("scoreQueryMatch", self.body)

    def test_header_is_separated_from_rows_by_geometry_and_ancestry(self) -> None:
        # above the input, in the input's column, in the top band, not inside a row/cell/table
        self.assertIn("frame.minY < inputFrame.minY", self.body)
        self.assertIn("frame.maxX > inputFrame.minX", self.body)
        self.assertIn("headerBandMaxY", self.body)
        self.assertIn("kAXRowRole", self.body)
        self.assertIn("kAXTableRole", self.body)

    def test_input_lookup_is_budgeted(self) -> None:
        # An unbounded walk of the 361-row list window took 15-20s (v1.260816.1).
        self.assertNotIn("findFirst(", self.body)
        self.assertIn("maxNodes:", self.body)

    def test_pane_resolution_carries_its_own_chat_title(self) -> None:
        self.assertIn("case openedInListPane", self.source)
        self.assertIn("var chatTitle: String? = nil", self.source)
        self.assertIn("method: .openedInListPane, chatTitle: paneTitle", self.source)
        reader = (REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptReader.swift").read_text(encoding="utf-8")
        self.assertIn("chat: chatTitleOverride ?? chatWindow.title ?? fallbackChatTitle", reader)
        read_cmd = (REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ReadCommand.swift").read_text(encoding="utf-8")
        self.assertIn("chatTitleOverride: resolution.chatTitle", read_cmd)


if __name__ == "__main__":
    unittest.main()
