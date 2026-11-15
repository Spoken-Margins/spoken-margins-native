"""Every sheet and full-screen cover in the app goes through the screen-rebuild tripwire (#4337).

A presentation that SwiftUI dismisses and presents again by itself builds a new screen, which flashes and loses
whatever was open on it (#2831, #4091 twice). `trackedSheet` and `trackedFullScreenCover` in
ScreenRebuildTripwire.swift record each presented screen's builds so a rebuild is caught: it fails the app-hosted test
that caused it, stops a scripted journey, and shows on the Diagnostics line `screenRebuilds`. A raw `.sheet(` or
`.fullScreenCover(` would put a screen outside all of that without any other test noticing, so this scan refuses one.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
WRAPPER = "ScreenRebuildTripwire.swift"
RAW = re.compile(r"\.(sheet|fullScreenCover)\(")


def raw_presentations(text):
    """(line number, line) for each raw call outside a `//` comment."""
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        code = line.split("//", 1)[0]
        if RAW.search(code):
            found.append((number, line.strip()))
    return found


class TrackedPresentationsTests(unittest.TestCase):
    def test_no_app_source_presents_a_sheet_or_cover_outside_the_tripwire(self):
        offenders = []
        for path in sorted(SOURCES.rglob("*.swift")):
            if path.name == WRAPPER:
                continue
            for number, line in raw_presentations(path.read_text(encoding="utf-8")):
                offenders.append(f"{path.relative_to(ROOT)}:{number}: {line}")
        self.assertEqual(offenders, [], "Use .trackedSheet( / .trackedFullScreenCover( (same arguments), so a rebuild "
                                        "of the screen is caught (#4337):\n" + "\n".join(offenders))

    def test_the_wrappers_exist_for_each_form(self):
        wrapper = (SOURCES / WRAPPER).read_text(encoding="utf-8")
        for form in ("func trackedSheet<Content", "func trackedSheet<Item", "func trackedFullScreenCover<Content",
                     "func trackedFullScreenCover<Item"):
            self.assertIn(form, wrapper)

    def test_the_scan_sees_raw_calls_and_skips_comments(self):
        self.assertEqual([n for n, _ in raw_presentations(
            "a.sheet(isPresented: $x) {\n"
            "content.fullScreenCover(item: $y) { _ in }\n"
            "// .sheet( in a comment\n"
            "b.trackedSheet(isPresented: $z) {\n"
            "let s = sheet\n")], [1, 2])


if __name__ == "__main__":
    unittest.main()
