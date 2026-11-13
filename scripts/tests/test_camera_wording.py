"""The camera prompt says only what the app does (#2708).

Photo Margins use the system camera when the listener taps Photo. The picture stays on this device and a shared
Margin never carries it, so the iOS prompt (project.yml and the committed Info.plist) must say that and no more, and
must not say "phone": the app runs on iPad too.
"""
import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LINE = (
    "Spoken Margins uses the camera only when you tap Photo, to take a picture of the page or board for your "
    "Margin. The picture stays on this device and is never sent with a shared Margin."
)


class CameraWordingTests(unittest.TestCase):
    def test_info_plist_prompt_is_the_reviewed_line(self):
        with open(ROOT / "App/SpokenMarginsApp/Info.plist", "rb") as f:
            self.assertEqual(plistlib.load(f)["NSCameraUsageDescription"], LINE)

    def test_project_yml_matches_info_plist(self):
        yml = (ROOT / "project.yml").read_text()
        self.assertEqual(yml.count("NSCameraUsageDescription: " + LINE + "\n"), 1)

    def test_only_the_app_asks_for_the_camera(self):
        # The extensions and the Watch never open a camera, so none declares the key.
        yml = (ROOT / "project.yml").read_text()
        self.assertEqual(yml.count("NSCameraUsageDescription"), 1)

    def test_the_line_never_says_phone_as_a_word(self):
        self.assertIsNone(re.search(r"\bphone\b", LINE.lower()))


if __name__ == "__main__":
    unittest.main()
