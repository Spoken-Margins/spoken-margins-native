import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import lane_conditions  # noqa: E402
import lane_slots  # noqa: E402
import lane_stall_report as report  # noqa: E402


def write_manifest(root, run, plan, steps, **extra):
    folder = Path(root) / run / plan
    folder.mkdir(parents=True)
    (folder / 'manifest.json').write_text(json.dumps({'plan': plan.removeprefix('verify-'), 'steps': steps, **extra}))
    return folder / 'manifest.json'


def conditions(load, pressure='normal', simulators=1, disk=30.0):
    return {'load_average': [load, load, load], 'memory_pressure': pressure, 'swap_used_mb': 1500,
            'free_disk_gb': disk, 'lane_jobs': {'build': [], 'host_test': [], 'simulator': ['x'] * simulators}}


class StallReportTests(unittest.TestCase):
    def test_each_launch_attempt_is_a_row_with_the_conditions_it_started_under(self):
        # #2176: a step that stalled once and recovered is two launches, one stalled, each with its own reading.
        with tempfile.TemporaryDirectory() as root:
            write_manifest(root, 'pr1-r1', 'verify-app', [
                {'name': 'simulator-ready'},
                {'name': 'xcode-tests', 'startup_attempts': 2, 'load_average_start': [9.0, 9.0, 9.0],
                 'startup_stalls': [{'attempt': 1, 'session_last_step': 'Launching app'}],
                 'launch_conditions': [{'attempt': 1, 'at': 'start', **conditions(180, 'warn', 2)},
                                       {'attempt': 2, 'at': 'start', **conditions(60)},
                                       {'attempt': 2, 'at': 'tests_started', 'seconds': 12.5, **conditions(60)}]}],
                app_bundle_mb=410.2)
            rows = report.collect([root])
        self.assertEqual([(r['attempt'], r['stalled'], r['conditions']['load_average'][0], r['tests_started_seconds'])
                          for r in rows], [(1, True, 180, None), (2, False, 60, 12.5)])
        out = report.report(rows)
        self.assertEqual(out['signals']['load_1m'], [('0-100', 0, 1), ('150-200', 1, 1)])
        self.assertEqual(out['signals']['memory_pressure'], [('normal', 0, 1), ('warn', 1, 1)])
        self.assertEqual(out['signals']['simulator_jobs'], [('1', 0, 1), ('2', 1, 1)])
        self.assertEqual(out['session_last_step'], {'Launching app': 1})
        self.assertEqual(out['startup_seconds_by_app_size'], {'400 MB': {'launches': 1, 'median_seconds': 12.5}})

    def test_manifests_from_before_2176_count_their_first_launch_by_the_steps_load(self):
        # Older manifests have only load_average_start; it stands for the first attempt, and a retry has no reading.
        with tempfile.TemporaryDirectory() as root:
            write_manifest(root, 'pr2-r1', 'verify-adapters', [
                {'name': 'xcode-tests', 'startup_attempts': 2, 'load_average_start': [210.0, 150.0, 120.0],
                 'startup_stalls': [{'attempt': 1, 'session_last_step': None}, {'attempt': 2}]}])
            write_manifest(root, 'pr3-r1', 'verify-app', [{'name': 'xcode-tests', 'load_average_start': [40.0, 1, 1]}])
            out = report.report(report.collect([root]))
        self.assertEqual((out['launches'], out['stalled']), (3, 2))
        self.assertEqual(out['signals']['load_1m'], [('0-100', 0, 1), ('200-300', 1, 1)])
        self.assertEqual(out['signals']['swap_used_mb'], [])
        self.assertEqual(out['by_attempt'], [('1', 1, 2), ('2', 1, 1)])
        self.assertEqual(out['session_last_step'], {'none recorded': 2})

    def test_other_plans_unreadable_manifests_and_old_days_are_left_out(self):
        with tempfile.TemporaryDirectory() as root:
            write_manifest(root, 'pr4-r1', 'verify-build', [{'name': 'xcode-tests'}])
            write_manifest(root, 'pr4-r1', 'fast', [{'name': 'xcode-tests'}])
            broken = Path(root) / 'pr5-r1/verify-app'
            broken.mkdir(parents=True)
            (broken / 'manifest.json').write_text('{not json')
            old = write_manifest(root, 'pr6-r1', 'verify-app', [{'name': 'xcode-tests'}])
            os.utime(old, (0, 0))
            self.assertEqual([r['run'] for r in report.collect([root])], ['pr6-r1'])
            self.assertEqual(report.collect([root], since='2000-01-01'), [])
            write_manifest(root, 'pr7-r1', 'verify-app', [{'name': 'xcode-tests'}])
            self.assertEqual([r['run'] for r in report.collect([root], since='2000-01-01')], ['pr7-r1'])

    def test_bucket_edges(self):
        edges = (0, 100, 150)
        self.assertEqual([report.bucket_label(v, edges) for v in (0, 99.9, 100, 149, 150, 900, -1)],
                         ['0-100', '0-100', '100-150', '100-150', '150+', '150+', '< 0'])

    def test_the_printed_report_and_json_both_run(self):
        with tempfile.TemporaryDirectory() as root:
            write_manifest(root, 'pr8-r1', 'verify-app', [
                {'name': 'xcode-tests', 'launch_conditions': [{'attempt': 1, 'at': 'start', **conditions(50)}]}])
            for flags in ([], ['--json']):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(report.main([root, *flags]), 0)
                self.assertIn('0 of 1' if not flags else '"launches": 1', out.getvalue())


class LaneConditionsTests(unittest.TestCase):
    def test_snapshot_names_the_lane_jobs_holding_slots(self):
        with tempfile.TemporaryDirectory() as state, patch.dict(os.environ, {'SM_LANE_STATE_DIR': state,
                                                                             'SM_LANE_MEMORY_PRESSURE': '2'}):
            with lane_slots.simulator_slot('runner T3 pr9', max_wait=1), \
                    lane_slots.build_slot('verify-tests app build', max_wait=1):
                found = lane_conditions.snapshot()
        self.assertEqual(found['memory_pressure'], 'warn')
        self.assertEqual(found['lane_jobs'], {'build': ['verify-tests app build'], 'host_test': [],
                                              'simulator': ['runner T3 pr9']})
        self.assertEqual(len(found['load_average']), 3)
        self.assertGreater(found['free_disk_gb'], 0)

    def test_a_missing_reading_is_none_not_an_error(self):
        with patch.object(lane_conditions.subprocess, 'run', side_effect=OSError('no sysctl')):
            self.assertIsNone(lane_conditions.swap_used_mb())
        self.assertIsNone(lane_conditions.free_disk_gb('/no/such/volume'))
        self.assertIsNone(lane_conditions.folder_mb('/no/such/App.app'))

    def test_folder_size_counts_every_file(self):
        with tempfile.TemporaryDirectory() as app:
            (Path(app) / 'Frameworks').mkdir()
            (Path(app) / 'Frameworks/model.onnx').write_bytes(b'x' * 1_500_000)
            (Path(app) / 'SpokenMarginsApp').write_bytes(b'x' * 500_000)
            self.assertEqual(lane_conditions.folder_mb(app), 2.0)


if __name__ == '__main__':
    unittest.main()
