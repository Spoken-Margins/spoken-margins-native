"""The controls #151 missed reach a 44 pt hit area (#1929).

`expandedHitArea` grows the tappable region without changing layout, for rows too tight for a 44 pt frame. This
scan fails when the button styles, the playback secondary controls or the Live Activity buttons lose it.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
WIDGET = ROOT / "App" / "SpokenMarginsGate2Widget" / "Sources" / "Gate2LiveActivityWidget.swift"


def _strip(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def _struct(text: str, name: str) -> str:
    start = text.index(f"struct {name}")
    return text[start:text.index("\n}\n", start)]


class TapTargetStyleTests(unittest.TestCase):
    def test_button_styles_expand_their_hit_area(self):
        root = _strip((APP / "Gate1RootView.swift").read_text())
        self.assertIn("expandedHitArea(horizontal: 5, vertical: 5)", _struct(root, "IconButtonStyle"))
        self.assertIn("expandedHitArea(", _struct(root, "SecondaryButtonStyle"))
        playback = _strip((APP / "PlaybackScreen.swift").read_text())
        self.assertIn("expandedHitArea(", _struct(playback, "LightButtonStyle"))

    def test_playback_secondary_controls_expand_their_hit_area(self):
        playback = _strip((APP / "PlaybackScreen.swift").read_text())
        self.assertGreaterEqual(playback.count(".expandedHitArea("), 8)

    def test_live_activity_buttons_expand_their_hit_area(self):
        widget = _strip(WIDGET.read_text())
        self.assertEqual(widget.count(".expandedHitArea("), 4)

    def test_the_helper_does_not_change_layout(self):
        text = _strip((APP / "ExperienceDesignSystem.swift").read_text())
        helper = text[text.index("func expandedHitArea"):]
        helper = helper[:helper.index("\n    }\n")]
        self.assertIn(".contentShape(Rectangle())", helper)
        self.assertIn(".padding(.horizontal, -horizontal)", helper)
        self.assertIn(".padding(.vertical, -vertical)", helper)


if __name__ == "__main__":
    unittest.main()
