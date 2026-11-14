"""Hand-built screen and section titles carry the heading trait (#1916).

The app had three `isHeader` uses, so the VoiceOver Headings rotor skipped nearly every title. `.screenTitle()`
(ScreenTitle.swift) adds the trait. This scan fails when a `Text` that is given a title font (`.title`,
`.title2`, `.title3`, `.largeTitle`) next to its literal or item-title string drops the modifier. Titles
that are deliberately not headings are listed with the reason. Both checks read the Swift source as text: they show the
modifier is applied and still adds the heading trait, not what VoiceOver then does (#4302).
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
    ("MarginRecordingScreen.swift", "Text(MicrophonePrimer.message)"): "body copy",
    ("MarginRecordingScreen.swift", "Text(state.anchorTitle)"): "context line",
    ("ExperienceSourcesScreen.swift", "Text(letter)"): "an index letter",
    ("ExperienceSourcesScreen.swift", 'Text(title.first.map { String($0).uppercased() } ?? "?")'): "a show artwork placeholder initial, hidden from VoiceOver",
    ("ExperienceStorageScreen.swift", 'Text("\\(Int(usageFraction * 100))%")'): "a value readout",
    ("PlaybackScreen.swift", "Text(model.compactPlaybackRateDescription)"): "a value readout",
    ("SpokenNoteRecordingView.swift", "Text(title)"): "the note's name inside the rename button, which carries the heading trait itself (#3663)",
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


def title_body(source: str) -> str:
    """The body of `screenTitle()` in ScreenTitle.swift, comments removed and braces balanced; empty when it is gone."""
    code = re.sub(r"//[^\n]*", "", source)
    start = re.search(r"func\s+screenTitle\s*\(\s*\)\s*->\s*some\s+View\s*\{", code)
    if not start:
        return ""
    depth, end = 1, start.end()
    while end < len(code) and depth:
        depth += {"{": 1, "}": -1}.get(code[end], 0)
        end += 1
    return code[start.end():end - 1]


def adds_heading_trait(source: str) -> bool:
    """Whether `screenTitle()` still adds `.isHeader` (extra modifiers after it are fine), and removes nothing."""
    body = re.sub(r"\s+", "", title_body(source))
    return bool(re.search(r"accessibilityAddTraits\(\[?\.isHeader\]?\)", body)) and "accessibilityRemoveTraits" not in body


class ScreenTitleModifierTests(unittest.TestCase):
    def test_screen_title_still_adds_the_heading_trait(self):
        """#4302: the scan above trusts `.screenTitle()`, so the modifier itself must still add `.isHeader`."""
        self.assertTrue(adds_heading_trait((SOURCES / "ScreenTitle.swift").read_text()))

    def test_that_check_fails_for_a_modifier_with_another_trait_or_none(self):
        real = (SOURCES / "ScreenTitle.swift").read_text()
        for wrong in ("accessibilityAddTraits(.isStaticText)", "self", "accessibilityRemoveTraits(.isHeader)"):
            self.assertFalse(adds_heading_trait(real.replace("accessibilityAddTraits(.isHeader)", wrong)), wrong)
        self.assertFalse(adds_heading_trait("// func screenTitle() -> some View { accessibilityAddTraits(.isHeader) }\n"))

    def test_a_correct_rewrite_is_not_a_failure(self):
        for body in ("self.accessibilityAddTraits(.isHeader)", "return accessibilityAddTraits([.isHeader])",
                     "accessibilityAddTraits(.isHeader)\n            .accessibilityLabel(\"title\")"):
            source = f"extension View {{\n  func screenTitle()-> some View {{\n    {body}\n  }}\n}}\n"
            self.assertTrue(adds_heading_trait(source), body)


if __name__ == "__main__":
    unittest.main()
