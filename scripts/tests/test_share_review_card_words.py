"""The share review card says what the friend gets in one set of words (#3839).

The strings live in SessionKit's `ShareReviewCardWords` and `ShareReviewSteps`, with table tests. This scan keeps the card
reading from them, so a new literal can't bring back "exact local voice assets", "High-reliability evidence", "Voice
preview" or the old "Share as" / "Transcript" labels the screen-tour critics flagged.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
CARD_FILES = ["Build23SenderSharingComponents.swift", "Build23SenderSharingExperience.swift"]
RETIRED = [
    "Review this Margin", "Voice preview", "exact local voice assets", "Preview Original", "Preview Cleaned",
    "voice preview could not be played", "Placement details", "Words before this Margin", "Words after this Margin",
    "These excerpts help place", "Reviewed transcript", "Show full transcript", "Private note — not exported",
    "Choose the version the recipient will receive", "Cleaned voice becomes available", "Read normally. Tap any word",
    "High-reliability",
]


def _code(name: str) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class ShareReviewCardWordsGuard(unittest.TestCase):
    def test_the_card_holds_none_of_the_retired_words(self):
        for name in CARD_FILES:
            text = _code(name)
            for phrase in RETIRED:
                self.assertNotIn(phrase, text, f"{name} still says {phrase!r}; use ShareReviewCardWords")

    def test_the_card_has_no_title_and_no_included_badge(self):
        text = _code("Build23SenderSharingComponents.swift")
        editor = text[text.index("struct Build23MarginEditor"):text.index("struct Build23ReviewTokenButton")]
        self.assertNotIn('"Included"', editor)
        self.assertNotIn(".screenTitle()", editor)

    def test_the_sentences_about_what_is_shared_stay_footnote_or_larger(self):
        # Replaces the literal pin in test_smallest_type_guard.py: the words live in ShareReviewCardWords now (#3337).
        text = _code("Build23SenderSharingComponents.swift")
        for shown in ["ShareReviewCardWords.whereItLandsCaption", "versionCaption", "note"]:
            self.assertRegex(text, r"Text\(%s\)\s+\.font\(\.footnote\)" % re.escape(shown), shown)

    def test_the_card_reads_the_shared_words(self):
        self.assertIn("ShareReviewCardWords.", _code("Build23SenderSharingComponents.swift"))

    def test_no_draft_warning_carries_the_placement_wait(self):
        # The wait is a live step on the card, not a warning copied into the draft when the sheet opens.
        for path in SOURCES.glob("*.swift"):
            self.assertNotIn("shareAnchorWarning", path.read_text(), path.name)
        export = (ROOT / "Packages/SessionKit/Sources/SessionKitSharing/SharedMarginExport.swift").read_text()
        self.assertNotIn("anchorWarning", export)

    def test_the_pinned_bar_carries_the_step_above_the_share_button(self):
        text = _code("Build23SenderSharingExperience.swift")
        self.assertLess(text.index("Build23PinnedStepLine"), text.index("primaryAction(snapshot)\n"))

    def test_the_dead_old_sharing_view_stays_deleted(self):
        text = (SOURCES / "SharingExperience.swift").read_text()
        self.assertNotIn("struct InterjectionSharingView", text)


if __name__ == "__main__":
    unittest.main()
