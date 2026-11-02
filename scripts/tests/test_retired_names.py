"""Names the listener no longer sees stay gone from the app's screens (#3208).

Four tabs renamed Sources to Following and settled the Add sheet's name, but old words stayed in labels, captions
and hints: a "Refresh Sources" button on Following, "appear in Sources", an Add sheet with three names, "Native Audio
Back". Brief rule 7: name things in the listener's words, not the code's. This scan fails when a retired name comes
back in a string in `App/SpokenMarginsApp/Sources`. Comments are ignored; accessibility identifiers (`sources.*`,
`home.addSource.button`) are not names and are not scanned for.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "App" / "SpokenMarginsApp" / "Sources"

# Each entry: the retired text and what the listener reads now.
RETIRED = {
    "Refresh Sources": "Refresh Following",
    "appear in Sources": "appear in Following",
    "under Add Source": "under Add to Library",
    "Opens Add Source": "Opens Add to Library",
    "Native Audio": "Podcast Skip Back / Forward",
    "Episode Map Preparation": "Prepare Chapters and Scenes Ahead",
    "from Add Source": "with Add to Library",
    "New from Sources": "Following",
}


def retired_uses(text: str, name: str) -> list[int]:
    """Line numbers where `name` sits in a string literal on a line that isn't a comment.

    Inside a triple-quoted string (the guided tour's text) every line is string, so no quote pair is needed.
    """
    hits = []
    in_block = False
    for number, line in enumerate(text.splitlines(), 1):
        if not in_block and line.lstrip().startswith("//"):
            continue
        code = line if in_block else re.split(r"\s//", line)[0]
        if in_block:
            matched = name in code
        else:
            matched = bool(re.search(r'"[^"\n]*' + re.escape(name) + r'[^"\n]*"', code))
        if matched:
            hits.append(number)
        if code.count('"""') % 2 == 1:
            in_block = not in_block
    return hits


class RetiredNamesScanTests(unittest.TestCase):
    def test_scan_finds_a_retired_name_in_a_string(self):
        self.assertEqual(retired_uses('Text("Refresh Sources")', "Refresh Sources"), [1])
        self.assertEqual(retired_uses('a\n  .accessibilityLabel("Refresh Sources")', "Refresh Sources"), [2])

    def test_scan_reads_every_line_of_a_triple_quoted_string(self):
        text = 'text: """\n  Add a podcast from Add Source.\n  """\nlet x = 1'
        self.assertEqual(retired_uses(text, "from Add Source"), [2])
        self.assertEqual(retired_uses('let y = 2 // from Add Source', "from Add Source"), [])

    def test_scan_ignores_comments_and_identifiers(self):
        self.assertEqual(retired_uses('// "Refresh Sources" was renamed', "Refresh Sources"), [])
        self.assertEqual(retired_uses('let x = 1 // "Refresh Sources"', "Refresh Sources"), [])
        self.assertEqual(retired_uses('.accessibilityIdentifier("sources.refresh")', "Refresh Sources"), [])

    def test_no_retired_name_is_in_a_screen_string(self):
        offenders = []
        for path in sorted(SOURCES.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for name, now in RETIRED.items():
                for line in retired_uses(text, name):
                    offenders.append(f'{path.name}:{line} "{name}" (now: {now})')
        self.assertEqual(offenders, [], "retired names are back; use the listener's current word")


if __name__ == "__main__":
    unittest.main()
