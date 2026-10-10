#!/usr/bin/env python3
"""Tests for the reference I14 projection.  python3 -m unittest tools/test_i14.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i14  # noqa: E402
import score  # noqa: E402
import regex  # noqa: E402

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

    def test_author_names_are_read_and_the_rest_of_the_title_page_is_not(self):
        # Owner, #191: names read; affiliations, emails, identifiers skipped.
        self.assertTrue(any(line.startswith("Ada Example") for line in self.lines))
        self.assertNotIn("Example University", self.text)

    def test_caption_label_is_not_said_twice(self):
        self.assertIn("Figure 1: Listening sessions by hour of day.", self.lines)
        self.assertNotIn("Figure 1.", self.lines)

    def test_body_math_and_headings_are_read(self):
        self.assertIn("1 Introduction", self.lines)
        self.assertTrue(any("E = mc²" in line for line in self.lines))


def make_doc(*parts, markers=()):
    """An I13 document from (role, text) parts; ranges count Characters (grapheme clusters)."""
    text, segments = "", []
    for role, part in parts:
        if text:
            text += "\n\n"
        start = len(regex.findall(r"\X", text))
        segments.append({"role": role, "range": {"start": start, "length": len(regex.findall(r"\X", part))}})
        text += part
    return {"text": text, "segments": segments, "markers": list(markers)}


class ProjectionRulesOnSmallDocuments(unittest.TestCase):
    """Cases the paper fixture can't tell apart: it has one reference segment, no back
    matter, no equation and no figure text, and only ASCII."""

    def project(self, *parts, **kwargs):
        return i14.project(make_doc(*parts, **kwargs)).split("\n")

    def test_a_run_of_references_is_announced_once_and_each_new_run_again(self):
        lines = self.project(("body", "First."), ("reference", "Ref one."), ("reference", "Ref two."),
                             ("reference", "Ref three."), ("body", "Second."), ("reference", "Ref four."))
        self.assertEqual(["First.", i14.REFERENCES_SKIPPED, "Second.", i14.REFERENCES_SKIPPED], lines)

    def test_a_run_of_back_matter_is_announced_once(self):
        lines = self.project(("body", "First."), ("back_matter", "Acknowledgements."), ("back_matter", "Funding."),
                             ("body", "Second."), ("back_matter", "Appendix."))
        self.assertEqual(["First.", i14.BACK_MATTER_SKIPPED, "Second.", i14.BACK_MATTER_SKIPPED], lines)

    def test_every_equation_is_announced_and_figure_text_is_silent(self):
        lines = self.project(("body", "Before."), ("equation", "E = mc^2"), ("figure_text", "axis label 0 5 10"),
                             ("equation", "a^2 + b^2 = c^2"), ("page_header", "Running head"), ("front_matter", "Dept."),
                             ("body", "After."))
        self.assertEqual(["Before.", i14.EQUATION, i14.EQUATION, "After."], lines)

    def test_ranges_and_markers_count_characters_not_code_points(self):
        # "Cafe" + combining acute is four Characters (five code points); the flag is one Character.
        cafe, flag = "Cafe\u0301", "\U0001F1FA\U0001F1F8"
        markers = [{"kind": "citation", "range": {"start": 5, "length": 3}}]  # "[3]" after "Café "
        lines = self.project(("body", f"{cafe} [3] ok {flag}."), ("body", f"{flag} tail"), markers=markers)
        self.assertEqual([f"{cafe} ok {flag}.", f"{flag} tail"], lines)


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
