"""Library rows and the onboarding strip stay readable at large text sizes (#1937).

Fixed frames around scaling glyphs, a status line cut to one line at every size, and two buttons squeezed side by side
in a narrowed column. This scan fails when the strip stops stacking, a frame goes back to a fixed size, or the status
line loses its two-line allowance. Default sizes keep the compact row.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCREEN = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp" / "ExperienceLibraryScreen.swift"


def _text() -> str:
    return re.sub(r"//[^\n]*", "", SCREEN.read_text())


class LibraryRowDynamicTypeTests(unittest.TestCase):
    def test_the_onboarding_strip_stacks_its_buttons_and_its_icon_row(self):
        text = _text()
        strip = text[text.index("private var onboardingStrip"):text.index("private var controls")]
        self.assertIn("if dynamicTypeSize.isAccessibilitySize", strip)
        self.assertIn("ViewThatFits(in: .horizontal)", text[text.index("private var onboardingContent"):])
        self.assertEqual(text.count("Text(\"Hear overview\")"), 1, "the two buttons are written once")
        # A label wider than the column wraps instead of being cut off (#2056).
        actions = text[text.index("private var onboardingActions"):text.index("private var onboardingDismiss")]
        self.assertEqual(actions.count(".fixedSize(horizontal: false, vertical: true)"), 2)

    def test_the_icon_tile_and_play_circle_scale_but_never_shrink_below_default(self):
        text = _text()
        self.assertNotIn(".frame(width: 38, height: 44)", text)
        self.assertNotIn(".frame(width: 40, height: 40)", text[text.index("struct LibraryRowPlayLabel"):])
        self.assertIn("min(max(iconWidth, 38), 76)", text)
        self.assertIn("min(max(diameter, 40), 80)", text)
        self.assertEqual(text.count("@ScaledMetric(relativeTo: .body)"), 3)

    def test_the_status_line_may_take_two_lines_only_at_the_largest_normal_size(self):
        text = _text()
        self.assertIn("dynamicTypeSize >= .xxxLarge ? 2 : 1", text)
        detail = text[text.index("private var detailLineView"):text.index("private var sourceByline")]
        self.assertNotIn(".lineLimit(1)", detail)
        self.assertEqual(detail.count(".lineLimit(detailLineLimit)"), 2)


if __name__ == "__main__":
    unittest.main()
