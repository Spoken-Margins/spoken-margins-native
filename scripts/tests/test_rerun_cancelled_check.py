"""scripts/rerun_cancelled_check.py: re-run a PR's required check once when a cancelled run is the newest (#4937), or
when it failed outside the PR (#5057)."""
from __future__ import annotations

import io
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import rerun_cancelled_check as rc  # noqa: E402

HEAD = 'a' * 40
NEWER = 'b' * 40


def check(id_, name, run_id, conclusion, status=None):
    row = {'id': id_, 'name': name, 'conclusion': conclusion,
           'details_url': f'https://github.com/o/r/actions/runs/{run_id}/job/{id_ * 10}'}
    if status:
        row['status'] = status
    return row


def pull(number=7, head=HEAD, labels=('automerge',), state='open', draft=False):
    return {'number': number, 'state': state, 'draft': draft, 'head': {'sha': head},
            'labels': [{'name': n} for n in labels]}


def run(id_=500, conclusion='cancelled', event='pull_request', attempt=1, head=HEAD, name='merge-policy'):
    return {'id': id_, 'name': name, 'conclusion': conclusion, 'event': event, 'run_attempt': attempt,
            'head_sha': head, 'pull_requests': [{'number': 7}]}


# #4898 on 2026-11-22: the older run 499 passed, the newer run 500 was cancelled, and the PR sat blocked.
STUCK = [check(10, 'merge policy', 499, 'success'), check(11, 'merge policy', 500, 'cancelled')]


class DecideTests(unittest.TestCase):
    def test_the_4929_case_is_re_run(self):
        action, why = rc.decide(run(), [pull()], STUCK)
        self.assertEqual(action, 'rerun', why)
        self.assertIn('merge policy', why)

    def test_a_check_the_cancelled_run_left_in_progress_is_re_run(self):
        # merge-policy.yml's script writes the `merge policy` check run itself (#4986). A cancel, a timeout or a lost
        # runner kills it before it can mark the check, so GitHub leaves it in progress, in a run that has ended.
        left = [check(10, 'merge policy', 499, 'success', 'completed'),
                check(11, 'merge policy', 500, None, 'in_progress')]
        action, why = rc.decide(run(), [pull()], left)
        self.assertEqual(action, 'rerun', why)
        self.assertIn('merge policy', why)

    def test_an_in_progress_check_of_another_run_or_an_older_one_is_not_this_runs(self):
        for label, checks in {
            'a newer run is the newest': [check(11, 'merge policy', 500, None, 'in_progress'),
                                           check(12, 'merge policy', 501, 'success', 'completed')],
            'the in-progress one belongs to another run': [check(11, 'merge policy', 500, 'success', 'completed'),
                                                           check(12, 'merge policy', 501, None, 'in_progress')],
        }.items():
            with self.subTest(label):
                action, why = rc.decide(run(), [pull()], checks)
                self.assertEqual(action, 'leave', why)

    def test_a_waiting_check_of_a_successful_run_is_left_alone(self):
        # The designed pending state: the job succeeded and left the check in progress. Nothing to re-run.
        waiting = [check(11, 'merge policy', 500, None, 'in_progress')]
        action, why = rc.decide(run(conclusion='success'), [pull()], waiting)
        self.assertEqual(action, 'leave', why)

    def test_cases_left_alone(self):
        table = {
            'the older run was the cancelled one': (run(id_=499), [pull()], [
                check(10, 'merge policy', 499, 'cancelled'), check(11, 'merge policy', 500, 'success')]),
            'a newer push replaced the run': (run(), [pull(head=NEWER)], STUCK),
            'second attempt cancelled too': (run(attempt=2), [pull()], STUCK),
            'not armed': (run(), [pull(labels=('needs-fix',))], STUCK),
            'draft': (run(), [pull(draft=True)], STUCK),
            'closed': (run(), [pull(state='closed')], STUCK),
            'no PR in the event': (run(), [], STUCK),
            'a merge group run': (run(event='merge_group'), [pull()], STUCK),
            'a dispatch run': (run(event='workflow_dispatch'), [pull()], STUCK),
            'it succeeded': (run(conclusion='success'), [pull()], STUCK),
            'it was skipped': (run(conclusion='skipped'), [pull()], STUCK),
            'stop-macs-on-red: portable failed, the run cancelled itself': (
                run(name='hosted-portable'), [pull()],
                [check(20, 'hosted fast: portable', 500, 'failure'), check(21, 'hosted fast: Mac rest', 500, 'cancelled')]),
            'only an unrequired check was cancelled': (
                run(name='hosted-portable'), [pull()], [check(30, 'owner-tap-alert', 500, 'cancelled')]),
        }
        for label, (r, pulls, checks) in table.items():
            with self.subTest(label):
                action, why = rc.decide(r, pulls, checks)
                self.assertEqual(action, 'leave', why)

    def test_a_portable_time_out_on_an_armed_pr_is_re_run(self):
        action, _ = rc.decide(run(name='hosted-portable'), [pull()], [
            check(40, 'hosted fast: scope', 500, 'success'), check(41, 'hosted fast: portable', 500, 'cancelled'),
            check(42, 'hosted fast: Mac rest', 500, 'skipped')])
        self.assertEqual(action, 'rerun')

    def test_the_run_id_is_read_from_either_url(self):
        self.assertEqual(rc.run_of({'html_url': 'https://github.com/o/r/actions/runs/123/job/9'}), 123)
        self.assertEqual(rc.run_of({'details_url': 'https://github.com/o/r/actions/runs/77'}), 77)
        self.assertIsNone(rc.run_of({'details_url': 'https://example.test/x'}))


