"""The share review says what cleanup does in one set of words (#3853).

The strings live in SessionKit's `ShareCleanupWords`, with a table test. This scan keeps the share screens reading from it, so
a new literal can't bring back "Clean selected", "Cleaned voice" or the technical failure lines.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
# One Margin's "Prepare All Included" steps moved into SessionKitSharing (#969); the guard follows them there.
BULK_STEPS = ROOT / "Packages" / "SessionKit" / "Sources" / "SessionKitSharing" / "BulkShareDraftPreparation.swift"
FILES = ["Build23SenderSharingExperience.swift", "Build23SenderSharingComponents.swift", "Gate1AppModel+ShareDrafts.swift",
         BULK_STEPS]
RETIRED = [
    "Clean selected", "Clean this Margin", "Pause analysis was unavailable", "Cleaned voice could not",
    "Cleaned voice storage", "The cleaned audio preview", "Cleaned audio could not", "Cleanup applied",
    "Automatic cleanup is unavailable", "Cleaning this Margin", "tightened",
]


def _code(name) -> str:
    return re.sub(r"//[^\n]*", "", (SOURCES / name).read_text())


class ShareCleanupWordsGuard(unittest.TestCase):
    def test_the_share_screens_hold_none_of_the_retired_words(self):
        for name in FILES:
            text = _code(name)
            for phrase in RETIRED:
                self.assertNotIn(phrase, text, f"{name} still says {phrase!r}; use ShareCleanupWords")

    def test_the_share_screens_read_the_shared_words(self):
        for name in FILES:
            self.assertIn("ShareCleanupWords.", _code(name), name)

    def test_a_cleanup_failure_never_puts_its_reason_on_the_screen(self):
        text = (_code("Gate1AppModel+ShareDrafts.swift") + _code("Gate1AppModel+BulkSharePreparation.swift")
                + _code(BULK_STEPS))
        for line in text.splitlines():
            if "preparationMessage" in line or ".warning" in line:
                self.assertNotRegex(line, r"\\\((reason|failure|result\.failure|analysisFailure)", line.strip())
        self.assertIn("shareCleanupFailure", text)

if __name__ == "__main__":
    unittest.main()
