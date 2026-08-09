"""목록 스캔이 자기 결과를 의심하는 계약.

창을 여는 명령(read/send) 직후 카톡이 목록을 다시 그리는 동안 컨테이너의 children 이
순간적으로 한둘만 남는다. 그때 kmsg 는 `status=done` 으로 그 한둘을 그대로 돌려주는데,
호출자에게 그것은 "나머지 방이 전부 사라졌다"와 구별되지 않는다 — talkfriend 브릿지
실측(2026-08-09)에서 스캔 50회 중 17회가 그 상태였고, 멀쩡한 방 ~100개가 고착으로
분류돼 창을 열었다 닫혔다(상대에겐 답장 없는 읽음 처리).

한 행짜리 목록과 한 행만 그려진 목록은 AX 상으로 구별되지 않으므로, 판단 근거는 이
설치본이 실제로 봐 온 방 수뿐이다. 이 테스트는 그 비교가 존재하고, 갓 설치한 상태
(레지스트리가 비어 있음)에서는 비교하지 않는다는 불변식을 고정한다.
"""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHATS_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ChatsCommand.swift"
REGISTRY = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatIdentityRegistry.swift"


class ChatScanSettleContractTests(unittest.TestCase):
    def test_registry_exposes_how_many_chats_this_install_has_seen(self) -> None:
        source = REGISTRY.read_text(encoding="utf-8")
        self.assertIn("var knownChatCount: Int", source)

    def test_scan_compares_its_result_against_that_count(self) -> None:
        source = CHATS_COMMAND.read_text(encoding="utf-8")
        self.assertIn(
            "let expectedRows = min(limit, ChatIdentityRegistryStore.shared.knownChatCount)",
            source,
        )
        # 갓 설치한 상태의 0 은 "빈 목록"이 아니라 "의견 없음"이다 — 그때 재시도를
        # 돌리면 정말 채팅방이 없는 설치본이 매 스캔 0.35초를 문다.
        self.assertIn("if expectedRows > 0 &&", source)

    def test_retry_drops_the_cached_container_path(self) -> None:
        # 덜 그려진 것인지 엉뚱한 컨테이너를 물었는지 스캐너는 구별할 수 없다
        # (isLikelyChatListContainer 가 역할만 본다). 캐시를 버리면 둘 다 덮인다.
        source = CHATS_COMMAND.read_text(encoding="utf-8")
        self.assertIn("AXPathCacheStore.shared.clear(slots: [.chatListContainer])", source)

    def test_retry_never_shrinks_the_result(self) -> None:
        source = CHATS_COMMAND.read_text(encoding="utf-8")
        self.assertIn("if settled.count > snapshots.count {", source)

    def test_summary_line_reports_whether_the_retry_helped(self) -> None:
        # 브릿지는 `[kmsg] ... total=` 줄을 그대로 중계한다. 이 필드가 프로덕션에서
        # "정말 덜 그려진 것이었나"를 답해주는 유일한 창구다.
        source = CHATS_COMMAND.read_text(encoding="utf-8")
        self.assertIn('profiler.note("resettled"', source)


if __name__ == "__main__":
    unittest.main()
