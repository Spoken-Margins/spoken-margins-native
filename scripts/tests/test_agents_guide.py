"""AGENTS.md is the public contributor guide and docs/decisions.md holds the owner's dated calls (#3033, #1854).

The owner's private text (Current focus, contact rules, tooling paths, the rules that change what his agents do)
lives in an overlay outside this repository. These tests fail when that text drifts back into the public guide,
when the guide grows past a screenful of rules, or when a link in the guide or the record breaks.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUIDE = ROOT / 'AGENTS.md'
AUTOMATION = ROOT / 'docs' / 'contributing' / 'automation.md'
RECORD = ROOT / 'docs' / 'decisions.md'
PUBLIC_FILES = (GUIDE, AUTOMATION)
WORD_CAP = 4000   # the guide's budget; a rule's story goes in the record, not here
CALL_HEADER = re.compile(r"^- \*\*Owner's standing calls? \(20\d\d-\d\d-\d\d\)", re.M)
DATE_HEADING = re.compile(r'^## (20\d\d-\d\d-\d\d)$', re.M)
LINK = re.compile(r'\]\(([^)\s]+?)(?:#[^)]*)?\)')
# Phrases that belong to the owner overlay. A hit means private text drifted back into the public guide.
PRIVATE_MARKERS = ("standing call", "dyslexic", "colorblind", "sm-gh", "/Users/colemiller", "Current focus",
                   "Dial gate", "usage breaker", "docs/decisions.md")


class AgentsGuideTests(unittest.TestCase):
    def test_links_in_the_guide_and_the_record_resolve(self):
        for path in (*PUBLIC_FILES, RECORD):
            for target in LINK.findall(path.read_text()):
                if re.match(r'[a-z]+:', target):
                    continue
                self.assertTrue((path.parent / target).exists(), f'{path.name} links to missing {target}')

    def test_the_guide_is_short(self):
        words = len(GUIDE.read_text().split())
        self.assertLessEqual(words, WORD_CAP, f'AGENTS.md is {words} words; move the story to the owner overlay')

    def test_public_guide_holds_no_owner_overlay_text(self):
        for path in PUBLIC_FILES:
            text = path.read_text().lower()
            for marker in PRIVATE_MARKERS:
                self.assertNotIn(marker.lower(), text, f'{path.name} contains owner-overlay text: {marker!r}')

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
        for heading in ('## Repository map', '## How to work', '## Verification', '## Releasing a build'):
            self.assertIn(heading, text)

    def test_claude_md_imports_the_guide_first_and_the_overlay_second(self):
        lines = (ROOT / 'CLAUDE.md').read_text().split()
        self.assertEqual(lines[0], '@AGENTS.md')
        self.assertEqual(lines[1], '@~/SpokenMarginsOps/ops/OWNER.md')


if __name__ == '__main__':
    unittest.main()
