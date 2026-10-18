"""The pinned playback dock stays bounded at accessibility text sizes (#1933).

At the largest sizes the dock took about half a 6.1-inch screen and the chapter title was one line between two
buttons. This scan fails when the dock loses its bounded scroll or the chapter row loses its accessibility layout.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"


def _strip(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


class DockDynamicTypeTests(unittest.TestCase):
    def test_the_dock_scrolls_inside_a_bounded_height_at_accessibility_sizes(self):
        playback = _strip((APP / "PlaybackScreen.swift").read_text())
        start = playback.index("private var playbackControls")
        end = playback.index("private var marginRow")
        self.assertIn(".boundedScrollDock(dynamicTypeSize.isAccessibilitySize)", playback[start:end])

    def test_the_bound_comes_from_the_tested_rule(self):
        dock = _strip((APP / "PlaybackBoundedDock.swift").read_text())
        self.assertIn("BoundedDockHeight.height(", dock)
        self.assertIn("ScrollView(", dock)

    def test_the_chapter_title_gets_more_lines_and_the_skim_controls_move_below_it(self):
        row = _strip((APP / "PlaybackChapterRowView.swift").read_text())
        self.assertIn("dynamicTypeSize.isAccessibilitySize ? 2 : 1", row)
        self.assertEqual(row.count(".lineLimit(1)"), 0, "no title is pinned to one line at every size")
        accessibility = row[row.index("if dynamicTypeSize.isAccessibilitySize {"):row.index("} else {")]
        self.assertIn("VStack", accessibility)


if __name__ == "__main__":
    unittest.main()
