"""Increase Contrast and Differentiate Without Color reach the views (#1922).

The numbers (the increased border reaching 3:1 on each surface, the default border unchanged) are host-tested in
SessionKit's ExperienceColorContrastTests. This scan guards the wiring the numbers can't see: `AppColors.border`
swaps to the increased variant under high contrast, nearly-invisible input fills get an edge, and the active filter
chip adds a glyph under Differentiate Without Color.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"


def _read(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class IncreaseContrastWiringTests(unittest.TestCase):
    def test_the_border_token_has_an_increased_variant(self):
        text = _read("Gate1RootView.swift")
        self.assertIn("AppSemanticColorRGB.borderIncreased", text)
        self.assertIn("traits.accessibilityContrast == .high", _read("AccessibilityPreferences.swift"))

    def test_one_helper_reads_both_settings(self):
        text = _read("AccessibilityPreferences.swift")
        self.assertIn("accessibilityDifferentiateWithoutColor", text)
        self.assertIn("colorSchemeContrast", text)

    def test_input_fills_that_match_their_surface_get_an_edge(self):
        for name in ("SharingExperience.swift", "PlaybackNativeTextPeekView.swift", "ExperienceDesignSystem.swift"):
            text = _read(name)
            if "AppColors.inputBackground" in text:
                self.assertIn(".increasedContrastEdge(", text, name)

    def test_the_active_filter_chip_adds_a_glyph_without_color(self):
        text = _read("ExperienceDesignSystem.swift")
        self.assertIn("preferences.differentiatesWithoutColor", text)
        self.assertIn('Image(systemName: "checkmark")', text)


if __name__ == "__main__":
    unittest.main()
