"""The phone-found bug list by device condition (#3899): the list is valid, the doc and the script agree on the rows."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import device_conditions as dc

DOC = Path(__file__).resolve().parents[2] / 'docs/workstreams/device-conditions.md'


def write(text):
    handle = tempfile.NamedTemporaryFile('w', suffix='.tsv', delete=False)
    handle.write(text)
    handle.close()
    return Path(handle.name)


class ListTests(unittest.TestCase):
    def test_the_shipped_list_is_valid(self):
        bugs = dc.load()
        self.assertGreaterEqual(len(bugs), 51)
        self.assertEqual(dc.problems(bugs), [])

    def test_every_row_has_a_section_in_the_doc(self):
        text = DOC.read_text()
        for row in dc.ROWS:
            self.assertIn(f'`{row}`', text, f'{row} has no row in the doc')

    def test_every_row_has_a_bug(self):
        used = {bug['row'] for bug in dc.load()}
        self.assertEqual(set(dc.ROWS) - used, set())

    def test_counts_share_leaves_out_no_row_bugs(self):
        bugs = [dict(issue=1, created='2026-11-01', state='open', row='route', also='', title=''),
                dict(issue=2, created='2026-11-02', state='open', row='none:logic', also='', title=''),
                dict(issue=3, created='2026-11-03', state='open', row='lock', also='route', title='')]
        primary, with_row, total = dc.counts(bugs)
        self.assertEqual((with_row, total, primary['route']), (2, 3, 1))
        self.assertIn('2 of 3 have a device condition (67%)', dc.report(bugs))


class ProblemTests(unittest.TestCase):
    def test_unknown_row_repeated_issue_and_bad_also_are_named(self):
        path = write('1\t2026-11-01\topen\tteleport\t\tx\n1\t2026-11-01\topen\tnone:logic\t\tx\n'
                     '2\t2026-11-01\topen\tlock\tlock\tx\n3\t2026-11-01\topen\tlock\tmoon\tx\n')
        found = dc.problems(dc.load(path))
        self.assertEqual(len(found), 4, found)

    def test_a_short_line_is_refused(self):
        with self.assertRaises(ValueError):
            dc.load(write('1\t2026-11-01\topen\n'))

    def test_a_non_number_issue_is_refused(self):
        with self.assertRaises(ValueError):
            dc.load(write('x\t2026-11-01\topen\tlock\t\tt\n'))


if __name__ == '__main__':
    unittest.main()
