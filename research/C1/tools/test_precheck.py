#!/usr/bin/env python3
"""Tests for the M2 pre-check.  python3 -m unittest tools/test_precheck.py"""

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


if __name__ == "__main__":
    unittest.main()
