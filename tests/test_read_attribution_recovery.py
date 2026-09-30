"""Execute the production extraction/recovery path with deterministic AX snapshots.

These fixtures cover scheduling and snapshot acceptance, not live Kakao rendering.
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
RECOVERY = ROOT / "Sources/kmsg/KakaoTalk/TranscriptAttributionRecovery.swift"

STUBS = r'''
import Foundation
import CoreGraphics
struct UIElement { let children = [1]; var frame: CGRect? = CGRect(x: 0, y: 0, width: 100, height: 500) }
enum MessageSide { case left, right, unknown }
final class FrameCache {}
struct Runner { func log(_ value: String) {} }
struct TranscriptMessage: Equatable {
    let author: String?
    let authorSource: String?
    var authorUnresolvedReason: String? = "missing-frame"
    let body: String
    let date: String? = "2026-09-30"
    let imageCount = 0, linkCount = 0, attachmentCount = 0
    let isSystem = false
}
final class Parser {
    let runner = Runner()
    var snapshots: [[TranscriptMessage]]
    var parses = 0, fallbacks = 0
    var caches: [FrameCache] = []
    init(_ snapshots: [[TranscriptMessage]]) { self.snapshots = snapshots }
    func parseMessages(from: [UIElement], transcriptRoot: UIElement, limit: Int,
                       includeSystemMessages: Bool, referenceDate: Date,
                       frameCache: FrameCache) -> [TranscriptMessage] {
        caches.append(frameCache); parses += 1
        precondition(!snapshots.isEmpty, "unbounded native retry")
        return snapshots.removeFirst()
    }
    func extractFallbackMessages(from: UIElement, limit: Int, referenceDate: Date) -> [TranscriptMessage] {
        fallbacks += 1; return []
    }
    func deduplicateMessagesPreservingOrder(_ messages: [TranscriptMessage]) -> [TranscriptMessage] { messages }
'''

FIXTURES = r'''
func check(_ label: String, _ value: Bool) { if !value { fatalError(label) } }
func row(_ i: Int, _ source: String, body: String? = nil) -> TranscriptMessage {
    TranscriptMessage(author: source == "explicit" ? "peer" : nil,
        authorSource: source, body: body ?? "message \(i)")
}
// This is a healthy-sized eight-row parse. Four rows are unknown, but only
// one is after the last known own reply: the reported production shape.
let initial = (0..<8).map { row($0, [0, 1, 2, 7].contains($0) ? "unattributed" : "default-me") }
let resolved = Array(initial.prefix(7)) + [row(7, "explicit")]
let root = UIElement()
let rows = Array(repeating: UIElement(), count: 30)
func run(_ snapshots: [[TranscriptMessage]]) -> (Parser, [TranscriptMessage], [(key: String, value: String)], Int) {
    let parser = Parser(snapshots)
    var recollections = 0
    let result = parser.extractMessages(from: rows, transcriptRoot: root, limit: 10,
        includeSystemMessages: false, referenceDate: Date(), frameCache: FrameCache(),
        recollectRows: { _ in recollections += 1; return rows })
    return (parser, result.messages, result.notes, recollections)
}
let recovered = run([initial, resolved])
check("healthy count does not skip recovery", recovered.1 == resolved)
check("exactly one recollection", recovered.0.parses == 2 && recovered.3 == 1)
check("fresh frame cache", recovered.0.caches[0] !== recovered.0.caches[1])
check("no fallback author inference", recovered.0.fallbacks == 0)
check("content-free acceptance diagnostic", recovered.2.contains { $0.key == "attraccepted" && $0.value == "1" })

let stableGeometry = initial.map { message in
    var row = message; row.authorUnresolvedReason = "ambiguous-geometry"; return row
}
let noGeometryRetry = run([stableGeometry])
check("stable measured geometry adds no read or wait", noGeometryRetry.0.parses == 1 && noGeometryRetry.3 == 0)
let missingBody = initial.map { message in
    var row = message; row.authorUnresolvedReason = "missing-body-frame"; return row
}
check("body absence behind ambiguous row remains retryable", run([missingBody, resolved]).0.parses == 2)
let persistent = run([initial, initial])
check("persistent unknown stays unknown", persistent.1 == initial)
check("persistent unknown bounded", persistent.0.parses == 2 && persistent.3 == 1)
check("persistent unknown reported", persistent.2.contains { $0.key == "attraccepted" && $0.value == "0" })

let quiet = run([resolved])
check("old unknown history does not retry", quiet.0.parses == 1 && quiet.3 == 0)
let dropped = run([initial, Array(resolved.dropFirst())])
check("missing rows are not recovery", dropped.1 == initial)
var conflicting = resolved; conflicting[5] = row(5, "explicit")
check("known owner change rejected", run([initial, conflicting]).1 == initial)
var changed = resolved; changed[7] = row(7, "explicit", body: "another window")
check("different snapshot rejected", run([initial, changed]).1 == initial)
var reordered = resolved; reordered.swapAt(0, 1)
check("changed order rejected", run([initial, reordered]).1 == initial)
var namedInitial = initial; namedInitial[6] = row(6, "explicit")
var namedCandidate = resolved
namedCandidate[6] = TranscriptMessage(author: "different peer", authorSource: "explicit", body: "message 6")
check("known peer name change rejected", run([namedInitial, namedCandidate]).1 == namedInitial)
let outgoing = Array(initial.prefix(7)) + [row(7, "default-me")]
check("fresh measured outgoing remains outgoing", run([initial, outgoing]).1 == outgoing)
let sparse = run([Array(resolved.prefix(3)), resolved])
check("existing sparse recovery preserved", sparse.0.parses == 2 && sparse.1 == resolved)
check("sparse diagnostics preserved", sparse.2.contains { $0.key == "sparse" })
let diagnostic = Parser([])
let missing = diagnostic.inferMessageSide(bodyFrame: nil, imageFrames: [], rowFrame: nil, transcriptRoot: root)
check("missing frame diagnosed without a sender guess", missing.side == .unknown && missing.failure == "missing-frame")
let middle = diagnostic.inferMessageSide(bodyFrame: CGRect(x: 58, y: 0, width: 2, height: 10), imageFrames: [], rowFrame: nil, transcriptRoot: root)
check("ambiguous geometry distinguished", middle.side == .unknown && middle.failure == "ambiguous-geometry")
let rowFallback = diagnostic.inferMessageSide(bodyFrame: nil, imageFrames: [], rowFrame: CGRect(x: 58, y: 0, width: 2, height: 10), transcriptRoot: root)
check("ambiguous row fallback retains absent body evidence", rowFallback.side == .unknown && rowFallback.failure == "missing-body-frame")
let left = diagnostic.inferMessageSide(bodyFrame: CGRect(x: 10, y: 0, width: 20, height: 10), imageFrames: [], rowFrame: nil, transcriptRoot: root)
check("valid left remains resolved", left.side == .left && left.failure == nil)
print("OK: count-healthy attribution, bounded ambiguity, snapshot safety, sparse recovery, geometry diagnostics")
'''


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ReadAttributionRecoveryTests(unittest.TestCase):
    def test_production_extraction_with_fresh_snapshots(self):
        source = READER.read_text()
        start = source.index("    private func extractMessages(")
        end = source.index("    private func parseMessages(", start)
        extraction = source[start:end].replace("private func", "func", 1)
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / "main.swift"
            side_start = source.index("    private func inferMessageSide(")
            side_end = source.index("    private func resolveAuthorInSegment(", side_start)
            side = source[side_start:side_end].replace("private func", "func", 1)
            main.write_text(STUBS + extraction + side + "\n}\n" + FIXTURES)
            binary = Path(tmp) / "recovery-check"
            sdk_args = []
            if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
                sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True)
                if sdk.returncode == 0:
                    sdk_args = ["-sdk", sdk.stdout.strip()]
            build = subprocess.run(["swiftc", *sdk_args, str(RECOVERY), str(main), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("OK:", result.stdout)
