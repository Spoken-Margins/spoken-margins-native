#!/usr/bin/env python3
"""Tests for the marker comparison.  python3 -m unittest tools/test_marker_diff.py"""

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marker_diff  # noqa: E402


def document(text: str, markers: list[tuple[str, int, int, str]], footnote: tuple[int, int] | None = None) -> dict:
    segments = [{"id": "s0", "role": "body", "range": {"start": 0, "length": len(marker_diff.characters(text))}}]
    if footnote:
        segments.append({"id": "s1", "role": "footnote", "range": {"start": footnote[0], "length": footnote[1]}})
    return {
        "text": text,
        "segments": segments,
        "markers": [
            {"kind": kind, "range": {"start": start, "length": length}, "label": label}
            for kind, start, length, label in markers
        ],
    }


class CharacterTests(unittest.TestCase):
    def test_a_marker_range_counts_swift_characters_not_code_points(self):
        # "g⃗" is two code points and one Character; so is CR-LF. A soft hyphen and a mark
        # after a line break stand alone.
        rows = [
            ("g⃗x1", ["g⃗", "x", "1"]),
            ("a\r\nb", ["a", "\r\n", "b"]),
            ("a­b", ["a", "­", "b"]),
            ("a\ñb", ["a", "\n", "̃", "b"]),
            ("𝑥𝑛", ["𝑥", "𝑛"]),
            ("", []),
        ]
        for text, expected in rows:
            self.assertEqual(marker_diff.characters(text), expected, repr(text))

    def test_context_is_read_at_the_character_offset(self):
        text = marker_diff.characters("the vector g⃗ and x̂n rose")
        left, run, right = marker_diff.context(text, 18, 1)
        self.assertEqual(run, "n")
        self.assertTrue(left.endswith("x̂"))
        self.assertEqual(right, " rose")


class CountTests(unittest.TestCase):
    def test_counts_split_letter_footnotes_from_the_rest(self):
        counted = marker_diff.counts(document(
            "xn rose,1 as Doea said.* Note text",
            [("footnote", 1, 1, "n"), ("citation", 8, 1, "1"), ("footnote", 16, 1, "a"), ("footnote", 23, 1, "*")],
            footnote=(25, 9),
        ))
        self.assertEqual(counted, {"citation": 1, "footnote": 3, "letter": 2, "footnote_chars": 9})

    def test_a_run_reports_what_is_now_spoken_and_what_is_now_silenced(self):
        text = "xn rose,1 as Doea said."
        before = document(text, [("footnote", 1, 1, "n"), ("footnote", 16, 1, "a")])
        after = document(text, [("citation", 8, 1, "1"), ("footnote", 16, 1, "a")])
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, value in (("before", before), ("after", after)):
                (root / name).mkdir()
                (root / name / "paper.json").write_text(json.dumps(value), encoding="utf-8")
            sites = root / "sites.tsv"
            output = io.StringIO()
            argv = sys.argv
            sys.argv = ["marker_diff.py", str(root / "before"), str(root / "after"), "--sites", str(sites)]
            try:
                with contextlib.redirect_stdout(output):
                    self.assertEqual(marker_diff.main(), 0)
            finally:
                sys.argv = argv
            rows = [line.split("\t") for line in sites.read_text(encoding="utf-8").splitlines()[1:]]
        self.assertEqual([(row[1], row[2], row[5]) for row in rows],
                         [("spoken-now", "footnote", "n"), ("silenced-now", "citation", "1")])
        self.assertEqual(rows[0][4], "x")
        printed = " ".join(output.getvalue().split())
        self.assertIn("footnote markers with a letter 2 → 1", printed)
        self.assertIn("papers whose text changed: 0", printed)


if __name__ == "__main__":
    unittest.main()
