import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatWindowResolver.swift"


class ChatWindowExactTitleContractTests(unittest.TestCase):
    """A resolved chat window must carry the requested title — or resolution fails.

    2026-08-15 (talkfriend): a `--chat-id` read clicked the right list row, the
    matching window did not surface within the wait, and resolveOpenedChatWindow
    fell through to "any focused/fallback/main window with a chat input". That
    window belonged to another user; their messages were ingested into the wrong
    conversation, the character replied to them, and the server renamed the room
    after the wrong author. The read was logged as status=ok. Fuzzy
    scoreQueryMatch (prefix/contains) had the same shape on the window side:
    '하린' would take an open '차하린' window.

    Identity therefore uses exact normalized equality only, and there is no
    title-blind window fallback anywhere in the resolver."""

    def setUp(self) -> None:
        self.source = RESOLVER.read_text(encoding="utf-8")

    def _body(self, start: str, end: str) -> str:
        return self.source.split(start, 1)[1].split(end, 1)[0]

    def test_wrong_window_is_a_named_failure(self) -> None:
        self.assertIn('case wrongWindow = "WRONG_WINDOW"', self.source)

    def test_window_matching_is_exact_not_scored(self) -> None:
        body = self._body("private func findMatchingChatWindow", "private func bestQueryMatch")
        self.assertIn("titleMatchesExactly(query: query, candidate: window.title)", body)
        self.assertNotIn("scoreQueryMatch", body)

    def test_opened_window_resolution_has_no_title_blind_fallback(self) -> None:
        body = self._body("private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement)", "private func windowContainsLikelyChatInput")
        self.assertNotIn("windowContainsLikelyChatInput(focusedWindow)", body)
        self.assertNotIn("windowContainsLikelyChatInput(fallbackWindow)", body)
        self.assertNotIn("windowContainsLikelyChatInput(mainWindow)", body)
        self.assertIn("ChatWindowFailureCode.wrongWindow", body)
        self.assertIn('note("res.wrong", "1")', body)

    def test_fast_and_background_safe_paths_use_exact_match(self) -> None:
        fast = self._body("private func resolveOpenedChatWindowFast", "private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement)")
        self.assertIn("titleMatchesExactly(query: query, candidate: focusedWindow.title)", fast)
        self.assertNotIn("scoreQueryMatch", fast)
        safe = self._body("private func resolveExistingWindowOnly", "throw KakaoTalkError.elementNotFound")
        self.assertIn("titleMatchesExactly(query: query, candidate: focusedWindow.title)", safe)
        self.assertNotIn("scoreQueryMatch", safe)

    def test_search_results_require_exact_title(self) -> None:
        body = self._body("private func findMatchingSearchResults", "return deduplicateSearchCandidates(results)")
        self.assertIn("titleMatchesExactly(query: query, candidate: matchedText)", body)

    def test_exact_match_keeps_symbol_only_titles_and_rejects_prefixes(self) -> None:
        body = self._body("private func titleMatchesExactly", "private func findMatchingChatWindow")
        # The registry normalizer keeps '.'-only names; normalizeSearchToken would blank them.
        self.assertIn("ChatTextNormalizer.normalizeForMatch(query)", body)
        self.assertNotIn("normalizeSearchToken", body)
        self.assertNotIn("hasPrefix", body)


if __name__ == "__main__":
    unittest.main()
