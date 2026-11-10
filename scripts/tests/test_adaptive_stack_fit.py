"""AdaptiveStack rows never squeeze a button label into broken words (#3897).

`AdaptiveStack` is a row at ordinary text sizes only while every child fits on one line each (`ViewThatFits` with the
labels held to one line), and a column otherwise and at every accessibility size. A row that holds free text meant to
wrap or truncate beside a control opts out with `wrapsText: true` and keeps the old rule. This scan fails when the
fitting rule is lost, when a spacer would add height to a column, and when a new row opts out without being named here.
The rendered check is app-hosted: App/SpokenMarginsAppTests/AdaptiveStackFitTests.swift.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
LAYOUT = SOURCES / "AdaptiveLayout.swift"

# Rows that keep a row until accessibility sizes because they hold free text. A new entry is a decision: say why.
WRAPS_TEXT_ROWS = {
    # A Margin's words fill the button and wrap; the Include switch sits beside them.
    "Build23SenderSharingComponents.swift": 1,
    # An item's title truncates to one line by design; the short Resume button sits beside it.
    "LiveSessionLiveRow.swift": 1,
    # Each preview button keeps its player in @State and relabels itself "Stop" while playing; a swap between a row and
    # a column would rebuild the buttons and stop the audio.
    "SharingExperience.swift": 1,
}


def _strip(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


class AdaptiveStackFitTests(unittest.TestCase):
    def test_a_row_is_tried_first_with_labels_on_one_line_then_a_column(self):
        text = _strip(LAYOUT.read_text())
        stack = text[text.index("struct AdaptiveStack"):text.index("struct AdaptiveSpacer")]
        body = stack[stack.index("var body: some View"):stack.index("private var row")]
        self.assertIn("if dynamicTypeSize.isAccessibilitySize {\n            column", body)
        fit = body[body.index("ViewThatFits(in: .horizontal)"):]
        self.assertLess(fit.index("row.lineLimit(1)"), fit.index("column"))

    def test_the_column_is_leading_aligned_and_marks_itself_for_spacers(self):
        text = _strip(LAYOUT.read_text())
        column = text[text.index("private var column"):text.index("private struct AdaptiveStackIsColumnKey")]
        self.assertIn("VStack(alignment: .leading, spacing: spacing)", column)
        self.assertIn(".environment(\\.adaptiveStackIsColumn, true)", column)

    def test_a_spacer_draws_nothing_in_any_column(self):
        text = _strip(LAYOUT.read_text())
        spacer = text[text.index("struct AdaptiveSpacer"):]
        spacer = spacer[:spacer.index("\n}\n")]
        self.assertIn("!dynamicTypeSize.isAccessibilitySize && !isColumn", spacer)

    def test_only_the_named_rows_keep_a_row_for_wrapping_text(self):
        found = {}
        for path in sorted(SOURCES.glob("*.swift")):
            count = len(re.findall(r"AdaptiveStack\([^)]*wrapsText:\s*true", _strip(path.read_text())))
            if count:
                found[path.name] = count
        self.assertEqual(
            found, WRAPS_TEXT_ROWS,
            "a row that opts out of the fitting rule must be named in WRAPS_TEXT_ROWS with its reason (#3897)")


if __name__ == "__main__":
    unittest.main()