WEB_FAILED = [check(50, 'hosted web: changes', 500, 'success'),
              check(51, 'hosted web: build and Playwright', 500, 'failure')]


def outside_says(answer, step='Speech model cache'):
    """merge_queue_dequeued.failed_outside_pr's answer, recorded with the checks it was asked about."""
    asked = []

    def outside(failed):
        asked.append([c['name'] for c in failed])
        return answer, [(c['name'], step) for c in failed]
    outside.asked = asked
    return outside


class FailedOutsideThePrTests(unittest.TestCase):
    """#5057: a PR run whose failed jobs all failed in setup, or on an outside host's network error, is re-run once
    after a wait; a failed test is the PR's verdict."""

    def test_a_web_setup_failure_waits_then_re_runs(self):
        outside = outside_says(True)
        action, why = rc.decide(run(conclusion='failure', name='hosted-web'), [pull()], WEB_FAILED, outside=outside,
                                waited=False)
        self.assertEqual(action, 'wait', why)
        self.assertEqual(outside.asked, [['hosted web: build and Playwright']])
        action, why = rc.decide(run(conclusion='failure', name='hosted-web'), [pull()], WEB_FAILED, outside=outside)
        self.assertEqual(action, 'rerun', why)
        self.assertIn('Speech model cache', why)

    def test_portable_failed_in_setup_and_stop_macs_on_red_cancelled_the_run(self):
        checks = [check(60, 'hosted fast: portable', 500, 'failure'), check(61, 'hosted fast: Mac rest', 500, 'cancelled')]
        action, why = rc.decide(run(name='hosted-portable'), [pull()], checks, outside=outside_says(True, 'Set up job'),
                                waited=False)
        self.assertEqual(action, 'wait', why)

    def test_cases_left_red(self):
        failed = run(conclusion='failure', name='hosted-web')
        table = {
            'a test failed (the PR\'s verdict)': (failed, [pull()], WEB_FAILED, outside_says(False, 'Playwright suite')),
            'no reader of the failed step': (failed, [pull()], WEB_FAILED, None),
            'the re-run failed outside the PR too': (run(conclusion='failure', attempt=2), [pull()], WEB_FAILED,
                                                     outside_says(True)),
            'a newer push replaced the run': (failed, [pull(head=NEWER)], WEB_FAILED, outside_says(True)),
            'not armed': (failed, [pull(labels=())], WEB_FAILED, outside_says(True)),
            'a person re-ran it and the newer run is on the head': (failed, [pull()], WEB_FAILED + [
                check(52, 'hosted web: build and Playwright', 501, 'success')], outside_says(True)),
            'it failed, but the failed job is not in the listing': (failed, [pull()], [
                check(54, 'hosted web: changes', 500, 'success'), check(55, 'hosted fast: Mac rest', 500, 'cancelled')],
                outside_says(True)),
            'only an unrequired job failed': (failed, [pull()], [check(53, 'owner-tap-alert', 500, 'failure')],
                                              outside_says(True)),
            'a merge group run (the dequeue notifier\'s)': (run(conclusion='failure', event='merge_group'), [pull()],
                                                            WEB_FAILED, outside_says(True)),
        }
        for label, (r, pulls, checks, outside) in table.items():
            with self.subTest(label):
                action, why = rc.decide(r, pulls, checks, outside=outside, waited=False)
                self.assertEqual(action, 'leave', why)

    def test_one_test_failure_among_setup_failures_keeps_the_run_red(self):
        # failed_outside_pr answers for every failed job together; a single test step makes the whole run the PR's.
        import merge_queue_dequeued as mqd
        steps = {510: 'Set up job', 520: 'Portable fast plan'}

        class Jobs:
            def get(self, path):
                return {'steps': [{'number': 1, 'name': steps[int(path.rsplit('/', 1)[1])], 'conclusion': 'failure'}]}

            def log_tail(self, job_id):
                return 'FAILED test_example - AssertionError'
        checks = [check(51, 'hosted web: build and Playwright', 500, 'failure'),
                  check(52, 'hosted fast: portable', 500, 'failure')]
        action, why = rc.decide(run(conclusion='failure'), [pull()], checks,
                                outside=lambda failed: mqd.failed_outside_pr(Jobs(), failed), waited=False)
        self.assertEqual(action, 'leave', why)
        steps[520] = 'Set up job'
        action, why = rc.decide(run(conclusion='failure'), [pull()], checks,
                                outside=lambda failed: mqd.failed_outside_pr(Jobs(), failed), waited=False)
        self.assertEqual(action, 'wait', why)


