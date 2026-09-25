"""창을 닫는 코드가 채팅 목록 창을 닫지 않는 계약.

채팅 목록 창은 한 번 닫히면 카카오톡을 활성화해도 돌아오지 않는다(⌘2 나 강제 재실행으로만).
그동안 `chats` 는 목록을 못 보고, 방 창이 남아 있으면 그 전사를 목록으로 읽었다.

talkfriend 브릿지 로그 6일치: 목록 창이 사라진 4건이 전부 0.9초 넘게 걸린 방 닫기 직후였다
(정상 0.4초) — 느린 닫기 101건 중 4%, 정상 닫기 12.9만 건 중 0.15%. 그중 하나가 2026-09-24
20:50~22:25 local-mac-1 의 95분 수신 정지다. 경로는 셋이었다.

  1. `closeWindow` 의 마지막 폴백 ⌘W 는 닫으려는 창이 아니라 **키 창**을 닫는다. 방이 앞 두
     경로로 안 닫힌 채 목록 창이 키 창이면 목록 창이 닫힌다.
  2. 닫기 버튼을 못 찾으면 **아무 첫 버튼**(buttons.first)을 눌렀다 — 방 창의 첫 버튼은 첨부·프로필
     같은 것이라 창은 안 닫히고 ⌘W 로 넘어갔다.
  3. `send` 는 시작할 때 목록 창이 없었으면 끝에 목록 창을 닫았다. 목록 창이 한 번 사라지면 다음
     send 가 ⌘2 로 되살렸다가 다시 닫아 그 상태를 영속화했다. `send-image` 는 조건도 없이 닫았다.

로컬 재현(2026-09-25, 방 창 하나 + 목록 창 닫힘에서 나와의 채팅으로 발송): v1.260925.0 은 전송 뒤
close=1.30초에 목록 창을 다시 닫았고(운영 20:49:48 의 close=1.12초와 같은 모양) 이 수정본은
close=0.38초(표준 닫기 버튼)에 목록 창을 남겼다. 1번(⌘W)이 운영에서 실제로 눌렸는지는 관측하지
못했다 — 그 가드는 방어다.
"""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatWindowResolver.swift"
SEND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "SendCommand.swift"
SEND_IMAGE = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "SendImageCommand.swift"


def _body(source: str, start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker)
    return source[start : source.index(end_marker, start)]


class CloseWindowGuardContract(unittest.TestCase):
    def setUp(self) -> None:
        self.resolver = RESOLVER.read_text(encoding="utf-8")

    def test_cmd_w_only_when_the_target_is_focused(self) -> None:
        close = _body(self.resolver, "    func closeWindow(_ window: UIElement) -> Bool {", "\n    private func resolveExistingWindowOnly(")
        guard = close.index("guard let focused = kakao.focusedWindow, areSameAXElement(focused, window) else {")
        press = close.index("runner.pressCommandW()")
        self.assertLess(guard, press, "cmd+w must be gated on the focused window being the target")
        refusal = close[guard:press]
        self.assertIn('note("close.cmdw", "skipped")', refusal)
        self.assertIn("return false", refusal)
        # 경로가 요약 줄에 남아야 프로덕션에서 느린 닫기를 가를 수 있다.
        for path in ('"axclose"', '"button"', '"cmdw"', '"none"'):
            self.assertIn(path, close)

    def test_close_button_is_never_an_arbitrary_button(self) -> None:
        finder = _body(self.resolver, "    private func findCloseButton(", "\n    private func waitForWindowClosed(")
        self.assertIn("kAXCloseButtonAttribute", finder)
        self.assertNotIn("return buttons.first\n", finder)
        self.assertIn("return buttons.first(where:", finder)

    def test_sends_leave_the_chat_list_window_open(self) -> None:
        for path in (SEND, SEND_IMAGE):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("resolver.closeWindow(listWindow)", source, path.name)
            self.assertNotIn("chatListWasOpen", source, path.name)


if __name__ == "__main__":
    unittest.main()
