import hashlib
import unicodedata
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
REGISTRY = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatIdentityRegistry.swift"


class ChatIdentitySymbolNameContractTests(unittest.TestCase):
    """Symbol-only display names must not share one chat id.

    The registry groups chats by normalized name and hashes that name into the
    chat id. Strict `normalize` strips punctuation and symbols, so "~.~",
    "-.--..-..--..-", "^^", and emoji names all reduce to "" and land in one
    group keyed by sha256("") = e3b0c44298fc. Two different people's rooms then
    shared a single chat id, inbound routed into the wrong conversation, and a
    reply carrying the other person's context was delivered to the wrong room
    (talkfriend, 2026-08-06). `normalizeForMatch` keeps those scalars when the
    strict form is empty, which is exactly the fallback this needs."""

    def setUp(self) -> None:
        self.source = REGISTRY.read_text(encoding="utf-8")

    def test_grouping_key_uses_the_lenient_normalizer(self) -> None:
        body = self.source.split("func assignChatIDs", 1)[1].split("func record(", 1)[0]

        self.assertIn("ChatTextNormalizer.normalizeForMatch(discoveries[index].title)", body)
        # The strict form must not be the group key any more.
        self.assertNotIn("ChatTextNormalizer.normalize(discoveries[index].title)", body)

    def test_stored_records_are_healed_to_the_current_rule_on_load(self) -> None:
        """Old records were written with the strict rule. Left alone they would
        never meet the lenient groups, so every healthy chat would be handed a
        brand-new id — the same damage as bumping schemaVersion."""
        body = self.source.split("private func loadDocument", 1)[1].split("private func persist", 1)[0]

        self.assertIn("healed.normalizedName = ChatTextNormalizer.normalizeForMatch(record.displayName)", body)
        # Healing must happen after the schema check, on the decoded document.
        self.assertLess(body.index("guard document.schemaVersion"), body.index("healed.normalizedName"))

    # 위 두 규칙이 실제로 무엇을 만들어내는지 못박는다. Swift 테스트 타깃이 없어
    # 해시 계산을 여기서 재현한다 — sha256(키) 앞 6바이트가 chat id 의 base 다.
    def test_symbol_names_hash_apart_while_normal_names_keep_their_id(self) -> None:
        zero_width = {0x200B, 0x200C, 0x200D, 0xFEFF}

        def strict(text: str) -> str:
            lowered = unicodedata.normalize("NFKD", text.strip()).lower()
            kept = []
            for char in lowered:
                if unicodedata.combining(char):
                    continue
                category = unicodedata.category(char)
                if char.isspace() or category[0] in "PS" or ord(char) in zero_width:
                    continue
                kept.append(char)
            return "".join(kept)

        def lenient(text: str) -> str:
            if strict(text):
                return strict(text)
            lowered = unicodedata.normalize("NFKD", text.strip()).lower()
            return "".join(
                char
                for char in lowered
                if not char.isspace() and ord(char) not in zero_width and not unicodedata.combining(char)
            )

        def base(name: str) -> str:
            return hashlib.sha256(name.encode()).hexdigest()[:12]

        self.assertEqual(base(""), "e3b0c44298fc")

        # 기호뿐인 이름은 strict 로는 전부 빈 키 → 한 id 로 뭉친다.
        symbol_names = ["~.~", "-.--..-..--..-", "👽", "^^", "^^~", "🦋", "*", "."]
        self.assertEqual({base(strict(name)) for name in symbol_names}, {"e3b0c44298fc"})
        # lenient 로는 전부 갈라진다.
        split = {base(lenient(name)) for name in symbol_names}
        self.assertEqual(len(split), len(symbol_names))
        self.assertNotIn("e3b0c44298fc", split)

        # 이름이 정상인 방은 strict 결과가 비지 않아 lenient 가 같은 값을 돌려주고,
        # 따라서 id 가 그대로다 — 기존 바인딩이 살아남는 근거다.
        for name in ["민준", "신규섭", "김유경"]:
            self.assertNotEqual(strict(name), "")
            self.assertEqual(base(strict(name)), base(lenient(name)))


if __name__ == "__main__":
    unittest.main()
