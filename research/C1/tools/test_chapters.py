#!/usr/bin/env python3
"""Tests for the title-page chapter check.  python3 -m unittest tools/test_chapters.py"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chapters  # noqa: E402

TRUTH = {"segments": [
    {"role": "title", "text": "Emotional intelligence: An important skill to learn now more than ever"},
    {"role": "authors", "text": "Nikhilesh Anand"}, {"role": "authors", "text": "Rajeev Ranjan"},
    {"role": "front_matter", "text": "Department of Pharmacology"},
    {"role": "heading", "text": "Introduction"}, {"role": "body", "text": "Emotional intelligence matters."},
]}


def doc(*headings):
    text, segments = "", []
    for heading in headings:
        if text:
            text += "\n\n"
        segments.append({"role": "heading", "range": {"start": len(text), "length": len(heading)}})
        text += heading
    return {"text": text, "segments": segments}


class ChapterTests(unittest.TestCase):
    def test_title_author_and_badge_headings_are_title_page_chapters(self):
        found = chapters.title_page_chapters(doc(
            "Emotional intelligence: An important skill to learn now more", "than ever",
            "Nikhilesh Anand1", ", Rajeev Ranjan3", "v1", "Introduction"), TRUTH)
        self.assertEqual(found, ["Emotional intelligence: An important skill to learn now more", "than ever",
                                 "Nikhilesh Anand1", ", Rajeev Ranjan3", "v1"])

    def test_real_section_headings_are_not(self):
        self.assertEqual(chapters.title_page_chapters(doc("Introduction", "Methods"), TRUTH), [])


if __name__ == "__main__":
    unittest.main()
