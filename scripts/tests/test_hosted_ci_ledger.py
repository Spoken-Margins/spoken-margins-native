"""Hosted CI cost and catch (#2459, #2596): queue waits, per-job totals and fast-mac-rest catch classes."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hosted_ci_ledger as h  # noqa: E402


def job(name, conclusion='success', label='ubuntu-latest', queued='2026-10-20T10:00:00Z',
        started='2026-10-20T10:00:30Z', done='2026-10-20T10:05:30Z', runner='GitHub Actions 1'):
    return {'name': name, 'labels': [label], 'created_at': queued, 'started_at': started,
            'completed_at': done, 'conclusion': conclusion, 'runner_name': runner}


def run(rid, sha, jobs, branch='ws/x', created='2026-10-20T10:00:00Z'):
    return {'id': rid, 'head_sha': sha * 40, 'head_branch': branch, 'created_at': created, 'jobs': jobs}


def mac_job(wait_seconds, name=h.MAC_REST, conclusion='success', label='xcode-27'):
    start = f'2026-10-20T10:{wait_seconds // 60:02d}:{wait_seconds % 60:02d}Z'
    return job(name, conclusion, label, queued='2026-10-20T10:00:00Z', started=start, done='2026-10-20T10:59:00Z')


class QueueTests(unittest.TestCase):
    def test_percentile_is_nearest_rank(self):
        values = list(range(1, 11))
        self.assertEqual(h.percentile(values, 50), 5)
        self.assertEqual(h.percentile(values, 90), 9)
        self.assertEqual(h.percentile([], 90), 0.0)

    def test_only_macos_jobs_that_ran_count(self):
        runs = [run(1, 'a', [mac_job(120), job('hosted fast: portable'),
                             job('skipped mac', 'skipped', 'xcode-27', runner=None),
                             mac_job(600, label='macos-26')])]
        self.assertEqual(sorted(h.queue_waits(runs)), [120.0, 600.0])

    def test_report_flags_a_p90_over_the_limit(self):
        runs = [run(i, 'a', [mac_job(60 * 20)]) for i in range(1, 4)]
        self.assertIn('WRONG', h.report(runs))
        self.assertIn('p90 20.0 min', h.report(runs))
        runs = [run(i, 'a', [mac_job(60)]) for i in range(1, 4)]
        self.assertIn(': ok.', h.report(runs))


class WindowTests(unittest.TestCase):
    def test_since_hours_drops_older_runs(self):
        from datetime import datetime, timezone
        runs = [run(1, 'a', [], created='2026-10-20T10:00:00Z'), run(2, 'b', [], created='2026-10-25T10:00:00Z')]
        now = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
        self.assertEqual([r['id'] for r in h.since_hours(runs, 48, now)], [2])


class CatchTests(unittest.TestCase):
    def pair(self, conclusion='success'):
        return [job(n, conclusion) for n in h.PAIR]

    def test_mac_rest_failure_with_the_pair_passing_is_classed_by_what_followed(self):
        runs = [
            run(1, 'a', self.pair() + [mac_job(10, conclusion='failure')], created='2026-10-20T10:00:00Z'),
            run(2, 'a', self.pair() + [mac_job(10)], created='2026-10-20T11:00:00Z'),
            run(3, 'b', self.pair() + [mac_job(10, conclusion='failure')], branch='ws/y', created='2026-10-20T12:00:00Z'),
            run(4, 'c', self.pair() + [mac_job(10)], branch='ws/y', created='2026-10-20T13:00:00Z'),
            run(5, 'd', self.pair() + [mac_job(10, conclusion='failure')], branch='ws/z', created='2026-10-20T14:00:00Z'),
        ]
        classes = {r['run']: r['class'] for r in h.mac_rest_catches(runs)}
        self.assertEqual(classes, {1: 'flake', 3: 'fixed', 5: 'unresolved'})

    def test_a_failure_the_pair_also_saw_is_not_mac_rests_catch(self):
        runs = [run(1, 'a', self.pair('failure') + [mac_job(10, conclusion='failure')])]
        self.assertEqual(h.mac_rest_catches(runs), [])

    def test_totals_count_runs_failures_and_minutes(self):
        runs = [run(1, 'a', [job('hosted fast: portable'), job('hosted fast: portable', 'failure')])]
        totals = h.job_totals(runs)['hosted fast: portable']
        self.assertEqual((totals['runs'], totals['fail']), (2, 1))
        self.assertAlmostEqual(totals['minutes'], 10.0)


if __name__ == '__main__':
    unittest.main()
