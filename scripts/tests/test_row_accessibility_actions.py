"""A row's long-press menu is also reachable without a long press (#1917).

VoiceOver and Switch Control can't long-press, so every action a `.contextMenu` offers on a timeline or Margin row
needs an `.accessibilityActions` (or `.accessibilityAction(named:)`) equivalent. Library's custom actions carry the
same `canDelete` and `offlineState` guards as its menu. A source scan guards both, because the SwiftUI modifiers
can't be read on the host.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"

# Files whose context menus are rows, with the reason for any menu that is not.
ROW_MENUS = {
    "PlaybackTimelineListView.swift": 1,
    "ExperienceMarginsScreen.swift": 1,
    "ExperienceLibraryScreen.swift": 1,
    "ExperienceSourcesScreen.swift": 1,
}


def _read(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class RowAccessibilityActionTests(unittest.TestCase):
    def test_every_row_context_menu_has_an_accessibility_equivalent(self):
        for name, menus in ROW_MENUS.items():
            with self.subTest(file=name):
                text = _read(name)
                self.assertEqual(text.count(".contextMenu"), menus)
                self.assertRegex(text, r"\.accessibilityActions?\b", f"{name} has a row menu but no accessibility action")

    def test_timeline_and_margin_rows_reuse_their_menu_content(self):
        self.assertIn(".accessibilityActions { details(entry.action) }", _read("PlaybackTimelineListView.swift"))
        margins = _read("ExperienceMarginsScreen.swift")
        self.assertIn(".contextMenu { ownMarginActions(row) }", margins)
        self.assertIn(".accessibilityActions { ownMarginActions(row) }", margins)

    def test_library_accessibility_actions_use_the_menus_guards(self):
        text = _read("ExperienceLibraryScreen.swift")
        self.assertNotIn('.accessibilityAction(named: "Prepare Offline"', text)
        self.assertNotIn('.accessibilityAction(named: "Move to Recently Deleted"', text)
        block = text[text.index('Button("Prepare Offline", action: onPrepareOffline)\n            }\n            Button("Add'):]
        self.assertIn("if row.canDelete {\n                Button(\"Move to Recently Deleted\", action: onDelete)", block)
        before = text[:text.index('Button("Prepare Offline", action: onPrepareOffline)\n            }\n            Button("Add')]
        self.assertTrue(before.rstrip().endswith("if row.offlineState != .readyOffline {"))


if __name__ == "__main__":
    unittest.main()
