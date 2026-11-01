"""The `area:` labels are retired (#2173): an issue's area lives in the board's Area field.

The labels were deleted from GitHub, so a script, routine or doc that reads or adds one would quietly
find nothing or fail to file an issue. This fails on any tracked tooling or doc that names one.
"""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RETIRED = re.compile(r'area: ?(sharing|groundwork|anchors|collaboration|rights)\b', re.I)
SCANNED = ('AGENTS.md', 'CLAUDE.md', 'scripts', 'ops', '.github', '.claude', 'docs', 'TestPlans')
SKIPPED = ('docs/archive/',)


def offenders():
    files = subprocess.run(['git', 'ls-files', '-z', '--', *SCANNED], cwd=ROOT, check=True,
                           capture_output=True).stdout.decode().split('\0')
    found = []
    for name in files:
        if not name or name.startswith(SKIPPED) or name == 'scripts/tests/test_no_area_labels.py':
            continue
        try:
            text = (ROOT / name).read_text(encoding='utf-8')
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if RETIRED.search(line):
                found.append(f'{name}:{number}')
    return found


class NoAreaLabels(unittest.TestCase):
    def test_pattern_catches_each_retired_label(self):
        for label in ('area: sharing', 'area:groundwork', "--label 'area: anchors'", 'area: collaboration',
                      'Area: Rights'):
            self.assertTrue(RETIRED.search(label), label)
        for text in ('Area field', 'risky area: audio', 'textarea:', 'area: sharingkit'):
            self.assertFalse(RETIRED.search(text), text)

    def test_nothing_tracked_names_a_retired_label(self):
        self.assertEqual(offenders(), [], 'use the board\'s Area field (docs/areas.md), not an area: label')


if __name__ == '__main__':
    unittest.main()
