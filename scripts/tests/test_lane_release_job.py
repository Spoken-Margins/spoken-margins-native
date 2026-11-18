"""lane.yml's `release` job: the automerge run a clean audit re-arms, dispatched with auto=true (#2170).

It was also where a T3 PASS handed a held automerge run's host tests (#1209) until #4572 took the T3 hold away; a
dispatch without auto=true now starts nothing.
"""
from __future__ import annotations

import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import FakeGitHub, HEAD, MERGE, lane  # noqa: E402
import workflow_yaml  # noqa: E402

WORKFLOW = (Path(__file__).resolve().parents[2] / '.github/workflows/lane.yml').read_text()


def job_steps(workflow: str, job: str) -> list[dict]:
    """A job's steps from lane.yml, each as {key: value}, block scalars (`run: |`) with their indentation removed.

    Enough YAML for this file's own layout (jobs at 2 spaces, steps at 6, step keys at 8), without PyYAML, which
    neither the venv nor the runners' /usr/bin/python3 carries."""
    body = workflow.split(f'\n  {job}:\n', 1)[1]
    body = re.split(r'\n  (?:[a-z][\w-]*:|# )', body, maxsplit=1)[0]  # up to the next job or the comment before it
    steps, step, key = [], None, None
    for line in body.split('\n    steps:\n', 1)[1].splitlines():
        if line.startswith('      - '):
            step, key = {}, None
            steps.append(step)
            line = '        ' + line[8:]
        if step is None or line.startswith('      #'):
            continue
        field = re.match(r'^        ([A-Za-z][\w-]*):(?: (.*))?$', line)
        if field:
            key, value = field.group(1), (field.group(2) or '').strip()
            step[key] = '' if value in ('|', '>-', '>', '') else value
        elif key is not None and (line.startswith('          ') or not line.strip()):
            step[key] += line[10:] + '\n'
    return steps


class AuditDispatchTests(unittest.TestCase):
    run_main = test_lane_runner.MainFlowTests.run_main
    conflicts, role, attempt, state_dir, ops = [], '', '1', None, mock.Mock()

    def test_the_audit_s_dispatch_for_a_fork_s_pr_or_another_base_runs_nothing(self):
        # #2170: the automerge job's `if` checks these for a pull_request event; a dispatch has no such event.
        for pull_repo, base in (('someone/fork', 'main'), ('o/r', 'next')):
            with self.subTest(repo=pull_repo, base=base):
                github = FakeGitHub(labels=('automerge',))
                github.pull = lambda: {'state': 'open', 'head': {'sha': HEAD, 'repo': {'full_name': pull_repo}},
                                       'base': {'ref': base}, 'labels': [{'name': 'automerge'}]}
                with mock.patch.object(lane, 'run_auto') as run, \
                        mock.patch.dict('os.environ', {'GITHUB_EVENT_NAME': 'workflow_dispatch'}):
                    self.role = 'build'
                    self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
                run.assert_not_called()

    def test_release_mode_is_gone(self):
        # #4572: nothing hands a T3 PASS to a release run any more; the old flags are refused, not half-honoured.
        with self.assertRaises(SystemExit), mock.patch('sys.stderr'):
            lane.main(['--pr', '5', '--event-head', HEAD, '--run-id', '1', '--mode', 'release'])
        with self.assertRaises(SystemExit), mock.patch('sys.stderr'):
            lane.main(['--pr', '5', '--event-head', HEAD, '--run-id', '1', '--mode', 'auto', '--t3-report', 'x'])


