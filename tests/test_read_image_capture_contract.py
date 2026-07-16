import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
READ_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ReadCommand.swift"
TRANSCRIPT_READER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptReader.swift"
IMAGE_CAPTURER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptImageCapturer.swift"
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

    def test_capture_enforces_size_hash_and_count_contract(self) -> None:
        source = IMAGE_CAPTURER.read_text(encoding="utf-8")

        self.assertIn("maximumJPEGBytes = 1_048_576", source)
        self.assertIn("SHA256.hash(data: data)", source)
        self.assertIn("IMAGE_CAPTURE_COUNT_MISMATCH", source)
        self.assertIn("guard capturedCount == expectedCount", source)
        self.assertIn("SCFrameStatus(rawValue: statusRawValue) == .complete", source)
        self.assertIn("attachments[.contentRect]", source)
        self.assertIn("visibleAreaRatio(of: frame, inside: bounds) >= 0.98", source)

    def test_readme_documents_capture_contract(self) -> None:
        source = README.read_text(encoding="utf-8")

        self.assertIn("--capture-images <dir>", source)
        self.assertIn("image_paths", source)
        self.assertIn("image_sha256", source)
        self.assertIn("IMAGE_CAPTURE_COUNT_MISMATCH", source)


if __name__ == "__main__":
    unittest.main()
