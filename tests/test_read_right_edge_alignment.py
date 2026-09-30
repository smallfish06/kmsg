"""Measured geometry regression; deliberately stores no chat names or text.

Coordinates and image flags come from the 2026-09-30 native snapshot. All 20
unknown text bodies matched confirmed sent outbox rows, but two were also
flagged as images by the native parser and must remain conservatively held.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "Sources/kmsg/KakaoTalk/TranscriptRightEdgeAlignment.swift"

HARNESS = r'''
import CoreGraphics
import Foundation
typealias Row = TranscriptRightEdgeAlignment.Row
let root = CGRect(x: 769, y: 323, width: 382, height: 434)
func check(_ label: String, _ condition: Bool) { if !condition { fatalError(label) } }
func row(_ x: CGFloat, _ width: CGFloat, _ side: String, peer: Bool = false,
         rich: Bool = false, y: CGFloat = -100, height: CGFloat = 16) -> Row {
    Row(bodyFrame: CGRect(x: x, y: y, width: width, height: height), side: side,
        explicitPeer: peer, richContent: rich)
}
// Every unknown outgoing row in the captured 50-message window. All have
// finite actual text bounds; waiting/reparsing cannot change this alignment.
let unknownBounds: [(CGFloat, CGFloat)] = [
    (852,280),(857,275),(853,279),(850,282),(854,278),
    (855,277),(853,279),(859,273),(852,280),(850,282),
    (850,282),(852,280),(855,277),(864,268),(857,275),
    (852,280),(860,272),(853,279),(855,277),(860,272)
]
let unknown = unknownBounds.map { row($0.0, $0.1, "unknown") }
let ownWidths: [CGFloat] = [74,192,122,155,186,119,171,208,122,234,167,122,163,186,160,208,82,224,212,66,202,190]
let anchors = ownWidths.map { row(1132 - $0, $0, "right") }
let peerWidths: [CGFloat] = [78,40,22,186,182,238,118,123]
let peers = peerWidths.map { row(830, $0, "left", peer:true) }
let aligned = TranscriptRightEdgeAlignment.resolvedRows(anchors + peers + unknown, transcriptFrame: root)
check("geometry-only case resolves twenty; image metadata intentionally absent", aligned == Set(30..<50))
// Actual AX rows 51 and 54 (unknown indices 17 and 18) carried image_count=1.
// Their bubble backgrounds were mis-associated captures. The classifier must
// retain its rich-content guard even though the DB independently proves these
// two old bodies were sent by us. This is a metadata-faithful helper replay,
// not a claim that the runtime or complete native parser resolved all twenty.
let imageFlaggedUnknownIndices: Set<Int> = [17, 18]
let capturedUnknown = unknownBounds.enumerated().map { index, bounds in
    row(bounds.0, bounds.1, "unknown", rich: imageFlaggedUnknownIndices.contains(index))
}
let capturedAligned = TranscriptRightEdgeAlignment.resolvedRows(anchors + peers + capturedUnknown, transcriptFrame: root)
check("actual metadata resolves eighteen and safely holds two image-flagged rows",
      capturedAligned == Set(30..<50).subtracting([47,48]))
check("all eight captured peers remain untouched", capturedAligned.isDisjoint(with: Set(22..<30)))
check("captured centers were all ambiguous", unknownBounds.allSatisfy { x,w in
    let midpoint = (x + w / 2 - root.minX) / root.width
    return midpoint > 0.56 && midpoint < 0.62
})
let incomingLong = row(830,282,"unknown")
check("long incoming with no name stays unknown", TranscriptRightEdgeAlignment.resolvedRows(anchors + [incomingLong], transcriptFrame: root).isEmpty)
check("single own anchor insufficient", TranscriptRightEdgeAlignment.resolvedRows([anchors[0], unknown[0]], transcriptFrame: root).isEmpty)
check("conflicting own edges reject calibration", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(1063,74,"right"),unknown[0]], transcriptFrame: root).isEmpty)
check("explicit peer on candidate edge vetoes", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(852,280,"unknown",peer:true),unknown[0]], transcriptFrame: root).isEmpty)
check("measured left on candidate edge vetoes", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(852,280,"left"),unknown[0]], transcriptFrame: root).isEmpty)
check("no row-frame substitution", TranscriptRightEdgeAlignment.resolvedRows(anchors + [Row(bodyFrame:nil,side:"unknown",explicitPeer:false,richContent:false)], transcriptFrame: root).isEmpty)
check("full-width row not a bubble", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(770,380,"unknown")], transcriptFrame: root).isEmpty)
check("rich content never calibrated", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(852,280,"unknown",rich:true)], transcriptFrame: root).isEmpty)
check("zero body rejected", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(1132,0,"unknown")], transcriptFrame: root).isEmpty)
check("nonfinite body rejected", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(.nan,280,"unknown")], transcriptFrame: root).isEmpty)
check("zero root rejected", TranscriptRightEdgeAlignment.resolvedRows(anchors + unknown, transcriptFrame: .zero).isEmpty)
check("nonfinite root rejected", TranscriptRightEdgeAlignment.resolvedRows(anchors + unknown, transcriptFrame: .null).isEmpty)
check("out-of-root bounds rejected", TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(768,364,"unknown")], transcriptFrame: root).isEmpty)
check("side label alone not an own anchor", TranscriptRightEdgeAlignment.resolvedRows([row(886,220,"right"),row(896,210,"right"),row(826,280,"unknown")], transcriptFrame: root).isEmpty)
check("old offscreen coordinates remain usable", !TranscriptRightEdgeAlignment.resolvedRows(anchors + [row(852,280,"unknown",y:-1973,height:64)], transcriptFrame: root).isEmpty)
print("OK: geometry-only twenty; captured metadata eighteen plus two holds; peer and geometry safety")
'''


@unittest.skipIf(shutil.which("swiftc") is None, "swiftc not available")
class ReadRightEdgeAlignmentTests(unittest.TestCase):
    def test_executable_captured_geometry(self):
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / "main.swift"
            main.write_text(HARNESS)
            binary = Path(tmp) / "alignment-check"
            sdk_args = []
            if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
                sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True)
                if sdk.returncode == 0:
                    sdk_args = ["-sdk", sdk.stdout.strip()]
            build = subprocess.run(["swiftc", *sdk_args, str(HELPER), str(main), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("OK:", result.stdout)

    def test_applied_before_author_and_timestamp_inheritance(self):
        source = (ROOT / "Sources/kmsg/KakaoTalk/TranscriptReader.swift").read_text()
        alignment = source.index("let aligned = TranscriptRightEdgeAlignment.resolvedRows")
        self.assertLess(alignment, source.index("let groupTails = resolveGroupTailStamps(analyses)", alignment))
        self.assertIn("bodyFrame: analysis.bodyCandidate?.frame", source)
        self.assertIn("analysis.attachmentCount > 0", source)
