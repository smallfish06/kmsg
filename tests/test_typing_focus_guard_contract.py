"""글자 키 이벤트는 텍스트 입력 요소가 키 포커스를 쥐고 있을 때만 친다는 계약.

kmsg 는 글자를 CGEvent(HID)로 친다. HID 키는 "kmsg 가 치려던 요소"가 아니라 **그 순간 키
포커스를 쥔 것**으로 간다. 그게 표(NSTableView)면 AppKit 의 타입 셀렉트가 글자마다 표를 훑으며
행 뷰를 만든다.

talkfriend local-mac-1(대화 1,900여 개) 2026-11-12 22:10~23:00, 11-13 01:50~05:10 KST: 카카오톡
AX 응답이 3~6배 느려져 read 17개 방이 실패했다. 22:12 의 macOS cpu_resource 리포트에서 카카오톡
메인 스레드의 가장 무거운 스택이 `-[NSTableView keyDown:] → _typeSelectInterpretKeyEvent: →
_performTypeSelect: → rowViewAtRow:createIfNeeded:` 였다. 어느 폴백이 쳤는지는 확정하지 못했다 —
그래서 가드는 호출부가 아니라 글자 키가 나가는 한 곳(AXActionRunner)에 두고, 막을 때마다 요약
줄에 `type.blocked=<역할>` 을 남겨 운영 로그가 답하게 한다.

로컬 확인(2026-11-13, 개인 카톡, 나와의 채팅 — 메시지는 한 통도 보내지 않았다):
  - `KMSG_DEBUG_TYPING=typed-draft` 로 입력창 타이핑 폴백을 태우면 가드를 통과하고 글자가
    입력창에 그대로 들어간다(보내지 않고 지움). 이름 검색의 검색어 타이핑도 통과한다
    (`search field input: typing reflected on attempt 1`).
  - 방 창의 **전사 표에 키 포커스를 둔 채** `KMSG_DEBUG_TYPING=forced`(입력창을 못 찾은 발송
    경로): `FORCED_TYPING_FAILED`, 요약 줄 `type.blocked=AXTable`, 키 0, 방에 새 메시지 0.
    종전 코드는 이 상태에서 본문을 표에 치고(타입 셀렉트) Enter 까지 누른 뒤 "✓ sent" 로 보고한다.
  - 같은 경로를 **다른 앱이 앞에 있을 때** 태우면 `type.blocked=otherapp`. activate() 는 요청일
    뿐이라 다른 앱이 활성일 때 무시될 수 있고, 카카오톡은 그동안에도 자기 포커스 창·포커스
    요소를 그대로 답한다 — 종전 코드는 메시지와 Enter 를 그 앞의 앱에 친다. (그 시험 전후로 이
    맥에서 앞에 있던 앱은 Claude 데스크톱과, 운영 브릿지 맥에 붙은 화면 공유였다.)
  - `kmsg inspect --focus` 는 채팅 목록 표·전사 표에 포커스가 있을 때 둘 다
    `type.blocked=AXTable` 로 판정했다. 채팅 목록 표에 포커스를 둔 채 도는 실제 타이핑 경로는
    만들지 못했다(검색 경로는 검색 버튼을 누르는 순간 검색창이 포커스를 가져간다).
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources" / "kmsg"
GUARD = SOURCES / "Accessibility" / "TypingFocusGuard.swift"
PROFILER = SOURCES / "Accessibility" / "PhaseProfiler.swift"
RUNNER = SOURCES / "Accessibility" / "AXActionRunner.swift"
SEND = SOURCES / "Commands" / "SendCommand.swift"
CONTACT = SOURCES / "KakaoTalk" / "KakaoContactAutomation.swift"

MAIN = '''
import Foundation

struct Case: Decodable {
    let name: String
    let readable: Bool
    let role: String?
    let subrole: String?
    let expected: Bool?
    let otherApp: Bool
}

let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
var out: [String: String] = [:]
for item in cases {
    let verdict = TypingFocusGuard.verdict(for: TypingFocusGuard.Observation(
        focusReadable: item.readable,
        role: item.role,
        subrole: item.subrole,
        isExpectedElement: item.expected,
        focusInOtherApp: item.otherApp
    ))
    switch verdict {
    case .allow: out[item.name] = "allow"
    case .block(let token): out[item.name] = "block:" + token
    }
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]))

// The refusal has to sit ahead of the long res.* notes on the summary line.
let profiler = PhaseProfiler(command: "read")
profiler.begin("resolve")
profiler.note("res.rows", "500")
profiler.note("res.list", "8.15")
profiler.noteFirst("type.blocked", "AXTable")
profiler.note("close.via", "button")
profiler.emitSummary(status: "fail")
'''


def _case(name, role=None, subrole=None, readable=True, expected=None, other_app=False):
    return {"name": name, "readable": readable, "role": role, "subrole": subrole,
            "expected": expected, "otherApp": other_app}


def _body(source: str, start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker)
    return source[start : source.index(end_marker, start)]


class TypingFocusVerdictTests(unittest.TestCase):
    """판정 파일을 실제로 컴파일해 돌린다."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        main = folder / "main.swift"
        main.write_text(MAIN, encoding="utf-8")
        cls.binary = folder / "typing-focus-test"
        # Same SDK discovery as test_phase_profiler.py.
        sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                 check=True, capture_output=True, text=True)
            sdk_args = ["-sdk", sdk.stdout.strip()]
        build = subprocess.run(["swiftc", *sdk_args, str(GUARD), str(PROFILER), str(main), "-o", str(cls.binary)],
                               capture_output=True, text=True)
        if build.returncode:
            raise RuntimeError(f"Typing focus harness compilation failed:\n{build.stdout}{build.stderr}")

    def run_harness(self, cases):
        return subprocess.run([str(self.binary)], input=json.dumps(cases), check=True,
                              capture_output=True, text=True)

    def verdicts(self, cases):
        return json.loads(self.run_harness(cases).stdout)

    def test_the_refusal_leads_the_summary_notes(self) -> None:
        summary = [line for line in self.run_harness([]).stderr.splitlines() if " total=" in line]
        self.assertEqual(len(summary), 1, summary)
        self.assertRegex(
            summary[0],
            r"^\[kmsg\] read total=\d+\.\d\d status=fail resolve=\d+\.\d\d "
            r"type\.blocked=AXTable res\.rows=500 res\.list=8\.15 close\.via=button$",
        )

    def test_text_inputs_may_be_typed_into(self) -> None:
        got = self.verdicts([
            _case("field", "AXTextField"),
            _case("area", "AXTextArea"),
            _case("search-role", "AXSearchField"),
            _case("combo", "AXComboBox"),
            _case("search-subrole", "AXGroup", subrole="AXSearchField"),
            _case("the-target", "AXTextArea", expected=True),
        ])
        self.assertEqual(set(got.values()), {"allow"}, got)

    def test_a_table_holding_focus_is_never_typed_into(self) -> None:
        # The incident: character keys reached an NSTableView.
        got = self.verdicts([
            _case("table", "AXTable"),
            _case("outline", "AXOutline"),
            _case("row", "AXRow"),
            _case("cell", "AXCell"),
            _case("scroll", "AXScrollArea"),
            _case("window", "AXWindow"),
            _case("button", "AXButton"),
            # The table has focus even though the caller holds a text field it
            # believes it focused: the role decides before identity does.
            _case("table-not-target", "AXTable", expected=False),
        ])
        self.assertEqual(got["table"], "block:AXTable")
        self.assertEqual(got["table-not-target"], "block:AXTable")
        for name, verdict in got.items():
            self.assertTrue(verdict.startswith("block:AX"), (name, verdict))

    def test_another_text_input_is_not_the_target(self) -> None:
        got = self.verdicts([
            _case("search-instead-of-composer", "AXTextField", expected=False),
            _case("no-target-given", "AXTextField", expected=None),
        ])
        self.assertEqual(got["search-instead-of-composer"], "block:AXTextField/other")
        self.assertEqual(got["no-target-given"], "allow")

    def test_unknown_focus_is_refused(self) -> None:
        got = self.verdicts([
            _case("unreadable", readable=False),
            _case("no-role", role=None),
        ])
        self.assertEqual(got["unreadable"], "block:nofocus")
        self.assertEqual(got["no-role"], "block:norole")

    def test_focus_in_another_app_wins_over_everything(self) -> None:
        # KakaoTalk keeps reporting its own composer as focused while another
        # app is frontmost; the keys would go to that other app.
        got = self.verdicts([
            _case("composer-behind", "AXTextArea", expected=True, other_app=True),
            _case("unreadable-behind", readable=False, other_app=True),
        ])
        self.assertEqual(got["composer-behind"], "block:otherapp")
        self.assertEqual(got["unreadable-behind"], "block:otherapp")

    def test_the_token_stays_one_summary_field(self) -> None:
        got = self.verdicts([_case("odd", "AX Weird=Role")])
        self.assertEqual(got["odd"], "block:AXWeirdRole")


