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


if __name__ == "__main__":
    unittest.main()
