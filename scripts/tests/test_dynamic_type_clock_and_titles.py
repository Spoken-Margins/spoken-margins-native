"""The session clock and the item title follow the listener's text size (#3726).

The Live session clock was a fixed size, so it ignored the text-size setting. It now scales from 28 pt in the dock through a
`@ScaledMetric` and shrinks to fit one line. The item's title on the Margins and Timeline panes is one line by default
and up to three at accessibility sizes, so a listener at the largest size can still see which item they are on.
This scan fails when any of the three goes back.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
TITLE_LIMIT = ".lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)"


def _read(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class SessionClockAndTitleDynamicTypeTests(unittest.TestCase):
    def test_the_live_session_clock_scales_with_text_size_and_keeps_its_default_size(self):
        # The clock moved into the dock when the screen was drawn like playback (#3491).
        text = _read("LiveSessionDock.swift")
        self.assertRegex(text, r"@ScaledMetric\(relativeTo: \.title\) private var clockFontSize: CGFloat = 28\b")
        self.assertNotRegex(text, r"\.system\(size: \d")
        self.assertEqual(text.count(".system(size: clockFontSize"), 1)
        self.assertEqual(text.count(".minimumScaleFactor(0.5)"), 1)
        self.assertNotRegex(_read("LiveSessionView.swift"), r"\.system\(size: \d")

    def test_the_item_title_gets_three_lines_at_accessibility_sizes(self):
        for name in ("PlaybackMarginsView.swift", "ExperienceTimelineRailScreen.swift"):
            text = _read(name)
            self.assertIn("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize", text, name)
            title = text[text.index("Text(model.selectedItem.title)"):]
            self.assertIn(TITLE_LIMIT, title[:400], name)


if __name__ == "__main__":
    unittest.main()
