"""A T3 PASS hands the held automerge run's host tests to a build runner instead of running them itself (#1209).

#834 let the build runner's held automerge run do the host tests while the T3 waited, and the T3 PASS merged
without them when next hadn't moved in ways that matter. When it had, the lane job still re-tested the merge
commit on sm-lane-mac, the one runner that runs T3s: 7 re-tests and about 63 runner-minutes on 2026-10-12 alone
(the slowest 25m37s), all of them correct under the gate, so the waste was where they ran. Now the lane job
dispatches lane.yml's release job to a build runner and moves on; a merge still needs a host PASS on the tree
that merges.
"""
from __future__ import annotations

import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import datetime
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
from test_lane_runner import FakeGitHub, HEAD, MERGE, comment, lane, runner_report  # noqa: E402
from test_lane_t3_first import RealGitLaneTests  # noqa: E402

PASSED = ('PASS', 'no simulator (compile only)', 'host tests (--plan fast): passed', [])
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


class HandOffAfterTheT3PassTests(RealGitLaneTests):
    """With real git: the build runner's held run, main moving, the T3 PASS, then the hand-off and the release."""

    def held_run(self, github):
        base = lane.fetch_base(self.tree, 'main')
        context = lane.AutoRunContext(base)
        with mock.patch.object(lane, 'run_automerge', return_value=PASSED):
            verdict, where, ran, details = lane.run_auto(github, github.pull(), 5, 'main', self.head, base,
                                                         self.evidence / 'held', github.comments(), context=context)
        github.comment(lane.report('pr5-r41', verdict, self.head, context.tested_base, 'auto', where, 1, ran, details,
                                   'none', '/e', 'owner', lane.identity('auto', self.head, context.tested_base, [])))
        return base

    def github(self):
        return FakeGitHub(labels=('automerge', 'lane:queued'), head=self.head, comments=[self.t3_request])

    def t3_passes(self, github):
        github._comments.append(runner_report('PASS', lane.identity('T3', self.head, self.rev(self.tree, 'origin/main'),
                                                                   ['SupertonicSpeechTests'])))

    def lane_job_release(self, github, hand_off):
        with mock.patch.object(lane, 'run_automerge', return_value=PASSED) as checks:
            released = lane.merge_after_t3(github, 5, 'main', self.head, 'pr5-r43-auto', self.evidence / 'released',
                                           self.rev(self.tree, 'origin/main'), 'started by the T3 PASS',
                                           hand_off=hand_off)
        return checks, released

    def move_next_by_a_build_input(self):
        (self.other / 'scripts').mkdir(exist_ok=True)
        self.commit(self.other, 'scripts/verify-tests.py', 'print(1)\n')
        self.push_next()

    def test_a_needed_re_test_goes_to_the_build_runner_and_the_simulator_runner_moves_on(self):
        self.handed_off()

    def handed_off(self):
        github = self.github()
        self.held_run(github)
        self.move_next_by_a_build_input()
        self.t3_passes(github)
        hand_off = mock.Mock(return_value='https://example.test/runs')
        before = self.rev(self.origin, 'main')
        checks, released = self.lane_job_release(github, hand_off)
        hand_off.assert_called_once_with()
        checks.assert_not_called()  # no --plan fast on the simulator runner
        self.assertEqual(self.rev(self.origin, 'main'), before)  # nothing merged without a host PASS
        self.assertTrue(released.startswith(lane.HANDED_OFF), released)
        self.assertEqual(github.posted[-1], released)
        self.assertIn('https://example.test/runs', released)
        self.assertIn('scripts/verify-tests.py', released)  # says why it has to test again
        # The note is no report and answers no /lane request, so the release run still finds the PR held.
        self.assertIsNone(lane.lane_report_verdict(released))
        self.assertTrue(lane.is_automerge_comment(released))
        self.assertTrue(lane.held_for_t3(github.comments(), self.head))
        return github

    def test_the_build_runner_s_release_then_tests_the_merge_commit_and_merges(self):
        github = self.handed_off()
        room = mock.Mock(return_value=(None, None))
        with mock.patch.object(lane, 'run_automerge', return_value=PASSED) as checks:
            released = lane.merge_after_t3(github, 5, 'main', self.head, 'pr5-r50-auto', self.evidence / 'release',
                                           self.rev(self.tree, 'origin/main'), 'handed to the build runner', room=room)
        room.assert_called_once_with()  # under the build runner's room rules
        checks.assert_called_once()  # the host PASS on the tree that merges
        self.assertTrue(released.startswith('Lane report pr5-r50-auto — PASS'), released)
        merged = self.rev(self.origin, 'main')
        self.assertIn(f'merged into main as {merged[:7]}', released)
        self.assertEqual(subprocess.check_output(['git', '-C', str(self.tree), 'rev-list', '--parents', '-n', '1',
                                                 merged], text=True).split()[2], self.head)

    def test_the_release_is_held_by_an_inherited_audit_finding_like_any_automerge_run(self):
        # #712 x #1209: the hand-off moves the host tests, not the merge rules. A PR that brings in another PR's
        # blocked commits stays held on the build runner, however clean its own T3 and host tests are.
        github = self.handed_off()
        before = self.rev(self.origin, 'main')
        hold = f'{lane.INHERITED_HOLD} from PR #616 on `abc1234`'
        with mock.patch.object(lane, 'run_automerge', return_value=PASSED) as checks, \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: [hold]) as inherited:
            released = lane.merge_after_t3(github, 5, 'main', self.head, 'pr5-r50-auto', self.evidence / 'release',
                                           before, 'handed to the build runner', room=mock.Mock(return_value=(None, None)))
        checks.assert_called_once()  # the host PASS still runs; only the merge waits
        inherited.assert_called_once()
        self.assertEqual(self.rev(self.origin, 'main'), before)
        self.assertNotIn('merged into main as', released)
        self.assertIn(f'not merged by the runner: {hold}.', released)
        self.assertTrue(lane.AUDIT_HOLD.search(released))  # the audit script finds it by this line

    def test_no_room_on_the_build_runner_reports_a_runner_fault_and_merges_nothing(self):
        github = self.handed_off()
        before = self.rev(self.origin, 'main')
        with mock.patch.object(lane, 'run_automerge') as checks:
            released = lane.merge_after_t3(github, 5, 'main', self.head, 'pr5-r50-auto', self.evidence / 'release',
                                           before, 'handed to the build runner',
                                           room=lambda: ('the build runner waited 90m00s for room: x', None))
        checks.assert_not_called()
        self.assertEqual(self.rev(self.origin, 'main'), before)
        self.assertTrue(released.startswith('Lane report pr5-r50-auto — INCONCLUSIVE'), released)
        self.assertIn('Remove and re-add automerge', released)
        self.assertTrue(lane.lane_report_verdict(released)[0])  # a runner fault, as in the automerge job

    def test_a_push_during_the_room_wait_releases_nothing(self):
        # The old head's report would become the newest automerge report and hide the new head's hold.
        github = self.handed_off()
        posted = len(github.posted)

        def room():
            github.head = 'c' * 40  # the owner merged main into the branch meanwhile
            return None, None
        with mock.patch.object(lane, 'run_automerge') as checks:
            released = lane.merge_after_t3(github, 5, 'main', self.head, 'pr5-r50-auto', self.evidence / 'release',
                                           self.rev(self.tree, 'origin/main'), 'handed to the build runner', room=room)
        self.assertIsNone(released)
        checks.assert_not_called()
        self.assertEqual(len(github.posted), posted)

    def test_a_note_that_cannot_be_posted_still_leaves_the_pr_held_for_the_release(self):
        github = self.github()
        self.held_run(github)
        self.move_next_by_a_build_input()
        self.t3_passes(github)
        real = github.comment

        def comment(body):
            if body.startswith(lane.HANDED_OFF):
                raise RuntimeError('GitHub API unavailable')
            return real(body)
        github.comment = comment
        checks, released = self.lane_job_release(github, mock.Mock(return_value='https://example.test/runs'))
        checks.assert_not_called()
        self.assertTrue(released.startswith(lane.HANDED_OFF))
        self.assertTrue(lane.held_for_t3(github.comments(), self.head))  # no lane-error report on top

    def test_checks_that_still_stand_merge_here_in_seconds_with_no_hand_off(self):
        github = self.github()
        self.held_run(github)
        self.t3_passes(github)
        hand_off = mock.Mock(return_value='https://example.test/runs')
        checks, released = self.lane_job_release(github, hand_off)
        hand_off.assert_not_called()
        checks.assert_not_called()
        self.assertIn('Lane report pr5-r43-auto — PASS', released)
        self.assertIn('merged into main as', released)

    def test_a_failed_hand_off_tests_here_as_before(self):
        # A PR whose merge ref predates this change has no actions: write, and a base without the release job
        # refuses the dispatch: the lane job then does what it did before #1209.
        github = self.github()
        self.held_run(github)
        self.move_next_by_a_build_input()
        self.t3_passes(github)
        hand_off = mock.Mock(side_effect=subprocess.CalledProcessError(1, ['gh', 'api']))
        checks, released = self.lane_job_release(github, hand_off)
        hand_off.assert_called_once_with()
        checks.assert_called_once()
        self.assertIn('the hand-off to the build runner failed', released)
        self.assertIn('merged into main as', released)

    def test_without_a_held_pass_to_reuse_it_hands_off_too(self):
        # Another runner's automerge run skipped its checks and reported held (no lane-checks line).
        github = self.github()
        github.comment(lane.report('pr5-r41', 'INCONCLUSIVE', self.head, self.rev(self.tree, 'origin/main'), 'auto',
                                   'no build', 1, 'nothing', [f'{lane.HELD_FOR_T3[0]}: the /lane T3 request'],
                                   'none', '/e', 'owner', lane.identity('auto', self.head, MERGE, [])))
        self.t3_passes(github)
        hand_off = mock.Mock(return_value='https://example.test/runs')
        checks, released = self.lane_job_release(github, hand_off)
        hand_off.assert_called_once_with()
        checks.assert_not_called()
        self.assertIn('no passed checks to reuse', released)


