#!/usr/bin/env python3
"""Tests for the reference I14 projection.  python3 -m unittest tools/test_i14.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i14  # noqa: E402
import score  # noqa: E402

FIXTURE = json.loads((Path(__file__).resolve().parents[1] / "I13" / "fixture.json").read_text())


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self.lines = i14.project(FIXTURE).split("\n")
        self.text = "\n".join(self.lines)

    def test_numeric_citation_and_footnote_markers_are_silent(self):
        body = next(line for line in self.lines if line.startswith("Listening is slower"))
        self.assertNotIn("[3]", body)
        self.assertNotIn("¹", body)
        self.assertIn("Listening is slower than reading, but it fits", body)

    def test_skipped_roles_are_announced_once_and_never_read(self):
        self.assertNotIn("C. Writer", self.text)                 # reference
        self.assertEqual(self.lines.count(i14.REFERENCES_SKIPPED), 1)
        self.assertNotIn("Participant Sessions", self.text)      # table cells
        self.assertIn(i14.TABLE_NOT_READ, self.lines)
        self.assertNotIn("Commutes, walks", self.text)           # footnote
        self.assertNotIn("Proc. Example Conf.", self.text)       # page footer
        self.assertNotIn("Listening to Papers\n", self.text.replace("Listening to Papers: A", ""))  # page header

    def test_caption_label_is_not_said_twice(self):
        self.assertIn("Figure 1: Listening sessions by hour of day.", self.lines)
        self.assertNotIn("Figure 1.", self.lines)

    def test_body_math_and_headings_are_read(self):
        self.assertIn("1 Introduction", self.lines)
        self.assertTrue(any("E = mc²" in line for line in self.lines))


class AnnouncementScoringTests(unittest.TestCase):
    def test_announcements_are_neither_clutter_nor_missing(self):
        truth = score.Truth([
            {"role": "body", "text": "Spoken margins let a listener record a thought exactly where it happened."},
            {"role": "reference", "text": "Smith J. Reading machines for everyone. J Audio Res. 2020;12:1-10."},
            {"role": "caption", "text": "A listener walking through a park at dusk with headphones on."},
        ])
        spoken = ("Spoken margins let a listener record a thought exactly where it happened.\n"
                  + i14.REFERENCES_SKIPPED + "\nFigure 3.\n"
                  + "A listener walking through a park at dusk with headphones on.")
        result = score.score(truth, spoken)
        self.assertEqual(result["clutter_rate"], 0)
        self.assertEqual(result["words_by_category"]["announcement"], 4)


if __name__ == "__main__":
    unittest.main()
