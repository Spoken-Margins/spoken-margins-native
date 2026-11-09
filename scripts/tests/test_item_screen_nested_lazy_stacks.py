"""The item screen has one lazy stack, not lazy stacks inside lazy stacks (#3781).

A friend's item screen froze the main thread at 100% CPU when scrolled, in Release too. Every sample sat in SwiftUI
layout (`LayoutEngineBox.sizeThatFits`, `LazySubviewPlacements`, `propagate_dirty`) with no app frames. The screen
nested a `LazyVStack` (the friend's layer list) holding a `LazyVStack` (each layer's Margin rail) inside the screen's
own `LazyVStack`, over `.fixedSize` text. Lazy containers ask their parent how far to measure, and when the parent is
itself lazy and the children change size the answer can chase itself. The card lists are short (a few layers, a few
Margins, tens of scenes), so only the screen's outer stack stays lazy and everything under it is a plain `VStack`.

This scan fails when a lazy container comes back in the item screen's own file or the friend's layer list file. A new
hosted view in another file is not covered; add its file here when one is added. It is a source scan because the hang needs a
simulator to see; the fix itself is checked by the Test Desk (#3781).
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
LAZY = re.compile(r"\bLazy(?:V|H)Stack\b|\bLazyVGrid\b|\bLazyHGrid\b")


def _code(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (APP / name).read_text())


class ItemScreenNestedLazyStackTests(unittest.TestCase):
    def test_the_screen_keeps_exactly_one_lazy_stack_and_it_is_the_outer_one(self):
        screen = _code("ExperienceItemDetailScreen.swift")
        found = LAZY.findall(screen)
        self.assertEqual(found, ["LazyVStack"], "only the screen's own scroll content is lazy")
        outer = screen.index("LazyVStack")
        self.assertLess(screen.index("ScrollView {"), outer)
        self.assertLess(outer, screen.index("var hero"), "the one lazy stack is the screen body's")

    def test_a_friends_layer_list_is_not_lazy_because_the_screen_hosts_it_inside_a_lazy_stack(self):
        presentation = _code("Build23ImportedMarginPresentation.swift")
        self.assertEqual(LAZY.findall(presentation), [], "layer list and Margin rail are plain stacks")

    def test_the_layer_list_and_the_margin_rail_are_still_stacks(self):
        presentation = _code("Build23ImportedMarginPresentation.swift")
        self.assertRegex(presentation, r"(?<!Lazy)VStack\(alignment: \.leading, spacing: 16\) \{\s+ForEach\(layers\)")
        rail = presentation[presentation.index("private func marginRail"):presentation.index("private func marginCard")]
        self.assertRegex(rail, r"(?<!Lazy)VStack\(alignment: \.leading, spacing: 10\)")
        self.assertIn("ForEach(layer.margins)", rail)


if __name__ == "__main__":
    unittest.main()
