import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SEND_IMAGE_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "SendImageCommand.swift"


class SendImageCommandContractTests(unittest.TestCase):
    def test_send_image_supports_chat_id_resolution(self) -> None:
        """--chat-id must route through the registry/chat-list resolver.

        Title-only resolution opens the FIRST global search result for a
        display name, which sends the image into the wrong chat when two
        friends share a name. The bridge always prefers the chat_id path.
        """
        source = SEND_IMAGE_COMMAND.read_text(encoding="utf-8")

        self.assertIn('@Option(name: .long, help: "Send using a chat_id', source)
        self.assertIn("chatWindowResolver.resolve(chatID:", source)
        self.assertIn("chatWindowResolver.resolve(query:", source)

    def test_send_image_reports_unclosed_window_loudly(self) -> None:
        """A window left open after the send must be retried, then reported.

        An open chat window makes KakaoTalk auto-read incoming messages (no
        unread badge), which blinds the bridge's badge-triggered read loop —
        observed live 2026-08-03 as a 23-minute unanswered message. The close
        is retried with Escape in between, and the final failure prints a
        stdout marker the bridge watches for.
        """
        source = SEND_IMAGE_COMMAND.read_text(encoding="utf-8")

        self.assertIn("closeChatWindowWithRetry", source)
        self.assertIn("WINDOW_LEFT_OPEN", source)

    def test_send_image_validates_mutually_exclusive_targets(self) -> None:
        source = SEND_IMAGE_COMMAND.read_text(encoding="utf-8")

        self.assertIn("Image path is required when using --chat-id.", source)
        self.assertIn("Recipient cannot be provided together with --chat-id.", source)


if __name__ == "__main__":
    unittest.main()