class RealVerifyTestsLogTests(unittest.TestCase):
    def test_the_4795_outage_in_portable_fast_plan_waits_then_re_runs(self):
        # Second audit of #5070: verify-tests' own `tools: 41s — FAILED` line must not hide the outside host's error.
        import merge_queue_dequeued as mqd
        sys.path.insert(0, str(SCRIPTS / 'tests'))
        from test_merge_queue_dequeued import SetupFailureTests

        class Jobs:
            def get(self, path):
                return {'steps': [{'number': 9, 'name': 'Portable fast plan', 'conclusion': 'failure'}]}

            def log_tail(self, job_id):
                return SetupFailureTests.VERIFY_TESTS_OUTAGE
        checks = [check(70, 'hosted fast: portable', 500, 'failure')]
        action, why = rc.decide(run(conclusion='failure', name='hosted-portable'), [pull()], checks,
                                outside=lambda failed: mqd.failed_outside_pr(Jobs(), failed), waited=False)
        self.assertEqual(action, 'wait', why)


class FakeGitHub:
    def __init__(self, answers, fail=None):
        self.answers, self.fail, self.reruns, self.waits, self.after_wait = dict(answers), fail, [], [], None

    def get(self, path):
        if self.fail:
            raise self.fail
        for prefix, value in self.answers.items():
            if path.startswith(prefix):
                return value
        raise KeyError(path)

    def rerun(self, run_id):
        self.reruns.append(run_id)

    def wait(self, minutes):
        self.waits.append(minutes)
        if self.after_wait:
            self.answers.update(self.after_wait)

    def log_tail(self, job_id):
        return ''


