"""Done on an import pushed inside a sheet closes that sheet, unless the sheet is somewhere worth going back to (#5052).

`OPMLImportScreen` is pushed onto its host's NavigationStack. Its Done pops by default, which lands the listener back on
the screen they came through. From Following's Follow sheet that is a sheet whose only way out is Cancel, and Cancel
after a successful follow reads as undoing it (Test Desk, T4 on PR #5032). So every place that builds the screen
either passes `onDone:` (what Done does instead of popping) or is listed below with why popping back is right. A new
caller has to make that choice here, so the same trap can't come back from another entry point.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources" / "SpokenMarginsApp"
CALL = re.compile(r"\bOPMLImportScreen\(")
LINE_COMMENT = re.compile(r"//[^\n]*")

# Callers whose Done pops back on purpose, keyed by (file, the import passed in).
POPS_BACK = {
    ("CatalogDrawer.swift", "makeOPMLImport()"): (
        "the first-run drawer's file import: back on the drawer the listener keeps picking favourites, and the "
        "drawer's own Done finishes first run"
    ),
}


def _call_arguments(text: str, start: int) -> str:
    """The text between the call's parentheses, starting at the opening one."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:index]
    raise AssertionError("unclosed OPMLImportScreen( call")


def import_screen_calls(sources: Path = SOURCES):
    """(file name, importer argument, whole argument text) for each place the screen is built."""
    calls = []
    for path in sorted(sources.rglob("*.swift")):
        text = LINE_COMMENT.sub(lambda m: " " * len(m.group(0)), path.read_text(encoding="utf-8"))
        for match in CALL.finditer(text):
            if re.search(r"(?:struct|init|static func|func)\s*$", text[max(0, match.start() - 20):match.start()]):
                continue
            arguments = _call_arguments(text, match.end() - 1)
            importer = re.match(r"\s*importer:\s*([^,]+)", arguments)
            calls.append((path.name, importer.group(1).strip() if importer else "", arguments))
    return calls


class OPMLImportDoneClosesHostTests(unittest.TestCase):
    def test_every_caller_chooses_what_done_does(self):
        calls = import_screen_calls()
        self.assertGreaterEqual(len(calls), 3, "the scan should find the Follow sheet's and the drawer's imports")
        undecided = [
            f"{name}: OPMLImportScreen({arguments.strip()})"
            for name, importer, arguments in calls
            if "onDone:" not in arguments and (name, importer) not in POPS_BACK
        ]
        self.assertEqual(
            undecided,
            [],
            "Done on these imports pops back to the screen they came through. Pass onDone: to close the host, or "
            "list the caller in POPS_BACK with why going back there is right (#5052).",
        )

    def test_the_follow_sheet_import_closes_the_follow_sheet(self):
        follow_sheet = [arguments for name, _, arguments in import_screen_calls() if name == "FollowSheet.swift"]
        self.assertEqual(len(follow_sheet), 1)
        self.assertRegex(follow_sheet[0], r"onDone:\s*\{\s*dismiss\(\)\s*\}")

    def test_pops_back_entries_still_exist(self):
        found = {(name, importer) for name, importer, _ in import_screen_calls()}
        self.assertEqual(sorted(set(POPS_BACK) - found), [], "remove POPS_BACK entries whose caller is gone")

    def test_a_new_caller_without_on_done_is_caught(self):
        import tempfile

        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "NewEntry.swift").write_text(
                "struct NewEntry: View {\n"
                "    var body: some View {\n"
                "        // OPMLImportScreen(importer: x, onDone: {}) in a comment doesn't count\n"
                "        NavigationLink { OPMLImportScreen(importer: makeOPMLImport(), opensFilePickerOnAppear: true) }\n"
                "    }\n"
                "}\n",
                encoding="utf-8",
            )
            calls = import_screen_calls(Path(folder))
        self.assertEqual(len(calls), 1)
        self.assertNotIn("onDone:", calls[0][2])


if __name__ == "__main__":
    unittest.main()