class VerdictOnThePrHeadTests(unittest.TestCase):
    """#3501 audit: a dispatched run's own check sits on the trunk's tip, so a release run that could not get the hosted
    checks left the PR with nothing red. The step that fixes it runs here for real, against a fake gh."""

    def run_step(self, *, reported='true', verdict='', held='false', job='success', pull_head=HEAD, post_fails=False):
        import yaml
        steps = yaml.safe_load(WORKFLOW)['jobs']['release']['steps']
        step = next(step for step in steps if step.get('name') == "Put the verdict on the PR's head")
        self.assertEqual(step['if'], 'always()')
        with tempfile.TemporaryDirectory() as temp:
            temp, posts = Path(temp), Path(temp) / 'posts'
            fake = temp / 'gh'
            fake.write_text('#!/bin/bash\n'
                            'case "$*" in\n'
                            f'  *pulls/5*) echo {pull_head} ;;\n'
                            f'  *) echo "$*" >> "{posts}"; exit {1 if post_fails else 0} ;;\n'
                            'esac\n')
            fake.chmod(0o755)
            ran = subprocess.run(['bash', '-e', '-c', step['run']], capture_output=True, text=True, env={
                'PATH': f'{temp}:/usr/bin:/bin', 'GH_REPO': 'o/r', 'PR_NUMBER': '5', 'EVENT_HEAD': HEAD,
                'RUN_URL': 'https://example.test/run', 'REPORTED': reported, 'VERDICT': verdict, 'HELD': held,
                'JOB_STATUS': job})
            self.assertEqual(ran.returncode, 0, ran.stderr)  # never red on the trunk's tip
            return (posts.read_text() if posts.exists() else ''), ran.stdout

    def test_each_outcome_puts_the_right_state_on_the_head(self):
        for name, kwargs, state in (
                ('a pass clears an earlier red', {'verdict': 'PASS'}, 'success'),
                ('a hold is not a failing PR', {'verdict': 'INCONCLUSIVE', 'held': 'true'}, 'success'),
                ('checks it could not get', {'verdict': 'INCONCLUSIVE'}, 'failure'),
                ('a failed check', {'verdict': 'FAIL'}, 'failure'),
                ('stopped before reporting', {'reported': '', 'job': 'failure'}, 'failure'),
                ('cancelled or timed out', {'reported': '', 'job': 'cancelled'}, 'failure')):
            with self.subTest(name):
                posts, _ = self.run_step(**kwargs)
                self.assertIn(f'repos/o/r/statuses/{HEAD}', posts)
                self.assertIn(f'state={state}', posts)
                self.assertIn('target_url=https://example.test/run', posts)

    def test_a_run_with_nothing_to_release_or_a_pr_that_moved_on_posts_nothing(self):
        self.assertEqual(self.run_step(reported='')[0], '')
        self.assertEqual(self.run_step(verdict='FAIL', pull_head='c' * 40)[0], '')

    def test_a_status_it_cannot_post_is_a_warning_not_a_red_trunk(self):
        posts, out = self.run_step(verdict='FAIL', post_fails=True)
        self.assertIn('state=failure', posts)
        self.assertIn('::warning', out)

    def test_the_job_may_post_statuses(self):
        # The job's token, not the workflow's: a `permissions:` block on the release job replaces the workflow's, and
        # the verdict-on-PR-head step would then 403 on a real run (#3704).
        workflow = workflow_yaml.load('lane.yml')
        self.assertEqual(workflow_yaml.effective_permissions(workflow, 'release').get('statuses'), 'write')
        step = next(step for step in workflow['jobs']['release']['steps']
                    if step.get('name') == "Put the verdict on the PR's head")
        self.assertIn('statuses/', step['run'])


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.assertIn('\n  release:\n', WORKFLOW)
        self.release = WORKFLOW.split('\n  release:\n')[1].split('\n  # Tell the coordinator')[0]

    def test_a_dispatch_starts_only_the_release_job_on_hosted_linux_or_a_build_runner(self):
        self.assertRegex(WORKFLOW, r'\n  workflow_dispatch:\n    inputs:\n      pr:\n[\s\S]*?\n      head:\n[\s\S]*?\n      auto:\n')
        self.assertNotRegex(WORKFLOW, r'\n      t3:\n')  # the T3 PASS hand-off's input is gone (#4572)
        # Only the hosted audit's dispatch for the run a clean audit released (#2170) starts it.
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.auto == 'true' &&", self.release)
        # #3501: hosted Linux once all three hosted checks are on, and the build runner only with them off.
        switches = "vars.LANE_HOSTED_FAST == 'on' && vars.LANE_HOSTED_MAC_REST == 'on'"
        self.assertIn("runs-on: ${{ fromJSON((" + switches + ") && '[\"ubuntu-latest\"]' || '[\"self-hosted\",\"macOS\",\"sm-lane-build\"]') }}",
                      self.release)
        self.assertIn(f"HOSTED_ARGS: ${{{{ ({switches}) && '--hosted' || '' }}}}", self.release)
        self.assertEqual(self.release.count('--mode auto $HOSTED_ARGS'), 2)  # the run and the tidy step
        self.assertNotIn('--t3-report', self.release)
        self.assertNotIn("'release'", self.release)
        self.assertIn('group: lane-release-pr-', self.release)  # never replaces a pending automerge run
        # The lane and automerge jobs need a pull_request, so a dispatch never starts a T3 or a second automerge run.
        for job in ('lane', 'automerge'):
            body = WORKFLOW.split(f'\n  {job}:\n')[1]
            self.assertIn('github.event.pull_request.head.repo.full_name == github.repository', body.split('runs-on')[0])

    def test_dispatch_inputs_reach_the_shell_only_through_variables(self):
        for line in self.release.splitlines():
            if '${{ inputs.' in line:
                self.assertRegex(line.strip(), r'^(ref|group|[A-Z0-9_]+): ', line)
        self.assertIn('git show "origin/$BASE_REF:scripts/lane-runner.py"', self.release)  # the base's runner

    def test_a_release_run_that_stops_before_its_runner_script_still_says_so(self):
        # #1542: a failed checkout or LFS fetch leaves no lane-runner.py, so the tidy step can't post anything. The
        # job's last step must work without anything the checkout or the runner fetch brought.
        steps = job_steps(WORKFLOW, 'release')
        names = [step.get('name', step.get('uses', '')) for step in steps]
        self.assertIn('actions/checkout@', names[0])
        last = steps[-1]
        self.assertIn('failure() || cancelled()', last.get('if', ''), names)
        self.assertNotIn('uses', last)
        run = last.get('run', '')
        self.assertIn('gh api', run)
        for checkout_file in ('GITHUB_WORKSPACE', 'RUNNER_TEMP', 'lane-runner', 'scripts/', 'python', './', 'source ',
                              '${{'):
            self.assertNotIn(checkout_file, run)
        self.assertNotRegex(run, r'\.(py|sh|rb|js)\b')  # no script of any kind (`.head.sha` is jq, not a file)
        # A redirect creates its file even when git show fails; an empty lane-runner.py exits 0, so the tidy step
        # would "succeed" without posting and this step would be skipped. The runner arrives whole or not at all.
        fetch = next(step for step in steps if step.get('name', '').startswith('Take the lane runner'))
        self.assertIn('> "$RUNNER_TEMP/lane-runner.py.part" &&', fetch['run'])
        self.assertIn('mv "$RUNNER_TEMP/lane-runner.py.part" "$RUNNER_TEMP/lane-runner.py"', fetch['run'])
        tidy = next(step for step in steps if step.get('name', '').startswith('Tidy up'))
        self.assertIn('steps.tidy.outcome', last['if'])  # one note: the tidy step's when it could post its own
        self.assertEqual(tidy.get('id'), 'tidy')

    def test_the_lane_job_dispatches_nothing(self):
        # #4572: the lane job no longer hands a released automerge run to the release job, so it needs no actions: write.
        granted = workflow_yaml.effective_permissions(workflow_yaml.load('lane.yml'), 'lane')
        self.assertNotEqual(granted.get('actions'), 'write')
        for permission in ('contents', 'pull-requests', 'issues'):
            self.assertEqual(granted.get(permission), 'write', permission)

    def test_dispatched_runs_keep_a_name_dedupe_ignores(self):
        name = workflow_yaml.load('lane.yml')['run-name']
        # A pull_request run's number and head come first, so its name, which lane_dedupe.py parses, is unchanged.
        self.assertIn('pr=${{ github.event.pull_request.number || inputs.pr }}', name)
        self.assertIn('head=${{ github.event.pull_request.head.sha || inputs.head }}', name)
        # Dedupe and the audit's re-arm check list only pull_request runs, so a release run never counts as one. This
        # one stays a source check (#3704): the line is the query string of dedupe's own `gh api` call, and running it
        # would need a stand-in for GitHub that answers whatever the string says.
        dedupe = (Path(__file__).resolve().parents[1] / 'lane_dedupe.py').read_text()
        self.assertIn('lane.yml/runs?event=pull_request&', dedupe)



