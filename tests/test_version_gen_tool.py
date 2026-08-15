import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _find_version_gen_binary() -> Path | None:
    """Locate the built VersionGenTool executable.

    Xcode's SwiftPM links plugin host tools next to the target products
    (`.build/debug/VersionGenTool-tool`), but the open-source 6.0 toolchain on
    CI keeps them under `.build/plugins/tools/`. Hardcoding the local path made
    these tests fail only on CI, so search the known homes and fall back to a
    glob."""
    candidates = [
        REPO_ROOT / ".build" / "debug" / "VersionGenTool-tool",
        REPO_ROOT / ".build" / "debug" / "VersionGenTool",
        REPO_ROOT / ".build" / "plugins" / "tools" / "debug" / "VersionGenTool-tool",
        REPO_ROOT / ".build" / "plugins" / "tools" / "debug" / "VersionGenTool",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    globbed = [
        hit
        for pattern in ("VersionGenTool-tool", "VersionGenTool")
        for hit in (REPO_ROOT / ".build").glob(f"**/{pattern}")
        if hit.is_file() and os.access(hit, os.X_OK) and ".dSYM" not in hit.parts
    ]
    return globbed[0] if globbed else None


VERSION_GEN_BINARY = _find_version_gen_binary()


class VersionGenToolTests(unittest.TestCase):
    def run_version_gen(self, version: str) -> tuple[subprocess.CompletedProcess[str], str | None]:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            version_path = tmp / "VERSION"
            output_path = tmp / "GeneratedVersion.swift"
            version_path.write_text(f"{version}\n", encoding="utf-8")

            result = subprocess.run(
                [
                    str(VERSION_GEN_BINARY),
                    str(version_path),
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            output_text = output_path.read_text(encoding="utf-8") if output_path.exists() else None
            return result, output_text

    def test_accepts_major_date_patch_version(self) -> None:
        self.assertIsNotNone(VERSION_GEN_BINARY, "VersionGenTool binary not found under .build (run `swift build` first)")
        result, output_text = self.run_version_gen("1.260424.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(output_text)
        self.assertIn('static let current = "1.260424.0"', output_text)

    def test_rejects_legacy_calendar_version(self) -> None:
        self.assertIsNotNone(VERSION_GEN_BINARY, "VersionGenTool binary not found under .build (run `swift build` first)")
        result, _ = self.run_version_gen("2026.0422.22")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "VERSION must match MAJOR.YYMMDD.PATCH_COUNT",
            f"{result.stdout}\n{result.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