class MainTests(unittest.TestCase):
    def test_it_re_runs_and_says_why(self):
        github = FakeGitHub({'actions/runs/500': run(), 'pulls/7': pull(), f'commits/{HEAD}/check-runs':
                             {'check_runs': STUCK}})
        out = io.StringIO()
        self.assertEqual(rc.main(['--repo', 'o/r', '--run-id', '500'], github=github, out=out), 0)
        self.assertEqual(github.reruns, [500])
        self.assertIn('re-run', out.getvalue())

    def web_failed_in_setup(self):
        return FakeGitHub({'actions/runs/500': run(conclusion='failure', name='hosted-web'), 'pulls/7': pull(),
                           f'commits/{HEAD}/check-runs': {'check_runs': WEB_FAILED},
                           'actions/jobs/': {'steps': [{'number': 3, 'name': 'Speech model cache',
                                                        'conclusion': 'failure'}]}})

    def test_a_setup_failure_waits_reads_again_and_re_runs(self):
        github = self.web_failed_in_setup()
        out = io.StringIO()
        self.assertEqual(rc.main(['--repo', 'o/r', '--run-id', '500'], github=github, out=out), 0)
        self.assertEqual(github.waits, [rc.RETRY_DELAY_MINUTES])
        self.assertEqual(github.reruns, [500])
        self.assertIn('waiting 90 minutes', out.getvalue())

    def test_a_push_during_the_wait_stops_the_re_run(self):
        github = self.web_failed_in_setup()
        github.after_wait = {'pulls/7': pull(head=NEWER)}
        out = io.StringIO()
        rc.main(['--repo', 'o/r', '--run-id', '500'], github=github, out=out)
        self.assertEqual(github.waits, [rc.RETRY_DELAY_MINUTES])
        self.assertEqual(github.reruns, [])
        self.assertIn('left alone', out.getvalue())

    def test_waited_skips_the_wait(self):
        github = self.web_failed_in_setup()
        rc.main(['--repo', 'o/r', '--run-id', '500', '--waited'], github=github, out=io.StringIO())
        self.assertEqual((github.waits, github.reruns), ([], [500]))

    def test_a_test_failure_is_neither_waited_on_nor_re_run(self):
        github = self.web_failed_in_setup()
        github.answers['actions/jobs/'] = {'steps': [{'number': 5, 'name': 'Playwright suite', 'conclusion': 'failure'}]}
        rc.main(['--repo', 'o/r', '--run-id', '500'], github=github, out=io.StringIO())
        self.assertEqual((github.waits, github.reruns), ([], []))

    def test_a_failed_read_is_a_warning_not_a_red_run(self):
        import subprocess
        github = FakeGitHub({}, fail=subprocess.CalledProcessError(1, ['gh']))
        out = io.StringIO()
        self.assertEqual(rc.main(['--repo', 'o/r', '--run-id', '500'], github=github, out=out), 0)
        self.assertIn('::warning::', out.getvalue())
        self.assertEqual(github.reruns, [])


class WorkflowTests(unittest.TestCase):
    def test_the_workflow_watches_every_workflow_that_reports_a_required_check(self):
        import yaml
        root = SCRIPTS.parent
        doc = yaml.safe_load((root / '.github/workflows/rerun-cancelled.yml').read_text())
        on = doc.get('on') or doc.get(True)
        watched = set(on['workflow_run']['workflows'])
        names = {yaml.safe_load((root / '.github/workflows' / f).read_text())['name']
                 for f in set(rc.REQUIRED_CHECKS.values())}
        self.assertEqual(watched, names)
        job = doc['jobs']['rerun']
        self.assertIn("workflow_run.event == 'pull_request'", job['if'])
        self.assertIn("workflow_run.conclusion == 'failure'", job['if'])
        self.assertIn("workflow_run.conclusion == 'cancelled'", job['if'])
        self.assertEqual(doc['permissions'].get('actions'), 'write')
        self.assertGreater(job['timeout-minutes'], rc.RETRY_DELAY_MINUTES + 2, 'the wait must fit in the job')
        sparse = job['steps'][0]['with']['sparse-checkout'].split()
        self.assertIn('scripts/merge_queue_dequeued.py', sparse, 'the script imports it')


if __name__ == '__main__':
    unittest.main()
