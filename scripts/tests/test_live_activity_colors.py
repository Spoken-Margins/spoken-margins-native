"""The Live Activity never draws a tint or glyph in green (#1924).

The card shows REC in red beside the progress bar. Red against green is the one pair the owner (red-green
colour-blind) cannot tell apart, so progress and the idle glyph use `progressTint` (sky blue). The Listen
button's soft green fill carries a white label and icon and is not a tint, so only `.tint(...)` and
`.foregroundStyle(...)` are scanned.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WIDGET = ROOT / "App/SpokenMarginsGate2Widget/Sources/Gate2LiveActivityWidget.swift"
GREEN_TINT = re.compile(r"\.(tint|foregroundStyle)\([^\n]*(?<![\w.])\.green\b|\.(tint|foregroundStyle)\([^\n]*Color\.green\b")


def green_tint_lines(text: str) -> list[int]:
    return [number for number, line in enumerate(text.splitlines(), start=1) if GREEN_TINT.search(line)]


class LiveActivityColorTests(unittest.TestCase):
    def test_scan_flags_the_old_progress_and_glyph_tints(self):
        bad = """
        .foregroundStyle(state.isRecording ? state.recordingTint : .green)
        ProgressView(value: 1).tint(isLuminanceReduced ? .white.opacity(0.72) : .green)
        .tint(Color.green)
        """
        self.assertEqual(green_tint_lines(bad), [2, 3, 4])
        good = """
        .foregroundStyle(state.isRecording ? state.recordingTint : Gate2LiveActivityAttributes.ContentState.progressTint)
        .background(Color.green.opacity(0.28))
        """
        self.assertEqual(green_tint_lines(good), [])

    def test_the_widget_has_no_green_tint(self):
        text = WIDGET.read_text(encoding="utf-8")
        self.assertTrue("Gate2LiveActivityContent" in text, "the scan is reading the wrong file")
        self.assertEqual(green_tint_lines(text), [])


if __name__ == "__main__":
    unittest.main()