@unittest.skipUnless(shutil.which('jq') and shutil.which('bash'), 'needs jq and bash, as the build runners have')
class ReleaseStoppedStepTests(unittest.TestCase):
    """The release job's last step (#1542), run in bash against a stand-in for gh that answers with real jq."""

    GH = """#!/bin/bash
for arg in "$@"; do printf '%s\\0' "$arg"; done >> "$GH_LOG"
printf '\\1' >> "$GH_LOG"
expr=
while [ $# -gt 0 ]; do
  if [ "$1" = --jq ]; then expr=$2; fi
  shift
done
if [ -n "$expr" ]; then printf '%s' "$STUB_PULL" | jq -r "$expr"; else echo '{}'; fi
"""

    def setUp(self):
        self.step = job_steps(WORKFLOW, 'release')[-1]
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        (self.folder / 'gh').write_text(self.GH)
        (self.folder / 'gh').chmod(0o755)

    def run_step(self, pull: dict | None = None, **env):
        pull = pull if pull is not None else self.pull()
        log = self.folder / 'gh.log'
        log.write_bytes(b'')
        jq = Path(shutil.which('jq')).parent
        environment = {'PATH': f'{self.folder}:{jq}:/usr/bin:/bin', 'GH_LOG': str(log), 'STUB_PULL': json.dumps(pull),
                       'GH_REPO': 'o/r', 'PR_NUMBER': '5', 'EVENT_HEAD': HEAD, 'BASE_REF': 'main',
                       'RUN_URL': 'https://github.com/o/r/actions/runs/42'}
        environment.update(env)
        done = subprocess.run(['bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c', self.step['run']],
                              env=environment, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return [call.split('\0')[:-1] for call in log.read_text().split('\1') if call]

    @staticmethod
    def pull(**changes):
        pull = {'state': 'open', 'head': {'sha': HEAD, 'repo': {'full_name': 'o/r'}}, 'base': {'ref': 'main'},
                'labels': [{'name': 'automerge'}, {'name': 'lane:queued'}]}
        pull.update(changes)
        return pull

    def test_it_posts_a_stopped_note_and_wakes_the_dispatcher(self):
        calls = self.run_step()
        self.assertEqual(calls[0][:2], ['api', 'repos/o/r/pulls/5'])
        posted = [call for call in calls if call[1] == 'repos/o/r/issues/5/comments']
        self.assertEqual(len(posted), 1, calls)
        body = posted[0][posted[0].index('-f') + 1].removeprefix('body=')
        self.assertTrue(body.startswith('Lane: the automerge run stopped before reporting '
                                        '(https://github.com/o/r/actions/runs/42)'), body)
        self.assertIn(f'`{HEAD[:7]}`', body)
        self.assertIn('Remove and re-add automerge', body)
        self.assertNotIn('T3', body)
        # The dispatcher and the lane read it as the existing stopped-job note: a runner fault that answers no
        # /lane request, and one that never counts toward an auto-revert, since it names no tested next.
        self.assertTrue(body.endswith(lane.NOTE), body)
        self.assertEqual(lane.lane_report_verdict(body), (True, 'the job stopped before it could report'))
        self.assertTrue(lane.is_automerge_comment(body))
        self.assertIsNone(lane.TESTED_ON.search(body))
        relabel = calls[calls.index(posted[0]) + 1:]
        self.assertEqual(relabel, [['api', '-X', 'DELETE', 'repos/o/r/issues/5/labels/lane%3Adone'],
                                   ['api', 'repos/o/r/issues/5/labels', '-f', 'labels[]=lane:done']])

    def test_a_pr_that_moved_on_closed_or_lost_automerge_gets_nothing(self):
        for pull in (self.pull(head={'sha': MERGE, 'repo': {'full_name': 'o/r'}}), self.pull(state='closed'),
                     self.pull(labels=[{'name': 'lane:done'}]), self.pull(base={'ref': 'next'}),
                     self.pull(head={'sha': HEAD, 'repo': None})):
            with self.subTest(pull=pull):
                calls = self.run_step(pull)
                self.assertEqual([call[1] for call in calls], ['repos/o/r/pulls/5'])

    def test_dispatch_inputs_that_aren_t_a_pr_number_and_a_full_sha_reach_no_api_call(self):
        for env in ({'PR_NUMBER': '5/../../../user'}, {'PR_NUMBER': ''}, {'EVENT_HEAD': 'abc1234'},
                    {'EVENT_HEAD': '$(touch pwned)' + 'a' * 30}):
            with self.subTest(env=env):
                self.assertEqual(self.run_step(**env), [])
        self.assertFalse((Path.cwd() / 'pwned').exists())


if __name__ == '__main__':
    unittest.main()
