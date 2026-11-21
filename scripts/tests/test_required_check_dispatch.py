"""Required checks that never ran on a head are started, not waited for (#4867).

scripts/required_checks.py (the shared set), scripts/dispatch_required_check.py (the sweep) and merge_policy.start_missing
(the policy's start-it step). GitHub is a small fake that records dispatches and, like GitHub, shows a dispatched run on
the head afterwards, so a second sweep finds it.
"""
from __future__ import annotations

import io
from pathlib import Path
import sys
import unittest

import yaml

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))


import dispatch_required_check as dispatch_script  # noqa: E402 - imported, not re-loaded: one ReadFailed class
import merge_policy as policy  # noqa: E402
import required_checks  # noqa: E402

REPO = 'Spoken-Margins/spoken-margins-native'


def run(status='completed', conclusion='success'):
    return {'status': status, 'conclusion': conclusion if status == 'completed' else None}


def pull(number, sha, ref=None, draft=False, state='open', repo=REPO):
    return {'number': number, 'state': state, 'draft': draft,
            'head': {'sha': sha, 'ref': ref or f'branch-{number}', 'repo': {'full_name': repo}}}


class FakeGitHub:
    repo = REPO

    def __init__(self, pulls, runs=None, broken=()):
        self.pulls = {p['number']: p for p in pulls}
        self.runs = {key: list(value) for key, value in (runs or {}).items()}  # (workflow, sha) -> runs
        self.dispatched = []
        self.broken = set(broken)  # workflows whose dispatch fails

    def api(self, path, paginate=False):
        assert paginate and path.startswith(f'repos/{REPO}/pulls?state=open'), path
        return list(self.pulls.values())

    def pull(self, number):
        return self.pulls[number]

    def workflow_runs(self, workflow, sha):
        return self.runs.get((workflow, sha), [])

    def dispatch(self, workflow, ref, inputs):
        if workflow in self.broken:
            raise policy.ReadFailed('gh api failed 1 times: HTTP 403')
        self.dispatched.append((workflow, ref, dict(inputs)))
        sha = next(p['head']['sha'] for p in self.pulls.values() if p['head']['ref'] == ref)
        self.runs.setdefault((workflow, sha), []).append(run('queued'))


def everything_ran(sha):
    return {(workflow, sha): [run()] for workflow in required_checks.dispatchable()}


class HeadStateTests(unittest.TestCase):
    def test_a_table_of_neighbouring_run_lists(self):
        table = [
            ([], 'not started'),
            ([run('queued')], 'running'),
            ([run('in_progress')], 'running'),
            ([run('waiting')], 'running'),
            ([run('completed', 'success')], 'ran'),
            ([run('completed', 'failure')], 'ran'),          # a failed run stays failed
            ([run('completed', 'skipped')], 'ran'),          # a skipped run satisfies the check (ci_model A2)
            ([run('completed', 'timed_out')], 'ran'),
            ([run('completed', 'cancelled')], 'cancelled'),  # a cancel is no verdict
            ([run('completed', 'cancelled'), run('completed', 'cancelled')], 'cancelled'),
            ([run('completed', 'cancelled'), run('completed', 'failure')], 'ran'),
            ([run('completed', 'cancelled'), run('in_progress')], 'running'),
            ([run('completed', 'failure'), run('queued')], 'running'),
        ]
        for runs, expected in table:
            with self.subTest(runs=runs):
                self.assertEqual(required_checks.head_state(runs), expected)


