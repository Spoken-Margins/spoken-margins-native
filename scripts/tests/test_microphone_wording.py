"""Every microphone line tells the same, true thing about recordings (#3447).

Share links and sent files take a recording off the phone, so no line may say recordings "stay on
your phone" without the share exception. The iOS prompt (project.yml and the committed Info.plist),
the in-app primer (MicrophonePrimer.swift) and the first-run design note must all carry it.
"""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRUE_CLAIM = "Recordings stay on your phone unless you choose to share them."
BARE_CLAIM = re.compile(r"stay on your phone(?! unless you choose to share them)")


class MicrophoneWordingTests(unittest.TestCase):
    def test_info_plist_prompt(self):
        with open(ROOT / "App/SpokenMarginsApp/Info.plist", "rb") as f:
            text = plistlib.load(f)["NSMicrophoneUsageDescription"]
        self.assertIn(TRUE_CLAIM, text)

    def test_project_yml_matches_info_plist(self):
        yml = (ROOT / "project.yml").read_text()
        with open(ROOT / "App/SpokenMarginsApp/Info.plist", "rb") as f:
            plist_text = plistlib.load(f)["NSMicrophoneUsageDescription"]
        self.assertIn("NSMicrophoneUsageDescription: " + plist_text, yml)

    def test_primer_message(self):
        swift = (ROOT / "Packages/SessionKit/Sources/SessionKit/MicrophonePrimer.swift").read_text()
        self.assertIn(TRUE_CLAIM, swift)

    def test_no_bare_claim_left_in_app_or_design_text(self):
        for rel in (
            "project.yml",
            "App/SpokenMarginsApp/Info.plist",
            "Packages/SessionKit/Sources/SessionKit/MicrophonePrimer.swift",
            "docs/design/first-run.md",
        ):
            text = (ROOT / rel).read_text()
            self.assertIsNone(BARE_CLAIM.search(text), f"{rel} still says recordings stay on the phone, unqualified")


if __name__ == "__main__":
    unittest.main()
