#!/usr/bin/env python3
"""Tests for the title-page chapter check.  python3 -m unittest tools/test_chapters.py"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chapters  # noqa: E402
import regex  # noqa: E402

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


def grapheme_doc(*headings):
    """Like doc(), with ranges counted in Characters (grapheme clusters), as I13 does."""
    text, segments = "", []
    for heading in headings:
        if text:
            text += "\n\n"
        segments.append({"role": "heading", "range": {"start": len(regex.findall(r"\X", text)),
                                                       "length": len(regex.findall(r"\X", heading))}})
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

    def test_a_real_heading_made_only_of_title_words_is_not_a_title_page_chapter(self):
        # "Emotional intelligence" is also a section of the paper, so its words are title words
        # and only the paper's own heading list keeps it out.
        truth = {"segments": TRUTH["segments"] + [{"role": "heading", "text": "Emotional intelligence"}]}
        self.assertEqual(chapters.title_page_chapters(doc("Emotional intelligence", "Introduction"), truth), [])
        # Without that heading in the paper, the same words are a title-page chapter.
        self.assertEqual(chapters.title_page_chapters(doc("Emotional intelligence"), TRUTH), ["Emotional intelligence"])

    def test_headings_are_cut_by_characters_not_code_points(self):
        # A flag is two code points but one Character: counted wrongly, the author line below
        # would be cut short and no longer match the title page's words.
        found = chapters.title_page_chapters(grapheme_doc("\U0001F1FA\U0001F1F8 flag", "Nikhilesh Anand"), TRUTH)
        self.assertEqual(["Nikhilesh Anand"], found)


if __name__ == "__main__":
    unittest.main()
