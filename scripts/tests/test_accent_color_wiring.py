"""The app's one tint reaches the build and the root view (#3733).

The asset's values and the filled-button rule are host-tested in SessionKit's AccentColorGuardTests; the contrast
numbers are in ExperienceColorContrastTests. This scan guards the wiring they can't see: the app target names the
accent asset (the global accent reaches alerts, menus and sheets), the generated project says the same, the asset
exists, and the scene's root view sets the same token as a tint, because toggles follow SwiftUI's tint, not the asset.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
SETTING = "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"


def _target_block(text: str, name: str) -> str:
    """The lines of one top-level target in project.yml, from its header to the next target."""
    match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  \S|\Z)", text, re.S | re.M)
    assert match, f"no target {name} in project.yml"
    return match.group(1)


class AccentColorWiringTests(unittest.TestCase):
    def test_the_app_target_names_the_accent_asset(self):
        block = _target_block((ROOT / "project.yml").read_text(), "SpokenMarginsApp")
        self.assertRegex(block, rf"{SETTING}: AccentColor\b")

    def test_the_committed_project_matches_project_yml(self):
        # Both the Debug and the Release configuration of the app target (the two that set the app's bundle id).
        project = (ROOT / "SpokenMarginsNative.xcodeproj" / "project.pbxproj").read_text()
        configurations = re.findall(r"buildSettings = \{(.*?)\n\t\t\t\};", project, re.S)
        app = [c for c in configurations if "PRODUCT_BUNDLE_IDENTIFIER = com.spokenmargins.native;" in c]
        self.assertEqual(len(app), 2, "the app target has a Debug and a Release configuration")
        for settings in app:
            self.assertIn(f"{SETTING} = AccentColor;", settings)

    def test_the_accent_asset_exists(self):
        self.assertTrue((SOURCES / "Assets.xcassets" / "AccentColor.colorset" / "Contents.json").is_file())

    def test_the_root_view_sets_the_same_token_as_a_tint(self):
        text = re.sub(r"//[^\n]*", "", (SOURCES / "SpokenMarginsApp.swift").read_text())
        self.assertIn(".tint(AppColors.evergreen)", text)


if __name__ == "__main__":
    unittest.main()
