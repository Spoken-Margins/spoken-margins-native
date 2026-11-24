"""Following inbox rows stay readable at accessibility text sizes (#1936).

The row deliberately never grows at default sizes (#884). At accessibility sizes the title and show name wrap fully,
the artwork and chevron move to a line above, and the text gets the whole row width. This scan fails when the
accessibility layout, or the compact default row, is lost.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCREEN = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp" / "ExperienceSourcesScreen.swift"


def _strip(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def _row() -> str:
    text = _strip(SCREEN.read_text())
    # Any access level: #2049 dropped `private` so app-hosted tests can reach the row (#2203).
    return text[re.search(r"\bstruct SourceInboxRow\b", text).start():]


class FollowingRowDynamicTypeTests(unittest.TestCase):
    def test_title_and_show_name_are_not_limited_at_accessibility_sizes(self):
        row = _row()
        self.assertIn(".lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)", row)
        self.assertIn(".lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)", row)

    def test_artwork_and_chevron_share_a_line_above_the_text_at_accessibility_sizes(self):
        row = _row()
        body = row[row.index("var body: some View"):row.index(".buttonStyle(.plain)")]
        accessibility = body[body.index("if dynamicTypeSize.isAccessibilitySize {"):body.index("} else {")]
        self.assertIn("VStack(alignment: .leading", accessibility)
        self.assertLess(accessibility.index("leadingImage"), accessibility.index("trailingIndicator"))
        self.assertLess(accessibility.index("trailingIndicator"), accessibility.index("textColumn"))

    def test_the_default_row_keeps_its_one_line_layout(self):
        row = _row()
        body = row[row.index("var body: some View"):row.index(".buttonStyle(.plain)")]
        default = body[body.index("} else {"):]
        order = [default.index(name) for name in ("leadingImage", "textColumn", "trailingIndicator")]
        self.assertEqual(order, sorted(order))
        self.assertIn("HStack(alignment: .center, spacing: 12)", default)


FRIEND_ROWS = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp" / "FollowingFriendRows.swift"


def _between(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class FollowingShowAndFriendRowStackTests(unittest.TestCase):
    """#4723: the "N new" count sits on the picture, and at accessibility sizes both rows stack the way #4104 matched them."""

    def test_show_row_stacks_picture_line_above_the_text_at_accessibility_sizes(self):
        text = _strip(SCREEN.read_text())
        view = _between(text, "struct FollowingShowRowView", "struct FollowingShowStatusView")
        body = view[view.index("var body: some View"):view.index("private var pictureWithTag")]
        accessibility = body[body.index("if dynamicTypeSize.isAccessibilitySize {"):body.index("} else {")]
        self.assertIn("VStack(alignment: .leading", accessibility)
        self.assertLess(accessibility.index("pictureWithTag"), accessibility.index("playButton"))
        self.assertLess(accessibility.index("playButton"), accessibility.index("chevronButton"))
        self.assertLess(accessibility.index("chevronButton"), accessibility.index("textColumn"))
        self.assertIn("size: 56", view)
        self.assertNotIn("row.newLabel", view)
        self.assertIn("row.newBadgeText", view)

    def test_in_library_is_one_text_with_an_inline_glyph_in_an_adaptive_stack(self):
        text = _strip(SCREEN.read_text())
        self.assertIn('Text("\\(Image(systemName: "checkmark.circle")) In Library")', text)
        view = _between(text, "struct FollowingShowRowView", "struct FollowingShowStatusView")
        status = _between(text, "struct FollowingShowStatusView", "struct FollowingArtworkNewBadge")
        self.assertNotIn('Label("In Library"', status)
        self.assertIn("AdaptiveStack(", view)

    def test_friend_row_stacks_and_keeps_the_exact_count_for_voiceover(self):
        text = _strip(FRIEND_ROWS.read_text())
        view = _between(text, "struct FollowingFriendRowView", "struct FollowingFriendItemsScreen")
        accessibility = view[view.index("if dynamicTypeSize.isAccessibilitySize {"):view.index("} else {")]
        self.assertIn("VStack(alignment: .leading", accessibility)
        self.assertLess(accessibility.index("initialWithTag"), accessibility.index("textColumn"))
        self.assertIn("friend.newBadgeText", view)
        self.assertEqual(view.count("friend.newLabel"), 1)
        self.assertIn(".accessibilityLabel([friend.name, friend.summary, friend.newLabel]", view)


if __name__ == "__main__":
    unittest.main()
