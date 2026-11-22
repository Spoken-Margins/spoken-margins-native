"""scripts/rerun_cancelled_check.py: re-run a PR's required check once when a cancelled run is the newest (#4937)."""
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


def check(id_, name, run_id, conclusion):
    return {'id': id_, 'name': name, 'conclusion': conclusion,
            'details_url': f'https://github.com/o/r/actions/runs/{run_id}/job/{id_ * 10}'}


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
        go, why = rc.decide(run(), [pull()], STUCK)
        self.assertTrue(go, why)
        self.assertIn('merge policy', why)

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
            'stop-macs-on-red: portable failed, the run cancelled itself': (
                run(name='hosted-portable'), [pull()],
                [check(20, 'hosted fast: portable', 500, 'failure'), check(21, 'hosted fast: Mac rest', 500, 'cancelled')]),
            'only an unrequired check was cancelled': (
                run(name='hosted-portable'), [pull()], [check(30, 'owner-tap-alert', 500, 'cancelled')]),
        }
        for label, (r, pulls, checks) in table.items():
            with self.subTest(label):
                go, why = rc.decide(r, pulls, checks)
                self.assertFalse(go, why)

    def test_a_portable_time_out_on_an_armed_pr_is_re_run(self):
        go, _ = rc.decide(run(name='hosted-portable'), [pull()], [
            check(40, 'hosted fast: scope', 500, 'success'), check(41, 'hosted fast: portable', 500, 'cancelled'),
            check(42, 'hosted fast: Mac rest', 500, 'skipped')])
        self.assertTrue(go)

    def test_the_run_id_is_read_from_either_url(self):
        self.assertEqual(rc.run_of({'html_url': 'https://github.com/o/r/actions/runs/123/job/9'}), 123)
        self.assertEqual(rc.run_of({'details_url': 'https://github.com/o/r/actions/runs/77'}), 77)
        self.assertIsNone(rc.run_of({'details_url': 'https://example.test/x'}))


class FakeGitHub:
    def __init__(self, answers, fail=None):
        self.answers, self.fail, self.reruns = answers, fail, []

    def get(self, path):
        if self.fail:
            raise self.fail
        for prefix, value in self.answers.items():
            if path.startswith(prefix):
                return value
        raise KeyError(path)

    def rerun(self, run_id):
        self.reruns.append(run_id)


class MainTests(unittest.TestCase):
    def test_it_re_runs_and_says_why(self):
        github = FakeGitHub({'actions/runs/500': run(), 'pulls/7': pull(), f'commits/{HEAD}/check-runs':
                             {'check_runs': STUCK}})
        out = io.StringIO()
        self.assertEqual(rc.main(['--repo', 'o/r', '--run-id', '500'], github=github, out=out), 0)
        self.assertEqual(github.reruns, [500])
        self.assertIn('re-run', out.getvalue())

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
        self.assertEqual(doc['permissions'].get('actions'), 'write')


if __name__ == '__main__':
    unittest.main()
