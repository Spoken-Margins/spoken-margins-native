"""A segmented picker is drawn only through `segmentedUnlessLargeText()` (#3721).

A segmented control squeezes or clips its labels at accessibility text sizes. `segmentedUnlessLargeText()` in
`AdaptiveLayout.swift` draws one segmented at ordinary sizes and a menu at accessibility sizes (#1939). The Live session
screen's Kind picker called `.pickerStyle(.segmented)` directly, twice, and was a missed sibling. This scan fails on any
raw `.pickerStyle(.segmented)` in the app's sources outside that one place.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
HOME = "AdaptiveLayout.swift"
RAW = re.compile(r"\.pickerStyle\(\s*\.segmented\s*\)")


def _strip(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


def raw_segmented(sources: dict) -> dict:
    return {name: len(RAW.findall(_strip(text))) for name, text in sources.items()
            if name != HOME and RAW.search(_strip(text))}


class SegmentedPickerGuardTests(unittest.TestCase):
    def test_no_screen_draws_a_raw_segmented_picker(self):
        found = raw_segmented({p.name: p.read_text() for p in sorted(SOURCES.glob("*.swift"))})
        self.assertEqual(found, {}, "use .segmentedUnlessLargeText() so the picker becomes a menu at accessibility sizes")

    def test_the_helper_still_draws_a_segmented_picker_at_ordinary_sizes(self):
        text = _strip((SOURCES / HOME).read_text())
        self.assertRegex(text, r"isAccessibilitySize \{\s*content\.pickerStyle\(\.menu\)\s*\} else \{\s*content\.pickerStyle\(\.segmented\)")

    def test_the_guard_catches_the_look_alikes(self):
        for source in (".pickerStyle(.segmented)", ".pickerStyle( .segmented )", "    .pickerStyle(\n.segmented)"):
            self.assertEqual(raw_segmented({"Screen.swift": source}), {"Screen.swift": 1}, source)
        self.assertEqual(raw_segmented({"Screen.swift": "// .pickerStyle(.segmented)\n.pickerStyle(.menu)"}), {})
        self.assertEqual(raw_segmented({HOME: ".pickerStyle(.segmented)"}), {})


if __name__ == "__main__":
    unittest.main()
