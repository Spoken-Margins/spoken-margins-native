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


def _strip_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def _read(name: str) -> str:
    return _strip_comments((SOURCES / name).read_text())


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
        for name in ("PinnedMarginCardView.swift", "PlaybackMarginRowView.swift"):
            text = _read(name)
            self.assertIn(".numericTextTransition()", text, name)
            self.assertNotIn(".contentTransition(.numericText())", text, name)

    def test_no_bare_animation_anywhere_in_the_app_outside_the_helper(self):
        """#3725: newer code missed `withMotion`. A plain `withAnimation` or `.animation(` fails here.

        Two files animate on purpose and choose the branch themselves from the Reduce Motion setting:
        the edge-swipe-back screen (fades instead of sliding) and the batch export jump (no animation).
        """
        allowed = {"ReduceMotion.swift", "EdgeSwipeBackTransition.swift", "BatchExportScreen.swift"}
        bare = re.compile(r"\bwithAnimation\b|\.animation\(")
        offenders = []
        for path in sorted((ROOT / "App").rglob("*.swift")):
            if path.name in allowed or "Tests" in path.parts[-3:-1] or path.parent.name.endswith("Tests"):
                continue
            for number, line in enumerate(_strip_comments(path.read_text()).splitlines(), 1):
                if bare.search(line):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(offenders, [], "use withMotion / motionAnimation (ReduceMotion.swift)")

    def test_the_scan_catches_a_bare_animation(self):
        bare = re.compile(r"\bwithAnimation\b|\.animation\(")
        for line in ("withAnimation { x.toggle() }", "withAnimation(.easeIn) { x }", "view.animation(.smooth, value: v)"):
            self.assertTrue(bare.search(line), line)
        for line in ("withMotion { x.toggle() }", "view.motionAnimation(.smooth, value: v)", "// withAnimation"):
            self.assertFalse(bare.search(_strip_comments(line)), line)

    def test_the_helpers_read_reduce_motion(self):
        text = _read("ReduceMotion.swift")
        self.assertIn("UIAccessibility.isReduceMotionEnabled", text)
        self.assertEqual(text.count("accessibilityReduceMotion"), 3)


if __name__ == "__main__":
    unittest.main()
