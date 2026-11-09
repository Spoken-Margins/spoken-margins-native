"""hosted_integration_status.py (#3602): what hosted integration has proved about the trunk's tip."""
from datetime import datetime, timezone
from pathlib import Path
import io
import sys
import unittest
from unittest import mock
from contextlib import redirect_stdout, redirect_stderr

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hosted_integration_status as s  # noqa: E402

NOW = datetime(2026, 11, 7, 21, 30, tzinfo=timezone.utc)
TIP = 'c' * 40


def run(rid, sha, status='completed', conclusion='success', created='2026-11-07T19:00:00Z', updated='2026-11-07T21:00:00Z'):
    return {'id': rid, 'head_sha': sha * 40 if len(sha) == 1 else sha, 'status': status, 'conclusion': conclusion,
            'created_at': created, 'run_started_at': created, 'updated_at': updated}


class ClassifyTests(unittest.TestCase):
    def test_cancelled_and_skipped_runs_tested_nothing_so_the_last_verdict_is_older(self):
        runs = [run(4, 'd', conclusion='cancelled', created='2026-11-07T21:00:00Z'),
                run(3, 'c', conclusion='skipped', created='2026-11-07T20:00:00Z'),
                run(2, 'b', conclusion='success', created='2026-11-07T19:00:00Z'),
                run(1, 'a', conclusion='failure', created='2026-11-07T10:00:00Z')]
        self.assertEqual(s.classify(runs)['last']['id'], 2)

    def test_order_of_the_list_does_not_matter(self):
        runs = [run(1, 'a', conclusion='failure', created='2026-11-07T10:00:00Z'),
                run(2, 'b', conclusion='success', created='2026-11-07T19:00:00Z')]
        self.assertEqual(s.classify(runs)['last']['id'], 2)
        self.assertEqual(s.classify(list(reversed(runs)))['last']['id'], 2)

    def test_running_and_pending_are_found_and_the_newest_pending_wins(self):
        runs = [run(5, 'e', status='pending', conclusion=None, created='2026-11-07T21:10:00Z'),
                run(4, 'd', status='queued', conclusion=None, created='2026-11-07T21:00:00Z'),
                run(3, 'c', status='in_progress', conclusion=None, created='2026-11-07T20:00:00Z')]
        picked = s.classify(runs)
        self.assertEqual((picked['running']['id'], picked['pending']['id'], picked['last']), (3, 5, None))

    def test_no_runs_at_all(self):
        self.assertEqual(s.classify([]), {'last': None, 'running': None, 'pending': None})


class VerdictTests(unittest.TestCase):
    def picked(self, conclusion='success', sha=TIP):
        return {'last': run(1, sha, conclusion=conclusion), 'running': None, 'pending': None}

    def test_none_when_nothing_finished(self):
        self.assertEqual(s.verdict({'last': None, 'running': None, 'pending': None}, TIP, None), 'NONE')

    def test_red_beats_a_close_tip(self):
        self.assertEqual(s.verdict(self.picked('failure'), TIP, 0), 'RED')
        self.assertEqual(s.verdict(self.picked('timed_out'), TIP, 3), 'RED')

    def test_green_on_the_tip_is_ok_whatever_the_distance_says(self):
        self.assertEqual(s.verdict(self.picked(), TIP, None), 'OK')

    def test_the_limit_is_inclusive(self):
        self.assertEqual(s.verdict(self.picked(sha='a' * 40), TIP, 10), 'OK')
        self.assertEqual(s.verdict(self.picked(sha='a' * 40), TIP, 11), 'STALE')

    def test_an_unknown_distance_is_never_ok(self):
        self.assertEqual(s.verdict(self.picked(sha='a' * 40), TIP, None), 'STALE')


