"""The engineering words stay off a friend's path (#3247, step 5 of the arrival rebuild).

The owner reviewed the friend's words: Cole's name, "Margin", Play and Skip do the work, and "layer", "package", "source",
"integrity" and "cryptographically" never reach a friend. A friend meets these files after a file or link arrives: the
sheet a file with a choice still gets, the Margins card on the item screen, and the words behind them. This guard reads
each string literal in them (comments are not shown to anyone) and fails on a term from the list, so a later edit can't
bring one back. The Settings, Diagnostics and sender screens are not on this path and are not read.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'App' / 'SpokenMarginsApp' / 'Sources' / 'SpokenMarginsApp'
FRIEND_PATH_FILES = [
    APP / 'Build23ImportedMarginPresentation.swift',
    APP / 'Build23RecipientSharingExperience.swift',
    APP / 'FriendMarginsIntroViews.swift',
    ROOT / 'Packages' / 'SessionKit' / 'Sources' / 'SessionKit' / 'FriendArrivalWords.swift',
    ROOT / 'Packages' / 'SessionKit' / 'Sources' / 'SessionKit' / 'FriendMarginsIntro.swift',
]

# Case-sensitive, so "Source reference" is caught while a sentence that says "source" in passing is a call for a
# reviewer, not for this test.
TERMS = (
    'Integrity checked', 'integrity check', 'cryptographically', 'Source transport', 'Source reference',
    'Separate imported layer', 'separate layer', 'Layer options', 'Layer enabled', 'Layer muted', 'Reveal mode',
    'Item included in package', 'Item not included in package', 'Shared by ', 'Imported Margins', 'imported layer',
    'Importing never starts playback',
)

STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def literals(text):
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split('//', 1)[0] if '"//' not in line and 'http' not in line else line
        for match in STRING_LITERAL.finditer(code):
            yield number, match.group(1)


def violations(text):
    return [(number, term) for number, literal in literals(text) for term in TERMS if term in literal]


class FriendPathWordsTests(unittest.TestCase):
    def test_the_files_are_there(self):
        for path in FRIEND_PATH_FILES:
            self.assertTrue(path.is_file(), path)

    def test_no_engineering_term_reaches_a_friend(self):
        for path in FRIEND_PATH_FILES:
            self.assertEqual(violations(path.read_text(encoding='utf-8')), [], path.name)

    def test_the_guard_catches_each_term_and_ignores_comments(self):
        for term in TERMS:
            self.assertTrue(violations(f'Text("{term} and more")'), term)
        self.assertEqual(violations('// "Integrity checked" was the old line\nText("From Cole")'), [])
        self.assertEqual(violations('Text("From Cole") // was "Shared by Cole"'), [])


if __name__ == '__main__':
    unittest.main()
