"""`chats` 는 채팅 목록 창이 아닌 창을 목록으로 스캔하지 않는다.

목록 창이 없고 방 창만 떠 있으면 `ensureMainWindow` 폴백은 그 방 창을 돌려준다
(focusedWindow 가 먼저다). 스캐너는 창의 첫 표를 목록으로 읽으므로 **그 방의 대화 전사**가
채팅 목록으로 나간다 — 행은 멀쩡히 오고 제목 자리에 `오후 8:38` 같은 시각이 들어간다. 빈
스캔도 친구 목록도 아니라 `tabrecovered` (⌘2) 도 안 돈다.

talkfriend 2026-09-24 20:50~22:25 KST local-mac-1: 코드 연결(`friend accept`)과 그 방 발송
뒤 이 상태로 95분간 read 0 · 발송 0. 스캔은 얕은 25행, 전체 52→60행(그 방에 온 유저 발화
7건만큼 늘었다)을 `status=done` 으로 돌려줬고 헬스는 초록이었다. read/send 는 같은 상태를
`ChatWindowResolver.ensureChatListWindow` 의 ⌘2 로 이미 되살리고 있었다 — chats 만 그 한
걸음이 없었다.
"""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHATS_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ChatsCommand.swift"
KAKAO_APP = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoTalkApp.swift"


def _body(source: str, start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker)
    return source[start : source.index(end_marker, start)]


class ChatsListWindowContract(unittest.TestCase):
    def setUp(self) -> None:
        self.chats = CHATS_COMMAND.read_text(encoding="utf-8")
        self.app = KAKAO_APP.read_text(encoding="utf-8")

    def test_restores_the_list_window_before_falling_back(self) -> None:
        # 목록 창이 없으면 폴백보다 먼저 ⌘2 로 되살린다.
        self.assertIn(
            "if let chatListWindow = kakao.chatListWindow ?? restoreChatListWindow(kakao: kakao, runner: runner, profiler: profiler) {",
            self.chats,
        )
        restore = _body(self.chats, "    private func restoreChatListWindow(", "\n    private func printChatsAsJSON(")
        # 창이 하나도 없는 콜드 스타트는 기존 폴백(활성화·재실행)의 몫이다.
        self.assertIn("guard !kakao.windows.isEmpty else {", restore)
        self.assertIn("runner.pressCommandTwo()", restore)
        self.assertIn("restored = kakao.chatListWindow", restore)
        # 브릿지는 --trace-ax 없이 돈다. 요약 줄에 남아야 프로덕션에서 보인다.
        self.assertIn('profiler.note("listrestored"', restore)

    def test_refuses_to_scan_a_conversation_window(self) -> None:
        fallback = _body(self.chats, "} else if let fallback = kakao.ensureMainWindow(", "runner.log(\"chats: fallback to ensureMainWindow\")")
        # 늦게 뜬 목록 창을 폴백 뒤에 한 번 더 찾고, 그래도 없을 때만 폴백 창의 정체를 본다.
        self.assertIn(
            "let listWindow = kakao.chatListWindow ?? (kakao.isChatListWindow(fallback) ? fallback : nil)",
            fallback,
        )
        guard = fallback.index("guard let listWindow else {")
        assign = fallback.index("mainWindow = listWindow")
        self.assertLess(guard, assign, "the fallback window must be checked before it is scanned")
        refusal = fallback[guard:assign]
        self.assertIn('profiler.note("nolistwindow", "1")', refusal)
        # 빈 결과로 끝낸다 — 호출자는 빈 스캔을 부재의 증거로 쓰지 않는다.
        self.assertIn("try printChatsAsJSON([])", refusal)
        self.assertIn("return", refusal)
        # 목록 창은 이번 실행이 띄웠어도 닫지 않는다 — 닫으면 다음 명령이 또 방 창만 남은 상태에서 시작한다.
        self.assertIn("autoOpenedWindow = false", fallback[assign:])

    def test_list_window_predicate_matches_chat_list_window(self) -> None:
        predicate = _body(self.app, "    public func isChatListWindow(", "\n    /// Get the chat list window")
        getter = _body(self.app, "    public var chatListWindow: UIElement? {", "\n    // MARK: - UI Navigation")
        # 같은 근거 셋을 쓴다. 한쪽만 바뀌면 되살린 목록 창을 폴백 검사가 거부하거나 그 반대가 된다.
        for evidence in ('"채팅"', '"카카오톡"', 'identifier: "chatrooms"'):
            self.assertIn(evidence, predicate)
            self.assertIn(evidence, getter)


if __name__ == "__main__":
    unittest.main()
