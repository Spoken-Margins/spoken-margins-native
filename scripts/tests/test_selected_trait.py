"""Selected state reaches VoiceOver as the `.isSelected` trait, not as colour or a changing label (#1915).

`ExperienceFilterChip` showed its active state only by colour, and the batch-export rows swapped their label between
"Select" and "Deselect". The trait lives inside the component, so every chip call site gets it. A SwiftUI trait
can't be read on the host, so this scan guards the source.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"


def _read(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class SelectedTraitTests(unittest.TestCase):
    def test_the_filter_chip_adds_the_selected_trait_when_active(self):
        text = _read("ExperienceDesignSystem.swift")
        chip = text[text.index("struct ExperienceFilterChip"):]
        chip = chip[:chip.index("\nstruct ", 1)] if "\nstruct " in chip[1:] else chip
        self.assertIn(".accessibilityAddTraits(isActive ? .isSelected : [])", chip)

    def test_batch_export_rows_keep_one_label_and_use_the_trait(self):
        text = _read("BatchExportScreen.swift")
        self.assertIn(".accessibilityAddTraits(selected ? .isSelected : [])", text)
        self.assertNotIn('"Deselect', text)
        self.assertNotRegex(text, r'selected \? "Deselect"')


if __name__ == "__main__":
    unittest.main()