class MainWiringTests(unittest.TestCase):
    run_main = test_lane_runner.MainFlowTests.run_main
    conflicts, role, attempt, state_dir, ops = [], '', '1', None, mock.Mock()
    T3_REQUEST = comment(f'/lane T3\ncommit: {HEAD[:7]}\ntests: SupertonicSpeechTests')

    def t3_job(self, github, role, released):
        self.role = role
        with mock.patch.object(lane, 't3_scope', return_value=([], [])), \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'sim', 'ran', [], 'none', '')), \
                mock.patch.object(lane, 'merge_after_t3', return_value=released) as release:
            self.run_main(github)
        return release

    def test_the_lane_job_off_the_build_runner_offers_the_hand_off(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST])
        github.hand_off_release = mock.Mock(return_value='https://example.test/runs')
        release = self.t3_job(github, '', None)
        hand_off = release.call_args.kwargs['hand_off']
        self.assertEqual(hand_off(), 'https://example.test/runs')
        github.hand_off_release.assert_called_once_with('main', HEAD, 'https://example.test/1')  # the T3 report

    def test_a_lane_job_on_a_build_runner_tests_where_it_is(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST])
        release = self.t3_job(github, 'build', None)
        self.assertIsNone(release.call_args.kwargs['hand_off'])

    def test_an_automerge_job_releasing_itself_does_not_hand_off(self):
        github = FakeGitHub(labels=('automerge',), comments=[self.T3_REQUEST])
        with mock.patch.object(lane, 'run_auto', return_value=('INCONCLUSIVE', 'x', 'ran', ['held'])), \
                mock.patch.object(lane, 'merge_after_t3', return_value=None) as release:
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        self.assertIsNone(release.call_args.kwargs['hand_off'])

    def test_a_hand_off_leaves_lane_done_to_the_release_run(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST])
        self.t3_job(github, '', f'{lane.HANDED_OFF} on `{HEAD[:7]}` goes to the build runner (#1209).\n{lane.NOTE}')
        self.assertNotIn('lane:done', github.labeled)
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST])
        self.t3_job(github, '', 'Lane report pr5-r42-auto — FAIL\n')
        self.assertIn('lane:done', github.labeled)  # a release that didn't merge still wakes the dispatcher

    def release_job(self, github, released, *, head=HEAD, merged_state='open', repo='o/r'):
        self.role = 'build'
        with tempfile.TemporaryDirectory() as outputs:
            out = Path(outputs) / 'out'
            with mock.patch.object(lane, 'merge_after_t3', return_value=released) as release, \
                    mock.patch.dict('os.environ', {'GITHUB_OUTPUT': str(out)}), \
                    mock.patch.object(lane, 'drop_workspace_builds'):
                github.pull = lambda: {'state': merged_state, 'head': {'sha': HEAD, 'repo': {'full_name': repo}},
                                       'base': {'ref': 'main'},
                                       'labels': [{'name': n} for n in sorted(github.labels)]}
                self.run_main(github, head, 'PASS', '--mode', 'release', '--t3-report', 'https://example.test/t3')
            outcome = dict(line.split('=', 1) for line in out.read_text().splitlines()) if out.exists() else {}
        return release, outcome

    def test_the_release_job_runs_the_release_under_the_room_rules(self):
        github = FakeGitHub(labels=('automerge',))
        release, outcome = self.release_job(github, 'Lane report pr5-r42-auto — FAIL\nran: x\n')
        args, kwargs = release.call_args
        self.assertEqual(args[:5], (github, 5, 'main', HEAD, 'pr5-r42-auto'))
        self.assertIs(kwargs['room'], lane.wait_for_room_to_test_on_host)
        self.assertNotIn('hand_off', kwargs)  # it never hands off again
        self.assertIn('https://example.test/t3', args[7])
        self.assertEqual(outcome, {'reported': 'true', 'verdict': 'FAIL', 'held': 'false'})  # for the Verdict step's warning
        self.assertEqual(github.labeled, ['lane:done'])

    def test_a_merged_release_leaves_the_labels_alone(self):
        github = FakeGitHub(labels=('automerge',))
        _, outcome = self.release_job(github, 'Lane report pr5-r42-auto — PASS\nmerged into main as abc1234\n',
                                      merged_state='closed')
        self.assertEqual(outcome['verdict'], 'PASS')
        self.assertEqual(github.label_changes, [])

    def test_a_release_with_nothing_held_reports_nothing(self):
        github = FakeGitHub(labels=('automerge',))
        _, outcome = self.release_job(github, None)
        self.assertEqual(outcome, {})
        self.assertEqual(github.posted, [])
        self.assertEqual(github.label_changes, [])  # a stray dispatch wakes nobody

    def test_a_release_run_that_dies_still_wakes_the_dispatcher(self):
        # The lane job left lane:done to the release run; a run that times out or is cancelled must not leave the
        # armed, T3-passed PR sitting unmerged with nobody woken.
        github = FakeGitHub(labels=('automerge',))
        with mock.patch.object(lane, 'sweep_runner_simulators'), mock.patch('builtins.print'):
            lane.cleanup(github, 'https://example.test/run', 'release')
        self.assertTrue(github.posted[0].startswith('Lane: the automerge run stopped before reporting'))
        self.assertEqual(github.labeled, ['lane:done'])

    def test_the_hand_off_note_says_when_the_release_run_counts_as_lost(self):
        # #1542: a release run that never starts (cancelled or timed out in the queue) runs no step at all, so it
        # can post nothing. The note itself tells the hourly dispatcher when to treat it as lost.
        now = datetime.datetime(2026, 10, 13, 17, 31, tzinfo=datetime.timezone.utc)
        note = lane.handed_off_note(HEAD, 'started by the T3 PASS', 'main moved', 'https://example.test/runs', now=now)
        self.assertIn('2026-10-13 20:31Z', note)
        self.assertIn('remove and re-add `automerge` once', note)
        # Still no report, no stopped-job note and no answer to a /lane request.
        self.assertIsNone(lane.lane_report_verdict(note))
        self.assertTrue(lane.is_automerge_comment(note))

    def test_a_dispatch_for_a_fork_s_pr_or_another_base_runs_nothing(self):
        release, _ = self.release_job(FakeGitHub(labels=('automerge',)), None, repo='someone/fork')
        release.assert_not_called()
        github = FakeGitHub(labels=('automerge',))
        with mock.patch.object(lane, 'merge_after_t3') as release:
            self.role = 'build'
            github.pull = lambda: {'state': 'open', 'head': {'sha': HEAD, 'repo': {'full_name': 'o/r'}},
                                   'base': {'ref': 'next'}, 'labels': []}
            self.run_main(github, HEAD, 'PASS', '--mode', 'release')
        release.assert_not_called()

    def test_a_dispatch_without_a_full_head_sha_does_nothing(self):
        github = FakeGitHub(labels=('automerge',))
        release, _ = self.release_job(github, None, head='abc1234')
        release.assert_not_called()


