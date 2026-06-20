import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_workflow_uses_major_date_patch_tags(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertIn("v1.260620.0", workflow)
        self.assertIn("vMAJOR.YYMMDD.PATCH_COUNT", workflow)
        self.assertIn("PATCH_COUNT must be >= 0", workflow)
        self.assertIn("YYMMDD must resolve to a real calendar date", workflow)

    def test_release_workflow_creates_github_release_asset(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")

        self.assertIn("RELEASE_ASSET_NAME: kmsg-macos-universal", workflow)
        self.assertIn("lipo -create", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("gh release upload", workflow)

    def test_release_workflow_does_not_require_homebrew_tap_sync(self) -> None:
        workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertNotIn("TAP_REPO_TOKEN", workflow)
        self.assertNotIn("Homebrew tap sync", workflow)


if __name__ == "__main__":
    unittest.main()
