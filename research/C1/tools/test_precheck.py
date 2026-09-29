#!/usr/bin/env python3
"""Tests for the M2 pre-check.  python3 -m unittest tools/test_precheck.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import precheck  # noqa: E402

FEATURES = dict.fromkeys(precheck.RULE_FEATURES, 0.0)


def row(hard, **values):
    return {**FEATURES, "words_per_page": 400.0, **values, "hard": hard}


class PrecheckTests(unittest.TestCase):
    def test_fit_catches_a_separable_feature_within_budget(self):
        rows = {f"math{i}": row(True, text_single_letter_share=0.25 + i / 100) for i in range(3)}
        rows.update({f"easy{i}": row(False, text_single_letter_share=0.02 + i / 1000) for i in range(20)})
        rows["scan"] = row(True, words_per_page=0.0)
        rule = precheck.fit(rows)
        result = precheck.evaluate(rows, {pid: precheck.flags(r, rule) for pid, r in rows.items()})
        self.assertEqual((result["caught"], result["false_alarms"]), (4, 0))
        # Midpoint, not the hard paper's own value.
        self.assertLess(rule["text_single_letter_share"], 0.25)
        self.assertGreater(rule["text_single_letter_share"], 0.039)

    def test_no_text_is_always_flagged(self):
        self.assertTrue(precheck.flags(row(True, words_per_page=3.0), precheck.fit({"a": row(False)})))

    def test_false_alarm_budget_is_respected(self):
        # The only feature that finds the hard paper also flags every easy one.
        rows = {"hard": row(True, numeric_line_share=0.5)}
        rows.update({f"easy{i}": row(False, numeric_line_share=0.5) for i in range(10)})
        rule = precheck.fit(rows)
        self.assertNotIn("numeric_line_share", rule)

    def test_reference_cut_port_matches_the_app_rule(self):
        refs = "\n".join(f"{i}. Author A. Title. Journal 20{10 + i}; doi:10/{i}" for i in range(1, 5))
        text = "# Paper\nBody text.\n# References\n" + refs
        self.assertEqual(precheck.app_listening_markdown(text), "# Paper\nBody text.")
        prose = "# Paper\nWe list references below.\n# References\nNone yet."
        self.assertEqual(precheck.app_listening_markdown(prose), prose)


# Same cases, same expected values as
# Packages/SessionKit/Tests/SessionKitTests/PDFListeningPrecheckTests.swift.
SWIFT_CASES = [
    ("Listening is slower than reading but it fits. " * 20, 2, 80.0, 0.0, []),
    ("Let x be in X and let f map x to y where y is in Y. " * 10, 1, 170.0, 0.4118, ["math_heavy"]),
    ("", 3, 0.0, 0.0, ["no_text_layer"]),
    (None, 3, 0.0, 0.0, ["no_text_layer"]),
    ("I have a cat and A dog. " * 10, 1, 70.0, 0.0, []),
    ("Die Größe α ist 3 × β. " * 10, 1, 60.0, 0.3333, ["math_heavy"]),
    ("cafe\u0301 au lait " * 10, 1, 30.0, 0.0, []),
    ("x " * 131 + "word " * 1869, 1, 2000.0, 0.0655, ["math_heavy"]),
    ("x " * 130 + "word " * 1870, 1, 2000.0, 0.065, []),
    ("word " * 20, 1, 20.0, 0.0, ["no_text_layer"]),
    ("word " * 21, 1, 21.0, 0.0, []),
    ("word " * 50, 0, 50.0, 0.0, []),
]


class SwiftParityTests(unittest.TestCase):
    def test_reference_matches_the_swift_cases(self):
        for text, pages, words_per_page, share, reasons in SWIFT_CASES:
            with self.subTest(text=(text or "")[:30], pages=pages):
                self.assertEqual(precheck.verdict(text, pages), {
                    "words_per_page": words_per_page, "text_single_letter_share": share, "reasons": reasons})

    def test_shipped_rule_is_what_the_corpus_fits(self):
        committed = precheck.ROOT / "results" / precheck.TARGET / "precheck-content.json"
        if not committed.exists():
            self.skipTest("no committed content-target run")
        self.assertEqual(json.loads(committed.read_text())["rule"], precheck.CONTENT_RULE)


if __name__ == "__main__":
    unittest.main()
