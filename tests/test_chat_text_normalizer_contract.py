import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHAT_LIST_SCANNER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatListScanner.swift"
CONTACT_AUTOMATION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoContactAutomation.swift"


class ChatTextNormalizerContractTests(unittest.TestCase):
    """Symbol-only display names (e.g. "~.~") strict-normalize to the empty
    string. Friend-add identity confirmation must fall back to a lenient
    normalizer instead of aborting after the first message was already sent
    (CHAT_IDENTITY_NOT_CONFIRMED regression, 2026-08-03)."""

    def test_normalizer_exposes_lenient_match_fallback(self) -> None:
        source = CHAT_LIST_SCANNER.read_text(encoding="utf-8")

        self.assertIn("static func normalizeForMatch(_ text: String) -> String", source)
        # The fallback triggers only when the strict form erased everything.
        self.assertIn("let strict = normalize(text)", source)
        self.assertIn("if !strict.isEmpty { return strict }", source)

    def test_confirm_chat_identity_uses_match_normalizer_on_both_sides(self) -> None:
        source = CONTACT_AUTOMATION.read_text(encoding="utf-8")

        self.assertIn(
            "let normalizedTitle = ChatTextNormalizer.normalizeForMatch(chatTitle)", source
        )
        self.assertIn(
            "let normalizedOpener = ChatTextNormalizer.normalizeForMatch(opener)", source
        )
        # Row comparison must use the same normalizer as the reference values,
        # otherwise a lenient reference can never equal a strict row form.
        self.assertIn(
            "ChatTextNormalizer.normalizeForMatch(snapshot.discovery.title) == normalizedTitle",
            source,
        )
        self.assertIn(
            "ChatTextNormalizer.normalizeForMatch(lastMessage) == normalizedOpener", source
        )
        # No strict-normalize call may remain inside the identity confirmation.
        confirm_body = source.split("private func confirmChatIdentity", 1)[1].split(
            "private func", 1
        )[0]
        self.assertNotIn("ChatTextNormalizer.normalize(", confirm_body)


if __name__ == "__main__":
    unittest.main()
