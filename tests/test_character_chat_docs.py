import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
README_PATH = REPO_ROOT / "README.md"
DOC_PATH = REPO_ROOT / "docs" / "character-chat.md"


class CharacterChatDocsTests(unittest.TestCase):
    def test_readme_links_character_chat_integration_guide(self) -> None:
        readme = README_PATH.read_text(encoding="utf-8")

        self.assertIn("docs/character-chat.md", readme)

    def test_guide_documents_code_based_open_profile_binding(self) -> None:
        guide = DOC_PATH.read_text(encoding="utf-8")

        self.assertIn("verification_code", guide)
        self.assertIn("status `pending`", guide)
        self.assertIn("status `verified`", guide)
        self.assertIn("kmsg chats --json --limit 50", guide)
        self.assertIn('kmsg read --chat-id "chat_..." --limit 5 --json', guide)
        self.assertIn('kmsg send --chat-id "chat_..."', guide)
        self.assertIn('kmsg watch --chat-id "chat_..." --json', guide)
        self.assertIn("Do not use chat title or nickname as the primary identity", guide)


if __name__ == "__main__":
    unittest.main()
