"""A listener's tap on a Following friend opens the item off the main thread (#3413, part of #2505).

`Gate1AppModel.openItem(id:)` reads the item on the main thread, so a big item freezes the tap. A listener's tap uses
`openItemFromTap(id:)`, which reads off the main thread and leaves the screen up until the item is ready. #3412 moved
the friend row back onto `openItemFromTap` after a merge had left it on `openItem`, and no test would have noticed.

What this guard checks, and nothing more (a scan of source text, no compiler):
1. `friendRow(_:)` on the Following screen: a friend with one item calls `model.openItemFromTap(id:)` and never
   `openItem`; a friend with several items only sets `openFriend` (the items screen opens, nothing is read at the tap).
2. Each item row on `FollowingFriendItemsScreen` calls `openItemFromTap`.
3. No other view calls `openItem` on the model unless it is listed in KNOWN_MAIN_THREAD_OPENS with the reason. A new
   tap site gets `openItemFromTap`; a list entry is for code that reads the result on the next line.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"

# Views that may still open an item on the main thread, each with the reason. Empty since #3416 moved the last two. Removing a line here is how to show one is fixed.
KNOWN_MAIN_THREAD_OPENS: dict = {}


def _code(path: Path) -> str:
    return re.sub(r"//[^\n]*", "", path.read_text())


def _body(text: str, start_pattern: str) -> str:
    """From the match to the closing brace at the same indent as its opening line."""
    match = re.search(start_pattern, text)
    assert match, f"{start_pattern} not found: the guard needs updating with the rename"
    line_start = text.rfind("\n", 0, match.start()) + 1
    indent = re.match(r"[ ]*", text[line_start:]).group(0)
    end = text.index("\n" + indent + "}", match.start())
    return text[match.start():end]


class ListenerTapOpensOffMainTests(unittest.TestCase):
    def test_a_friend_with_one_item_opens_it_from_the_tap_path(self):
        row = _body(_code(APP / "ExperienceSourcesScreen.swift"), r"private func friendRow\(")
        self.assertRegex(row, r"friend\.items\.count == 1,\s*let item = friend\.items\.first\s*\{\s*model\.openItemFromTap\(id: item\.id\)\s*\}")
        self.assertNotRegex(row, r"\bopenItem\(")

    def test_a_friend_with_several_items_reads_nothing_at_the_tap(self):
        row = _body(_code(APP / "ExperienceSourcesScreen.swift"), r"private func friendRow\(")
        # The tap closure only: the modifiers after it are not the tap.
        closure = row[:row.index("\n        }\n")]
        match = re.search(r"\belse\s*\{(.*)", closure, re.DOTALL)
        self.assertIsNotNone(match, "friendRow lost its several-items branch")
        self.assertEqual(re.sub(r"[\s}]+", " ", match.group(1)).strip(), "openFriend = friend")

    def test_each_item_on_the_friends_items_screen_opens_from_the_tap_path(self):
        text = _code(APP / "FollowingFriendRows.swift")
        screen = text[text.index("struct FollowingFriendItemsScreen"):]
        self.assertRegex(screen, r"Button\s*\{\s*model\.openItemFromTap\(id: item\.id\)\s*\}\s*label:")
        self.assertNotRegex(screen, r"\bopenItem\(")

    def test_no_other_view_opens_an_item_on_the_main_thread(self):
        found = set()
        for path in sorted(APP.glob("*.swift")):
            if path.name.startswith("Gate1AppModel"):
                continue
            # Any receiver (`model`, `appModel`, `$0`, a key path); `environment.openItem` is the import
            # coordinator's closure, which the model fills in and which is not a view tap.
            # Strings go first (an accessibility id), and the dot needs a receiver (`== .openItem` is an enum case).
            code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', _code(path))
            if re.search(r"(?<!environment)(?<=[\w?)])\.openItem\b", code):
                found.add(path.name)
        self.assertEqual(
            found - set(KNOWN_MAIN_THREAD_OPENS), set(),
            "a view calls model.openItem on a listener's tap: use model.openItemFromTap (#2505, #3413)",
        )
        self.assertEqual(
            set(KNOWN_MAIN_THREAD_OPENS) - found, set(),
            "KNOWN_MAIN_THREAD_OPENS lists a file that no longer calls model.openItem: remove the line",
        )


if __name__ == "__main__":
    unittest.main()