class GitHubDispatchTests(unittest.TestCase):
    def test_the_hand_off_dispatches_lane_yml_on_the_base_with_the_pr_head_and_report(self):
        github = lane.GitHub('o/r', 5)
        with mock.patch.object(github, 'api', return_value='') as api, \
                mock.patch.dict('os.environ', {'GITHUB_SERVER_URL': 'https://github.com'}):
            where = github.hand_off_release('main', HEAD, 'https://example.test/t3')
        api.assert_called_once_with('-X', 'POST', 'repos/o/r/actions/workflows/lane.yml/dispatches', '-f', 'ref=main',
                                    '-f', 'inputs[pr]=5', '-f', f'inputs[head]={HEAD}',
                                    '-f', 'inputs[t3]=https://example.test/t3')
        self.assertTrue(where.startswith('https://github.com/o/r/actions/workflows/lane.yml'), where)


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.assertIn('\n  release:\n', WORKFLOW)
        self.release = WORKFLOW.split('\n  release:\n')[1].split('\n  # Tell the coordinator')[0]

    def test_a_dispatch_starts_only_the_release_job_on_a_build_runner(self):
        self.assertRegex(WORKFLOW, r'\n  workflow_dispatch:\n    inputs:\n      pr:\n[\s\S]*?\n      head:\n[\s\S]*?\n      t3:\n')
        self.assertIn("github.event_name == 'workflow_dispatch'", self.release)
        self.assertIn('runs-on: [self-hosted, macOS, sm-lane-build]', self.release)
        self.assertIn('--mode release', self.release)
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

    def test_the_lane_job_may_dispatch(self):
        lane_job = WORKFLOW.split('\n  lane:\n')[1].split('\n  automerge:\n')[0]
        self.assertIn('actions: write', lane_job)
        for permission in ('contents: write', 'pull-requests: write', 'issues: write'):
            self.assertIn(permission, lane_job)  # a job's permissions replace the workflow's

    def test_dispatched_runs_keep_a_name_dedupe_ignores(self):
        name = WORKFLOW.split('run-name: >-\n')[1].split('\non:')[0]
        # A pull_request run's number and head come first, so its name, which lane_dedupe.py parses, is unchanged.
        self.assertIn('pr=${{ github.event.pull_request.number || inputs.pr }}', name)
        self.assertIn('head=${{ github.event.pull_request.head.sha || inputs.head }}', name)
        # Dedupe and the audit's re-arm check list only pull_request runs, so a release run never counts as one.
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
        self.assertIn('remove and re-add automerge', body)
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