class MergesBetweenTests(unittest.TestCase):
    def test_counts_merged_prs_not_branch_update_merges_or_plain_commits(self):
        # 2026-11-07: 10 PR merges came with 17 merge commits and 37 commits, because PR branches merge main in.
        def c(message):
            return {'commit': {'message': message}, 'parents': [1, 2]}
        compare = {'ahead_by': 5, 'commits': [c('Merge pull request #3657: A headphone press\n\nbody'),
                                              c("Merge remote-tracking branch 'origin/main' into ws/3650-x"),
                                              c('Merge branch main into ws/3652-y'),
                                              c('Fix the thing'),
                                              c('Merge pull request #3652: Showcase speed')]}
        self.assertEqual(s.merges_between(compare), 2)

    def test_no_pr_merge_in_range_is_zero(self):
        self.assertEqual(s.merges_between({'ahead_by': 1, 'commits': [{'commit': {'message': 'Fix'}}]}), 0)

    def test_a_truncated_list_falls_back_to_the_commit_count(self):
        self.assertEqual(s.merges_between({'ahead_by': 400, 'commits': [{'commit': {'message': 'Merge pull request #1: x'}}] * 250}), 400)


class RenderTests(unittest.TestCase):
    def test_a_green_run_behind_the_tip_with_a_run_covering_it(self):
        picked = {'last': run(1, 'a', created='2026-11-07T19:00:00Z', updated='2026-11-07T21:15:00Z'),
                  'running': run(2, TIP, status='in_progress', conclusion=None, created='2026-11-07T21:00:00Z'),
                  'pending': None}
        text = s.render(picked, TIP, 17, NOW)
        self.assertIn('PASS on aaaaaaa, ran 2h15m, ended 0h15m ago; the trunk is 17 merged PRs ahead of it', text)
        self.assertIn('in progress: the current tip, 0h30m so far', text)
        self.assertIn('verdict: STALE', text)

    def test_a_pending_run_on_an_older_tip_says_it_does_not_cover_the_tip(self):
        picked = {'last': None, 'running': None, 'pending': run(2, 'b', status='pending', conclusion=None, created='2026-11-07T21:20:00Z')}
        self.assertIn('pending: bbbbbbb, not the current tip, 0h10m so far', s.render(picked, TIP, None, NOW))

    def test_one_merge_is_singular_and_a_failure_names_its_conclusion(self):
        picked = {'last': run(1, 'a', conclusion='failure'), 'running': None, 'pending': None}
        text = s.render(picked, TIP, 1, NOW)
        self.assertIn('FAIL (failure) on aaaaaaa', text)
        self.assertIn('1 merged PR ahead', text)
        self.assertIn('no run in progress or pending', text)
        self.assertIn('verdict: RED', text)


