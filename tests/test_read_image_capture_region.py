import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REGION = ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ImageCaptureRegion.swift"

# The transcript viewport of a 380x640 bridge chat window, in screen points.
VIEWPORT = (0, 100, 380, 480)

MAIN = '''
import CoreGraphics
import Foundation

struct Case: Decodable { let name: String; let viewport: [Double]?; let messages: [[[Double]]] }
func rect(_ v: [Double]) -> CGRect { CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }

let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
var out: [String: [[[Double]?]]] = [:]
for item in cases {
    let regions = ImageCaptureRegion.regions(
        for: item.messages.map { $0.map(rect) },
        in: item.viewport.map(rect)
    )
    out[item.name] = regions.map { $0.map { r in r.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } } }
}
// A frame AX reports as null/infinite must be skipped, not trap the process.
let odd = ImageCaptureRegion.regions(for: [[CGRect.null, CGRect.infinite, rect([10, 200, 100, 100])]],
                                     in: rect([0, 100, 380, 480]))
out["odd"] = odd.map { $0.map { r in r.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } } }
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]))
'''


class ImageCaptureRegionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        main = folder / "main.swift"
        main.write_text(MAIN, encoding="utf-8")
        cls.binary = folder / "region-test"
        # Same SDK discovery as test_phase_profiler.py.
        sdk_args = []
        if sys.platform == "darwin" and not os.environ.get("SDKROOT"):
            sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                 check=True, capture_output=True, text=True)
            sdk_args = ["-sdk", sdk.stdout.strip()]
        build = subprocess.run(["swiftc", *sdk_args, str(REGION), str(main), "-o", str(cls.binary)],
                               capture_output=True, text=True)
        if build.returncode:
            raise RuntimeError(f"Region harness compilation failed:\n{build.stdout}{build.stderr}")

    def regions(self, cases):
        result = subprocess.run([str(self.binary)], input=json.dumps(cases), check=True,
                                capture_output=True, text=True)
        return json.loads(result.stdout)

    def test_a_clipped_frame_does_not_cost_the_other_frames_their_pixels(self) -> None:
        # Three photos sent in a row, newest at the bottom. The newest fits,
        # the middle one is cut by the top of the viewport, the oldest shows
        # only a sliver. Before this change the whole read came back without
        # images.
        newest = [70, 330, 200, 240]
        middle = [70, 40, 200, 280]      # y 40..320, viewport starts at 100: 220/280 visible
        oldest = [70, -220, 200, 330]    # y -220..110: 10/330 visible
        got = self.regions([{
            "name": "burst", "viewport": list(VIEWPORT),
            "messages": [[oldest], [middle], [newest]],
        }])["burst"]

        self.assertEqual(got[2], [newest])                     # saved whole
        self.assertEqual(got[1], [[70, 100, 200, 220]])        # visible part only
        self.assertEqual(got[0], [None])                       # a sliver: no path

    def test_a_text_bubble_background_cut_by_the_viewport_leaves_the_photo_alone(self) -> None:
        # Production reads flag some text bubbles' background images as message
        # images. One of those sitting on the top edge used to void the photo.
        bubble_on_edge = [60, 80, 180, 40]   # half above the viewport
        photo = [70, 300, 200, 260]
        got = self.regions([{
            "name": "edge", "viewport": list(VIEWPORT),
            "messages": [[bubble_on_edge], [photo]],
        }])["edge"]

        self.assertEqual(got[1], [photo])
        self.assertEqual(got[0], [[60, 100, 180, 20]])

    def test_thresholds(self) -> None:
        def one(frame):
            return self.regions([{"name": "t", "viewport": list(VIEWPORT), "messages": [[frame]]}])["t"][0][0]

        self.assertEqual(one([10, 100, 100, 100]), [10, 100, 100, 100])   # fully inside
        self.assertEqual(one([10, 98, 100, 100]), [10, 98, 100, 100])     # 98% visible: whole, as before
        self.assertEqual(one([10, 97, 100, 100]), [10, 100, 100, 97])     # 97%: the visible part
        self.assertEqual(one([10, 50, 100, 100]), [10, 100, 100, 50])     # exactly half
        self.assertIsNone(one([10, 49, 100, 100]))                        # under half
        self.assertIsNone(one([10, 700, 100, 100]))                       # off screen
        self.assertEqual(one([10, 530, 100, 100]), [10, 530, 100, 50])    # cut by the bottom edge

    def test_no_viewport_and_unusable_frames_save_nothing(self) -> None:
        got = self.regions([{"name": "blind", "viewport": None, "messages": [[[10, 200, 100, 100]]]}])
        self.assertEqual(got["blind"], [[None]])
        self.assertEqual(got["odd"], [[None, None, [10, 200, 100, 100]]])

    def test_frames_stay_in_message_and_frame_order(self) -> None:
        a, b, c = [10, 120, 60, 60], [80, 120, 60, 60], [10, 300, 60, 60]
        got = self.regions([{
            "name": "order", "viewport": list(VIEWPORT),
            "messages": [[a, b], [], [c]],
        }])["order"]
        self.assertEqual(got, [[a, b], [], [c]])


if __name__ == "__main__":
    unittest.main()
