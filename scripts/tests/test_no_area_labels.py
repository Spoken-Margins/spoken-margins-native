"""The old `area:` labels stay retired (#2173). Since 2026-11-07 (#3636) the six areas of docs/areas.md are
labels again (`area: get it in` ... `area: housekeeping`, scripts/area_labels.py), but the earlier names were
deleted from GitHub, so a script, routine or doc that reads or adds one would quietly find nothing or fail to
file an issue. This fails on any tracked tooling or doc that names one of those.
"""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RETIRED = re.compile(r'area: ?(sharing|anchors|collaboration|rights)\b', re.I)
SKIPPED = ('docs/archive/',)
# Every tracked file is read, not a list of folders (#3707): the label was written into Design/ and Contracts/docs/
# without this test noticing. It read about 3,900 text files when this was written; a scan that finds far fewer has
# lost its file list (the empty-scan class, #1905) and fails instead of passing.
SCANNED_FLOOR = 1500


def offenders():
    """(places that name a retired label, how many tracked text files were read)."""
    files = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, check=True, capture_output=True).stdout.decode().split('\0')
    found, scanned = [], 0
    for name in files:
        if not name or name.startswith(SKIPPED) or name == 'scripts/tests/test_no_area_labels.py':
            continue
        try:
            text = (ROOT / name).read_text(encoding='utf-8')
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        scanned += 1
        for number, line in enumerate(text.splitlines(), 1):
            if RETIRED.search(line):
                found.append(f'{name}:{number}')
    return found, scanned


class NoAreaLabels(unittest.TestCase):
    def test_pattern_catches_each_retired_label(self):
        for label in ('area: sharing', 'area:sharing', "--label 'area: anchors'", 'area: collaboration',
                      'Area: Rights'):
            self.assertTrue(RETIRED.search(label), label)
        for text in ('Area field', 'risky area: audio', 'textarea:', 'area: sharingkit', 'area: groundwork',
                     'area: housekeeping', 'area: hear it well'):
            self.assertFalse(RETIRED.search(text), text)

    def test_nothing_tracked_names_a_retired_label(self):
        found, scanned = offenders()
        self.assertEqual(found, [], 'use one of the six area labels in docs/areas.md')
        self.assertGreater(scanned, SCANNED_FLOOR, 'the scan lost its file list')


if __name__ == '__main__':
    unittest.main()
