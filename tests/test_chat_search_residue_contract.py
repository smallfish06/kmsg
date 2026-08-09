"""이름 검색이 끝나면 검색을 끄는 계약.

검색은 방을 열면 끝나지만 검색어는 창에 남는다. 그 상태는 프로세스가 아니라 카톡
GUI 에 남으므로 **뒤이어 뜨는 모든 kmsg 실행이 통째로 물려받는다** — 목록이 필터된
채라 `chats` 는 한두 행짜리 결과를 `status=done` 으로 돌려주고, `--chat-id` 해석은
그 목록에서 행을 못 찾아 매번 검색 경로로 떨어져 필터를 다시 깐다. 스스로 일감을
만드는 고리다.

talkfriend 실측 2026-08-09 09:50~10:00 UTC: `rows=1` 스캔이 153회 연속, 그 10분간
read/send 0건(수신 전면 정지), 복구 직후 첫 read 는 resolve 에만 16.0s 를 썼다.
바로 앞선 `test_chat_scan_settle_contract` 의 재스캔은 이걸 못 고친다 — 덜 그려진
목록은 기다리면 채워지지만 필터된 목록은 지워주기 전까지 영원히 그대로다.

종전 코드의 모양이 특히 고약했다: 실패 경로 세 곳에는 `pressEscape()` 가 있었고
**성공 경로에만 없었다.** 정확히 잘 된 검색만 필터를 남겼다는 뜻이다.
"""

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatWindowResolver.swift"
CHATS_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ChatsCommand.swift"


def _open_chat_via_search_body(source: str) -> str:
    start = source.index("private func openChatViaSearch(")
    end = source.index("\n    /// 채팅 목록의 검색어를 지운다.", start)
    return source[start:end]


class ChatSearchResidueContractTests(unittest.TestCase):
    def test_cleanup_covers_every_exit_of_the_search_path(self) -> None:
        # defer 여야 한다. 이 함수는 성공 1곳(+Enter 직개통 1곳)과 throw 4곳으로
        # 나가는데, 나가는 자리마다 손으로 부르는 형태는 새 분기가 하나 생길 때마다
        # 조용히 빠진다 — 실제로 그렇게 빠져 있었다.
        body = _open_chat_via_search_body(RESOLVER.read_text(encoding="utf-8"))
        self.assertIn(
            "defer { clearChatListSearch(searchField, in: rootWindow, label: query) }", body
        )

    def test_no_stray_escape_left_in_the_search_path(self) -> None:
        # 포커스를 확인하지 않은 Escape 는 지금 키 이벤트를 받는 창으로 간다.
        # 검색 도중 그 창은 방금 열린 채팅창일 수 있고, 카톡에서 Escape 는 채팅창을
        # 닫는다. 정리는 필드를 잡은 뒤에만 한다.
        body = _open_chat_via_search_body(RESOLVER.read_text(encoding="utf-8"))
        self.assertNotIn("pressEscape()", body)

    def test_clear_uses_real_key_events(self) -> None:
        # AXValue 로 비우면 필드는 비는데 목록은 필터된 채로 남는다 — 카톡 검색은
        # 실제 키 이벤트에만 반응한다(검색어를 넣을 때 타이핑을 쓰는 것과 같은 이유).
        # 그 상태는 지금보다 나쁘다: 눈에 보이는 증거까지 사라진다.
        source = RESOLVER.read_text(encoding="utf-8")
        start = source.index("private func clearChatListSearch(")
        body = source[start : source.index("\n    /// 목록이 남은 검색어로", start)]
        self.assertIn("runner.pressCommandA()", body)
        self.assertIn("runner.pressDeleteKey()", body)
        # 필드를 못 잡으면 키를 하나도 보내지 않는다.
        self.assertLess(
            body.index("runner.focusWithVerification("),
            body.index("runner.pressCommandA()"),
        )

    def test_clear_activates_kakao_before_pressing_keys(self) -> None:
        # AX 포커스와 키 이벤트의 목적지는 다른 축이다. focusWithVerification 은 AX
        # 속성만 세팅하고 pressCommandA/pressDeleteKey 는 CGEvent 라 프론트모스트 앱으로
        # 간다 — activate 를 빼먹은 첫 판은 스모크에서 "FAILED to clear" 로 죽었고,
        # 그 ⌘A/delete 는 kmsg 를 띄운 터미널로 갔다.
        source = RESOLVER.read_text(encoding="utf-8")
        start = source.index("private func clearChatListSearch(")
        body = source[start : source.index("\n    /// 목록이 남은 검색어로", start)]
        self.assertIn("kakao.activate()", body)
        self.assertLess(body.index("kakao.activate()"), body.index("runner.pressCommandA()"))

    def test_clear_failure_is_logged(self) -> None:
        # 조용히 실패하면 다음 스캔이 필터된 목록을 정상 결과로 돌려주는 것으로만
        # 드러난다 — 그게 위의 10분짜리 정지였다.
        source = RESOLVER.read_text(encoding="utf-8")
        self.assertIn("FAILED to clear", source)

    def test_scan_self_heals_a_dirty_search_box(self) -> None:
        # 정리 한 곳에만 걸어두지 않는다: 사람이 그 Mac 에서 직접 검색창에 타이핑한
        # 경우에도 잔재의 대가는 똑같이 수신 전면 정지다. 이 그물이 그걸 다음 스캔
        # 한 번으로 되돌린다.
        source = CHATS_COMMAND.read_text(encoding="utf-8")
        self.assertIn("clearChatListSearchIfDirty(in: mainWindow)", source)
        self.assertIn('profiler.note("searchcleared", "1")', source)
        # 스캔보다 먼저 돌아야 한다.
        self.assertLess(
            source.index("clearChatListSearchIfDirty"),
            source.index('profiler.begin("scan")'),
        )

    def test_self_heal_never_presses_search_buttons(self) -> None:
        # locateSearchField 는 못 찾으면 검색처럼 생긴 버튼들을 눌러본다. 이 경로는
        # 매 tick(기본 1.5s) 도므로 그 부작용이 상시화된다 — 부작용 없는 조회만 쓴다.
        source = RESOLVER.read_text(encoding="utf-8")
        start = source.index("func clearChatListSearchIfDirty(")
        body = source[start : source.index("\n    private func openChatListRow(", start)]
        self.assertIn("findExistingSearchField(in: window)", body)
        self.assertNotIn("locateSearchField(in:", body)

    def test_existing_search_field_lookup_has_no_side_effects(self) -> None:
        source = RESOLVER.read_text(encoding="utf-8")
        start = source.index("private func findExistingSearchField(")
        body = source[start : source.index("\n    private func locateSearchField(", start)]
        self.assertNotIn(".press()", body)
        self.assertFalse(
            re.search(r"runner\.press[A-Z]", body),
            "부작용 없는 조회여야 한다",
        )


if __name__ == "__main__":
    unittest.main()
