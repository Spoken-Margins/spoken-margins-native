"""scripts/recorder_failed_start.py: a recorder whose start failed is stopped before it is let go (#3633)."""
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import recorder_failed_start as rfs  # noqa: E402


def rows(source):
    return rfs.scan([('App/X/Sources/X.swift', source)])


class RecorderFailedStartTests(unittest.TestCase):
    def test_the_tree_has_no_row(self):
        bad = rfs.scan(rfs.tree_sources())
        self.assertEqual(bad, [], '\n'.join(f'{p}:{n}' for p, n in bad))

    def test_the_build_36_shape_is_a_row(self):
        before = ('        recorder.prepareToRecord()\n'
                  '        guard recorder.record() else {\n'
                  '            throw SessionKitError.persistenceFailed("recording_failed")\n'
                  '        }\n')
        self.assertEqual(rows(before), [('App/X/Sources/X.swift', 2)])

    def test_a_stop_in_the_else_block_is_not_a_row(self):
        after = ('guard recorder.record() else {\n'
                 '    recorder.stop()\n'
                 '    throw E.failed\n'
                 '}\n')
        self.assertEqual(rows(after), [])

    def test_prepare_and_record_in_one_guard_is_checked(self):
        source = ('guard recorder.prepareToRecord(), recorder.record() else {\n'
                  '    try? FileManager.default.removeItem(at: url)\n'
                  '    throw E.failed\n'
                  '}\n')
        self.assertEqual(len(rows(source)), 1)

    def test_a_stop_after_the_else_block_does_not_count(self):
        source = ('guard recorder.record() else {\n'
                  '    if retry { log() }\n'
                  '    throw E.failed\n'
                  '}\n'
                  'recorder.stop()\n')
        self.assertEqual(len(rows(source)), 1)

    def test_a_bare_record_call_is_not_a_row(self):
        self.assertEqual(rows('guard isCaptureActive, let recorder else { return }\nrecorder.record()\n'), [])


if __name__ == '__main__':
    unittest.main()
