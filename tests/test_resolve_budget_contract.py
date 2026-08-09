"""방을 못 찾는 해석이 무한정 비싸지지 않게 하는 계약.

`resolve(chatID:)` 는 미스일 때 사다리를 끝까지 내려간다 — 제목 훑기 → 레지스트리
스캔 → 이름 검색. talkfriend 프로덕션 실측(2026-08-09 최희연): 그 한 번이
`resolve=18.53` 을 쓰고 **결국 실패했다**. 같은 15분 구간의 정상 분포는
p50 0.34s / p90 0.91s 였다.

비용은 시간만이 아니다. 브릿지는 계정당 단일 outbound lock 으로 발송을 직렬화하므로,
한 방의 18초짜리 헛수고가 그 계정의 모든 답장을 18초 뒤로 민다. 18초 걸려 실패하는
것보다 빨리 실패하는 게 낫다 — 다음 tick 이 어차피 다시 집어간다.

내역은 추측하지 않는다. 브릿지는 `--trace-ax` 없이 돌아서 runner.log 가 안 보이므로,
요약 줄에 res.list / res.search 를 실어 프로덕션이 직접 답하게 한다. 이 계측이 붙자마자
첫 실측에서 `res.list=33.02` 가 나왔다 — 비싼 쪽이 검색이 아니라 목록일 수 있다는 뜻이고,
그건 계측 전의 추정과 반대였다.
"""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RESOLVER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatWindowResolver.swift"
READ_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ReadCommand.swift"
SEND_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "SendCommand.swift"


def _open_chat_list_row_body(source: str) -> str:
    start = source.index("    private func openChatListRow(")
    return source[start : source.index("\n    private func openMatchedRow(", start)]


class ResolveBudgetContractTests(unittest.TestCase):
    def test_budget_is_overridable_without_a_rebuild(self) -> None:
        # 브릿지가 kmsg 를 spawn 하므로 bridge.env 의 값이 그대로 상속된다 —
        # 조이거나 푸는 데 브릿지 코드 변경이 필요 없어야 한다.
        source = RESOLVER.read_text(encoding="utf-8")
        self.assertIn('environment["KMSG_RESOLVE_BUDGET_MS"]', source)

    def test_registry_scan_does_not_re_climb_what_the_title_scan_already_walked(self) -> None:
        # 종전에는 제목으로 200행을 훑은 뒤 20 → 60 → 200 으로 다시 올라갔다. 20/60 은
        # 정의상 그 200행 안에 있으므로 같은 행을 세 번 더 걷는 것뿐이다. 사다리가 벌어주는
        # "위에서 일찍 맞으면 싸다"는 이미 제목 경로가 가져갔다.
        body = _open_chat_list_row_body(RESOLVER.read_text(encoding="utf-8"))
        self.assertIn("for horizon in [titleScanHorizon]", body)
        self.assertNotIn("[20, 60, 200]", body)

    def test_both_scans_share_one_horizon(self) -> None:
        # 두 값이 갈리면 뒤엣것이 앞엣것이 이미 본 행을 다시 걷거나, 앞엣것이 본 행을
        # 뒤엣것이 못 본다.
        source = RESOLVER.read_text(encoding="utf-8")
        self.assertIn("private static let chatListResolveHorizon = 200", source)
        body = _open_chat_list_row_body(source)
        self.assertIn("limit: titleScanHorizon", body)

    def test_budget_is_checked_between_every_blocking_scan(self) -> None:
        # 스캔 한 번은 통째로 블로킹이라 중간에 못 끊는다. 끊을 수 있는 자리는 스캔과
        # 스캔 사이뿐이므로, 그 자리를 하나도 빠뜨리면 안 된다.
        source = RESOLVER.read_text(encoding="utf-8")
        for step in [
            "the chat list title scan",
            "the registry scan",
            "the search fallback",
            "the Enter-commit retry",
            "opening the matched search result",
        ]:
            self.assertIn(f'deadline.describe("{step}")', source, step)

    def test_resolve_split_reaches_the_summary_line(self) -> None:
        # runner.log 는 --trace-ax 없이는 안 보이고 브릿지는 그 플래그 없이 돈다.
        # 요약 줄이 프로덕션에서 내역을 답하는 유일한 창구다.
        source = RESOLVER.read_text(encoding="utf-8")
        self.assertIn('noteSeconds("res.list"', source)
        self.assertIn('noteSeconds("res.search"', source)
        for command in (READ_COMMAND, SEND_COMMAND):
            self.assertIn(
                "note: { key, value in profiler.note(key, value) }",
                command.read_text(encoding="utf-8"),
                command.name,
            )

    def test_search_timing_is_recorded_on_failure_too(self) -> None:
        # 성공만 기록하면 "실패가 왜 오래 걸렸나"에 답하지 못한다 — 그게 정확히
        # 이 계측이 필요했던 질문이다.
        source = RESOLVER.read_text(encoding="utf-8")
        start = source.index("private func searchStep(")
        body = source[start : source.index("\n    func resolve(chatID:", start)]
        self.assertIn("rethrows", body)
        self.assertIn('defer { noteSeconds("res.search"', body)


if __name__ == "__main__":
    unittest.main()
