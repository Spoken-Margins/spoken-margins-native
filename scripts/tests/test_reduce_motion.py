"""Motion the app starts by itself respects Reduce Motion (#1928).

The Timeline scrolls to the playing entry on every change, slides in full screen, and lists animate their reorders.
`withMotion`, `motionAnimation`, `motionTransition` and `numericTextTransition` (ReduceMotion.swift) are off under Reduce
Motion. This scan fails when one of the listed sites goes back to a plain `withAnimation`, `.animation` or
`.numericText()`. Animations the listener causes with a tap (a disclosure, a button press) are not covered.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"


def _read(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class ReduceMotionTests(unittest.TestCase):
    def test_the_timeline_scrolls_and_returns_without_a_plain_with_animation(self):
        text = _read("ExperienceTimelineRailScreen.swift")
        self.assertNotIn("withAnimation", text)
        self.assertEqual(text.count("withMotion("), 3)

    def test_the_onboarding_scroll_in_playback_uses_the_helper(self):
        text = _read("PlaybackScreen.swift")
        self.assertNotIn("withAnimation", text)
        self.assertIn("withMotion {", text)

    def test_the_timeline_slide_becomes_a_fade(self):
        text = _read("Gate1RootView.swift")
        self.assertIn(".motionTransition(.move(edge: .bottom)", text)
        self.assertNotIn(".transition(.move(edge: .bottom)", text)

    def test_list_reorders_and_numeric_text_respect_it(self):
        for name in ("ExperienceLibraryScreen.swift", "ExperienceSourcesScreen.swift"):
            text = _read(name)
            self.assertIn(".motionAnimation(.smooth", text, name)
            self.assertNotRegex(text, r"(?<![\w.])\.animation\(\.smooth", name)
        for name in ("PlaybackScreen.swift", "PlaybackMarginRowView.swift"):
            text = _read(name)
            self.assertIn(".numericTextTransition()", text, name)
            self.assertNotIn(".contentTransition(.numericText())", text, name)

    def test_the_helpers_read_reduce_motion(self):
        text = _read("ReduceMotion.swift")
        self.assertIn("UIAccessibility.isReduceMotionEnabled", text)
        self.assertEqual(text.count("accessibilityReduceMotion"), 3)


if __name__ == "__main__":
    unittest.main()
