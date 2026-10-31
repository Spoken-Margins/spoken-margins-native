"""The Live Activity follows the listener's text size and its control row fits the Lock Screen (#1940).

The card had a fixed 10 pt skim-time caption and a fixed 16 pt glyph, one-line titles that shrank to nothing, and a
row of circles plus the next-chapter button and the mic that added up to about 420 pt on a Lock Screen that offers
about 327 pt. This scan fails when a fixed font size comes back, when the transport grows a second row (the card
would pass the 160 pt the Lock Screen allows), or when the base sizes no longer fit one row.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WIDGET = ROOT / "App" / "SpokenMarginsGate2Widget" / "Sources" / "Gate2LiveActivityWidget.swift"
LOCK_SCREEN_CONTENT_WIDTH = 327  # a 359 pt Live Activity on a 393 pt screen, minus the 16 pt padding on each side
MIN_TOUCH_TARGET = 44
NARROW_LOCK_SCREEN_CONTENT_WIDTH = 311  # a 375 pt-wide phone
LOCK_SCREEN_MAX_HEIGHT = 160


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

    def test_the_circles_are_fixed_size_controls_that_never_drop_below_a_touch_target(self):
        text = _text()
        self.assertNotRegex(text, r"\.frame\(width: (50|56|60), height: (50|56|60)\)")
        self.assertNotIn("controlScale", text, "a circle that grows would not fit the row at large text sizes")
        helper = _between(text, "enum Gate2ControlSize", "private struct AdaptiveLineLimit")
        for name in ("skim", "skip", "play", "record"):
            self.assertGreaterEqual(_constant(helper, name), MIN_TOUCH_TARGET, name)

    def test_the_transport_is_one_row_so_the_card_keeps_its_height(self):
        # A second row put the card at about 186 pt; the Lock Screen cuts off anything over 160 pt (audit on 71aed00).
        text = _text()
        controls = _between(text, "private var transportControls", "private var playbackCircles")
        self.assertNotIn("ViewThatFits", controls)
        self.assertNotIn("VStack", controls)
        self.assertEqual(controls.count("HStack("), 1)
        for part in ("playbackCircles", "recordButton"):
            self.assertEqual(controls.count(part), 1, part)
        self.assertNotIn("nextNavigation", controls, "the next-chapter action sits in the header")
        header = _between(text, "struct Gate2LiveActivityView", "private var transportControls")
        self.assertIn("nextNavigation", header)

    def test_the_card_height_budget_holds_at_the_default_text_size(self):
        text = _text()
        helper = _between(text, "enum Gate2ControlSize", "private struct AdaptiveLineLimit")
        play = _constant(helper, "play")
        # headline 22 + chapter 16 + next line 13 and their 2 pt gaps, the progress bar, and the 6 pt stack gaps and 10 pt
        # vertical padding. The Summary and Discuss row and the paused prompt are not counted.
        height = 2 * 10 + (22 + 2 + 16 + 2 + 13) + 6 + 4 + 6 + play
        self.assertLessEqual(height, LOCK_SCREEN_MAX_HEIGHT, height)

    def test_the_base_sizes_fit_one_row_on_the_narrowest_lock_screen(self):
        helper = _between(_text(), "enum Gate2ControlSize", "private struct AdaptiveLineLimit")
        skim, skip, play, record, spacing = (
            _constant(helper, name) for name in ("skim", "skip", "play", "record", "rowSpacing")
        )
        row = 2 * skim + 2 * skip + play + record + 5 * spacing  # five circles, a spacer and the mic: five gaps
        self.assertLessEqual(row, NARROW_LOCK_SCREEN_CONTENT_WIDTH)
        self.assertLessEqual(NARROW_LOCK_SCREEN_CONTENT_WIDTH, LOCK_SCREEN_CONTENT_WIDTH)


if __name__ == "__main__":
    unittest.main()