class SweepTests(unittest.TestCase):
    def sweep(self, github, workflow='hosted-web.yml', dry_run=False):
        out, self.naps = io.StringIO(), []
        started, failures = dispatch_script.sweep(github, workflow, 'main', dry_run, out, sleep=self.naps.append,
                                                  recheck_wait=5)
        return started, failures, out.getvalue()

    def test_a_run_that_shows_up_on_the_recheck_is_not_duplicated(self):
        github = FakeGitHub([pull(1, 'a' * 40, 'ws/one')])
        original, looks = github.workflow_runs, {'n': 0}

        def appears_late(workflow, sha):
            looks['n'] += 1
            return [run('queued')] if looks['n'] > 1 else original(workflow, sha)
        github.workflow_runs = appears_late
        started, _, _ = self.sweep(github)
        self.assertEqual((started, github.dispatched, self.naps), ([], [], [5]))

    def test_nothing_to_start_waits_for_nothing(self):
        github = FakeGitHub([pull(1, 'a' * 40)], {('hosted-web.yml', 'a' * 40): [run()]})
        self.sweep(github)
        self.assertEqual(self.naps, [])

    def test_a_failed_dispatch_on_a_branch_without_the_workflow_says_to_update_the_branch(self):
        github = FakeGitHub([pull(1, 'a' * 40, 'old-branch')])

        def not_found(workflow, ref, inputs):
            raise policy.ReadFailed('gh api failed 1 times: HTTP 404: Not Found')
        github.dispatch = not_found
        started, failures, out = self.sweep(github)
        self.assertEqual((started, failures), ([], 1))
        self.assertIn('merge main into it', out)

    def test_a_pr_whose_head_never_ran_the_check_is_started_on_its_branch(self):
        github = FakeGitHub([pull(1, 'a' * 40, 'ws/one')])
        started, failures, out = self.sweep(github)
        self.assertEqual((started, failures), ([1], 0))
        self.assertEqual(github.dispatched, [('hosted-web.yml', 'ws/one', {})])
        self.assertIn('started 1 PR(s) (#1)', out)

    def test_the_base_input_is_passed_only_to_a_workflow_that_takes_it(self):
        github = FakeGitHub([pull(1, 'a' * 40, 'ws/one')])
        self.sweep(github, 'hosted-portable.yml')
        self.assertEqual(github.dispatched, [('hosted-portable.yml', 'ws/one', {'base': 'main'})])

    def test_a_second_sweep_starts_nothing(self):
        github = FakeGitHub([pull(1, 'a' * 40), pull(2, 'b' * 40)])
        self.assertEqual(self.sweep(github)[0], [1, 2])
        started, _, out = self.sweep(github)
        self.assertEqual(started, [])
        self.assertEqual(len(github.dispatched), 2)
        self.assertIn('started 0 PR(s).', out)

    def test_neighbouring_cases(self):
        sha = {name: name[0] * 40 for name in 'abcdefg'}
        github = FakeGitHub(
            [pull(1, sha['a']),                    # never ran: started
             pull(2, sha['b']),                    # failed on this head: not restarted
             pull(3, sha['c']),                    # running: left alone
             pull(4, sha['d']),                    # cancelled: started
             pull(5, sha['e'], draft=True),        # draft: left alone
             pull(6, sha['f'], repo='fork/x'),     # fork: left alone
             pull(7, sha['g'])],                   # passed: left alone
            {('hosted-web.yml', sha['b']): [run('completed', 'failure')],
             ('hosted-web.yml', sha['c']): [run('in_progress')],
             ('hosted-web.yml', sha['d']): [run('completed', 'cancelled')],
             ('hosted-web.yml', sha['g']): [run()]})
        started, failures, _ = self.sweep(github)
        self.assertEqual((started, failures), ([1, 4], 0))

    def test_a_head_that_changed_since_its_run_counts_by_its_new_head(self):
        old, new = 'a' * 40, 'b' * 40
        github = FakeGitHub([pull(1, new)], {('hosted-web.yml', old): [run()]})
        self.assertEqual(self.sweep(github)[0], [1])

    def test_a_dry_run_starts_nothing(self):
        github = FakeGitHub([pull(1, 'a' * 40)])
        started, _, out = self.sweep(github, dry_run=True)
        self.assertEqual((started, github.dispatched), ([1], []))
        self.assertIn('would start', out)
        self.assertIn('dry run', out)

    def test_a_failed_dispatch_is_counted_and_the_rest_still_start(self):
        github = FakeGitHub([pull(1, 'a' * 40, 'one'), pull(2, 'b' * 40, 'two')], broken=())
        original = github.dispatch

        def flaky(workflow, ref, inputs):
            if ref == 'one':
                raise policy.ReadFailed('HTTP 403')
            original(workflow, ref, inputs)
        github.dispatch = flaky
        started, failures, _ = self.sweep(github)
        self.assertEqual((started, failures), ([2], 1))

    def test_main_refuses_the_workflow_it_cannot_start_and_one_that_is_no_required_check(self):
        out = io.StringIO()
        self.assertEqual(dispatch_script.main(['merge-policy.yml'], github=FakeGitHub([]), out=out), 2)
        self.assertIn("doesn't satisfy a required check", out.getvalue())
        out = io.StringIO()
        self.assertEqual(dispatch_script.main(['lane.yml'], github=FakeGitHub([]), out=out), 2)
        naps = []
        self.assertEqual(dispatch_script.main(['hosted-web.yml'], github=FakeGitHub([pull(1, 'a' * 40)]),
                                              out=io.StringIO(), sleep=naps.append), 0)
        self.assertEqual(naps, [dispatch_script.RECHECK_WAIT])


