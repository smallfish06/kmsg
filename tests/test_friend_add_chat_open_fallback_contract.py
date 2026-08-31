import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
AUTOMATION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoContactAutomation.swift"


class FriendAddChatOpenFallbackContractTests(unittest.TestCase):
    """When the profile's 1:1 click fails, friend add must fall back to the resolver ladder.

    2026-08-31 (talkfriend): a paying user's connect died 5/5 on
    CHAT_WINDOW_NOT_READY — the friend was added, the 1:1 chat click ran three
    times, and no input-ready window ever surfaced (failure dump: main window
    only, composer=false). 7 users hit the same code path in 48h, none
    recovered. The friend already exists at that point, so the chat-list/search
    ladder that read/send uses (exact-title only, rung-by-rung open) is a
    legitimate second route to the same room."""

    def setUp(self) -> None:
        self.source = AUTOMATION.read_text(encoding="utf-8")

    def _body(self, start: str, end: str) -> str:
        return self.source.split(start, 1)[1].split(end, 1)[0]

    def test_chat_window_not_ready_tries_the_ladder_before_throwing(self) -> None:
        body = self._body("private func openOneToOneChat(", "private func openChatViaResolverLadder(")
        fallback_index = body.index("openChatViaResolverLadder(")
        throw_index = body.index("ContactAutomationFailureCode.chatWindowNotReady.rawValue")
        self.assertLess(fallback_index, throw_index)

    def test_missing_chat_action_after_add_tries_the_ladder(self) -> None:
        # The add-confirmation was pressed, so the friend exists even when the
        # profile UI never renders its 1:1 action.
        body = self._body("private func openOneToOneChat(", "// A newly-added friend's profile")
        add_index = body.index("pressFriendAddConfirmation(addButton)")
        fallback_index = body.index("openChatViaResolverLadder(", add_index)
        throw_index = body.index("1:1 chat action did not appear", add_index)
        self.assertLess(add_index, fallback_index)
        self.assertLess(fallback_index, throw_index)

    def test_no_fallback_when_the_friend_was_never_added(self) -> None:
        # "neither Add Friend nor 1:1 Chat action" means no add was committed —
        # searching for a contact name that may not exist opens nothing useful
        # and burns resolve budget.
        body = self._body(
            "Friend result had neither Add Friend nor 1:1 Chat action",
            "// A newly-added friend's profile",
        )
        self.assertNotIn("openChatViaResolverLadder(", body)

    def test_fallback_uses_the_shared_resolver(self) -> None:
        body = self._body("private func openChatViaResolverLadder(", "private func sendFirstMessage(")
        self.assertIn("ChatWindowResolver(kakao: kakao, runner: runner)", body)
        self.assertIn("resolver.resolve(query: friendName)", body)

    def test_fallback_only_returns_a_window_with_a_composer(self) -> None:
        # Search results include friend PROFILES: same title, no message input.
        # Returning one would make sendFirstMessage type into the wrong surface.
        body = self._body("private func openChatViaResolverLadder(", "private func sendFirstMessage(")
        composer_index = body.index("hasChatComposer(in: window")
        return_index = body.index("return window")
        self.assertLess(composer_index, return_index)
        main_reject_index = body.index("sameElement(window, mainListWindow)")
        self.assertLess(main_reject_index, return_index)

    def test_fallback_failure_preserves_the_original_error(self) -> None:
        # The server's retry eligibility keys off the original failure string;
        # the fallback must return nil (caller rethrows), not throw its own.
        body = self._body("private func openChatViaResolverLadder(", "private func sendFirstMessage(")
        self.assertIn("return nil", body)
        self.assertNotIn("throw ", body)


if __name__ == "__main__":
    unittest.main()
