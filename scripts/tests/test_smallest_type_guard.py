"""No sentence is set in the smallest type (#3319).

The human-factors audit (#1862) found explanations a listener must read before sharing, or when changing how
other apps are handled, set in `.caption2` (11 pt at the default size). Long text in the smallest size is the
hardest combination to read with dyslexia. This guard fails on a `Text("...")` literal longer than 40
characters whose modifier chain sets `.font(.caption2...)`. Interpolated values (`\\(...)`) count as nothing,
so a short counter such as "3/280" passes. Labels and badges under the limit stay as they are.

Scope is the iPhone and iPad app. The watch and the widgets have their own type rules.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'App' / 'SpokenMarginsApp' / 'Sources'
LIMIT = 40
# Text("literal") then the run of `.modifier(...)` lines that follow it, ending at the first line that is not one.
TEXT = re.compile(r'Text\("((?:[^"\\]|\\.)*)"\)((?:[ \t]*\n?[ \t]*\.[A-Za-z]+(?:\([^\n]*\))?)*)')
INTERPOLATION = re.compile(r'\\\([^()]*\)')


def visible_length(literal):
    previous = None
    while previous != literal:
        previous, literal = literal, INTERPOLATION.sub('', literal)
    return len(literal)


def long_caption2_texts(source):
    found = []
    for match in TEXT.finditer(source):
        literal, chain = match.groups()
        if '.font(.caption2' in chain and visible_length(literal) > LIMIT:
            found.append((source[:match.start()].count('\n') + 1, literal))
    return found

# Sentences that say what is shared or sent, or what the listener agrees to (#3337, from the #3319 call on each
# `.caption` sentence over 70 characters). Each must stay `.footnote` or larger. Keyed by file, then the literal.
# Shortening the copy is the owner's voice and is not part of this guard.
PINNED_FOOTNOTE = {
    'Build23RecipientSharingExperience.swift': ['Deleting this import removes your local copy only.'],
    'Build23SenderSharingComponents.swift': ['These excerpts help place the Margin for the recipient.'],
    'SharingExperience.swift': [
        'The recipient will rebuild it from this link.',
        'This Spoken Margins sample is app-authored',
        'The full listened-to text will be included so the recipient',
        'This cannot be included.',
    ],
    'Gate1RootView.swift': ['This note helps you choose what to send.'],
    'ExportScreen.swift': ['Native audio exports include only bounded listening context'],
    'SettingsScreen.swift': [
        'Send transcripts of public episodes to the Spoken Margins server',
        'App state and recent playback events, as a file for a bug report.',
        'A private log of listening time, Margins, shares and finishes',
    ],
}
SMALL_FONT = re.compile(r'\.font\(\.caption2?[.)]')


def small_pinned_texts(source, prefixes):
    """Pinned sentences found in `source` whose modifier chain sets `.caption` or `.caption2`."""
    small = []
    for match in TEXT.finditer(source):
        literal, chain = match.groups()
        if SMALL_FONT.search(chain) and any(literal.startswith(prefix) for prefix in prefixes):
            small.append(literal)
    return small


class SmallestTypeGuardTests(unittest.TestCase):
    def test_no_long_sentence_uses_caption2(self):
        offenders = []
        for path in sorted(APP.rglob('*.swift')):
            for line, literal in long_caption2_texts(path.read_text()):
                offenders.append(f'{path.relative_to(ROOT)}:{line}: {literal[:60]}')
        self.assertEqual(offenders, [], 'use .footnote or larger for sentences (#3319):\n' + '\n'.join(offenders))

    def test_sharing_and_privacy_sentences_stay_footnote_or_larger(self):
        offenders = []
        for name, prefixes in PINNED_FOOTNOTE.items():
            paths = list(APP.rglob(name))
            self.assertEqual(len(paths), 1, f'{name} moved or was renamed: update PINNED_FOOTNOTE (#3337)')
            source = paths[0].read_text()
            for prefix in prefixes:
                self.assertIn(f'Text("{prefix}', source, f'{name}: "{prefix}" is gone or reworded: update PINNED_FOOTNOTE')
            offenders += [f'{name}: {literal[:60]}' for literal in small_pinned_texts(source, prefixes)]
        self.assertEqual(offenders, [], 'use .footnote or larger for what is shared or agreed to (#3337):\n' + '\n'.join(offenders))

    def test_the_pinned_check_sees_a_caption_and_ignores_footnote(self):
        self.assertEqual(len(small_pinned_texts('Text("Sent: all")\n .font(.caption)\n .foregroundStyle(.red)', ['Sent'])), 1)
        self.assertEqual(len(small_pinned_texts('Text("Sent: all")\n .font(.caption2)', ['Sent'])), 1)
        self.assertEqual(small_pinned_texts('Text("Sent: all")\n .font(.footnote)', ['Sent']), [])
        self.assertEqual(small_pinned_texts('Text("Other")\n .font(.caption)', ['Sent']), [])

    def test_the_guard_sees_a_long_caption2_text(self):
        long_text = 'Text("' + 'word ' * 12 + '")\n    .font(.caption2)\n    .foregroundStyle(.secondary)'
        self.assertEqual(len(long_caption2_texts(long_text)), 1)

    def test_the_guard_ignores_short_labels_counters_and_larger_type(self):
        self.assertEqual(long_caption2_texts('Text("NEW")\n .font(.caption2.weight(.bold))'), [])
        self.assertEqual(long_caption2_texts('Text("\\(draft.count)/\\(Model.limit)")\n .font(.caption2)'), [])
        self.assertEqual(long_caption2_texts('Text("' + 'word ' * 12 + '")\n .font(.footnote)'), [])
        # a .caption2 on the next view must not be read as this Text's modifier
        self.assertEqual(long_caption2_texts('Text("' + 'word ' * 12 + '")\n .font(.body)\nText("a")\n .font(.caption2)'), [])


if __name__ == '__main__':
    unittest.main()
