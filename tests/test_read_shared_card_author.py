"""Run the actual sender evidence, metadata, and segment functions against AX fixtures.

Fixtures model tree ancestry and screen geometry; no historical raw AX captures
were retained, so these are regression cases, not a claim of live UI coverage.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT / "Sources/kmsg/KakaoTalk/TranscriptReader.swift"
EVIDENCE = ROOT / "Sources/kmsg/KakaoTalk/TranscriptAuthorEvidence.swift"

HARNESS = r'''
func check(_ label: String, _ passed: Bool) {
    if !passed { fatalError("FAIL: \(label)") }
}
let parser = Parser()
let bubble = CGRect(x: 80, y: 120, width: 240, height: 160)
let sender = CGRect(x: 80, y: 96, width: 60, height: 18)
let title = CGRect(x: 90, y: 148, width: 160, height: 20)
func eligible(_ frame: CGRect?, direct: Bool = true, inside: Bool = false,
              rich: Bool = true, content: [CGRect] = [bubble]) -> Bool {
    TranscriptAuthorEvidence.isSenderLabel(labelFrame: frame, contentFrames: content,
        isDirectMetadata: direct, isInsideContent: inside, hasRichContent: rich)
}
check("real sender above rich card", eligible(sender))
check("two pixel AX rounding allowance", eligible(CGRect(x: 80, y: 104, width: 60, height: 18)))
check("overlapping card text rejected", !eligible(CGRect(x: 80, y: 105, width: 60, height: 18)))
check("same-height label is content", !eligible(CGRect(x: 80, y: 120, width: 60, height: 18)))
check("missing label frame on measured rich card", !eligible(nil))
check("missing card frame with measured label", !eligible(sender, content: []))
check("nested real sender above content", eligible(sender, direct: false))
check("sibling card title is not sender", !eligible(title))
check("nested card title even with bad geometry", !eligible(sender, direct: false, inside: true))
check("offscreen descendant remains content", !eligible(nil, direct: false, inside: true, content: []))
check("unknown card sibling is not author", !eligible(nil, content: []))
check("offscreen plain direct name survives", eligible(nil, rich: false, content: []))
check("zero sized rich content is not evidence", !eligible(nil, content: [.zero]))
check("nested unmeasured name not guessed", !eligible(nil, direct: false, rich: false, content: []))
check("plain text body sibling is not sender", !eligible(title, rich: false))
check("title above a later text but inside card", !eligible(title, content: [CGRect(x: 80, y: 180, width: 200, height: 40), bubble]))

func metadata(_ title: String, withSender: String? = nil) -> RowMetadata {
    // Feed the actual metadata parser all tokens, while only the name's AX
    // position qualifies as sender evidence. A title can even equal a name.
    let tokens = [title, withSender, "오후 1:59", "수정됨", "1"].compactMap { $0 }
    let authors = eligible(sender) ? [withSender].compactMap { $0 } : []
    return parser.parseRowMetadata(tokens: tokens, authorTokens: authors)
}
check("video title rejected, time preserved", metadata("새 영상 제목").author == nil && metadata("새 영상 제목").timeRaw == "오후 1:59")
check("product title rejected", metadata("새 상품").author == nil)
check("sender on rich card retained", metadata("새 영상 제목", withSender: "하늘").author == "하늘")
check("name-like title rejected", metadata("민지").author == nil)
check("status never author", parser.parseRowMetadata(tokens: ["수정됨"], authorTokens: ["수정됨"]).author == nil)

func row(_ name: String?, _ side: MessageSide = .left, _ system: Bool = false) -> RowAnalysis {
    RowAnalysis(bodyCandidate: nil, explicitAuthor: name, timeRaw: "오후 1:59",
        side: side, rowFrame: nil, imageFrames: [], linkCount: 1,
        attachmentCount: 0, isSystemLikeRow: system, axHelpDate: nil)
}
let cardAuthor = metadata("영상 카드 제목").author
let sequence = parser.segment([row("하늘"), row(cardAuthor), row(nil), row(nil)])
check("card cannot poison author of later text", sequence.map { $0.author } == ["하늘", "하늘", "하늘", "하늘"])
check("known left card keeps chain source", sequence[1].source == "left-chain")
let group = parser.segment([row("하늘"), row(nil), row("민지"), row(nil), row("민지"), row(nil)])
check("genuine repeated group authors survive", group.map { $0.author } == ["하늘", "하늘", "민지", "민지", "민지", "민지"])
let outgoing = parser.segment([row("하늘"), row("unexpected card title", .right), row(nil)])
check("right side beats explicit metadata", outgoing[1].author == nil && outgoing[1].source == "default-me")
check("outgoing ends left run", outgoing[2].source == "left-unresolved")
let unknown = parser.segment([row("하늘"), row(cardAuthor, .unknown), row(nil)])
check("unknown card not attributed", unknown[1].author == nil && unknown[1].source == "unattributed")
check("unknown card never poisons existing anchor", unknown[2].author == "하늘")
let unknownName = parser.segment([row("하늘", .unknown), row(nil)])
check("validated offscreen name anchors later measured left", unknownName[1].author == "하늘")
let noAnchor = parser.segment([row(cardAuthor), row(nil)])
check("unanchored shared row does not invent peer", noAnchor.allSatisfy { $0.source == "left-unresolved" })
let separator = parser.segment([row("하늘"), row(nil, .unknown, true), row(nil)])
check("system boundary resets anchor", separator[2].source == "left-unresolved")
print("OK: shared-card metadata and segment fixtures")
'''


def extracted_harness():
    source = READER.read_text()
    def section(start, end):
        return source[source.index(start):source.index(end, source.index(start))]
    metadata = section("    private func parseRowMetadata", "    private func isLikelyAttachmentButtonTitle")
    segment = section("    private func resolveAuthorInSegment", "    private func logicalTimestamp")
    # Exact production anchor update block, followed by actual resolver.
    anchor = section("            let side = analysis.side", "            let bodyCandidate = analysis.bodyCandidate")
    dedup = section("    private func deduplicatePreservingOrder", "    private func deduplicateBodyCandidates")
    types = section("private struct RowMetadata", "private final class FrameCache")
    wrapper = '''
    func segment(_ rows: [RowAnalysis]) -> [(author: String?, source: String)] {
        var leftAnchorAuthor: String?
        var leftAnchorTimeRaw: String?
        return rows.map { analysis in
    ''' + anchor + '''
            return resolveAuthorInSegment(analysis: analysis, leftAnchorAuthor: leftAnchorAuthor,
                                          leftAnchorTimeRaw: leftAnchorTimeRaw)
        }
    }
    '''
    return ("import Foundation\nimport CoreGraphics\n" + types + "\nstruct Parser {\n" + metadata + segment + dedup + wrapper + "\n}\n" + HARNESS).replace("private ", "")


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ReadSharedCardAuthorTests(unittest.TestCase):
    def test_executable_fixtures(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / "main.swift"
            main.write_text(extracted_harness())
            binary = Path(tmp) / "authorcheck"
            sdk_args = []
            if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
                sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True)
                if sdk.returncode == 0:
                    sdk_args = ["-sdk", sdk.stdout.strip()]
            build = subprocess.run(["swiftc", *sdk_args, str(EVIDENCE), str(main), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("OK:", run.stdout)

    def test_ax_adapter_and_fallback_use_evidence(self):
        source = READER.read_text()
        self.assertIn("[kAXLinkRole, kAXTextAreaRole, kAXButtonRole, kAXImageRole]", source)
        self.assertIn("insideContent || !reachedContainer", source)
        self.assertIn("authorTokens: authorTokensBuffer", source)
        self.assertIn("$0.width > 72 || $0.height > 72", source)
        self.assertIn("return frame.width > 72 || frame.height > 72", source)
        fallback = source.split("private func extractRowMetadata", 1)[1].split("private func isSenderLabel", 1)[0]
        self.assertIn("analyzeRow(row, transcriptRoot: transcriptRoot", fallback)
        self.assertNotIn("findAll", fallback)
        self.assertIn("MessageBodyCandidate(body: title, frame: link.frame)", source)
        self.assertIn("hasUnmeasuredLink ? .unknown", source)
        self.assertNotIn("body: linkOnlyText, frame: container.frame", source)


if __name__ == "__main__":
    unittest.main()
