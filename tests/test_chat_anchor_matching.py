"""앵커 매칭 규칙을 실제로 **실행**해서 확인한다.

소스를 읽는 계약 테스트로는 부족한 자리다. 이 규칙이 조용히 틀리면 결과가 "남의
대화로 메시지가 배달된다" 이고, 그건 로그에도 안 남는다. ChatAnchor 는 의존성이
없도록 떼어 놨으므로 파일 하나만 컴파일해 돌릴 수 있다.
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHAT_ANCHOR = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ChatAnchor.swift"

HARNESS = r"""
func check(_ label: String, _ actual: Int, _ expected: Int) {
    if actual != expected {
        print("FAIL \(label): expected \(expected), got \(actual)")
        failures += 1
    }
}
var failures = 0

let reply = "거기 진짜 맛있는데 아무도 안 믿어줌 너도 한번 가봐"
let mine = "후문에서 조금 더 올라가면 있는 작은 가게"
let transcript = [reply, "ㅇㅇ", mine, "밥은 먹었어?"]

// 정상: 두 앵커 모두 전사에 있다.
check("both anchors", ChatAnchor.matchCount(anchors: [reply, mine], inTranscriptBodies: transcript), 2)

// 남의 방: 앵커가 하나도 없다. 이게 0 이 아니면 오배송이 통과한다.
check("other room", ChatAnchor.matchCount(anchors: [reply, mine], inTranscriptBodies: ["장 봐왔어", "ㅇㅇ"]), 0)

// 잘린 앵커도 앞부분 일치로 확인된다 (서버가 길이를 잘라 보낼 수 있다).
check("truncated anchor", ChatAnchor.matchCount(anchors: [String(reply.prefix(12))], inTranscriptBodies: transcript), 1)

// 짧은 맞장구는 어느 방에나 있어서 증거가 아니다.
check("short anchor ignored", ChatAnchor.matchCount(anchors: ["ㅇㅇ"], inTranscriptBodies: transcript), 0)
check("short anchor usable", ChatAnchor.usable(["ㅇㅇ", "응 ㅋㅋ"]).count, 0)

// 같은 앵커를 여러 번 넘겨도 한 번만 센다 — 안 그러면 expect-min 2 가 공짜로 통과한다.
check("dedupe", ChatAnchor.matchCount(anchors: [reply, reply], inTranscriptBodies: transcript), 1)

// 자모 분리형(AX 가 이렇게 돌려줄 수 있다)과 조합형은 같게 본다.
let decomposed = reply.decomposedStringWithCanonicalMapping
check("NFD transcript", ChatAnchor.matchCount(anchors: [reply], inTranscriptBodies: [decomposed]), 1)
check("NFD anchor", ChatAnchor.matchCount(anchors: [decomposed], inTranscriptBodies: [reply]), 1)

// 줄바꿈과 연속 공백 차이는 무시한다.
check("whitespace", ChatAnchor.matchCount(anchors: ["후문에서 조금 더 올라가면"], inTranscriptBodies: ["후문에서  조금\n더 올라가면 있는 작은 가게"]), 1)

// 기호뿐인 본문도 살아남아야 한다 — 이걸 깎아내는 정규화가 2026-08-06 1차 사고였다.
check("symbol body kept", ChatAnchor.normalize("~.~ -.--..-").isEmpty ? 1 : 0, 0)

// 앞부분이 겹쳐도 더 긴 다른 메시지는 앵커를 만족시키지 않는다.
check("prefix direction", ChatAnchor.matchCount(anchors: [reply], inTranscriptBodies: [String(reply.prefix(12))]), 0)

if failures == 0 { print("OK") }
"""


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ChatAnchorMatchingTests(unittest.TestCase):
    def test_anchor_matching_rules(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / "main.swift"
            main.write_text(HARNESS, encoding="utf-8")
            binary = Path(tmp) / "anchorcheck"
            build = subprocess.run(
                ["swiftc", "-O", str(CHAT_ANCHOR), str(main), "-o", str(binary)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.strip(), "OK", run.stdout)


if __name__ == "__main__":
    unittest.main()
