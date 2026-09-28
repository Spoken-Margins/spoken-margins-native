#!/usr/bin/env python3
"""Tests for the scorer and ground-truth parsers.  python3 -m unittest tools/test_score.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import groundtruth  # noqa: E402
import score  # noqa: E402

BODY_1 = ("Spoken margins let a listener record a thought exactly where it happened in the paper, "
          "and the recording stays attached to that passage when the paper is shared with a friend.")
BODY_2 = ("Extraction quality decides whether the listener hears the argument or a stream of page numbers, "
          "running headers and reference lists that nobody wants to hear read aloud.")


def truth(*segments):
    return score.Truth([dict(s) for s in segments])


BASE = [
    {"role": "title", "text": "Listening to papers"},
    {"role": "body", "text": BODY_1,
     "markers": [{"kind": "citation", "label": "12", "at": BODY_1.index(" and the recording")}]},
    {"role": "caption", "text": "Figure 1: A listener holding a phone while walking through a park at dusk."},
    {"role": "body", "text": BODY_2},
    {"role": "reference", "text": "Smith J, Jones K. Reading machines for everyone. J Audio Res. 2020;12:1-10."},
]


class ScoreTests(unittest.TestCase):
    def test_body_only_text_is_clean_and_complete(self):
        result = score.score(truth(*BASE), "Listening to papers\n" + BODY_1 + "\n" + BODY_2)
        self.assertEqual(result["clutter_rate"], 0)
        self.assertEqual(result["missing_body_rate"], 0)
        self.assertEqual(result["order_breaks"], 0)

    def test_reference_list_counts_as_clutter(self):
        text = "Listening to papers\n" + BODY_1 + "\n" + BODY_2 + "\n" + BASE[4]["text"]
        result = score.score(truth(*BASE), text)
        self.assertGreater(result["words_by_category"]["reference"], 10)
        self.assertGreater(result["clutter_rate"], 0.1)

    def test_missing_paragraph_is_reported(self):
        result = score.score(truth(*BASE), "Listening to papers\n" + BODY_1)
        self.assertGreater(result["missing_body_rate"], 0.4)

    def test_repeated_running_header_is_clutter(self):
        header = "\nListening to papers {}\n"
        text = "Listening to papers\n" + BODY_1 + header.format(2) + BODY_2 + header.format(3) + BODY_1 + header.format(4)
        result = score.score(truth(*BASE), text)
        self.assertGreater(result["words_by_category"].get("repeated", 0)
                           + result["words_by_category"].get("furniture", 0), 0)

    def test_citation_rendering_is_classified(self):
        before, after = BODY_1.split(" and the recording")
        cases = {
            "number_read": before + " 12 and the recording" + after,
            "glued_number": before[:-1] + "12, and the recording" + after,
            "spoken_label": before + " citation 12 and the recording" + after,
            "silent": BODY_1,
        }
        for expected, body in cases.items():
            with self.subTest(expected):
                result = score.score(truth(*BASE), body + "\n" + BODY_2)
                self.assertEqual(result["citations"], {expected: 1})

    def test_line_end_hyphenation_is_counted_not_missing(self):
        broken = BODY_1.replace("recording", "record-\ning")
        result = score.score(truth(*BASE), broken + "\n" + BODY_2)
        self.assertEqual(result["hyphen_breaks"], 1)
        self.assertLess(result["missing_body_rate"], 0.1)

    def test_columns_read_out_of_order_are_order_breaks(self):
        half = len(BODY_2) // 2
        cut = BODY_2.rfind(" ", 0, half)
        text = BODY_1 + "\n" + BODY_2[cut:] + "\n" + BODY_2[:cut]
        result = score.score(truth(*BASE), text)
        self.assertGreaterEqual(result["order_breaks"], 1)

    def test_caption_mid_sentence_is_an_interruption(self):
        words = BODY_2.split()
        text = BODY_1 + "\n" + " ".join(words[:6]) + "\n" + BASE[2]["text"] + "\n" + " ".join(words[6:])
        result = score.score(truth(*BASE), text)
        self.assertEqual(result["mid_sentence_interruptions"], {"caption": 1})
        self.assertEqual(result["captions"], {"total": 1, "read": 1})


class GroundTruthTests(unittest.TestCase):
    def test_jats_separates_markers_floats_and_references(self):
        xml = b"""<article><front><article-meta><title-group><article-title>T</article-title></title-group>
        <contrib-group><contrib><name><surname>Li</surname><given-names>Wei</given-names></name></contrib></contrib-group>
        </article-meta></front><body><sec><title>Intro</title>
        <p>Cells divide [<xref ref-type="bibr" rid="b1">1</xref>] as shown by
        <xref ref-type="bibr" rid="b2">Smith et al. (2020)</xref>.<xref ref-type="fn" rid="f1">a</xref>
        <fig id="f1"><label>Figure 1</label><caption><p>Dividing cells.</p></caption></fig> Then they rest
        <inline-formula><tex-math>x^2</tex-math></inline-formula> quietly.</p></sec></body>
        <back><ref-list><ref id="b1"><mixed-citation>A. Paper. 2020.</mixed-citation></ref></ref-list></back></article>"""
        segments = groundtruth.jats_segments(xml)
        roles = [s["role"] for s in segments]
        self.assertEqual(roles, ["title", "front_matter", "heading", "body", "caption", "body", "reference"])
        self.assertIn("Li Wei", segments[1]["text"])
        body = segments[3]
        self.assertEqual([m["kind"] for m in body["markers"]], ["citation", "footnote"])
        self.assertIn("Smith et al. (2020)", body["text"])  # narrative citation stays in the sentence
        self.assertNotIn("[1]", body["text"].replace(" ", ""))
        self.assertEqual(segments[5]["markers"][0]["kind"], "math")
        self.assertEqual(segments[4]["label"], "Figure 1")

    def test_latexml_footnote_leaves_the_paragraph(self):
        html = b"""<html><body><article class="ltx_document"><h1 class="ltx_title ltx_title_document">T</h1>
        <div class="ltx_para"><p class="ltx_p">Models learn <cite class="ltx_cite">[3]</cite> fast.<span class="ltx_note ltx_role_footnote"><sup class="ltx_note_mark">1</sup><span class="ltx_note_outer"><span class="ltx_note_content"><sup class="ltx_note_mark">1</sup>A footnote.</span></span></span> Then more.</p></div>
        <figure class="ltx_figure"><figcaption class="ltx_caption"><span class="ltx_tag">Figure 1: </span>A plot.</figcaption></figure>
        <section class="ltx_bibliography"><ul><li class="ltx_bibitem">B. Book. 2019.</li></ul></section></article></body></html>"""
        segments = groundtruth.latexml_segments(html)
        roles = [s["role"] for s in segments]
        self.assertEqual(roles, ["title", "body", "footnote", "body", "caption", "reference"])
        self.assertEqual(segments[2]["text"], "A footnote.")
        self.assertEqual([m["kind"] for m in segments[1]["markers"]], ["citation", "footnote"])
        self.assertEqual(segments[4]["label"], "Figure 1")


if __name__ == "__main__":
    unittest.main()
