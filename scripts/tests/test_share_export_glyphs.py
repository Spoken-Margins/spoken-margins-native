"""Share and Export wear different glyphs, so the picture says what the word says (#3211).

Share means another listener and wears the system share arrow (`square.and.arrow.up`). Export means yourself or your
tools and wears the document glyph (`doc.text`). Before this check every Export door wore the share arrow, so the icon
said "send to someone" while the word said "take out for yourself". A control's words are its button title or label,
its accessibility label and its identifier; a new door that mixes the two fails here, with the line to change.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"

SHARE_ARROW = "square.and.arrow.up"
DOCUMENT = "doc.text"
# How far around a glyph line its control's words can sit (the label, accessibility label and identifier).
BEFORE, AFTER = 4, 6
# Lines whose glyph is not a control: the Share glyph beside a sentence about the share sheet.
NOT_A_CONTROL = {
    ("BatchExportScreen.swift", 'Image(systemName: "square.and.arrow.up")'),
}


def words_near(lines: list[str], index: int) -> str:
    """The control's own words around a glyph line, stopping at the next control or the end of this one."""
    start, end = index, index
    while start > max(0, index - BEFORE) and not re.search(r"\bButton\b|\bMenu\b|ShareLink", lines[start]):
        start -= 1
    while end < min(len(lines) - 1, index + AFTER) and not re.search(r"\.accessibilityIdentifier", lines[end]):
        end += 1
    # An identifier names the control for tests (`export.share.button`) and may keep an old word; only what the
    # listener reads or hears counts.
    return " ".join(line for line in lines[start:end + 1] if ".accessibilityIdentifier" not in line)


def controls_with(glyph: str):
    for path in sorted(SOURCES.glob("*.swift")):
        lines = path.read_text().splitlines()
        for index, line in enumerate(lines):
            if f'"{glyph}"' not in line or line.strip().startswith("//"):
                continue
            if "systemImage:" not in line and "Image(systemName:" not in line:
                continue  # a glyph name returned from a switch is not a control
            if (path.name, line.strip()) in NOT_A_CONTROL:
                continue
            yield path.name, index + 1, words_near(lines, index)


def mentions(words: str, word: str) -> bool:
    return re.search(rf"\b{word}\b", words, re.IGNORECASE) is not None


class ShareExportGlyphTests(unittest.TestCase):
    def test_no_export_control_wears_the_share_arrow(self):
        offenders = [f"{name}:{line}" for name, line, words in controls_with(SHARE_ARROW)
                     if mentions(words, "export|exports") and not mentions(words, "share")]
        self.assertEqual([], offenders, "Export controls take doc.text, not the share arrow (#3211)")

    def test_no_share_control_wears_the_document_glyph(self):
        offenders = [f"{name}:{line}" for name, line, words in controls_with(DOCUMENT)
                     if mentions(words, "share") and not mentions(words, "export|exports")]
        self.assertEqual([], offenders, "Share controls take the share arrow, not doc.text (#3211)")

    def test_the_scan_sees_both_kinds_of_door(self):
        """A scan that finds nothing would pass on a typo; it must see the doors it guards."""
        share_doors = [words for _, _, words in controls_with(SHARE_ARROW) if mentions(words, "share")]
        export_doors = [words for _, _, words in controls_with(DOCUMENT) if mentions(words, "export|exports")]
        self.assertGreaterEqual(len(share_doors), 5)
        self.assertGreaterEqual(len(export_doors), 8)

    def test_the_playback_options_dock_has_distinct_glyphs(self):
        """The dock's two icon-only buttons, Details and Export, used to wear the same document glyph."""
        text = (SOURCES / "PlaybackScreen.swift").read_text()
        dock = text[text.index("private var sessionActionDock"):]
        dock = dock[:dock.index(".font(.subheadline.weight(.semibold))")]
        glyphs = re.findall(r'Image\(systemName: "([^"]+)"\)', dock)
        self.assertEqual(["info.circle", DOCUMENT], glyphs, "Details is info.circle and Export is doc.text")


if __name__ == "__main__":
    unittest.main()
