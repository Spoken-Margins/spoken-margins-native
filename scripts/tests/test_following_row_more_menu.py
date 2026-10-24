"""A Following row offers its actions from a visible control, not only a swipe or a long press (#1932).

A listener with a tremor, one hand free or Switch Control can't make a precise swipe or hold for the context menu.
This scan fails when the visible More menu is dropped, shrinks below 44 pt, or drifts from the context menu's actions.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCREEN = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp" / "ExperienceSourcesScreen.swift"


def _row() -> str:
    text = re.sub(r"//[^\n]*", "", SCREEN.read_text())
    return text[re.search(r"\bstruct SourceInboxRow\b", text).start():]


class FollowingRowMoreMenuTests(unittest.TestCase):
    def test_the_row_has_a_more_menu_beside_the_button_at_least_44_points(self):
        row = _row()
        self.assertRegex(row, r"HStack\(spacing: 0\) \{\s*rowButton\s*moreMenu\s*\}")
        menu = row[row.index("private var moreMenu"):]
        menu = menu[:menu.index("\n    }\n")]
        self.assertIn("Menu { rowActions }", menu)
        self.assertIn(".frame(width: 44, height: 44)", menu)
        self.assertIn('.accessibilityLabel("More actions")', menu)

    def test_the_menu_and_the_context_menu_share_one_list_of_actions(self):
        row = _row()
        self.assertIn(".contextMenu { rowActions }", row)
        actions = row[row.index("private var rowActions"):row.index("private var moreMenu")]
        for title in ("Add to Library", "Play now", "Dismiss", "FollowingRowActions.muteTitle", "FollowingRowActions.unfollowTitle"):
            self.assertIn(title, actions)

    def test_the_swipes_stay(self):
        row = _row()
        self.assertIn(".swipeActions(edge: .leading", row)
        self.assertIn(".swipeActions(edge: .trailing", row)


if __name__ == "__main__":
    unittest.main()
