import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TRANSCRIPT_READER = REPO_ROOT / "Sources" / "kmsg" / "KakaoTalk" / "TranscriptReader.swift"
READ_COMMAND = REPO_ROOT / "Sources" / "kmsg" / "Commands" / "ReadCommand.swift"


class ReadAuthorSourceContractTests(unittest.TestCase):
    """An unknown side is a non-verdict, not "(me)".

    `resolveAuthorInSegment` used to fold `side == .unknown` (missing AX
    frames on a half-rendered window, typically right after a failed read)
    into the same `(nil, "default-me")` branch as `.right`, and the JSON
    encoder renders `author ?? "(me)"` — so every undecidable row shipped as
    ours. On 2026-08-14 a read against such a window misattributed 39/50 rows,
    which poisoned the talkfriend bridge's anchor and our-row gate in the same
    direction and lost user messages (이예은 방). The contract: unknown-side
    rows carry a distinguishable `author_source` of "unattributed" in every
    read/watch JSON row, and the read summary line carries the count so the
    bridge can distrust the read without --trace-ax."""

    def setUp(self) -> None:
        self.reader_source = TRANSCRIPT_READER.read_text(encoding="utf-8")
        self.read_command_source = READ_COMMAND.read_text(encoding="utf-8")

    def resolve_body(self) -> str:
        return self.reader_source.split("private func resolveAuthorInSegment", 1)[1].split(
            "private func", 1
        )[0]

    def test_unknown_side_is_not_default_me(self) -> None:
        body = self.resolve_body()

        self.assertIn('return (nil, "unattributed")', body)
        # The default-me branch must be reachable for .right only: no branch
        # may test .unknown together with .right the way the bug did.
        self.assertNotIn(".right || analysis.side == .unknown", body)
        self.assertNotIn(".unknown || analysis.side == .right", body)

    def test_unknown_side_cannot_reach_the_left_chain(self) -> None:
        """The left-anchor chain assumes a left-side row; an unknown side must
        exit before it, or a half-rendered window inherits a peer author."""
        body = self.resolve_body()

        unknown_at = body.index('return (nil, "unattributed")')
        left_chain_at = body.index('return (anchorAuthor, "left-chain")')
        self.assertLess(unknown_at, left_chain_at)

    def test_author_source_rides_every_encoded_row(self) -> None:
        self.assertIn('case authorSource = "author_source"', self.reader_source)
        self.assertIn(
            "try container.encodeIfPresent(authorSource, forKey: .authorSource)",
            self.reader_source,
        )
        # The segment loop must hand resolveAuthorInSegment's verdict to the
        # message rather than re-deriving or dropping it.
        self.assertIn("authorSource: resolvedAuthor.source", self.reader_source)
        # --capture-images rebuilds messages; the verdict must survive the copy.
        with_captured = self.reader_source.split("func withCapturedImages", 1)[1].split(
            "\n    }", 1
        )[0]
        self.assertIn("authorSource: authorSource", with_captured)

    def test_fallback_rows_without_an_author_are_unattributed(self) -> None:
        """The fallback extractor has no side information, so its nil-author
        rows are the same non-verdict and must not read as "(me)"."""
        fallback = self.reader_source.split("private func extractFallbackMessages", 1)[1].split(
            "private func", 1
        )[0]

        self.assertIn(
            'metadata.author == nil ? "unattributed" : "fallback-metadata"', fallback
        )
        self.assertIn('authorSource: "unattributed"', fallback)

    def test_read_summary_line_carries_the_unattributed_count(self) -> None:
        """The bridge reads only the [kmsg] summary line, not runner.log."""
        self.assertIn('profiler.note(\n                "unattributed",', self.read_command_source)
        self.assertIn(
            '$0.authorSource == "unattributed"', self.read_command_source
        )


if __name__ == "__main__":
    unittest.main()