class PolicyStartTests(unittest.TestCase):
    def start(self, github, number=1, head='a' * 40):
        out, naps = io.StringIO(), []
        started = policy.start_missing(github, number, head, 'main', out, sleep=naps.append, recheck_wait=7)
        return started, out.getvalue(), naps

    def test_a_held_pr_with_a_check_that_never_ran_is_started_and_says_so(self):
        github = FakeGitHub([pull(1, 'a' * 40, 'ws/one')])
        started, out, naps = self.start(github)
        self.assertEqual(started, ['hosted-portable.yml', 'hosted-web.yml'])
        self.assertEqual(naps, [7])  # looked again before starting, in case the PR's own run was only slow to list
        self.assertIn('`hosted fast: scope`', out)
        self.assertIn('not started on this head; started `hosted-web.yml` on `ws/one`', out)
        self.assertEqual([d[:2] for d in github.dispatched],
                         [('hosted-portable.yml', 'ws/one'), ('hosted-web.yml', 'ws/one')])

    def test_a_run_that_shows_up_on_the_recheck_is_not_duplicated(self):
        github = FakeGitHub([pull(1, 'a' * 40)])
        original = github.workflow_runs
        looks = {'n': 0}

        def appears_late(workflow, sha):
            looks['n'] += 1
            if looks['n'] > len(required_checks.dispatchable()):  # the second look
                return [run('queued')]
            return original(workflow, sha)
        github.workflow_runs = appears_late
        started, _, _ = self.start(github)
        self.assertEqual((started, github.dispatched), ([], []))

    def test_a_head_with_every_check_run_starts_nothing_and_does_not_wait(self):
        github = FakeGitHub([pull(1, 'a' * 40)], everything_ran('a' * 40))
        started, out, naps = self.start(github)
        self.assertEqual((started, out, naps, github.dispatched), ([], '', [], []))

    def test_a_cancelled_check_is_not_restarted_by_the_policy_but_is_by_the_sweep(self):
        runs = {(w, 'a' * 40): [run('completed', 'cancelled')] for w in required_checks.dispatchable()}
        github = FakeGitHub([pull(1, 'a' * 40)], runs)
        self.assertEqual(self.start(github)[0], [])
        out = io.StringIO()
        started, _ = dispatch_script.sweep(github, 'hosted-web.yml', 'main', False, out, sleep=lambda s: None)
        self.assertEqual(started, [1])

    def test_the_head_moving_during_the_wait_starts_nothing(self):
        github = FakeGitHub([pull(1, 'a' * 40)])
        moved = []

        def nap(_):
            github.pulls[1] = pull(1, 'c' * 40)
            moved.append(True)
        out = io.StringIO()
        started = policy.start_missing(github, 1, 'a' * 40, 'main', out, sleep=nap, recheck_wait=7)
        self.assertEqual((started, moved, github.dispatched), ([], [True], []))

    def test_a_failed_dispatch_on_an_old_branch_says_what_to_do(self):
        github = FakeGitHub([pull(1, 'a' * 40)])

        def unprocessable(workflow, ref, inputs):
            raise policy.ReadFailed('gh api failed 1 times: HTTP 422: Workflow does not have workflow_dispatch trigger')
        github.dispatch = unprocessable
        _, out, _ = self.start(github)
        self.assertIn('merge main into it', out)

    def test_a_failed_check_is_not_restarted(self):
        runs = {(w, 'a' * 40): [run('completed', 'failure')] for w in required_checks.dispatchable()}
        github = FakeGitHub([pull(1, 'a' * 40)], runs)
        self.assertEqual(self.start(github)[0], [])

    def test_closed_draft_fork_and_moved_on_heads_are_left_alone(self):
        for name, p in {'closed': pull(1, 'a' * 40, state='closed'), 'draft': pull(1, 'a' * 40, draft=True),
                        'fork': pull(1, 'a' * 40, repo='fork/x'), 'moved on': pull(1, 'c' * 40)}.items():
            with self.subTest(name):
                github = FakeGitHub([p])
                started, out, naps = self.start(github)
                self.assertEqual((started, out, naps, github.dispatched), ([], '', [], []))

    def test_a_dispatch_that_fails_is_reported_and_blocks_nothing(self):
        github = FakeGitHub([pull(1, 'a' * 40)], broken=('hosted-web.yml',))
        started, out, _ = self.start(github)
        self.assertEqual(started, ['hosted-portable.yml'])
        self.assertIn('starting `hosted-web.yml` failed', out)

    def test_a_read_that_fails_is_reported_and_starts_nothing(self):
        github = FakeGitHub([pull(1, 'a' * 40)])

        def broken(workflow, sha):
            raise policy.ReadFailed('HTTP 502')
        github.workflow_runs = broken
        started, out, _ = self.start(github)
        self.assertEqual((started, github.dispatched), ([], []))
        self.assertIn('could not look for required checks', out)


