"""Self-hosted runner queue (#2271): per-label queue waits, the one-more-runner model and the single-file flag."""
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runner_queue as q  # noqa: E402

BUILD = ['self-hosted', 'macOS', 'sm-lane-build']


def job(queued_min, started_min, done_min, labels=BUILD, runner='sm-lane-mac-2', conclusion='success'):
    at = lambda minute: f'2026-10-21T{1 + minute // 60:02d}:{minute % 60:02d}:00Z'
    return {'name': 'release', 'labels': labels, 'created_at': at(queued_min), 'started_at': at(started_min),
            'completed_at': at(done_min), 'conclusion': conclusion, 'runner_name': runner}


def runner(name, labels, status='online'):
    return {'name': name, 'status': status, 'labels': ['self-hosted', 'macOS', 'ARM64', *labels]}


RUNNERS = [runner('sm-lane-mac', ['sm-lane']), runner('sm-lane-mac-2', ['sm-lane-build']),
           runner('sm-lane-mac-3', ['sm-lane-priority'])]

# 2026-10-21: three merge runs armed together, 20 minutes each, single file on the one sm-lane-build runner.
SINGLE_FILE = [job(0, 0, 20), job(0, 20, 40), job(0, 40, 60)]


class SummaryTests(unittest.TestCase):
    def test_the_2271_case_is_flagged_single_file_beside_two_idle_mac_runners(self):
        s = q.summarise({'runners': RUNNERS, 'jobs': SINGLE_FILE})
        self.assertEqual(s['single_file'], ['sm-lane-build'])
        self.assertEqual(s['idle'], ['sm-lane-mac', 'sm-lane-mac-3'])
        build = s['labels']['sm-lane-build']
        self.assertEqual((build['jobs'], build['runners'], build['queue_total'], build['queue_max']), (3, 1, 60, 40))

    def test_the_model_replays_the_real_queue_and_one_more_runner_halves_it(self):
        build = q.summarise({'runners': RUNNERS, 'jobs': SINGLE_FILE})['labels']['sm-lane-build']
        self.assertEqual(build['modelled_now'], (60, 40))
        self.assertEqual(build['modelled_one_more'], (20, 20))

    def test_a_second_carrier_counts_and_shrinks_the_model(self):
        both = [RUNNERS[0], RUNNERS[1], runner('sm-lane-mac-3', ['sm-lane-priority', 'sm-lane-build'])]
        build = q.summarise({'runners': both, 'jobs': SINGLE_FILE})['labels']['sm-lane-build']
        self.assertEqual(build['runners'], 2)
        self.assertEqual(build['modelled_now'], (20, 20))

    def test_an_offline_runner_or_one_missing_a_label_is_not_a_carrier(self):
        runners = [runner('a', ['sm-lane-build'], status='offline'), runner('b', ['sm-lane-priority'])]
        self.assertEqual(q.carriers(runners, 'sm-lane-build'), [])
        self.assertEqual(q.carriers(runners, 'sm-lane-build,sm-lane-priority'), [])

    def test_no_flag_when_the_other_mac_runners_were_busy(self):
        jobs = SINGLE_FILE + [job(0, 0, 30, ['self-hosted', 'macOS', 'sm-lane'], 'sm-lane-mac'),
                              job(0, 0, 30, ['self-hosted', 'macOS', 'sm-lane-priority'], 'sm-lane-mac-3')]
        s = q.summarise({'runners': RUNNERS, 'jobs': jobs})
        self.assertEqual((s['idle'], s['single_file']), ([], []))

    def test_no_flag_when_waits_are_short(self):
        jobs = [job(0, 0, 5), job(0, 5, 10), job(30, 30, 35)]
        self.assertEqual(q.summarise({'runners': RUNNERS, 'jobs': jobs})['single_file'], [])

    def test_skipped_unstarted_and_hosted_jobs_are_left_out(self):
        skipped = job(0, 0, 0, conclusion='skipped')
        unstarted = dict(job(0, 0, 0), started_at=None, completed_at=None)
        hosted = job(0, 90, 95, labels=['ubuntu-latest'], runner='GitHub Actions 1')
        never_picked_up = dict(job(0, 30, 30), runner_name=None)  # cancelled while it queued
        self.assertEqual(q.self_hosted_jobs([skipped, unstarted, hosted, never_picked_up]), [])

    def test_p90_is_nearest_rank_and_an_empty_window_reports_nothing(self):
        self.assertEqual(q.percentile(list(range(1, 11)), 90), 9)
        self.assertEqual(q.percentile([], 90), 0.0)
        s = q.summarise({'runners': RUNNERS, 'jobs': []})
        self.assertEqual((s['labels'], s['single_file']), ({}, []))

    def test_the_report_names_the_label_and_the_idle_runners(self):
        text = q.report({'since': 'a', 'until': 'b', 'runners': RUNNERS, 'jobs': SINGLE_FILE})
        self.assertIn('| sm-lane-build | 3 | 1 | 60m |', text)
        self.assertIn('Single file: `sm-lane-build`', text)
        self.assertIn('sm-lane-mac, sm-lane-mac-3 ran no job', text)


class FetchTests(unittest.TestCase):
    def test_a_window_past_githubs_1000_run_cap_fails_loudly(self):
        def api(path):  # GitHub serves 10 pages of 100, then nothing, while total_count says 1,500
            page = int(path.split('&page=')[1].split('&')[0])
            return {'total_count': 1500, 'workflow_runs': [{'id': page}] * 100 if page <= 10 else []}
        with mock.patch.object(q, '_api', side_effect=api):
            with self.assertRaisesRegex(RuntimeError, 'shorter --days'):
                q.fetch(7)


if __name__ == '__main__':
    unittest.main()
