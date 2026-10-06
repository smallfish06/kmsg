"""Execute production chat-row classification without Accessibility or KakaoTalk.

The scanner's pure methods are compiled verbatim. Only AX role constants and
the already-collected row data are supplied by the fixture. In particular,
neither the timestamp predicates nor title/preview selection are reimplemented.
"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_auth_ack_structure_scope import block, swiftc_command


ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "Sources/kmsg/KakaoTalk/ChatListScanner.swift"


def production_block(source, signature):
    return block(source, source.index(signature))


def program(source):
    normalizer = production_block(source, "enum ChatTextNormalizer {")
    members = "\n\n".join(production_block(source, signature) for signature in (
        "private struct RowTextNode {",
        "private struct RowContent {",
        "private func extractTitle(from",
        "private func extractTitleCandidate(from",
        "private func extractPreview(from",
        "private func extractUnread(from",
        "private func titleCandidate(",
        "private func previewCandidate(",
        "private func normalizedText(",
    ))
    return STUBS + normalizer + "\nstruct ScannerFixture {\n" + members + ADAPTER


STUBS = r'''
import Foundation
let kAXStaticTextRole = "AXStaticText", kAXTextAreaRole = "AXTextArea"
let kAXRowRole = "AXRow", kAXCellRole = "AXCell", kAXGroupRole = "AXGroup"
let kAXListRole = "AXList", kAXTableRole = "AXTable", kAXOutlineRole = "AXOutline"
struct ChatListTitleObservation {}
struct Fixture: Decodable {
    let name: String?
    let clock: String
    let preview: String
    let badge: Int
    let clockFirst: Bool
    let rowTitle: Bool
}
struct Observation: Encodable {
    let title: String
    let preview: String?
    let unread: Int?
    let nameIsTime: Bool?
    let clockIsTime: Bool
}
'''


ADAPTER = r'''
    func observe(_ fixture: Fixture) -> Observation {
        let clock = RowTextNode(role: kAXStaticTextRole, value: fixture.clock, title: nil, identifier: nil)
        var nodes: [RowTextNode] = []
        if fixture.clockFirst { nodes.append(clock) }
        if let name = fixture.name, !fixture.rowTitle {
            nodes.append(RowTextNode(role: kAXStaticTextRole, value: name, title: nil, identifier: nil))
        }
        nodes.append(RowTextNode(role: kAXStaticTextRole, value: String(fixture.badge), title: nil, identifier: "Count Label"))
        if !fixture.clockFirst { nodes.append(clock) }
        nodes.append(RowTextNode(role: kAXTextAreaRole, value: fixture.preview, title: nil, identifier: nil))
        let content = RowContent(
            rowRole: kAXRowRole, rowValue: nil,
            rowTitle: fixture.rowTitle ? fixture.name : nil, rowIdentifier: nil,
            textNodes: nodes, sawClockText: true, nodesVisited: nodes.count + 1,
            titleObservation: ChatListTitleObservation()
        )
        let title = extractTitle(from: content)
        return Observation(
            title: title, preview: extractPreview(from: content, title: title), unread: extractUnread(from: content),
            nameIsTime: fixture.name.map(ChatTextNormalizer.isTimeLikeValue),
            clockIsTime: ChatTextNormalizer.isTimeLikeValue(fixture.clock)
        )
    }
}
let input = FileHandle.standardInput.readDataToEndOfFile()
let fixtures = try JSONDecoder().decode([Fixture].self, from: input)
let observations = fixtures.map { ScannerFixture().observe($0) }
print(String(decoding: try JSONEncoder().encode(observations), as: UTF8.self))
'''


def fixture(name, clock="오후 5:05", preview="123456", badge=1,
            clock_first=False, row_title=False):
    return dict(name=name, clock=clock, preview=preview, badge=badge,
                clockFirst=clock_first, rowTitle=row_title)


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc unavailable")
class ChatTitleTimestampTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="kmsg-title-timestamps-")
        cls.addClassCleanup(cls.temp.cleanup)
        main = Path(cls.temp.name) / "main.swift"
        main.write_text(program(SCANNER.read_text(encoding="utf-8")), encoding="utf-8")
        cls.binary = Path(cls.temp.name) / "title-check"
        built = subprocess.run([*swiftc_command(), str(main), "-o", str(cls.binary)],
                               capture_output=True, text=True)
        if built.returncode:
            raise AssertionError(built.stderr)

    def observe(self, fixtures):
        result = subprocess.run([str(self.binary)], input=json.dumps(fixtures, ensure_ascii=False),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_names_ending_in_il_remain_titles(self):
        names = ["홍길일", "김성일", "김철일", "금요일", "생일", "매일", "내일", "기념일", "일"]
        for row_title in (False, True):
            observed = self.observe([fixture(name, row_title=row_title) for name in names])
            for name, result in zip(names, observed):
                with self.subTest(name=name, row_title=row_title):
                    self.assertFalse(result["nameIsTime"], result)
                    self.assertEqual(result["title"], name)

    def test_actual_timestamps_cannot_become_titles(self):
        clocks = ["오후 5:05", "오후 8:45", "오전 3:12", "오후11:47", "11:47",
                  "어제", "그저께", "1월 10일", "2026년 8월 3일", "2020. 1. 20.", "  오후 5:05  "]
        observed = self.observe([fixture("테스트 친구", clock=clock, clock_first=True) for clock in clocks])
        for clock, result in zip(clocks, observed):
            with self.subTest(clock=clock):
                self.assertTrue(result["clockIsTime"], result)
                self.assertEqual(result["title"], "테스트 친구")

    def test_timestamp_without_a_name_is_unknown(self):
        rows = [fixture(None, clock="오후 5:05"), fixture("오후 8:45", row_title=True)]
        for result in self.observe(rows):
            with self.subTest(result=result):
                self.assertEqual(result["title"], "(Unknown Chat)")
                self.assertEqual(result["preview"], "123456")

    def test_connect_codes_and_badges_survive_title_classification(self):
        rows = [fixture("홍길일", clock="오후 5:05", preview="123456"),
                fixture("김성일", clock="오후 8:45", preview="654321", badge=2),
                fixture("김철일", clock="오후 11:40", preview="001234", clock_first=True)]
        for row, result in zip(rows, self.observe(rows)):
            with self.subTest(name=row["name"]):
                self.assertEqual(result["title"], row["name"])
                self.assertEqual(result["preview"], row["preview"])
                self.assertEqual(result["unread"], row["badge"])

    def test_ordinary_and_symbol_names_still_work(self):
        names = ["홍길동", "미라(2913)", "~.~", "🙂"]
        for name, result in zip(names, self.observe([fixture(name) for name in names])):
            with self.subTest(name=name):
                self.assertEqual(result["title"], name)
                self.assertEqual(result["preview"], "123456")


if __name__ == "__main__":
    unittest.main()
