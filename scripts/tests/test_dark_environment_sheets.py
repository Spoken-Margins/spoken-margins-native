"""A sheet opened from a screen drawn dark through the environment asks for its own scheme (#5414).

`.environment(\\.colorScheme, .dark)` darkens a screen's content, and a sheet presented from inside it inherits that
environment, but the sheet's own container follows the device. In light mode the Timeline inside Now Playing opened a
Link details sheet that drew light while its text took the dark scheme's white, so the link's title could not be seen
(Test Desk, #4778 run on c7020f7). The cure is `.preferredColorScheme(...)` on the presented content, which makes the
whole sheet match. A simulator sees this only in light mode, so this scan guards the pairing on the host.

In a Swift file that sets `.environment(\\.colorScheme, .dark)`, every `.sheet`, `.fullScreenCover` or `.popover`
(tracked or not) must name `.preferredColorScheme(` inside its content closure.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
DARK_ENVIRONMENT = re.compile(r"\.environment\(\s*\\\.colorScheme\s*,\s*\.dark\s*\)")
PRESENTATION = re.compile(r"\.(?:trackedSheet|sheet|trackedFullScreenCover|fullScreenCover|popover)\(")


def _strip_comments(text: str) -> str:
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def _closure_after(code: str, start: int) -> str:
    """The text of the first brace-delimited closure at or after `start`, or '' when there is none."""
    opening = code.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return code[opening:index + 1]
    return code[opening:]


def unmatched(text: str) -> list[int]:
    """Line numbers of presentations whose content doesn't ask for a scheme, in a file that forces dark."""
    code = _strip_comments(text)
    if not DARK_ENVIRONMENT.search(code):
        return []
    found = []
    for match in PRESENTATION.finditer(code):
        if ".preferredColorScheme(" not in _closure_after(code, match.end()):
            found.append(code.count("\n", 0, match.start()) + 1)
    return found


class DarkEnvironmentSheetTests(unittest.TestCase):
    def test_every_sheet_from_a_dark_environment_asks_for_its_scheme(self):
        offenders = {path.name: lines for path in sorted(SOURCES.rglob("*.swift")) if (lines := unmatched(path.read_text()))}
        self.assertEqual(offenders, {}, "add .preferredColorScheme(...) to the presented content (#5414)")

    def test_the_scan_sees_the_screen_it_guards(self):
        text = (SOURCES / "ExperienceTimelineRailScreen.swift").read_text()
        self.assertRegex(text, DARK_ENVIRONMENT, "the Timeline still draws dark through the environment")
        self.assertRegex(text, PRESENTATION, "and still opens sheets, so the scan has something to check")

    def test_the_scan_flags_a_sheet_without_a_scheme(self):
        dark = "content.environment(\\.colorScheme, .dark)\n"
        bad = dark + ".trackedSheet(item: $x) { row in\n    Detail(row: row)\n}\n"
        self.assertEqual(unmatched(bad), [2])
        good = dark + ".trackedSheet(item: $x) { row in\n    Detail(row: row)\n        .preferredColorScheme(scheme)\n}\n"
        self.assertEqual(unmatched(good), [])
        nested = dark + ".sheet(isPresented: $on) {\n    VStack { Text(\"a\") }\n}\n.preferredColorScheme(.dark)\n"
        self.assertEqual(unmatched(nested), [2], "a scheme after the closure is on the presenter, not the sheet")
        commented = dark + ".fullScreenCover(item: $x) { x in\n    V(x) // .preferredColorScheme(.dark)\n}\n"
        self.assertEqual(unmatched(commented), [2])
        light = "content.environment(\\.colorScheme, .light)\n.sheet(isPresented: $on) { V() }\n"
        self.assertEqual(unmatched(light), [])


if __name__ == "__main__":
    unittest.main()
