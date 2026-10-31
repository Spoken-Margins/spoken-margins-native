"""AGENTS.md stays a short guide and docs/decisions.md holds the owner's dated calls (#3033).

The owner agreed on 2026-10-30 that the guide keeps the rules that change an agent's behaviour and the
standing calls live in a decisions record. These tests fail when a dated call drifts back into the guide,
when the guide grows past a screenful of rules, or when a link in either file breaks.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / 'AGENTS.md'
RECORD = ROOT / 'docs' / 'decisions.md'
WORD_CAP = 4000   # the guide's budget; a rule's story goes in the record, not here
CALL_HEADER = re.compile(r"^- \*\*Owner's standing calls? \(20\d\d-\d\d-\d\d\)", re.M)
DATE_HEADING = re.compile(r'^## (20\d\d-\d\d-\d\d)$', re.M)
LINK = re.compile(r'\]\(([^)\s]+?)(?:#[^)]*)?\)')


class AgentsGuideTests(unittest.TestCase):
    def test_links_in_the_guide_and_the_record_resolve(self):
        for path in (GUIDE, RECORD):
            for target in LINK.findall(path.read_text()):
                if re.match(r'[a-z]+:', target):
                    continue
                self.assertTrue((path.parent / target).exists(), f'{path.name} links to missing {target}')

    def test_the_guide_is_short(self):
        words = len(GUIDE.read_text().split())
        self.assertLessEqual(words, WORD_CAP, f'AGENTS.md is {words} words; move the story to docs/decisions.md')

    def test_dated_calls_live_in_the_record_not_the_guide(self):
        self.assertFalse(CALL_HEADER.search(GUIDE.read_text()), 'a dated standing call is in AGENTS.md')
        self.assertGreaterEqual(len(CALL_HEADER.findall(RECORD.read_text())), 17)

    def test_the_record_is_grouped_by_date_in_order(self):
        dates = DATE_HEADING.findall(RECORD.read_text())
        self.assertGreaterEqual(len(dates), 19)
        self.assertEqual(dates, sorted(dates))
        self.assertEqual(len(dates), len(set(dates)), 'a date heading repeats')

    def test_the_guide_keeps_the_sections_threads_read(self):
        text = GUIDE.read_text()
        for heading in ('## Working with the owner', '## Current focus', '## Repository map', '## How to work',
                        '## Verification', '## Releasing a build'):
            self.assertIn(heading, text)
        self.assertIn('docs/decisions.md', text)

    def test_claude_md_imports_the_guide(self):
        self.assertEqual((ROOT / 'CLAUDE.md').read_text().split()[0], '@AGENTS.md')


if __name__ == '__main__':
    unittest.main()
