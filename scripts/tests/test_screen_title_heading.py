"""Hand-built screen and section titles carry the heading trait (#1916).

The app had three `isHeader` uses, so the VoiceOver Headings rotor skipped nearly every title. `.screenTitle()`
(ScreenTitle.swift) adds the trait. This scan fails when a `Text` that is given a title font (`.title`,
`.title2`, `.title3`, `.largeTitle`) next to its literal or item-title string drops the modifier. Titles
that are deliberately not headings are listed with the reason.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"

TITLE_FONT = re.compile(r"\.font\(\.(largeTitle|title|title2|title3)\b")

# (file, text of the Text(...) line) that carry a title font without being a heading.
NOT_HEADINGS = {
    ("Build23ImportedMarginPresentation.swift", "Text(layer.itemTitle)"): "a row title inside the screen",
    ("Build23RecipientSharingExperience.swift", "Text(snapshot.itemTitle)"): "the item named under the screen title",
    ("Build23SenderSharingComponents.swift", "Text(preview.itemTitle)"): "a preview's item name",
    ("Build23SenderSharingExperience.swift", "Text(snapshot.itemTitle)"): "the item named under the screen title",
    ("ExperienceRecordingScreen.swift", "Text(MicrophonePrimer.message)"): "body copy",
    ("ExperienceRecordingScreen.swift", "Text(context.itemTitle)"): "context line",
    ("ExperienceSourcesScreen.swift", "Text(letter)"): "an index letter",
    ("ExperienceSourcesScreen.swift", 'Text(title.first.map { String($0).uppercased() } ?? "?")'): "a show artwork placeholder initial, hidden from VoiceOver",
    ("ExperienceStorageScreen.swift", 'Text("\\(Int(usageFraction * 100))%")'): "a value readout",
    ("PlaybackScreen.swift", "Text(model.compactPlaybackRateDescription)"): "a value readout",
    ("SharingExperience.swift", "Text(review.contents.manifest.item.title)"): "the item named under the screen title",
}


class ScreenTitleHeadingTests(unittest.TestCase):
    def test_every_titled_text_is_a_heading_or_listed_as_not_one(self):
        missing = []
        for path in sorted(SOURCES.glob("*.swift")):
            lines = path.read_text().split("\n")
            for index, line in enumerate(lines[:-1]):
                text = line.strip()
                if not text.startswith("Text(") or not TITLE_FONT.search(lines[index + 1]):
                    continue
                window = "\n".join(lines[index + 1:index + 8])
                if ".screenTitle()" in window or ".isHeader" in window:
                    continue
                if (path.name, text) in NOT_HEADINGS or (path.name, text.rstrip(" {")) in NOT_HEADINGS:
                    continue
                missing.append(f"{path.name}:{index + 1} {text}")
        self.assertEqual(missing, [], "titles without the heading trait")


if __name__ == "__main__":
    unittest.main()
