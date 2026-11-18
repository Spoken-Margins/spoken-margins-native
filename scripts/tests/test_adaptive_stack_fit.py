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
    # The "Where are you now?" field keeps focus while it is typed in (`@FocusState`); a `ViewThatFits` swap would
    # rebuild it. A column at accessibility sizes, so the placeholder is not cut (#3721).
    "LiveSessionSessionPane.swift": 1,
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

    def _row_text(self, file_name: str, start: str, end: str) -> str:
        text = _strip((SOURCES / file_name).read_text())
        first = text.index(start)
        return text[first:text.index(end, first)]

    def test_the_session_clock_row_and_heard_place_rows_adapt_to_large_text(self):
        # A field beside a button, and a pair of buttons, squeeze at accessibility sizes unless they sit in an
        # AdaptiveStack (#3721, a sibling of #1939).
        pane = _strip((SOURCES / "LiveSessionSessionPane.swift").read_text())
        clock = pane[pane.index("Where are you now?"):pane.index("Type it once")]
        self.assertRegex(clock, r"AdaptiveStack\(spacing: 8, wrapsText: true\)\s*\{\s*AppTextField\(")
        self.assertNotIn("HStack", clock, "the clock row must not be a raw HStack at large text (#3721)")
        detail = _strip((SOURCES / "LiveSessionMarginDetailView.swift").read_text())
        self.assertRegex(detail, r"AdaptiveStack\(spacing: 8\)\s*\{\s*Button\(\"Keep\"\)")
        self.assertRegex(detail, r"AdaptiveStack\(spacing: 8\)\s*\{\s*Button\(\"Save\"\)")
        self.assertNotIn("HStack", detail, "a button pair in the Margin detail must not be a raw HStack (#3721)")


if __name__ == "__main__":
    unittest.main()
