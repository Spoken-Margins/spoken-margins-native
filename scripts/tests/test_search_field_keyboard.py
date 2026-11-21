"""A search box's keyboard always has a way down (#4636).

A listener who tapped the Library search field could not put the keyboard away: the Search key left it up, the
Library list did not close it on a drag, and there was no Done on the keyboard bar. A SwiftUI behaviour like this
can't be seen by a host test, so this scan guards the three ways down:

1. `AppSearchField` takes the field out of focus on submit (the Search key).
2. Every file that draws an `AppSearchField` also sets `.scrollDismissesKeyboard(.interactively)`, so a drag closes
   the keyboard. A new screen with the box has to do the same.
3. Every such file also adds `.searchKeyboardDoneBar()` (a Done on the keyboard bar), except a sheet whose
   navigation bar already has its own Done and Cancel, named in `OWN_DONE`. The bar is declared on the host's
   list, not inside the field: a toolbar in a List row may never reach the navigation stack.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
FIELD_FILE = SOURCES / "ExperienceDesignSystem.swift"
# Library and Margins use the box (the collection's item picker, `CollectionItemsSheet`, was retired by #3769's Select).
MIN_HOSTS = 2
# A sheet whose navigation bar has Cancel and its own Done would not take a second Done on the keyboard (#4636); none today.
OWN_DONE: set[str] = set()


def field_body(text: str) -> str:
    """The source of `struct AppSearchField`, up to the next top-level declaration."""
    start = text.index("struct AppSearchField")
    match = re.search(r"\n(?:/// |struct |final class |class |enum |extension )", text[start + 10:])
    return text[start:start + 10 + match.start()] if match else text[start:]


def hosts(files: dict[str, str]) -> list[str]:
    return sorted(name for name, text in files.items() if re.search(r"AppSearchField\s*\(", text))


def hosts_missing(files: dict[str, str], marker: str, exempt: set[str] = frozenset()) -> list[str]:
    """Host files that never set the marker; a comment line does not count."""
    missing = []
    for name in hosts(files):
        code = "\n".join(line for line in files[name].splitlines() if not line.lstrip().startswith("//"))
        if name not in exempt and marker not in code:
            missing.append(name)
    return missing


class SearchFieldKeyboardTests(unittest.TestCase):
    def test_the_scan_flags_a_host_without_the_drag_or_the_bar(self):
        files = {
            "A.swift": 'AppSearchField("x", text: $q, identifier: "a")\n.scrollDismissesKeyboard(.interactively)',
            "B.swift": 'AppSearchField("x", text: $q, identifier: "b")',
            "C.swift": 'Text("no box")',
            "D.swift": 'AppSearchField ("x", text: $q, identifier: "d")\n// .scrollDismissesKeyboard(.interactively)',
        }
        self.assertEqual(hosts_missing(files, ".scrollDismissesKeyboard(.interactively)"), ["B.swift", "D.swift"])
        self.assertEqual(hosts_missing(files, ".searchKeyboardDoneBar()", {"B.swift"}), ["A.swift", "D.swift"])

    def test_the_search_key_closes_the_keyboard(self):
        self.assertRegex(field_body(FIELD_FILE.read_text(encoding="utf-8")),
                         r"\.onSubmit\s*\{\s*isFocused\s*=\s*false\s*\}")

    def test_the_done_bar_resigns_the_first_responder(self):
        text = FIELD_FILE.read_text(encoding="utf-8")
        start = text.index("func searchKeyboardDoneBar()")
        bar = text[start:start + 700]
        self.assertIn("ToolbarItemGroup(placement: .keyboard)", bar)
        self.assertIn('Button("Done")', bar)
        self.assertIn("resignFirstResponder", bar)

    def test_every_screen_with_the_box_closes_the_keyboard(self):
        files = {
            path.name: path.read_text(encoding="utf-8")
            for path in sorted(SOURCES.glob("*.swift")) if path != FIELD_FILE
        }
        self.assertGreaterEqual(len(hosts(files)), MIN_HOSTS, "the scan stopped finding the screens that draw the box")
        self.assertEqual(hosts_missing(files, ".scrollDismissesKeyboard(.interactively)"), [])
        self.assertEqual(hosts_missing(files, ".searchKeyboardDoneBar()", OWN_DONE), [])
        for name in OWN_DONE:
            self.assertIn(name, files, f"{name} in OWN_DONE no longer exists")


if __name__ == "__main__":
    unittest.main()