class MainStartTests(unittest.TestCase):
    """--start never changes what the policy says: same exit code with and without it, and only for a --pr run."""

    def run_main(self, argv, judged, github, start=None):
        from unittest import mock
        started = []
        with mock.patch.object(policy, 'judge', return_value=judged), \
                mock.patch.object(policy, 'start_missing', start or (lambda *a, **k: started.append(a) or [])):
            out = io.StringIO()
            with mock.patch('sys.stdout', out):
                code = policy.main(['--repo', REPO, *argv], github=github)
        return code, started, out.getvalue()

    def test_the_exit_code_is_the_judges_with_and_without_start(self):
        github = FakeGitHub([pull(1, 'a' * 40)])
        for judged in (0, 1):
            for flags in ([], ['--start']):
                with self.subTest(judged=judged, flags=flags):
                    self.assertEqual(self.run_main(['--pr', '1', '--head', 'a' * 40, *flags], judged, github)[0], judged)

    def test_start_runs_only_with_the_flag_and_only_for_a_pr(self):
        github = FakeGitHub([pull(1, 'a' * 40)])
        self.assertEqual(self.run_main(['--pr', '1', '--head', 'a' * 40], 0, github)[1], [])
        self.assertEqual(len(self.run_main(['--pr', '1', '--head', 'a' * 40, '--start'], 0, github)[1]), 1)
        policy_group = policy.group_prs
        try:
            policy.group_prs = lambda entries, head: [(1, 'a' * 40)]
            github.queue_entries = lambda branch: []
            code, started, _ = self.run_main(['--group-head', 'g' * 40, '--start'], 0, github)
        finally:
            policy.group_prs = policy_group
        self.assertEqual((code, started), (0, []))

    def test_an_empty_head_means_the_prs_current_head(self):
        github = FakeGitHub([pull(1, 'd' * 40)])
        _, started, _ = self.run_main(['--pr', '1', '--start'], 0, github)
        self.assertEqual(started[0][:3], (github, 1, 'd' * 40))

    def test_a_crash_in_the_start_step_is_printed_and_the_verdict_stands(self):
        github = FakeGitHub([pull(1, 'a' * 40)])

        def crash(*args, **kwargs):
            raise KeyError('head')
        for judged in (0, 1):
            code, _, out = self.run_main(['--pr', '1', '--head', 'a' * 40, '--start'], judged, github, start=crash)
            self.assertEqual(code, judged)
            self.assertIn('the verdict above stands', out)


class SharedSetTests(unittest.TestCase):
    """One set, read by the dispatch script and the policy, equal to the ruleset snapshot and to the workflow files."""

    def test_the_set_is_the_rulesets_required_checks(self):
        import ci_model
        self.assertEqual(sorted(required_checks.REQUIRED_CHECKS),
                         sorted(ci_model.SNAPSHOT['ruleset']['required_checks']),
                         'a required check was added or removed in only one place: update scripts/required_checks.py '
                         'and ci_model.py SNAPSHOT together, then run the dispatch script (test-lane.md)')

    def test_each_workflow_really_produces_the_check_the_set_names_for_it(self):
        import ci_model
        produced = ci_model.extract(ROOT)['required_checks']
        for check, workflow in required_checks.REQUIRED_CHECKS.items():
            with self.subTest(check):
                self.assertIn(workflow, [p['workflow'] for p in produced[check]])

    def test_every_workflow_is_startable_or_says_why_not(self):
        for workflow in required_checks.workflows():
            with self.subTest(workflow):
                self.assertTrue((workflow in required_checks.DISPATCH_INPUTS) != (workflow in required_checks.NOT_DISPATCHABLE))
        self.assertEqual(sorted(required_checks.DISPATCH_INPUTS), sorted(required_checks.dispatchable()))

    def test_dispatch_inputs_equal_what_each_workflow_declares(self):
        for workflow, inputs in required_checks.DISPATCH_INPUTS.items():
            with self.subTest(workflow):
                doc = yaml.safe_load((ROOT / '.github/workflows' / workflow).read_text())
                triggers = doc.get('on', doc.get(True))
                self.assertIn('workflow_dispatch', triggers, f'{workflow} can not be dispatched')
                declared = ((triggers['workflow_dispatch'] or {}).get('inputs') or {})
                self.assertEqual(sorted(inputs), sorted(declared))

    def test_the_policy_and_the_dispatch_script_read_the_same_module(self):
        source = (SCRIPTS / 'merge_policy.py').read_text() + (SCRIPTS / 'dispatch_required_check.py').read_text()
        self.assertEqual(source.count('import required_checks'), 2)
        for literal in required_checks.workflows():
            self.assertNotIn(f"'{literal}'", source, f'{literal} is spelled out outside required_checks.py')


if __name__ == '__main__':
    unittest.main()
