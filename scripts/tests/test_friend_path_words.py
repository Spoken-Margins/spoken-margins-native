"""The engineering words stay off a friend's path (#3247, step 5 of the arrival rebuild).

The owner reviewed the friend's words: Cole's name, "Margin", Play and Skip do the work, and "layer", "package", "source",
"integrity" and "cryptographically" never reach a friend. A friend meets these files after a file or link arrives: the
sheet a file with a choice still gets, the Margins card on the item screen, and the words behind them.

What this guard checks, and nothing more. It reads each string literal in the friend-path files (comments are not
shown to anyone; identifiers with no space and text inside \\( ) are skipped) and fails on:
1. a phrase from TERMS, such as "Integrity checked" or "Shared by ";
2. the whole words "package", "source", "layer", "integrity" or "verified" in a sentence, unless that exact sentence
   is listed in KNOWN_STAND_INS.

KNOWN_STAND_INS are sentences the step 5 and step 6 pages do not cover. They are listed so the owner can pick words
for them, and each is named in the PR table. Removing one from the list is the way to prove it is gone. The Settings,
Diagnostics and sender screens are not on this path and are not read.
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

# Sentences on the friend's path that still use an engineering word because no reviewed page gives a replacement.
KNOWN_STAND_INS = frozenset({
    'Article text verified', 'Transcript verified', 'Audio verified',
    'Add the source to continue',
    'A matching source is required for ',
    'Add the matching source before importing',
})

WORDS = re.compile(r'\b(package|source|layer|integrity|verified)\b', re.IGNORECASE)
INTERPOLATION = re.compile(r'\\\([^)]*(?:\([^)]*\)[^)]*)*\)')

STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def literals(text):
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split('//', 1)[0] if '"//' not in line and 'http' not in line else line
        for match in STRING_LITERAL.finditer(code):
            yield number, match.group(1)


def sentence_words(literal):
    shown = INTERPOLATION.sub('', literal)
    if ' ' not in shown.strip() or shown in KNOWN_STAND_INS:
        return []
    return WORDS.findall(shown)


def violations(text):
    found = [(number, term) for number, literal in literals(text) for term in TERMS if term in literal]
    found += [(number, word) for number, literal in literals(text) for word in sentence_words(literal)]
    return found


class FriendPathWordsTests(unittest.TestCase):
    def test_the_files_are_there(self):
        for path in FRIEND_PATH_FILES:
            self.assertTrue(path.is_file(), path)

    def test_no_engineering_term_reaches_a_friend(self):
        for path in FRIEND_PATH_FILES:
            self.assertEqual(violations(path.read_text(encoding='utf-8')), [], path.name)

    def test_the_guard_catches_the_engineering_words_in_a_sentence(self):
        for word in ('package', 'source', 'layer', 'integrity', 'verified'):
            self.assertTrue(violations(f'Text("Please add the {word} now")'), word)
        self.assertEqual(violations('.accessibilityIdentifier("build23.imported.layer.\\(id).report")'), [])
        self.assertEqual(violations('Text("\\(possessiveMargins(senderLabel: layer.senderLabel)) on")'), [])

    def test_every_known_stand_in_is_still_in_the_files(self):
        text = ' '.join(path.read_text(encoding='utf-8') for path in FRIEND_PATH_FILES)
        for sentence in KNOWN_STAND_INS:
            self.assertIn(sentence, text, 'delete it from KNOWN_STAND_INS: ' + sentence)

    def test_the_guard_catches_each_term_and_ignores_comments(self):
        for term in TERMS:
            self.assertTrue(violations(f'Text("{term} and more")'), term)
        self.assertEqual(violations('// "Integrity checked" was the old line\nText("From Cole")'), [])
        self.assertEqual(violations('Text("From Cole") // was "Shared by Cole"'), [])


# The sender's side and the screens that show a file's Margins once it is in (#3210). The words below are the file-format
# and cryptography terms the design audit found on the main path: "verified package", "integrity check",
# "acoustic anchor signatures". Main-path labels say "Margins" (or "the file" where a file is the point). The rights
# wording in SharingRightsPresentation.swift is a lawyer's to review and is not read here.
SENDER_PATH_FILES = [
    APP / 'Build23SenderSharingExperience.swift',
    APP / 'Build23SenderSharingComponents.swift',
    APP / 'SharingExperience.swift',
    APP / 'ExperienceMarginsScreen.swift',
    APP / 'ShareLinkSender.swift',
    APP / 'Build23SharingSeams.swift',
]

# Case-sensitive. Each is a phrase a listener once read.
RETIRED_PHRASES = (
    'verified package', 'Verified package', 'Share verified', 'verified share file', 'verifying the recipient',
    'could not be verified', 'No verified recipient', 'verified projection', 'package-affecting',
    'Package contents', 'Package ready', 'Package details', 'Package and placement', 'Preview package details',
    'Acoustic anchor signatures', 'Integrity checked', 'Package integrity', 'integrity check', 'cryptographically',
    'Verified from the written package', 'in the package', 'the package ', 'Verifying',
)


def retired_phrases(text):
    return [(number, phrase) for number, literal in literals(text) for phrase in RETIRED_PHRASES if phrase in literal]


class SenderPathWordsTests(unittest.TestCase):
    def test_the_files_are_there(self):
        for path in SENDER_PATH_FILES:
            self.assertTrue(path.is_file(), path)

    def test_no_retired_phrase_returns_to_the_sharing_screens(self):
        for path in SENDER_PATH_FILES:
            self.assertEqual(retired_phrases(path.read_text(encoding='utf-8')), [], path.name)

    def test_the_guard_catches_each_phrase_and_ignores_comments(self):
        for phrase in RETIRED_PHRASES:
            self.assertTrue(retired_phrases(f'Text("{phrase} and more")'), phrase)
        self.assertEqual(retired_phrases('// "Share verified package" was the old label\nText("Share your Margins")'), [])
        self.assertEqual(retired_phrases('Text("We can\'t prove who sent this.")'), [])
        # The identifiers and rights wording that keep these words are not literals in these files.
        self.assertEqual(retired_phrases('.accessibilityIdentifier("build23.sender.recipient.verified-preview")'), [])


SESSIONKIT = ROOT / 'Packages' / 'SessionKit' / 'Sources'
ALL_SWIFT_ROOTS = [ROOT / 'App', SESSIONKIT]

# The stand-ins for a missing sender name (#3247). A file that names nobody carries one of these as an internal key;
# no screen may show one. Only these files may use the constants or the literals.
STAND_IN = re.compile(r'importedCollectionLabel|unsignedSenderLabel|Imported collection|Unsigned sender')
STAND_IN_ALLOWED = {
    # Defines the constants and the one function (senderName) that turns a label into a name or nil.
    'Packages/SessionKit/Sources/SessionKit/SharedPacketArrival.swift',
}

# A raw sender label printed on a screen. It may hold a stand-in, so shown text goes through
# FriendArrivalWords or SharedPacketArrival.senderName instead.
RAW_SHOWN = re.compile(r'Text\(\s*[\w.]*senderLabel\s*\)|\\\(\s*[\w.]*senderLabel\s*\)')
RAW_SHOWN_ALLOWED = {
    # These print a MarginLayerSynthesis label, not a snapshot label: MarginLayerSynthesis.label turns a blank label
    # into "Someone", and the app never writes a stand-in into a layer's displayLabel. The label also feeds the stored
    # summary's input and digest, so it must not change here. MarginLayerSummary.swift builds the model prompt.
    'App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceReactionsScreen.swift',
    'Packages/SessionKit/Sources/SessionKit/MarginLayerSummary.swift',
}


def swift_files():
    for base in ALL_SWIFT_ROOTS:
        yield from sorted(base.rglob('*.swift'))


def stand_in_uses(text):
    return [(number, match.group(0))
            for number, line in enumerate(text.splitlines(), 1)
            for match in STAND_IN.finditer(line.split('//', 1)[0])]


def raw_shown_uses(text):
    return [(number, m.group(0)) for number, line in enumerate(text.splitlines(), 1)
            for m in RAW_SHOWN.finditer(line.split('//', 1)[0])]


class StandInGuardTests(unittest.TestCase):
    def test_no_stand_in_is_used_outside_its_definition(self):
        for path in swift_files():
            rel = path.relative_to(ROOT).as_posix()
            if rel in STAND_IN_ALLOWED:
                continue
            self.assertEqual(stand_in_uses(path.read_text(encoding='utf-8')), [], rel)

    def test_no_raw_sender_label_is_printed(self):
        for path in swift_files():
            rel = path.relative_to(ROOT).as_posix()
            if rel in RAW_SHOWN_ALLOWED:
                continue
            self.assertEqual(raw_shown_uses(path.read_text(encoding='utf-8')), [], rel)

    def test_the_allowlists_name_files_that_still_need_them(self):
        for rel in STAND_IN_ALLOWED:
            self.assertTrue(stand_in_uses((ROOT / rel).read_text(encoding='utf-8')), rel)
        for rel in RAW_SHOWN_ALLOWED:
            self.assertTrue(raw_shown_uses((ROOT / rel).read_text(encoding='utf-8')), rel)

    def test_the_old_import_sheet_stays_deleted(self):
        # It drew review.senderLabel raw and nothing presented it (#3909); the live sheet is Build23RecipientSharingExperience.
        back = [p for p in (ROOT / 'App').rglob('*.swift')
                if 'SpokenMarginsPackageImportView' in p.read_text(encoding='utf-8')]
        self.assertEqual(back, [], 'the old import sheet is back: use the live sheet, or route its sender through FriendArrivalWords')

    def test_the_guard_catches_each_way_to_show_a_stand_in(self):
        self.assertTrue(stand_in_uses('let x = SharedPacketArrival.importedCollectionLabel'))
        self.assertTrue(stand_in_uses('Text("Imported collection")'))
        self.assertTrue(stand_in_uses('return "Unsigned sender"'))
        self.assertEqual(stand_in_uses('// was "Unsigned sender"\nlet x = 1'), [])
        self.assertTrue(raw_shown_uses('Text(review.senderLabel)'))
        self.assertTrue(raw_shown_uses('Text("Reply to \\(layer.senderLabel)")'))
        self.assertEqual(raw_shown_uses('Text(FriendArrivalWords.fromLine(senderLabel: snapshot.senderLabel))'), [])


if __name__ == '__main__':
    unittest.main()
