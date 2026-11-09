"""The item screen has no lazy stack at all (#3781).

A friend's item screen froze the main thread at 100% CPU when scrolled, in Release too. Every sample sat in SwiftUI
layout with no app frames. The first fix (#3859) made the stacks nested under the screen's `LazyVStack` plain, on the
theory that lazy inside lazy was the cause. The Test Desk then reproduced the freeze on that build, twice.

Its samples show what loops. One `GraphHost.flushTransactions()` call never returns: the screen's `LazyVStack` places
its children (`LazySubviewPlacements.updateValue`), queues a change of which children count as on screen
(`LazyLayoutCacheItem.AllItemsPhaseMutation`), that change makes layout stale, and layout places the children again.
Each pass also re-measures the stack's size estimates (`LazyStack.measureEstimates`) through every safe-area inset
around the scroll view, five deep in the sample. A plain `VStack` has no estimates, no placement cache and no on-screen phases,
so this loop has nothing to run on. The sections are short (a few layers, a few Margins, tens of chapters, scenes and
sessions), so building them all when the screen opens is the cost, and it is small.

This scan fails when a lazy container comes back in the item screen's own file or the friend's layer list file. A new
hosted view in another file is not covered; add its file here when one is added. It is a source scan because the hang
needs a simulator to see; the fix itself is checked by the Test Desk (#3781).
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
    def test_the_screen_has_no_lazy_container(self):
        screen = _code("ExperienceItemDetailScreen.swift")
        self.assertEqual(LAZY.findall(screen), [], "the item screen's scroll content and its sections are plain stacks")

    def test_the_screen_body_is_still_a_stack_inside_the_scroll_view(self):
        screen = _code("ExperienceItemDetailScreen.swift")
        body = screen[screen.index("ScrollView {"):screen.index("var hero")]
        self.assertRegex(body, r"ScrollView \{\s+VStack\(alignment: \.leading, spacing: 22\) \{")

    def test_a_friends_layer_list_is_not_lazy(self):
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
