"""The Live Activity follows the listener's text size and its control row fits the Lock Screen (#1940).

The card had a fixed 10 pt skim-time caption and a fixed 16 pt glyph, one-line titles that shrank to nothing, and a
row of circles plus the next-chapter button and the mic that added up to about 420 pt on a Lock Screen that offers
about 327 pt. This scan fails when a fixed font size comes back, when a circle goes back to a fixed frame, when the
row stops falling back to two rows, or when the base sizes no longer fit the row at the default text size.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WIDGET = ROOT / "App" / "SpokenMarginsGate2Widget" / "Sources" / "Gate2LiveActivityWidget.swift"
LOCK_SCREEN_CONTENT_WIDTH = 327  # a 359 pt Live Activity on a 393 pt screen, minus the 16 pt padding on each side
MIN_TOUCH_TARGET = 44
ROW_SPACING = 6


def _text() -> str:
    return re.sub(r"//[^\n]*", "", WIDGET.read_text())


def _between(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


def _constant(text: str, name: str) -> float:
    return float(re.search(rf"static let {name}: CGFloat = ([0-9.]+)", text).group(1))


class LiveActivityDynamicTypeTests(unittest.TestCase):
    def test_no_font_has_a_fixed_point_size(self):
        for match in re.finditer(r"\.system\(size: ([^,)]+)", _text()):
            self.assertFalse(re.fullmatch(r"[0-9.]+", match.group(1).strip()),
                             f"fixed font size {match.group(1)}: use a text style or @ScaledMetric")

    def test_the_skim_caption_uses_a_text_style(self):
        self.assertRegex(_text(), r"Text\(caption\)\s*\.font\(\.caption2\.weight\(\.semibold\)\.monospacedDigit\(\)\)")

    def test_the_small_view_glyph_and_frame_scale(self):
        small = _between(_text(), "struct Gate2LiveActivitySmallView", "struct Gate2LiveActivityView")
        self.assertIn("@ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = 16", small)
        self.assertIn("@ScaledMetric(relativeTo: .caption) private var glyphFrame: CGFloat = 22", small)
        self.assertIn(".frame(width: glyphFrame, height: glyphFrame)", small)

    def test_titles_and_chapters_get_two_lines_at_accessibility_sizes(self):
        text = _text()
        self.assertIn("dynamicTypeSize.isAccessibilitySize ? 2 : 1", text)
        # The Dynamic Island lines, the small and medium titles and chapters, and the next-chapter title.
        self.assertGreaterEqual(text.count(".adaptiveLineLimit()"), 9)
        # What keeps a bare one-line limit is a short word or a button label that shrinks to fit.
        self.assertEqual(text.count(".lineLimit(1)"), 5)

    def test_the_circles_scale_with_text_but_never_below_default(self):
        text = _text()
        self.assertNotRegex(text, r"\.frame\(width: (50|56|60), height: (50|56|60)\)")
        self.assertEqual(text.count("@ScaledMetric(relativeTo: .title2) private var controlScale: CGFloat = 1"), 3)
        self.assertIn("base * min(max(scale, 1), maxGrowth)", _between(text, "enum Gate2ControlSize", "private struct AdaptiveLineLimit"))

    def test_the_row_falls_back_to_two_rows_instead_of_overflowing(self):
        controls = _between(_text(), "private var transportControls", "private var playbackCircles")
        self.assertIn("ViewThatFits(in: .horizontal)", controls)
        for part in ("playbackCircles", "recordButton", "nextNavigation"):
            self.assertEqual(controls.count(part), 2, f"{part} sits in both layouts")

    def test_the_base_sizes_fit_the_lock_screen_at_default_size_and_stay_touch_targets(self):
        helper = _between(_text(), "enum Gate2ControlSize", "private struct AdaptiveLineLimit")
        skim, skip, play, record = (_constant(helper, name) for name in ("skim", "skip", "play", "record"))
        growth = _constant(helper, "maxGrowth")
        for size in (skim, skip, play, record):
            self.assertGreaterEqual(size, MIN_TOUCH_TARGET)
        circles = 2 * skim + 2 * skip + play
        # Five circles, a spacer and the mic make six gaps. With a next-chapter button the first layout cannot fit and
        # the view falls back to two rows; this proves the common case, no next button.
        self.assertLessEqual(circles + record + 6 * ROW_SPACING, LOCK_SCREEN_CONTENT_WIDTH,
                             "the circles and the mic share one row at the default size")
        self.assertLessEqual(circles * growth + 4 * ROW_SPACING, LOCK_SCREEN_CONTENT_WIDTH,
                             "the circles alone fit one row at the largest growth")


if __name__ == "__main__":
    unittest.main()
