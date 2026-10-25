"""#2633: the repeat-trigger guard flags the shape that caused #2626 and nothing that is merely a counter."""
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'repeat_trigger_scan.py'
spec = importlib.util.spec_from_file_location('repeat_trigger_scan', SCRIPT)
scan = importlib.util.module_from_spec(spec)
sys.modules['repeat_trigger_scan'] = scan
spec.loader.exec_module(scan)


class Judging(unittest.TestCase):
    def flagged(self, line, previous=''):
        return [rhs for _, _, rhs in scan.judge(line, previous)]

    def test_the_2626_shape_is_flagged(self):
        # The line that shipped in Build 35: true on every buffer after one seek.
        self.assertEqual(self.flagged('if sparseSchedule.continuityEpoch > 0 {'), ['0'])
        self.assertEqual(self.flagged('if schedule.continuityEpoch >= 1 {'), ['1'])
        self.assertEqual(self.flagged('if a.renderGeneration > b.limit {'), ['b.limit'])

    def test_a_served_marker_compare_passes(self):
        self.assertEqual(self.flagged('if sparseSchedule.continuityEpoch > stablePostSeekServedEpoch {'), [])
        self.assertEqual(self.flagged('if itemRevision > lastHandledRevision {'), [])

    def test_validity_edge_and_staleness_compares_pass(self):
        self.assertEqual(self.flagged('&& landmark.continuityEpoch >= 0'), [])
        self.assertEqual(self.flagged('if observedGeneration != reading.transportGeneration {'), [])
        self.assertEqual(self.flagged('if request.generation < currentGeneration {'), [])

    def test_a_comment_is_not_code(self):
        self.assertEqual(self.flagged('let x = 1 // continuityEpoch > 0 was the bug'), [])

    def test_an_exemption_comment_names_the_marker(self):
        self.assertEqual(self.flagged('if epoch > 0 {', '// once-per-trigger: reset to 0 in noteSeek'), [])
        self.assertEqual(self.flagged('if epoch > 0 { // once-per-trigger: reset in noteSeek'), [])
        self.assertEqual(self.flagged('if seekEpoch > 0 {', '// unrelated note'), ['0'])

    def test_other_names_are_not_counters(self):
        self.assertEqual(self.flagged('if words.count > 0 {'), [])
        self.assertEqual(self.flagged('if retryCount > 3 {'), [])


class TheTree(unittest.TestCase):
    def test_no_source_line_is_flagged(self):
        rows = scan.scan(scan.swift_files())
        self.assertEqual(rows, [], 'a counter compare can stay true after it fires (#2626 class)')


if __name__ == '__main__':
    unittest.main()
