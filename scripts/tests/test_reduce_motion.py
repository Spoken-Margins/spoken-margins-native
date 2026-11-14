"""Motion the app starts by itself respects Reduce Motion (#1928).

These are text checks of Swift sources, not runs of the app: they fail when a listed site goes back to a plain
animation, and when a helper's Reduce Motion branch is turned round (the polarity of each condition is read out of the
source, #4302). That the app really stills under the setting is the owner's check with Reduce Motion on.

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


BARE_ANIMATION = re.compile(r"\bwithAnimation\b|\.animation\(")


# helper -> the source line in which Reduce Motion picks the still branch
HELPER_BRANCHES = {
    "withMotion": "if UIAccessibility.isReduceMotionEnabled { return try body() }",
    "motionAnimation": "content.animation(reduceMotion ? nil : animation, value: value)",
    "motionTransition": "content.transition(reduceMotion ? .opacity : transition)",
    "numericTextTransition": "content.contentTransition(reduceMotion ? .identity : .numericText())",
}


def branch_problems(text: str) -> list[str]:
    """The helpers whose Reduce Motion branch is not the still one, or that no longer carry it."""
    return [name for name, line in HELPER_BRANCHES.items() if line not in text]


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
        offenders = []
        for path in sorted((ROOT / "App").rglob("*.swift")):
            if path.name in allowed or "Tests" in path.parts[-3:-1] or path.parent.name.endswith("Tests"):
                continue
            for number, line in enumerate(_strip_comments(path.read_text()).splitlines(), 1):
                if BARE_ANIMATION.search(line):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        self.assertEqual(offenders, [], "use withMotion / motionAnimation (ReduceMotion.swift)")

    def test_the_scan_catches_a_bare_animation(self):
        for line in ("withAnimation { x.toggle() }", "withAnimation(.easeIn) { x }", "view.animation(.smooth, value: v)"):
            self.assertTrue(BARE_ANIMATION.search(line), line)
        for line in ("withMotion { x.toggle() }", "view.motionAnimation(.smooth, value: v)", "// withAnimation"):
            self.assertFalse(BARE_ANIMATION.search(_strip_comments(line)), line)

    def test_the_helpers_read_reduce_motion(self):
        text = _read("ReduceMotion.swift")
        self.assertIn("UIAccessibility.isReduceMotionEnabled", text)
        self.assertEqual(text.count("accessibilityReduceMotion"), 3)

    def test_each_helper_turns_motion_off_when_reduce_motion_is_on(self):
        """#4302: counting the spelling passed with every condition inverted, so each branch is read."""
        self.assertEqual(branch_problems(_read("ReduceMotion.swift")), [])

    def test_the_branch_check_catches_each_inverted_helper(self):
        text = _read("ReduceMotion.swift")
        for name, right in HELPER_BRANCHES.items():
            wrong = {
                "withMotion": "if !UIAccessibility.isReduceMotionEnabled { return try body() }",
                "motionAnimation": "content.animation(reduceMotion ? animation : nil, value: value)",
                "motionTransition": "content.transition(reduceMotion ? transition : .opacity)",
                "numericTextTransition": "content.contentTransition(reduceMotion ? .numericText() : .identity)",
            }[name]
            self.assertIn(right, text, "the line moved; update this test with the source")
            self.assertEqual(branch_problems(text.replace(right, wrong)), [name])


if __name__ == "__main__":
    unittest.main()
