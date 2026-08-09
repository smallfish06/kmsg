"""친구 탭을 채팅 목록으로 착각하지 않는 계약.

친구 탭은 채팅 목록인 척한다: 같은 자리의 컨테이너(`AXOutline`), 같은 이름의 행,
그리고 `status=done` 에 꽉 찬 행수. 다른 것은 하나뿐인데 그게 치명적이다 — 친구 행의
"미리보기"는 **상태메시지**라서 메시지가 와도 절대 안 변한다. 그래서 이 착각은
에러가 아니라 침묵으로 나타난다: 폴링하는 쪽에서는 모든 방이 영원히 조용해 보인다.

talkfriend 실측 2026-08-09 23:34:30~23:40:18 KST: 수신이 5분 48초 통째로 멈췄고
(미조 349s, 채희 369s 지연) 그동안 `chats` 는 매 tick `status=done rows=25` 를
돌려줬다. 지문은 행당 스캔 시간뿐이었다 — 25행이 정상 0.57s 대신 0.10s.

종전 가드(`looksLikeFriendsList`)는 **부재 기반**이었다: 상위 10행에 시계 같은
문자열이 하나도 없으면 친구 목록. 그 판정은 양방향으로 틀린다.

  - 거짓 음성: 친구 한 명의 상태메시지가 시계처럼 보이면 친구 목록이 통과한다.
    판정자가 `isTimeLikeValue` 에 위임했는데 그건 **"일" 로 끝나는 아무 문자열이나**
    받는다 ("매일", "생일", "내일", …). 위의 5분 48초가 이 구멍이다.
  - 거짓 양성: 멀쩡한 채팅 목록의 상위 10행이 전부 인식 못 하는 형식이면 방이
    하나도 없다고 돌려준다.

그래서 판정 근거를 행 내용에서 **창이 그리는 헤더**로 옮겼다. 탭마다 자기 헤더를
창의 직속 자식으로 그린다(실측): 채팅 → `AXButton title:"채팅"`, 친구 →
`AXStaticText value:"친구"`, 더보기 → `AXStaticText value:"더보기"`. 네비게이션
버튼(id: friends/chatrooms/more)에는 선택 상태가 아예 없다 — `--show-attributes`
로 확인했다.
"""

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCANNER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatListScanner.swift"
CHATS_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ChatsCommand.swift"
RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatWindowResolver.swift"
CONTACT_AUTOMATION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "KakaoContactAutomation.swift"

CALL_SITES = (CHATS_COMMAND, RESOLVER, CONTACT_AUTOMATION)


def _verdict_body(source: str) -> str:
    start = source.index("    func looksLikeFriendsList(")
    return source[start : source.index("\n    /// Which tab the KakaoTalk main window", start)]


def _detector_body(source: str) -> str:
    start = source.index("    static func detectMainWindowTab(")
    return source[start : source.index("\n\n    /// The header sits within", start)]


