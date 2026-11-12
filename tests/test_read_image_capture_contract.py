import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
READ_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ReadCommand.swift"
TRANSCRIPT_READER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptReader.swift"
IMAGE_CAPTURER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptImageCapturer.swift"
IMAGE_REGION = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "ImageCaptureRegion.swift"
README = REPO_ROOT / "README.md"


class ReadImageCaptureContractTests(unittest.TestCase):
    def test_read_exposes_capture_images_and_rejects_background_safe(self) -> None:
        source = READ_COMMAND.read_text(encoding="utf-8")

        self.assertIn("var captureImages: String?", source)
        self.assertIn("backgroundSafe, captureImages != nil", source)
        self.assertIn("--capture-images cannot be used together with --background-safe", source)
        self.assertIn("capturer.captureImages(in: snapshot, from: window)", source)

    def test_transcript_preserves_filtered_frames_and_emits_pure_image_body(self) -> None:
        source = TRANSCRIPT_READER.read_text(encoding="utf-8")

        self.assertIn("imageFrames: messageImageFrames", source)
        self.assertIn('MessageBodyCandidate(body: "[사진]"', source)
        self.assertIn("messageDeduplicationFingerprint", source)
        self.assertIn('case imagePaths = "image_paths"', source)
        self.assertIn('case imageSHA256 = "image_sha256"', source)
        self.assertIn("encodeIfPresent(imagePaths", source)

    def test_capture_uses_one_screencapturekit_window_image(self) -> None:
        source = IMAGE_CAPTURER.read_text(encoding="utf-8")

        self.assertIn("import ScreenCaptureKit", source)
        self.assertIn("SCContentFilter(desktopIndependentWindow: matchedWindow)", source)
        self.assertIn("SCScreenshotManager.captureImage", source)
        self.assertEqual(source.count("captureWindow("), 2)  # declaration plus one call
        self.assertNotIn("CGWindowListCreateImage", source)

    def test_capture_enforces_size_and_hash_contract(self) -> None:
        source = IMAGE_CAPTURER.read_text(encoding="utf-8")

        self.assertIn("maximumJPEGBytes = 1_048_576", source)
        self.assertIn("SHA256.hash(data: data)", source)
        self.assertIn("SCFrameStatus(rawValue: statusRawValue) == .complete", source)
        self.assertIn("attachments[.contentRect]", source)

    def test_each_frame_is_saved_or_skipped_alone(self) -> None:
        source = IMAGE_CAPTURER.read_text(encoding="utf-8")
        region = IMAGE_REGION.read_text(encoding="utf-8")

        # The parser's own count must still agree with its frames...
        self.assertIn("IMAGE_CAPTURE_COUNT_MISMATCH", source)
        self.assertIn("guard frameCount == expectedCount", source)
        # ...but a frame that cannot be saved no longer voids the others
        # (behaviour: test_read_image_capture_region.py).
        self.assertNotIn("guard capturedCount == expectedCount", source)
        self.assertNotIn("guard savedCount == expectedCount", source)
        self.assertIn("ImageCaptureRegion.regions(", source)
        self.assertIn("wholeFrameVisibleRatio: CGFloat = 0.98", region)
        self.assertIn("partialFrameVisibleRatio: CGFloat = 0.5", region)

    def test_capture_outcome_reaches_the_summary_line(self) -> None:
        source = IMAGE_CAPTURER.read_text(encoding="utf-8")
        command = READ_COMMAND.read_text(encoding="utf-8")

        for key in ["cap.frames", "cap.saved", "cap.partial", "cap.clipped", "cap.nocrop", "cap.noenc"]:
            self.assertIn(f'profiler?.note("{key}"', source)
        self.assertIn('profiler.note("cap.fail"', command)

    def test_readme_documents_capture_contract(self) -> None:
        source = README.read_text(encoding="utf-8")

        self.assertIn("--capture-images <dir>", source)
        self.assertIn("image_paths", source)
        self.assertIn("image_sha256", source)
        self.assertIn("cap.clipped", source)
        self.assertNotIn("비정상 종료하며 성공 JSON을 출력하지 않습니다", source)


if __name__ == "__main__":
    unittest.main()
