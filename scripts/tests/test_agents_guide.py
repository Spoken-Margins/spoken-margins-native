"""AGENTS.md is the public contributor guide (#1854): its links resolve, and the owner's private text stays out."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_FILES = ('AGENTS.md', 'docs/contributing/automation.md')
# Phrases that belong to the owner overlay. A hit means private text drifted back into the public guide.
PRIVATE_MARKERS = ("standing call", "dyslexic", "colorblind", "sm-gh", "/Users/colemiller", "Current focus",
                   "Dial gate", "usage breaker")


class AgentsGuideTests(unittest.TestCase):
    def test_relative_links_resolve(self):
        for name in PUBLIC_FILES:
            path = ROOT / name
            for target in re.findall(r'\]\(([^)#\s]+)(?:#[^)]*)?\)', path.read_text()):
                if re.match(r'[a-z]+:', target):
                    continue
                self.assertTrue((path.parent / target).exists(), f'{name} links to missing {target}')

    def test_public_guide_holds_no_owner_overlay_text(self):
        for name in PUBLIC_FILES:
            text = (ROOT / name).read_text().lower()
            for marker in PRIVATE_MARKERS:
                self.assertNotIn(marker.lower(), text, f'{name} contains owner-overlay text: {marker!r}')

    def test_claude_md_imports_the_public_guide_first(self):
        lines = (ROOT / 'CLAUDE.md').read_text().split()
        self.assertEqual(lines[0], '@AGENTS.md')

    def test_public_guide_keeps_the_sections_threads_read(self):
        text = (ROOT / 'AGENTS.md').read_text()
        for heading in ('## Repository map', '## How to work', '## Verification'):
            self.assertIn(heading, text)


if __name__ == '__main__':
    unittest.main()
