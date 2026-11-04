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


class SmallestTypeGuardTests(unittest.TestCase):
    def test_no_long_sentence_uses_caption2(self):
        offenders = []
        for path in sorted(APP.rglob('*.swift')):
            for line, literal in long_caption2_texts(path.read_text()):
                offenders.append(f'{path.relative_to(ROOT)}:{line}: {literal[:60]}')
        self.assertEqual(offenders, [], 'use .footnote or larger for sentences (#3319):\n' + '\n'.join(offenders))

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
