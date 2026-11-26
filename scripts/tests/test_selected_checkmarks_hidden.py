"""A checkmark glyph that marks a selected row is hidden from VoiceOver (#4639).

A ticked row says it is selected with the `.isSelected` trait, and a bare `Image(systemName: "checkmark")` is also an
accessibility element named "checkmark", so VoiceOver reads "HIST 210, checkmark, selected". The other collection
sheets already hide the glyph. The component is a source scan because the accessibility tree only exists in an
app-hosted test with automation switched on, and this class (one row hiding it, the next forgetting) is what came back.

Every `Image(systemName: "checkmark")` in the app must carry `.accessibilityHidden(true)` on the same line or in the
next three lines, unless it is listed below with the reason an element above it already names the state.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
GLYPH = re.compile(r'Image\(systemName:\s*"checkmark"\)')
WINDOW = 3

# file name -> why a glyph there may stay visible to VoiceOver.
ALLOWED = {
    # The button's `.accessibilityLabel(option.title)` replaces its children, so the glyph is never read.
    "PlaybackMarginsFilterView.swift": 1,
}


def _unhidden(path: Path) -> list[int]:
    """Line numbers of checkmark glyphs with no accessibilityHidden(true) on their line or the next WINDOW lines."""
    lines = path.read_text().splitlines()
    found = []
    for index, line in enumerate(lines):
        code = line.split("//", 1)[0]
        if not GLYPH.search(code):
            continue
        nearby = "\n".join(lines[index:index + WINDOW + 1])
        if ".accessibilityHidden(true)" not in nearby:
            found.append(index + 1)
    return found


class SelectedCheckmarksHiddenTests(unittest.TestCase):
    def test_every_checkmark_glyph_is_hidden_from_voiceover(self):
        offenders = {}
        for path in sorted(SOURCES.glob("*.swift")):
            lines = _unhidden(path)
            if len(lines) > ALLOWED.get(path.name, 0):
                offenders[path.name] = lines
        self.assertEqual(offenders, {}, "add .accessibilityHidden(true) to these checkmark glyphs (the row's selected "
                         "trait already says it), or list the file in ALLOWED with the reason")

    def test_the_scan_sees_the_glyphs_it_is_meant_to_guard(self):
        sheet = (SOURCES / "ItemCollectionSheet.swift").read_text()
        self.assertRegex(sheet, GLYPH, "the Add to Collection sheet still draws its checkmark, so the scan has something to check")

    def test_the_scan_flags_a_glyph_with_nothing_hiding_it(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            bad = Path(folder) / "Bad.swift"
            bad.write_text('Spacer()\nif on {\n    Image(systemName: "checkmark").foregroundStyle(.red)\n}\n')
            self.assertEqual(_unhidden(bad), [3])
            good = Path(folder) / "Good.swift"
            good.write_text('if on {\n    Image(systemName: "checkmark").foregroundStyle(.red)\n        .accessibilityHidden(true)\n}\n')
            self.assertEqual(_unhidden(good), [])
            commented = Path(folder) / "Commented.swift"
            commented.write_text('// Image(systemName: "checkmark") is drawn by the row\n')
            self.assertEqual(_unhidden(commented), [])


if __name__ == "__main__":
    unittest.main()
