import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
READ_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ReadCommand.swift"
KMSG_ENTRYPOINT = REPO_ROOT / "Sources" / "kmsg" / "kmsg.swift"
MCP_SERVER_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "MCPServerCommand.swift"
CHAT_WINDOW_RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatWindowResolver.swift"
MESSAGE_CONTEXT_RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "MessageContextResolver.swift"
TRANSCRIPT_READER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptReader.swift"


class ReadBackgroundSafeContractTests(unittest.TestCase):
    def test_entrypoint_uses_invoked_command_name_for_aliases(self) -> None:
        source = KMSG_ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("invokedCommandName", source)
        self.assertIn("CommandLine.arguments.first", source)
        self.assertIn("commandName: commandName", source)

    def test_read_command_exposes_background_safe_flag(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn("var backgroundSafe: Bool = false", source)
        self.assertIn("KakaoTalkApp(autoLaunch: false)", source)
        self.assertIn("interactionMode: backgroundSafe ? .backgroundSafe", source)
        self.assertIn("title(s) hidden in background-safe mode", source)

    def test_background_safe_resolver_blocks_focus_stealing_paths(self) -> None:
        source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")

        self.assertIn("case backgroundSafe", source)
        self.assertIn("resolveExistingWindowOnly", source)
        self.assertIn("BACKGROUND_SAFE_BLOCKED", source)
        self.assertIn("background-safe mode; preserving window focus, size, and position", source)

    def test_split_layout_modes_support_marketing_workspaces(self) -> None:
        resolver_source = CHAT_WINDOW_RESOLVER.read_text(encoding="utf-8")
        read_source = READ_COMMAND.read_text(encoding="utf-8")
        mcp_source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")

        self.assertIn('case splitLeft = "split-left"', resolver_source)
        self.assertIn('case splitRight = "split-right"', resolver_source)
        self.assertIn("splitLayoutFrame", resolver_source)
        self.assertIn("split-left, or split-right", read_source)
        self.assertIn('"split-left", "split-right"', mcp_source)

    def test_background_safe_context_resolution_skips_activation_fallback(self) -> None:
        source = MESSAGE_CONTEXT_RESOLVER.read_text(encoding="utf-8")

        self.assertIn("interactionMode: ChatWindowInteractionMode = .allowUIAutomation", source)
        self.assertIn("background-safe mode; skipping chat window activation fallback", source)

    def test_transcript_message_json_exposes_media_metadata(self) -> None:
        source = TRANSCRIPT_READER.read_text(encoding="utf-8")

        self.assertIn('case hasImage = "has_image"', source)
        self.assertIn('case imageCount = "image_count"', source)
        self.assertIn('case linkCount = "link_count"', source)
        self.assertIn('case hasAttachment = "has_attachment"', source)
        self.assertIn('case attachmentCount = "attachment_count"', source)
        self.assertIn("likelyMessageImageFrames", source)
        self.assertIn("countURLTokens", source)


if __name__ == "__main__":
    unittest.main()