def _clock_patterns(source: str) -> list[str]:
    start = source.index("private static let clockPatterns = [")
    # 배열 리터럴의 닫는 대괄호. 패턴 안에도 "]" 가 있으므로 들여쓰기로 찾는다.
    body = source[start : source.index("\n    ]", start)]
    # Swift 소스의 "\\." 는 정규식의 "\." 다. unicode_escape 로 풀면 한글이 깨지므로
    # 역슬래시만 되돌린다.
    return [literal.replace("\\\\", "\\") for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', body)]


class FriendsTabDetectionContractTests(unittest.TestCase):
    def test_verdict_asks_the_window_before_reading_the_rows(self) -> None:
        # 직접 답이 있으면 그걸 쓴다. 행 휴리스틱은 양방향으로 틀리고 두 실패가 다
        # 조용하므로, 순서가 뒤집히면 헤더를 넣은 의미가 없다.
        body = _verdict_body(SCANNER.read_text(encoding="utf-8"))
        self.assertIn("Self.detectMainWindowTab(in: window)", body)
        self.assertLess(
            body.index("detectMainWindowTab"),
            body.index("snapshot.sawClockText"),
        )

    def test_chats_tab_verdict_is_conclusive(self) -> None:
        # 헤더가 채팅 탭이라고 답하면 거기서 끝난다. 이게 거짓 양성(멀쩡한 목록을
        # "방 없음"으로 돌려주던 쪽)을 막는 자리다.
        body = _verdict_body(SCANNER.read_text(encoding="utf-8"))
        self.assertIn("if tab == .chats { return false }", body)

    def test_unknown_header_falls_back_instead_of_refusing(self) -> None:
        # 모른다를 "틀린 탭"으로 읽으면 카톡이 헤더를 바꾸는 날 스캔이 전부 멈춘다 —
        # 지금 고치는 고장보다 나쁘다. nil 은 옵셔널 바인딩으로 흘려보내고 행
        # 휴리스틱이 그물로 남아야 한다.
        source = SCANNER.read_text(encoding="utf-8")
        body = _verdict_body(source)
        self.assertIn("if let tab = Self.detectMainWindowTab(in: window) {", body)
        # 기본값 nil 을 두면 새 호출자가 조용히 2순위로 떨어진다.
        self.assertIn("in window: UIElement,", body)
        self.assertNotIn("in window: UIElement? = nil", body)
        # 판정자 자신은 못 알아보면 nil 을 준다.
        self.assertTrue(_detector_body(source).rstrip().endswith("return nil\n    }"))

    def test_detection_does_not_walk_into_the_list(self) -> None:
        # 이 판정은 스캔마다 도는 자리다. 창의 직속 자식 몇 개만 본다 — 그 뒤에
        # 오는 것이 813행짜리 스크롤 영역이다.
        detector = _detector_body(SCANNER.read_text(encoding="utf-8"))
        self.assertIn("window.children.prefix(headerScanLimit)", detector)
        self.assertNotIn("findAll", detector)

    def test_every_call_site_passes_the_window(self) -> None:
        # 창을 안 넘기는 호출은 조용히 옛 휴리스틱으로 되돌아간다. 새 호출자가
        # 하나 생길 때 빠지는 것이 정확히 이 인자다.
        for path in CALL_SITES:
            source = path.read_text(encoding="utf-8")
            for call in re.findall(r"looksLikeFriendsList\([^)]*\)", source):
                with self.subTest(file=path.name, call=call):
                    self.assertIn(" in: ", call)

    def test_clock_predicate_does_not_accept_any_word_ending_in_il(self) -> None:
        # 여기서 한 건이 맞으면 "채팅 목록"으로 확정되므로, 넓은 술어는 곧 속는
        # 방법이다. isTimeLikeValue 는 제목 후보를 **버리는** 반대 질문에 쓰이는
        # 넓은 술어라 재사용하면 안 된다.
        source = SCANNER.read_text(encoding="utf-8")
        start = source.index("static func isClockLikeValue(")
        body = source[start : source.index("\n    private static let clockPatterns", start)]
        self.assertNotIn("isTimeLikeValue", body)

    def test_clock_patterns_cover_every_measured_rendering(self) -> None:
        patterns = _clock_patterns(SCANNER.read_text(encoding="utf-8"))
        self.assertTrue(patterns)

        def matches(value: str) -> bool:
            return any(re.search(pattern, value) for pattern in patterns)

        # 채팅 목록 타임스탬프 칸의 실측 표기.
        for value in ("오후 11:47", "오전 3:12", "11:47", "1월 10일", "2026년 8월 3일", "2020. 1. 20."):
            with self.subTest(accepts=value):
                self.assertTrue(matches(value))

        # 친구의 상태메시지로 흔한 것들. 하나라도 통과하면 친구 탭이 채팅 목록으로
        # 확정된다.
        for value in ("매일 행복하자", "생일", "내일 봐요", "24년 11월 06일 /21개월 1살", "일"):
            with self.subTest(rejects=value):
                self.assertFalse(matches(value))

    def test_yesterday_is_still_accepted(self) -> None:
        # 정규식으로 옮기면서 빠뜨리기 쉬운 값이고, 빠지면 하루라도 조용했던 계정의
        # 채팅 목록이 통째로 친구 목록으로 판정된다.
        source = SCANNER.read_text(encoding="utf-8")
        start = source.index("static func isClockLikeValue(")
        body = source[start : source.index("\n    private static let clockPatterns", start)]
        self.assertIn('trimmed == "어제"', body)
        self.assertIn('trimmed == "그저께"', body)

    def test_wrong_tab_is_recovered_not_just_reported(self) -> None:
        # 탐지만 하고 두면 그 상태는 GUI 에 남아 뒤이은 모든 실행이 물려받는다.
        source = CHATS_COMMAND.read_text(encoding="utf-8")
        self.assertIn("runner.pressCommandTwo()", source)
        self.assertLess(
            source.index("looksLikeFriendsList"),
            source.index("runner.pressCommandTwo()"),
        )

    def test_recovery_is_visible_without_trace_ax(self) -> None:
        # runner.log 는 --trace-ax 없이는 어디에도 안 간다. 브릿지는 그 플래그 없이
        # 도는데 이 상태의 대가는 조용한 수신 정지라, 요약 줄에 안 남기면 재발이
        # 프로덕션에서 또 안 보인다.
        source = CHATS_COMMAND.read_text(encoding="utf-8")
        self.assertIn('profiler.note("tabrecovered", "1")', source)
        self.assertLess(
            source.index('profiler.note("tabrecovered", "1")'),
            source.index("runner.pressCommandTwo()"),
        )


if __name__ == "__main__":
    unittest.main()
