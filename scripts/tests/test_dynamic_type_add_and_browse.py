"""Browse podcasts, the Add Source picker and the paste bar adapt at accessibility text sizes (#1934).

At the largest sizes the Follow control grew to about 200 pt beside the title, the route picker kept two columns
that broke words, and the Paste button sat beside a crushed text column. This scan fails when any of them loses
its accessibility-size layout.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"


def _strip(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


class AddAndBrowseDynamicTypeTests(unittest.TestCase):
    def test_both_catalog_rows_share_one_layout_that_stacks_the_follow_control(self):
        drawer = _strip((APP / "CatalogDrawer.swift").read_text())
        layout = drawer[drawer.index("struct CatalogShowRowLayout"):drawer.index("struct CatalogDrawerRow")]
        self.assertIn("dynamicTypeSize.isAccessibilitySize", layout)
        self.assertIn("VStack(alignment: .leading", layout)
        self.assertEqual(drawer.count("CatalogShowRowLayout(artworkURL:"), 2, "the drawer row and the search row")
        self.assertNotIn("ArtworkThumbnail(url: entry.artworkURL", drawer, "a row must not lay out its own artwork")

    def test_catalog_titles_get_more_lines_at_accessibility_sizes(self):
        drawer = _strip((APP / "CatalogDrawer.swift").read_text())
        self.assertEqual(drawer.count("lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)"), 2)

    def test_the_route_picker_uses_one_column_at_accessibility_sizes(self):
        flow = _strip((APP / "ExperienceAddSourceFlow.swift").read_text())
        grid = flow[flow.index("LazyVGrid(columns:"):]
        self.assertTrue(grid.startswith("LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())]"))

    def test_the_paste_bar_stacks_at_accessibility_sizes(self):
        bar = _strip((APP / "PasteAndGoBar.swift").read_text())
        self.assertIn("dynamicTypeSize.isAccessibilitySize", bar)
        self.assertIn("AnyLayout(VStackLayout", bar)
        self.assertIn("if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }", bar)


if __name__ == "__main__":
    unittest.main()
