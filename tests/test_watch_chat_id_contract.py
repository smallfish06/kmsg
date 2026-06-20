import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WATCH_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "WatchCommand.swift"
README_PATH = REPO_ROOT / "README.md"


class WatchChatIDContractTests(unittest.TestCase):
    def test_watch_supports_chat_id_option(self) -> None:
        source = WATCH_COMMAND.read_text(encoding="utf-8")

        self.assertIn("var chatID: String?", source)
        self.assertIn("resolve(chatID: chatID)", source)
        self.assertIn("Chat name cannot be provided together with --chat-id.", source)

    def test_readme_documents_watch_chat_id(self) -> None:
        readme = README_PATH.read_text(encoding="utf-8")

        self.assertIn("kmsg watch --chat-id <chat-id>", readme)
        self.assertIn("`--chat-id <chat-id>`", readme)


if __name__ == "__main__":
    unittest.main()