class MainTests(unittest.TestCase):
    BASE = 'repos/Spoken-Margins/spoken-margins-native'

    def api(self, runs, behind, calls=None, page_size=100):
        """Answers only the exact paths the script should ask for, so a dropped filter or a swapped compare fails."""
        def call(path):
            if calls is not None:
                calls.append(path)
            if path.startswith(f'{self.BASE}/actions/workflows/hosted-integration.yml/runs?branch=main&per_page=100&page='):
                page = int(path.rsplit('=', 1)[1])
                return {'workflow_runs': runs[(page - 1) * page_size:page * page_size]}
            if path == f'{self.BASE}/commits/main':
                return {'sha': TIP}
            if path.startswith(f'{self.BASE}/compare/'):
                base, _, head = path.rsplit('/', 1)[1].partition('...')
                if head != TIP or base == TIP:
                    return {'ahead_by': 0, 'commits': []}   # what GitHub says for the swapped direction
                return {'ahead_by': behind, 'commits': [{'commit': {'message': 'Merge pull request #1: x'}}] * behind}
            raise AssertionError(path)
        return call

    def call(self, runs, behind, argv=(), **kw):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = s.main(list(argv), api=self.api(runs, behind, **kw), now=NOW)
        return code, out.getvalue(), err.getvalue()

    def test_exit_codes_follow_the_verdict(self):
        green = [run(1, 'a')]
        self.assertEqual(self.call(green, 3)[0], 0)
        self.assertEqual(self.call(green, 30)[0], 2)
        self.assertEqual(self.call([run(1, 'a', conclusion='failure')], 1)[0], 1)
        self.assertEqual(self.call([run(1, 'a', conclusion='cancelled')], 0)[0], 2)

    def test_a_green_run_on_the_tip_is_ok_with_no_compare(self):
        calls = []
        code, text, _ = self.call([run(1, TIP)], 99, calls=calls)
        self.assertEqual(code, 0)
        self.assertIn('it tested the current tip', text)
        self.assertFalse([c for c in calls if '/compare/' in c])

    def test_the_distance_is_asked_from_the_tested_tip_to_the_tip(self):
        code, text, _ = self.call([run(1, 'a')], 4)
        self.assertIn('4 merged PRs ahead of it', text)
        self.assertEqual(code, 0)

    def test_a_red_never_asks_for_a_distance(self):
        calls = []
        self.assertEqual(self.call([run(1, 'a', conclusion='failure')], 1, calls=calls)[0], 1)
        self.assertFalse([c for c in calls if '/compare/' in c])

    def test_a_startup_failure_is_red(self):
        self.assertEqual(self.call([run(2, 'b', conclusion='startup_failure', created='2026-11-07T20:00:00Z'), run(1, 'a')], 1)[0], 1)

    def test_a_red_then_a_newer_green_is_green(self):
        runs = [run(2, 'b', created='2026-11-07T20:00:00Z'), run(1, 'a', conclusion='failure', created='2026-11-07T10:00:00Z')]
        self.assertEqual(self.call(runs, 1)[0], 0)

    def test_a_day_of_cancelled_runs_does_not_hide_the_last_verdict(self):
        cancelled = [run(1000 - i, 'x', conclusion='cancelled', created=f'2026-11-07T20:{i % 60:02d}:00Z') for i in range(120)]
        red = run(1, 'a', conclusion='failure', created='2026-11-01T10:00:00Z')
        calls = []
        code, text, _ = self.call(cancelled + [red], 1, calls=calls)
        self.assertEqual(code, 1)
        self.assertEqual(len([c for c in calls if '/runs?' in c]), 2)

    def test_it_stops_paging_after_the_page_limit(self):
        cancelled = [run(i, 'x', conclusion='cancelled', created='2026-11-07T20:00:00Z') for i in range(s.PAGE * (s.MAX_PAGES + 2))]
        calls = []
        self.assertEqual(self.call(cancelled, 0, calls=calls)[0], 2)
        self.assertEqual(len([c for c in calls if '/runs?' in c]), s.MAX_PAGES)

    def test_max_merges_changes_the_line(self):
        self.assertEqual(self.call([run(1, 'a')], 30, ['--max-merges', '40'])[0], 0)

    def test_a_bad_flag_is_a_usage_error(self):
        code, _, err = self.call([], 0, ['--nope'])
        self.assertEqual(code, 3)
        self.assertIn('usage', err)

    def test_a_bad_trunk_name_is_a_usage_error_not_a_traceback(self):
        with mock.patch.dict('os.environ', {'SM_TRUNK': 'a..b'}):
            code, _, err = self.call([], 0)
        self.assertEqual((code, 'usage' in err), (3, True))

    def test_a_failed_github_read_exits_3_without_a_traceback(self):
        def broken(path):
            raise OSError('no network')
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            self.assertEqual(s.main([], api=broken, now=NOW), 3)
        self.assertIn('could not read GitHub', err.getvalue())

    def test_a_run_with_missing_fields_exits_3_not_1(self):
        # A traceback exits 1, which a caller would read as RED.
        broken = {'id': 1, 'head_sha': 'a' * 40, 'status': 'completed', 'conclusion': 'success', 'created_at': None}
        code, _, err = self.call([broken], 1)
        self.assertEqual(code, 3)
        self.assertIn('could not read GitHub', err)


if __name__ == '__main__':
    unittest.main()
