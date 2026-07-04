import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SEND_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "SendCommand.swift"


class SendCommandContractTests(unittest.TestCase):
    def test_send_command_delegates_chat_window_resolution(self) -> None:
        source = SEND_COMMAND.read_text(encoding="utf-8")

        self.assertIn("let chatWindowResolver = ChatWindowResolver(", source)
        self.assertIn("chatWindowResolver.resolve(chatID:", source)
        self.assertIn("chatWindowResolver.resolve(query:", source)

        delegated_helpers = [
            "private func requireUsableWindow(",
            "private func selectSearchWindow(",
            "private func openChatViaSearch(",
            "private func pickBestSearchResult(",
            "private func scoreSearchResult(",
            "private func triggerSearchResultOpen(",
            "private func tryActivateSearchResult(",
            "private func trySelectSearchResult(",
            "private func findMatchingChatWindow(",
            "private func locateSearchField(",
            "private func discoverSearchFieldCandidates(",
            "private func waitForMatchingSearchResults(",
            "private func findMatchingSearchResults(",
            "private func waitForOpenedChatWindow(",
            "private func resolveOpenedChatWindowFast(",
            "private func resolveOpenedChatWindow(",
            "private func windowContainsLikelyChatInput(",
            "private func pickSearchField(",
            "private func containsText(",
        ]
        for helper in delegated_helpers:
            self.assertNotIn(helper, source)


if __name__ == "__main__":
    unittest.main()
