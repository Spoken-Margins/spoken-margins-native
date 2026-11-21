"""A screen that forces a dark navigation bar also shows the bar's background (#4607).

`.toolbarColorScheme(.dark, for: .navigationBar)` darkens the status bar (clock, Wi-Fi, battery) only while the bar's
background is shown. With the default, automatic visibility the bar is clear until content scrolls under it, the status
bar follows the system, and in light mode its near-black text sat on the player's dark green screen. The player and the
live session screen both had the pairing without `.toolbarBackground(.visible, for: .navigationBar)` (or a conditional
that picks it for the dark case). The accessibility and screenshot tools see this only on a booted simulator in light
mode, so this scan guards the pairing on the host.

Every `.toolbarColorScheme(` that can be dark must have a `.toolbarBackground(` naming `.visible` within three lines
before it.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
WINDOW = 3


def unpaired(path: Path) -> list[int]:
    """Line numbers of a dark toolbarColorScheme with no `.toolbarBackground(... .visible ...)` just before it."""
    lines = path.read_text().splitlines()
    found = []
    for index, line in enumerate(lines):
        code = line.split("//", 1)[0]
        if ".toolbarColorScheme(" not in code or ".dark" not in code:
            continue
        before = [l.split("//", 1)[0] for l in lines[max(0, index - WINDOW):index]]
        paired = any(".toolbarBackground(" in l and ".visible" in l for l in before)
        if not paired:
            found.append(index + 1)
    return found


class DarkToolbarBackgroundVisibleTests(unittest.TestCase):
    def test_every_dark_navigation_bar_shows_its_background(self):
        offenders = {path.name: lines for path in sorted(SOURCES.rglob("*.swift")) if (lines := unpaired(path))}
        self.assertEqual(offenders, {}, "add .toolbarBackground(.visible, for: .navigationBar) before the dark scheme")

    def test_the_scan_sees_the_screens_it_guards(self):
        for name in ("PlaybackScreen.swift", "LiveSessionView.swift", "TimelineClipPicture.swift"):
            text = (SOURCES / name).read_text()
            self.assertIn(".toolbarColorScheme(", text, f"{name} still forces a dark bar, so the scan has something to check")

    def test_the_scan_flags_a_dark_bar_without_a_visible_background(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            bad = Path(folder) / "Bad.swift"
            bad.write_text("x\n.toolbarBackground(Color.green, for: .navigationBar)\n.toolbarColorScheme(.dark, for: .navigationBar)\n")
            self.assertEqual(unpaired(bad), [3])
            good = Path(folder) / "Good.swift"
            good.write_text("x\n.toolbarBackground(.visible, for: .navigationBar)\n.toolbarColorScheme(.dark, for: .navigationBar)\n")
            self.assertEqual(unpaired(good), [])
            conditional = Path(folder) / "Conditional.swift"
            conditional.write_text(".toolbarBackground(on ? .visible : .automatic, for: .navigationBar)\n.toolbarColorScheme(on ? .dark : nil, for: .navigationBar)\n")
            self.assertEqual(unpaired(conditional), [])
            light = Path(folder) / "Light.swift"
            light.write_text(".toolbarColorScheme(.light, for: .navigationBar)\n")
            self.assertEqual(unpaired(light), [])


if __name__ == "__main__":
    unittest.main()