class TypingFocusGuardContract(unittest.TestCase):
    def setUp(self) -> None:
        self.runner = RUNNER.read_text(encoding="utf-8")

    def test_character_keys_are_posted_from_one_place(self) -> None:
        for path in SOURCES.rglob("*.swift"):
            if path == RUNNER:
                continue
            self.assertNotIn("keyboardSetUnicodeString", path.read_text(encoding="utf-8"), path.name)
        self.assertEqual(self.runner.count("keyboardSetUnicodeString"), 1)
        self.assertIn("    private func typeText(_ text: String, perCharacterDelay: TimeInterval) {", self.runner)

    def test_typing_is_gated_on_the_focused_element(self) -> None:
        # typeText has exactly two callers: the guarded one and the login one.
        self.assertEqual(self.runner.count("typeText(text, perCharacterDelay: perCharacterDelay)"), 2)
        guarded = _body(self.runner, "    func typeTextGuarded(", "\n    /// Read-only view")
        gate = guarded.index("guard typingAllowed(into: target, label: label) else { return false }")
        self.assertLess(gate, guarded.index("typeText(text, perCharacterDelay: perCharacterDelay)"))

        allowed = _body(self.runner, "    private func typingAllowed(", "\n    private func observeTypingFocus(")
        self.assertIn("TypingFocusGuard.verdict(for: observeTypingFocus(target))", allowed)
        self.assertIn("typingBlocks.report(token)", allowed)
        self.assertIn("return false", allowed)

        observe = _body(self.runner, "    private func observeTypingFocus(", "\n    /// The focused element is the target")
        # KakaoTalk's own focused element, plus whether KakaoTalk is in front at all.
        self.assertIn("app.focusedUIElement", observe)
        self.assertIn("kAXFrontmostAttribute", observe)
        self.assertIn("isExpectedElement = Self.isSameOrInside(focused, expected)", observe)
        # NSWorkspace.frontmostApplication goes stale in a process with no run loop.
        self.assertNotIn("NSWorkspace", observe)

    def test_verified_typing_goes_through_the_guard_and_fails_when_refused(self) -> None:
        verified = _body(self.runner, "    func typeTextWithVerification(", "\n    @discardableResult\n    func pressEnterWithVerification(")
        self.assertIn("let target: TypingTarget = element.map { .element($0) } ?? .focusedTextInput", verified)
        refusal = verified.index("guard typeTextGuarded(text, into: target, label: label, perCharacterDelay: perCharacterDelay) else {")
        self.assertIn("return false", verified[refusal : refusal + 200])
        # Without a target the old code returned true unconditionally; the
        # refusal has to come first.
        self.assertLess(refusal, verified.index('log("\\(label): typed without verification target")'))

    def test_unguarded_typing_is_only_for_the_login_screen(self) -> None:
        callers = []
        for path in SOURCES.rglob("*.swift"):
            source = path.read_text(encoding="utf-8")
            if "runner.typeTextDirect(" in source:
                callers.append(path.relative_to(SOURCES).parts[0])
        self.assertEqual(set(callers), {"Auth"})

    def test_blind_send_does_not_press_enter_after_a_refusal(self) -> None:
        send = SEND.read_text(encoding="utf-8")
        forced = _body(send, "    private func forceTypeIntoChatWindow(", "\n    private func tryRaiseWindow(")
        typed = forced.index('guard runner.typeTextGuarded(message, into: .focusedTextInput, label: "forced typing") else {')
        enter = forced.index("runner.pressEnterKey()")
        self.assertLess(typed, enter)
        self.assertIn("return false", forced[typed:enter])
        self.assertNotIn("typeTextWithVerification(message, on: nil", send)

    def test_contact_form_typing_is_guarded(self) -> None:
        contact = CONTACT.read_text(encoding="utf-8")
        self.assertIn("guard runner.typeTextGuarded(text, into: .focusedTextInput, label: label) else {", contact)

    def test_a_refusal_reaches_the_summary_line(self) -> None:
        self.assertIn('typingBlocks.install { note("type.blocked", $0) }', self.runner)
        # noteFirst: the bridge relays only the first 500 characters of a summary
        # line, and a read's res.* notes alone can fill that.
        wire = "runner.reportTypingBlocks { key, value in profiler.noteFirst(key, value) }"
        expected = {
            "SendCommand.swift": 1,
            "SendImageCommand.swift": 1,
            "ReadCommand.swift": 1,
            "FriendCommand.swift": 2,
            "ChatsCommand.swift": 1,
        }
        for name, count in expected.items():
            source = (SOURCES / "Commands" / name).read_text(encoding="utf-8")
            self.assertEqual(source.count(wire), count, name)
        # Every command that prints a summary line and types is wired.
        for path in (SOURCES / "Commands").glob("*.swift"):
            source = path.read_text(encoding="utf-8")
            if "PhaseProfiler(command:" in source and "AXActionRunner(traceEnabled:" in source:
                self.assertIn(wire, source, path.name)
        # A command with no summary line still says so on stderr.
        reporter = _body(self.runner, "final class TypingBlockReporter {", "\nstruct AXActionRunner {")
        self.assertIn('"[kmsg] type.blocked=\\(token)\\n"', reporter)

    def test_debug_typing_switches_do_not_exist_in_release_builds(self) -> None:
        hook = _body(self.runner, "enum DebugTypingHook {", "\n/// Where a run of character keys")
        self.assertRegex(hook, r"#if DEBUG\s+return ProcessInfo\.processInfo\.environment\[\"KMSG_DEBUG_TYPING\"\] == name\s+#else\s+return false\s+#endif")
        for path in SOURCES.rglob("*.swift"):
            source = path.read_text(encoding="utf-8")
            if path != RUNNER:
                self.assertNotIn("KMSG_DEBUG_TYPING", source, path.name)


if __name__ == "__main__":
    unittest.main()
