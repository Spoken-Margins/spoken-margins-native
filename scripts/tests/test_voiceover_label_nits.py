"""The small VoiceOver label gaps from the accessibility audit stay closed (#1919).

Progress bars carry a name, the sender review's Previous/Next say what they move, the catalog's Retry and spinner
name the show, decorative symbols inside combined buttons are hidden, the Written Margin placeholder is not a
second readable element, and the sharing star does not read its state twice. SwiftUI labels can't be read on the
host, so this scan guards the source.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"


def _read(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class VoiceOverLabelNitTests(unittest.TestCase):
    def test_progress_views_with_a_value_are_named(self):
        self.assertIn('.accessibilityLabel("Audio preparation progress")', _read("ExperienceAudioPreparationQueueScreen.swift"))
        detail = _read("ExperienceItemDetailScreen.swift")
        self.assertIn('.accessibilityLabel("Download progress")', detail)
        self.assertIn('.accessibilityLabel("Downloading")', detail)

    def test_sender_review_navigation_says_margin(self):
        text = _read("Build23SenderSharingExperience.swift")
        self.assertIn('.accessibilityLabel("Previous Margin")', text)
        self.assertIn('.accessibilityLabel("Next Margin")', text)

    def test_catalog_retry_and_spinner_name_the_show(self):
        text = _read("CatalogDrawer.swift")
        for subject in ("entry", "show"):
            self.assertIn(f'.accessibilityLabel("Retry following \\({subject}.title)")', text)
            self.assertIn(f'.accessibilityLabel("Following \\({subject}.title)")', text)

    def test_decorative_symbols_in_combined_buttons_are_hidden(self):
        for name in ("ExperienceAddSourceFlow.swift", "ExperienceCanonicalNavigationTree.swift",
                     "ExperienceAudioPreparationQueueScreen.swift", "ExperienceSourcesScreen.swift",
                     "ExperienceMarginsScreen.swift"):
            self.assertIn(".accessibilityHidden(true)", _read(name), name)

    def test_the_written_margin_placeholder_is_not_a_second_element(self):
        text = _read("ExperienceWrittenMarginScreen.swift")
        placeholder = text[text.index('Text("What do you want to remember?")'):]
        self.assertIn(".accessibilityHidden(true)", placeholder[:400])
        self.assertIn('.accessibilityHint("What do you want to remember?")', text)

    def test_the_sharing_star_does_not_read_its_state_twice(self):
        text = _read("PlaybackScreen.swift")
        self.assertIn('.accessibilityLabel(isStarred ? "Remove sharing star" : "Star Margin for sharing")', text)
        self.assertNotIn('.accessibilityValue(isStarred ? "Starred" : "Not starred")', text)


if __name__ == "__main__":
    unittest.main()
