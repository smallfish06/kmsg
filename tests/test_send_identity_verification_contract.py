"""발송 직전 방 신원 확인 계약.

chat id 는 표시이름 해시라 재배치되고 이름 검색은 기호뿐인 이름에서 동작하지 않는다.
즉 주소가 맞았는지는 주소로 증명할 수 없고, 그 방의 대화 내용으로만 증명할 수 있다.
이 테스트는 그 확인이 **타이핑 전에, 이미 잡은 창에서** 일어난다는 불변식을 고정한다.
"""

import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SEND_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "SendCommand.swift"
SEND_IMAGE_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "SendImageCommand.swift"
VERIFIER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatIdentityVerifier.swift"
CHAT_ANCHOR = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatAnchor.swift"


class SendIdentityVerificationContractTests(unittest.TestCase):
    def test_both_send_commands_accept_anchors(self) -> None:
        for path in (SEND_COMMAND, SEND_IMAGE_COMMAND):
            source = path.read_text(encoding="utf-8")
            with self.subTest(command=path.name):
                self.assertIn('name: .customLong("expect-anchor")', source)
                self.assertIn("var expectAnchors: [String] = []", source)
                self.assertIn('name: .customLong("expect-min")', source)

    def test_verification_runs_before_anything_is_typed(self) -> None:
        cases = (
            (SEND_COMMAND, "try sendMessageToWindow("),
            (SEND_IMAGE_COMMAND, "try sendImageToWindow("),
        )
        for path, send_call in cases:
            source = path.read_text(encoding="utf-8")
            with self.subTest(command=path.name):
                verify_at = source.find("ChatIdentityVerifier(")
                send_at = source.find(send_call)
                self.assertNotEqual(verify_at, -1, "verifier is not wired in")
                self.assertNotEqual(send_at, -1)
                self.assertLess(verify_at, send_at, "verification must precede typing")

    def test_verification_reuses_the_already_resolved_window(self) -> None:
        # 창을 다시 해석하면 확인한 방과 타이핑하는 방이 달라질 수 있다. 그 틈이
        # 이 검증이 막으려는 것 자체이므로, 확인은 resolution.window 로만 한다.
        for path in (SEND_COMMAND, SEND_IMAGE_COMMAND):
            source = path.read_text(encoding="utf-8")
            with self.subTest(command=path.name):
                verify_at = source.find("ChatIdentityVerifier(")
                self.assertIn("window: resolution.window", source[verify_at:])
                tail = source[verify_at:]
                self.assertNotIn("chatWindowResolver.resolve(", tail)

    def test_verifier_declares_both_failure_codes(self) -> None:
        source = VERIFIER.read_text(encoding="utf-8")
        # 대응이 다르다 — 전자는 바인딩을 고쳐야 하고 후자는 리더가 깨진 것이다.
        self.assertIn('static let mismatchCode = "IDENTITY_MISMATCH"', source)
        self.assertIn('static let unverifiedCode = "IDENTITY_UNVERIFIED"', source)

    def test_anchor_rules_do_not_use_the_lossy_name_normalizer(self) -> None:
        # ChatTextNormalizer.normalize 는 구두점과 기호를 통째로 버린다. 이름에 그걸
        # 적용해 '~.~' 가 빈 문자열이 된 것이 2026-08-06 1차 사고다. 메시지 본문에
        # 쓰면 서로 다른 메시지가 같아진다.
        for path in (VERIFIER, CHAT_ANCHOR):
            source = path.read_text(encoding="utf-8")
            with self.subTest(file=path.name):
                self.assertNotIn("ChatTextNormalizer.normalize(", source)
        self.assertIn("precomposedStringWithCanonicalMapping", CHAT_ANCHOR.read_text(encoding="utf-8"))

    def test_anchor_rules_ignore_anchors_that_prove_nothing(self) -> None:
        source = CHAT_ANCHOR.read_text(encoding="utf-8")
        self.assertIn("static let minimumLength = 8", source)
        self.assertIn("normalized.count >= minimumLength", source)

    def test_anchor_rules_stay_dependency_free(self) -> None:
        # tests/test_chat_anchor_matching.py 가 이 파일 하나만 컴파일해 규칙을 실제로
        # 실행한다. AX·KakaoTalk 타입이 새어 들어오면 그 실행 테스트가 죽고, 판정 규칙은
        # 다시 소스만 읽는 계약으로 후퇴한다.
        source = CHAT_ANCHOR.read_text(encoding="utf-8")
        self.assertNotIn("UIElement", source)
        self.assertNotIn("KakaoTalkApp", source)
        self.assertNotIn("AXActionRunner", source)
        self.assertEqual(
            [line for line in source.splitlines() if line.startswith("import ")],
            ["import Foundation"],
        )

    def test_no_anchors_means_no_verification(self) -> None:
        # 이 플래그를 안 쓰는 호출자(구버전 브릿지, 사람이 직접 치는 CLI)의 동작은
        # 그대로여야 한다.
        source = VERIFIER.read_text(encoding="utf-8")
        self.assertIn("guard !usable.isEmpty else { return }", source)


if __name__ == "__main__":
    unittest.main()
