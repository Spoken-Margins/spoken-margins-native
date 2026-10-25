"""Every screen `Gate1RootView` swaps in place tells VoiceOver the screen changed (#1914).

The root view replaces whole screens instead of pushing them, so iOS sends VoiceOver no "screen changed" cue and
focus can stay on an element that is gone. `announcesScreenChange()` posts it. Home, Timeline, Settings (now a tab, #1254), Offline
Storage, Export and Batch Export had no cue until #1914. A new case in the `switch model.screen` without one would
bring that back with no other test noticing, so this scan guards it.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
CUE = ".announcesScreenChange()"

# Screens that post the cue themselves, so the root view doesn't add a second one.
SELF_ANNOUNCING = {
    "item": "ExperienceItemDetailScreen.swift",
    "playback": "PlaybackScreen.swift",
}

LINE_COMMENT = re.compile(r"//[^\n]*")


def _screen_cases() -> dict[str, str]:
    """The body of each `case .name:` inside Gate1RootView's `switch model.screen`."""
    text = LINE_COMMENT.sub("", (SOURCES / "Gate1RootView.swift").read_text())
    start = text.index("switch model.screen {")
    depth = 0
    end = None
    for index in range(text.index("{", start), len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                end = index
                break
    assert end is not None, "unbalanced braces in the screen switch"
    block = text[text.index("{", start) + 1:end]
    parts = re.split(r"^\s*case \.(\w+):", block, flags=re.M)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts), 2)}


class ScreenChangeCueTests(unittest.TestCase):
    def test_the_scan_finds_every_screen(self):
        self.assertEqual(
            set(_screen_cases()),
            {"home", "item", "playback", "timeline", "offlineStorage", "export", "batchExport"},
        )

    def test_every_swapped_screen_announces_itself_or_the_root_does(self):
        for screen, body in _screen_cases().items():
            with self.subTest(screen=screen):
                if screen in SELF_ANNOUNCING:
                    source = (SOURCES / SELF_ANNOUNCING[screen]).read_text()
                    self.assertIn(CUE, source, f"{screen} is expected to announce itself")
                else:
                    self.assertIn(CUE, body, f"the root view swaps in {screen} with no VoiceOver cue")


if __name__ == "__main__":
    unittest.main()
