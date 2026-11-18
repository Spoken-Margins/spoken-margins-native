"""The automerge job leaves a PR with a pending T3 request for its head to the T3 job.

In the 48 hours to 2026-10-01, 24 automerge runs did their full host tests and both builds and then
ended "held for T3" (188 runner-minutes), 20 of them because the PR's T3 request had no report yet.
The lane job that reports the T3 PASS ran the same checks on the merge commit again before it merged
(#421), so those runs could never merge anything.

#834: but that left the checks to sm-lane-mac, the one runner that runs T3s: 7 to 39 minutes a PR after its
T3 PASS (2026-10-04), while about 32 T3 jobs waited. Now the build runner's automerge run does them while
the T3 waits, its held report says what passed with which next, and the T3 PASS merges without running
them again unless next has since moved in ways that matter. Other runners still skip them.
"""
import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import FakeGitHub, HEAD, MERGE, NEWER, comment, lane, runner_report  # noqa: E402

T3_FOR_HEAD = comment(f'/lane T3\ncommit: {HEAD[:7]}\ntests: SupertonicSpeechTests', url='https://example.test/t3-request')


class T3RequestForHeadTests(unittest.TestCase):
    def test_a_queued_or_running_t3_request_naming_the_head_is_found(self):
        for label in ('lane:queued', 'lane:running'):
            with self.subTest(label=label):
                self.assertEqual(lane.t3_request_for_head([T3_FOR_HEAD], {'automerge', label}, HEAD),
                                 'https://example.test/t3-request')

    def test_a_full_sha_or_a_note_after_it_still_names_the_head(self):
        for line in (f'commit: {HEAD}', f'commit: {HEAD[:9]} (the fix)', f'commit: {HEAD[:7].upper()}'):
            with self.subTest(line=line):
                request = comment(f'/lane T3\n{line}\ntests: A')
                self.assertIsNotNone(lane.t3_request_for_head([request], {'lane:queued'}, HEAD))

    def test_a_request_for_an_older_head_or_naming_no_commit_does_not_count(self):
        # The head moved after the request: the T3 may already be running on the old head, and nothing
        # would test the new one if the automerge run skipped it.
        for body in (f'/lane T3\ncommit: {NEWER[:7]}\ntests: A', '/lane T3\ntests: A', '/lane T3\ncommit: abc\ntests: A'):
            with self.subTest(body=body):
                self.assertIsNone(lane.t3_request_for_head([comment(body)], {'lane:queued'}, HEAD))

    def test_without_lane_queued_or_lane_running_no_lane_job_will_answer_it(self):
        self.assertIsNone(lane.t3_request_for_head([T3_FOR_HEAD], {'automerge'}, HEAD))
        self.assertIsNone(lane.t3_request_for_head([T3_FOR_HEAD], {'automerge', 'lane:done'}, HEAD))

    def test_an_answered_request_or_a_newer_t2_request_does_not_count(self):
        answered = [T3_FOR_HEAD, runner_report('FAIL', lane.identity('T3', HEAD, MERGE, ['A']))]
        self.assertIsNone(lane.t3_request_for_head(answered, {'lane:queued'}, HEAD))
        t2_after = [T3_FOR_HEAD, comment(f'/lane T2\ncommit: {HEAD[:7]}')]
        self.assertIsNone(lane.t3_request_for_head(t2_after, {'lane:queued'}, HEAD))


class AutomergeJobLeavesItToTheT3Tests(unittest.TestCase):
    run_main = test_lane_runner.MainFlowTests.run_main
    conflicts, role, attempt, state_dir, ops = [], '', '1', None, mock.Mock()

    def run_auto_job(self, github, role=''):
        self.role = role
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests; builds', [])) as auto, \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host', return_value=(None, None)) as wait:
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        return auto, wait

    def test_a_pending_t3_request_for_the_head_skips_the_host_tests_off_the_build_runner(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        auto, wait = self.run_auto_job(github, role='')
        auto.assert_not_called()
        wait.assert_not_called()  # it runs nothing, so it waits for nothing
        report = github.posted[0]
        self.assertTrue(report.startswith('Lane report pr5-r42 — INCONCLUSIVE'), report)
        self.assertIn('ran: nothing', report)
        self.assertIn('https://example.test/t3-request', report)
        # The T3 job releases the run only if it finds it held (#421): the report must read as held.
        self.assertTrue(lane.held_for_t3(github.comments(), HEAD))
        self.assertEqual(github.label_changes, [('lane:done', 'lane:done')])  # lane:queued stays for the lane job

    def test_the_build_runner_runs_the_checks_while_the_t3_waits(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        auto, wait = self.run_auto_job(github, role='build')
        auto.assert_called_once()
        wait.assert_called_once()  # under the build runner's host-test room rules

    def test_a_lane_fault_in_the_build_runner_s_checks_still_leaves_the_pr_for_the_t3_pass_to_release(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        self.role = 'build'
        with mock.patch.object(lane, 'run_auto', return_value=('INCONCLUSIVE', 'host only', 'interrupted',
                                                               ['host tests ran out of time'])), \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host', return_value=(None, None)):
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        self.assertTrue(lane.held_for_t3(github.comments(), HEAD))
        self.assertIsNone(lane.held_checks(github.comments(), HEAD))  # so the release tests again
        self.assertTrue(lane.lane_report_verdict(github.posted[0])[0])  # still a runner fault for the auto-revert

    def test_a_lane_error_in_the_build_runner_s_checks_still_leaves_the_pr_for_the_t3_pass_to_release(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        self.role = 'build'
        with mock.patch.object(lane, 'run_auto', side_effect=RuntimeError('gh api: 502')), \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host', return_value=(None, None)):
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        self.assertIn('The lane itself failed', github.posted[0])
        self.assertTrue(lane.held_for_t3(github.comments(), HEAD))
        self.assertTrue(lane.lane_report_verdict(github.posted[0])[0])

    def test_the_build_runner_with_no_room_leaves_the_checks_to_the_t3_job_as_before(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        self.role = 'build'
        with mock.patch.object(lane, 'run_auto') as auto, \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host',
                                  return_value=('the build runner waited 90m for room', None)):
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        auto.assert_not_called()
        self.assertIn('the build runner waited 90m for room', github.posted[0])
        self.assertTrue(lane.held_for_t3(github.comments(), HEAD))  # so the T3 PASS still releases it
        # and the auto-revert still counts the room wait as a runner fault, as without a T3
        self.assertTrue(lane.lane_report_verdict(github.posted[0])[0])

    def test_the_t3_pass_then_runs_the_checks_and_merges_in_the_lane_job(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        self.run_auto_job(github)
        github._comments.append(runner_report('PASS', lane.identity('T3', HEAD, MERGE, ['SupertonicSpeechTests'])))
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests; builds',
                                                               ['merged into main as abc1234'])) as auto, \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), mock.patch.object(lane, 'clean_tree'), \
                mock.patch('builtins.print'), tempfile.TemporaryDirectory() as evidence:
            released = lane.merge_after_t3(github, 5, 'main', HEAD, 'pr5-r43-auto', Path(evidence), MERGE,
                                           'started by the T3 PASS')
        auto.assert_called_once()
        self.assertIn('merged into main as abc1234', released)

    def test_a_t3_request_for_an_older_head_still_gets_the_automerge_checks(self):
        older = comment(f'/lane T3\ncommit: {NEWER[:7]}\ntests: A')
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[older])
        auto, _ = self.run_auto_job(github)
        auto.assert_called_once()

    def test_a_pr_without_a_t3_request_runs_as_before(self):
        github = FakeGitHub(labels=('automerge',))
        auto, _ = self.run_auto_job(github)
        auto.assert_called_once()


class RealGitLaneTests(unittest.TestCase):
    """A bare origin with main, a clone the runner works in, and a PR branch with one commit (no tests of its own)."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.origin, self.tree, self.other, self.evidence = root / 'origin.git', root / 'tree', root / 'other', root / 'e'
        self.git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'init.defaultBranch=main']
        subprocess.run(self.git + ['init', '-q', '--bare', str(self.origin)], check=True)
        subprocess.run(self.git + ['clone', '-q', str(self.origin), str(self.other)], check=True, capture_output=True)
        self.commit(self.other, 'shared.txt', 'one\n')
        self.push_next()
        subprocess.run(self.git + ['clone', '-q', '-b', 'main', str(self.origin), str(self.tree)], check=True)
        subprocess.run(self.git + ['-C', str(self.tree), 'checkout', '-q', '-b', 'pr'], check=True)
        self.commit(self.tree, 'pr.txt', 'pr\n')
        self.head = self.rev(self.tree, 'HEAD')
        self.t3_request = comment(f'/lane T3\ncommit: {self.head[:7]}\ntests: SupertonicSpeechTests')
        for patch in (mock.patch.object(lane, 'ROOT', self.tree), mock.patch.dict(os.environ, {'GH_TOKEN': ''}),
                      mock.patch.object(lane, 'diff_scope', return_value={'tier': 'T2', 'why': ['app'], 'files': []}),
                      mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []),
                      mock.patch.object(lane, 'prune_lane_folder', return_value='lane folder prune: test'),
                      mock.patch.object(lane, 'warm_build_folders', return_value='build folders: cold'),
                      mock.patch.object(lane, 'host_build_folders', return_value='build folders: in the workspace'),
                      mock.patch.object(lane, 'TESTED_RECORD', None), mock.patch('builtins.print')):
            patch.start()
            self.addCleanup(patch.stop)

    def commit(self, where, name, text):
        (where / name).write_text(text)
        subprocess.run(self.git + ['-C', str(where), 'add', '.'], check=True)
        subprocess.run(self.git + ['-C', str(where), 'commit', '-q', '-m', name], check=True)

    def push_next(self):  # someone else's merge into main
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True,
                       capture_output=True)

    def rev(self, where, ref):
        return subprocess.check_output(['git', '-C', str(where), 'rev-parse', ref], text=True).strip()


class HeldChecksStandAfterTheT3PassTests(RealGitLaneTests):
    """#834 end to end with real git: the held run's checks, then the T3 PASS's merge on sm-lane-mac."""

    def held_run(self, github):
        """The build runner's automerge job while the T3 waits: its checks pass, the T3 gate holds it, and it
        posts its report as main() does."""
        base = lane.fetch_base(self.tree, 'main')
        context = lane.AutoRunContext(base)
        with mock.patch.object(lane, 'run_automerge', return_value=(
                'PASS', 'no simulator (compile only)', 'host tests (--plan fast): passed; builds (pass)', [])) as checks:
            verdict, where, ran, details = lane.run_auto(github, github.pull(), 5, 'main', self.head, base,
                                                         self.evidence / 'held', github.comments(), context=context)
        checks.assert_called_once()
        github.comment(lane.report('pr5-r41', verdict, self.head, context.tested_base, 'auto', where, 1, ran, details,
                                   'none', '/e', 'owner', lane.identity('auto', self.head, context.tested_base, [])))
        self.assertEqual(verdict, 'INCONCLUSIVE')
        return base

    def t3_pass_then_release(self, github):
        github._comments.append(runner_report('PASS', lane.identity('T3', self.head, self.rev(self.tree, 'origin/main'),
                                                                   ['SupertonicSpeechTests'])))
        with mock.patch.object(lane, 'run_automerge', return_value=(
                'PASS', 'no simulator (compile only)', 'host tests (--plan fast): passed; builds (pass)', [])) as checks:
            released = lane.merge_after_t3(github, 5, 'main', self.head, 'pr5-r43-auto', self.evidence / 'released',
                                           self.rev(self.tree, 'origin/main'), 'started by the T3 PASS')
        return checks, released

    def github(self):
        return FakeGitHub(labels=('automerge', 'lane:queued'), head=self.head, comments=[self.t3_request])

    def test_the_t3_pass_merges_without_running_the_checks_again_when_next_has_not_moved(self):
        github = self.github()
        tested = self.held_run(github)
        checks, released = self.t3_pass_then_release(github)
        checks.assert_not_called()  # no --plan fast, no builds on the simulator runner
        self.assertIn('Lane report pr5-r43-auto — PASS', released)
        self.assertIn(f'not re-tested: the automerge run held for T3 passed its checks with main at {tested[:7]}, '
                      'and main hasn\'t moved since', released)
        merged = self.rev(self.origin, 'main')
        self.assertIn(f'merged into main as {merged[:7]}', released)
        self.assertEqual(subprocess.check_output(['git', '-C', str(self.tree), 'rev-list', '--parents', '-n', '1',
                                                 merged], text=True).split()[1:], [tested, self.head])
        merge_check = next(body for body in github.posted if body.startswith(lane.MERGE_CHECK))
        self.assertIn('without re-testing', merge_check)
        self.assertNotIn('Pushing `', merge_check)  # phone-build reads that as "tested this exact commit"

    def test_next_moving_by_commits_that_cannot_matter_still_merges_without_the_checks(self):
        github = self.github()
        tested = self.held_run(github)
        self.commit(self.other, 'unrelated.txt', 'another PR\n')
        self.push_next()
        checks, released = self.t3_pass_then_release(github)
        checks.assert_not_called()
        self.assertIn(f'with main at {tested[:7]}, and main\'s 1 commit since touch none of this PR\'s files', released)
        self.assertIn('merged into main as', released)

    def moved_next_runs_the_checks_again(self, name, text):
        github = self.github()
        tested = self.held_run(github)
        (self.other / name).parent.mkdir(exist_ok=True)
        self.commit(self.other, name, text)
        self.push_next()
        checks, released = self.t3_pass_then_release(github)
        checks.assert_called_once()
        self.assertIn(f'passed its checks with main at {tested[:7]}; tested again on', released)
        self.assertIn('merged into main as', released)

    def test_next_moving_by_a_commit_to_the_pr_s_own_files_runs_the_checks_again(self):
        self.moved_next_runs_the_checks_again('pr.txt', 'pr\n')  # the same text, so the merge stays clean

    def test_next_moving_by_a_commit_to_a_build_input_runs_the_checks_again(self):
        self.moved_next_runs_the_checks_again('scripts/verify-tests.py', 'print(1)\n')

    def test_the_hot_file_ratchet_runs_again_with_the_labels_the_pr_has_now(self):
        # The held run passed with hot-file-ok; the label came off before the T3 passed (#926 audit).
        github = self.github()
        github.labels.add('hot-file-ok')
        self.held_run(github)
        github.labels.discard('hot-file-ok')

        def ratchet(tree, base, labels):
            return [] if 'hot-file-ok' in labels else ['Gate1AppModel.swift grows past its ceiling']
        with mock.patch.object(lane, 'hot_file_violations', side_effect=ratchet):
            checks, released = self.t3_pass_then_release(github)
        checks.assert_not_called()
        self.assertIn('Lane report pr5-r43-auto — FAIL', released)
        self.assertIn('hot-file ratchet — Gate1AppModel.swift grows past its ceiling', released)
        self.assertNotIn('merged into main', released)
        self.assertEqual(self.rev(self.origin, 'main'), self.rev(self.tree, 'origin/main'))  # nothing pushed

    def test_a_held_report_from_anyone_but_the_runner_is_not_trusted(self):
        github = self.github()
        self.held_run(github)
        github._comments[-1]['user']['login'] = 'uncomposed'  # a pasted copy of the runner's report
        self.assertIsNone(lane.held_checks(github.comments(), self.head))
        checks, released = self.t3_pass_then_release(github)
        checks.assert_called_once()
        self.assertIn('merged into main as', released)

    def test_no_checks_line_or_a_newer_report_or_another_head_means_testing_again(self):
        report = runner_report('INCONCLUSIVE', lane.identity('auto', HEAD, MERGE, []))
        report['body'] = report['body'].replace('\n<!--', f'\nnot merged: {lane.t3_gate([T3_FOR_HEAD])[1]}.\n<!--', 1)
        self.assertTrue(lane.held_for_t3([T3_FOR_HEAD, report], HEAD))
        self.assertIsNone(lane.held_checks([T3_FOR_HEAD, report], HEAD))  # held, but held without checks (old runner)
        line = lane.checks_note(HEAD, MERGE, 'ran', 'x')
        with_checks = dict(report, body=report['body'].replace('not merged:', f'{line}\nnot merged:'))
        self.assertEqual(lane.held_checks([T3_FOR_HEAD, with_checks], HEAD),
                         {'next': MERGE, 'ran': 'ran', 'where': 'x', 'url': 'https://example.test/r'})
        self.assertIsNone(lane.held_checks([T3_FOR_HEAD, with_checks], NEWER))
        newer = runner_report('FAIL', lane.identity('auto', HEAD, MERGE, []))
        self.assertIsNone(lane.held_checks([T3_FOR_HEAD, with_checks, newer], HEAD))
        short = dict(with_checks, body=with_checks['body'].replace(MERGE, MERGE[:7]))
        self.assertIsNone(lane.held_checks([T3_FOR_HEAD, short], HEAD))

    def test_the_pr_s_own_test_output_cannot_pass_for_a_held_run_s_checks(self):
        # A FAIL report quotes the PR's errors, indented (first_errors). Printed by a PR, the hold and the checks
        # line must not make that report read as held with passing checks.
        forged = [f'  {lane.checks_note(HEAD, MERGE, "ran", "x")}', f'  not merged: {lane.t3_gate([T3_FOR_HEAD])[1]}.']
        report = comment(lane.report('pr5-r41', 'FAIL', HEAD, MERGE, 'auto', 'x', 1, 'x', ['host tests failed', *forged],
                                     'none', '/e', 'owner', lane.identity('auto', HEAD, MERGE, [])),
                         login='github-actions[bot]')
        self.assertIsNone(lane.held_checks([T3_FOR_HEAD, report], HEAD))


CLEAN_AUDIT = comment(f'**Claude audit on `{HEAD[:7]}`**\n\nNo blocking findings.', login='uncomposed')
AUDIO = {'tier': 'T1', 'why': ['audio'], 'files': [{'path': 'Packages/SessionKit/Sources/SessionKitAudio/X.swift',
                                                  'category': 'audio'}]}
HOST_RAN = 'host tests (--plan fast): passed'


class AuditHeldChecksStandAfterTheAuditTests(RealGitLaneTests):
    """#1461 end to end with real git: the automerge run the audit hold stopped, then the run the clean audit re-arms."""

    def setUp(self):
        super().setUp()
        patch = mock.patch.object(lane, 'diff_scope', return_value=AUDIO)
        patch.start()
        self.addCleanup(patch.stop)

    def github(self):
        return FakeGitHub(labels=('automerge',), head=self.head)

    def run_automerge(self, github, checked=None):
        """One automerge run as main() starts it: the checks, then the merge or the hold. Returns the run's checks mock,
        its details, and the base it tested; a report is posted for it as main() does."""
        base = lane.fetch_base(self.tree, 'main')
        context = lane.AutoRunContext(base)
        with mock.patch.object(lane, 'run_automerge', return_value=('PASS', 'no simulator (compile only)', HOST_RAN,
                                                                    [])) as checks:
            verdict, where, ran, details = lane.run_auto(github, github.pull(), 5, 'main', self.head, base,
                                                         self.evidence / f'run{len(github.posted)}', github.comments(),
                                                         context=context, checked=checked, labels=github.labels)
        github.comment(lane.report(f'pr5-r{len(github.posted)}', verdict, self.head, context.tested_base, 'auto', where,
                                   1, ran, details, 'none', '/e', 'owner',
                                   lane.identity('auto', self.head, context.tested_base, [])))
        return checks, details, base

    def audited_head_comment(self):
        return comment(f'**Claude audit on `{self.head[:7]}`**\n\nNo blocking findings.')

    def held_then_audited(self):
        github = self.github()
        checks, details, tested = self.run_automerge(github)
        checks.assert_called_once()  # the first run tests, and the audit holds it
        self.assertTrue(any(line.startswith('not merged by the runner: ') for line in details), details)
        self.assertEqual(self.rev(self.origin, 'main'), tested)  # nothing was pushed
        github._comments.append(self.audited_head_comment())
        return github, tested

    def rearmed_run(self, github):
        return self.run_automerge(github, lane.audit_held_checks(github.comments(), self.head))

    def test_the_run_the_clean_audit_re_arms_merges_the_earlier_pass_without_the_checks_again(self):
        github, tested = self.held_then_audited()
        checks, details, _ = self.rearmed_run(github)
        checks.assert_not_called()  # no --plan fast
        hold_report = github.posted[0]
        self.assertIn(f'not re-tested: the automerge run held for the audit (https://example.test/1) passed its '
                      f'checks with main at {tested[:7]}, and main hasn\'t moved since', details[0])
        merged = self.rev(self.origin, 'main')
        self.assertIn(f'merged into main as {merged[:7]}', details[-1])
        self.assertEqual(subprocess.check_output(['git', '-C', str(self.tree), 'rev-list', '--parents', '-n', '1',
                                                 merged], text=True).split()[1:], [tested, self.head])
        self.assertIn(f'(tested merged with main at {tested[:7]})', github.posted[-1].partition('\n')[2])
        self.assertIn(lane.checks_note(self.head, tested, HOST_RAN, 'no simulator (compile only)'), hold_report)
        merge_check = next(body for body in github.posted if body.startswith(lane.MERGE_CHECK))
        self.assertIn('without re-testing', merge_check)
        self.assertIn('Reuses the earlier PASS: the automerge run held for the audit (https://example.test/1)',
                      merge_check)
        self.assertIn('main hasn\'t moved since that run', merge_check)
        self.assertNotIn('Pushing `', merge_check)  # phone-build reads that as "tested this exact commit"

    def test_next_moving_by_commits_that_cannot_matter_still_merges_the_earlier_pass(self):
        github, tested = self.held_then_audited()
        self.commit(self.other, 'unrelated.txt', 'another PR\n')
        self.push_next()
        checks, details, _ = self.rearmed_run(github)
        checks.assert_not_called()
        self.assertIn(f'with main at {tested[:7]}, and main\'s 1 commit since touch none of this PR\'s files', details[0])
        self.assertIn('merged into main as', details[-1])
        merge_check = next(body for body in github.posted if body.startswith(lane.MERGE_CHECK))
        self.assertIn('Reuses the earlier PASS', merge_check)
        self.assertIn('touch none of this PR\'s files and no build inputs', merge_check)
        # the report names the trunk tip the checks ran with, not the newer one it merged onto
        self.assertIn(f'(tested merged with main at {tested[:7]})', github.posted[-1].partition('\n')[2])

    def moved_next_runs_the_checks_again(self, name, text):
        github, tested = self.held_then_audited()
        (self.other / name).parent.mkdir(exist_ok=True)
        self.commit(self.other, name, text)
        self.push_next()
        checks, details, _ = self.rearmed_run(github)
        checks.assert_called_once()
        self.assertIn(f'passed its checks with main at {tested[:7]}; tested again on', details[1])
        self.assertIn('merged into main as', details[-1])
        merge_check = next(body for body in github.posted if body.startswith(lane.MERGE_CHECK))
        self.assertNotIn('Reuses the earlier PASS', merge_check)

    def test_next_moving_by_a_commit_to_the_pr_s_own_files_runs_the_checks_again(self):
        self.moved_next_runs_the_checks_again('pr.txt', 'pr\n')  # the same text, so the merge stays clean

    def test_next_moving_by_a_commit_to_a_build_input_runs_the_checks_again(self):
        self.moved_next_runs_the_checks_again('scripts/verify-tests.py', 'print(1)\n')

    def test_the_audit_hold_alone_never_merges(self):
        github = self.github()
        checks, details, tested = self.run_automerge(github)
        self.assertEqual(self.rev(self.origin, 'main'), tested)
        self.assertNotIn('merged into main', '\n'.join(details))

    def test_a_push_refused_after_a_reused_pass_is_re_merged_as_reused(self):
        github, tested = self.held_then_audited()
        self.commit(self.other, 'unrelated.txt', 'another PR\n')
        original = lane.push_merge
        calls = []

        def push(tree, sha, base):
            calls.append(sha)
            if len(calls) == 1:  # main moves just before the push
                self.push_next()
                return False, '! [rejected] main -> main (fetch first)'
            return original(tree, sha, base)
        with mock.patch.object(lane, 'push_merge', side_effect=push):
            checks, details, _ = self.rearmed_run(github)
        checks.assert_not_called()
        self.assertEqual(len(calls), 2)
        self.assertIn('merged into main as', details[-1])
        self.assertIn('the push to main was refused', details[1])
        self.assertIn(f'not re-tested: main\'s 1 commit since the tested {tested[:7]}', details[1])
        merge_checks = [body for body in github.posted if body.startswith(lane.MERGE_CHECK)]
        self.assertEqual(len(merge_checks), 2)  # one per push attempt, each saying it reuses the earlier PASS
        self.assertTrue(all('Reuses the earlier PASS' in body for body in merge_checks), merge_checks)

    def test_a_refused_push_that_needs_a_retest_does_not_claim_the_earlier_pass(self):
        github, tested = self.held_then_audited()
        original = lane.push_merge
        calls = []

        def push(tree, sha, base):
            calls.append(sha)
            if len(calls) == 1:  # main moves onto a build input just before the push
                (self.other / 'scripts').mkdir(exist_ok=True)
                self.commit(self.other, 'scripts/verify-tests.py', 'print(1)\n')
                self.push_next()
                return False, '! [rejected] main -> main (fetch first)'
            return original(tree, sha, base)
        with mock.patch.object(lane, 'push_merge', side_effect=push):
            checks, details, _ = self.rearmed_run(github)
        checks.assert_called_once()  # tested again on the newest main
        self.assertIn('merged into main as', details[-1])
        merge_checks = [body for body in github.posted if body.startswith(lane.MERGE_CHECK)]
        self.assertIn('Reuses the earlier PASS', merge_checks[0])
        self.assertNotIn('Reuses the earlier PASS', merge_checks[1])

    def test_the_hot_file_ratchet_runs_again_with_the_labels_the_pr_has_now(self):
        github = self.github()
        github.labels.add('hot-file-ok')
        self.run_automerge(github)  # the first run passed with hot-file-ok
        github._comments.append(self.audited_head_comment())
        github.labels.discard('hot-file-ok')

        def ratchet(tree, base, labels):
            return [] if 'hot-file-ok' in labels else ['Gate1AppModel.swift grows past its ceiling']
        with mock.patch.object(lane, 'hot_file_violations', side_effect=ratchet):
            checks, details, tested = self.rearmed_run(github)
        checks.assert_not_called()
        self.assertTrue(github.posted[-1].startswith('Lane report pr5-r1 — FAIL'), github.posted[-1])
        self.assertIn('hot-file ratchet — Gate1AppModel.swift grows past its ceiling', details[-1])
        self.assertEqual(self.rev(self.origin, 'main'), tested)  # nothing pushed

    def test_a_reused_run_held_again_still_reuses_the_original_pass_after_the_audit(self):
        github = self.github()
        checks, _, tested = self.run_automerge(github)  # held: no audit yet
        checks.assert_called_once()
        checks, details, _ = self.rearmed_run(github)  # re-armed too early: still no audit
        checks.assert_not_called()
        self.assertTrue(any(line.startswith('not merged by the runner: ') for line in details), details)
        self.assertEqual(lane.audit_held_checks(github.comments(), self.head)['next'], tested)  # not the newer main
        github._comments.append(self.audited_head_comment())
        checks, details, _ = self.rearmed_run(github)
        checks.assert_not_called()
        self.assertIn('merged into main as', details[-1])

    def test_a_hold_report_is_trusted_only_as_the_runner_s_own_newest_pass_on_the_head(self):
        github, tested = self.held_then_audited()
        found = lane.audit_held_checks(github.comments(), self.head)
        self.assertEqual((found['next'], found['ran']), (tested, HOST_RAN))
        self.assertIsNone(lane.audit_held_checks(github.comments(), NEWER))  # another head
        pasted = [dict(c) for c in github.comments()]
        pasted[0] = dict(pasted[0], user={'login': 'uncomposed'})  # a pasted copy of the runner's report
        self.assertIsNone(lane.audit_held_checks(pasted, self.head))
        newer = runner_report('FAIL', lane.identity('auto', self.head, tested, []))
        self.assertIsNone(lane.audit_held_checks(github.comments() + [newer], self.head))  # a later run wins
        later_pass = runner_report('PASS', lane.identity('auto', self.head, tested, []))  # a PASS with no checks line
        self.assertIsNone(lane.audit_held_checks(github.comments() + [later_pass], self.head))
        short = dict(github.comments()[0], body=github.comments()[0]['body'].replace(tested, tested[:7]))
        self.assertIsNone(lane.audit_held_checks([short], self.head))

    def test_a_report_that_is_not_held_by_the_audit_gives_no_checks(self):
        # A PASS that merged, a FAIL, and a T3 hold carry no audit hold line, whatever else they say.
        line = lane.checks_note(self.head, self.rev(self.tree, 'origin/main'), 'ran', 'x')
        wanted = lane.identity('auto', self.head, self.rev(self.tree, 'origin/main'), [])
        for verdict, details in (('PASS', ['merged into main as abc1234', line]),
                                 ('FAIL', ['not merged by the runner: it touches the audio session and has no audit', line]),
                                 ('INCONCLUSIVE', [line, f'not merged: {lane.t3_gate([T3_FOR_HEAD])[1]}.'])):
            with self.subTest(verdict=verdict):
                held = comment(lane.report('pr5-r1', verdict, self.head, wanted['next'], 'auto', 'x', 1, 'x', details,
                                           'none', '/e', 'owner', wanted), login='github-actions[bot]')
                self.assertIsNone(lane.audit_held_checks([held], self.head))

    def test_the_pr_s_own_test_output_cannot_pass_for_an_audit_hold(self):
        wanted = lane.identity('auto', self.head, self.rev(self.tree, 'origin/main'), [])
        line = lane.checks_note(self.head, wanted['next'], 'ran', 'x')
        forged = comment(lane.report('pr5-r1', 'PASS', self.head, wanted['next'], 'auto', 'x', 1, 'x',
                                     [f'  {line}', '  not merged by the runner: it touches audio and has no audit'],
                                     'none', '/e', 'owner', wanted), login='github-actions[bot]')
        self.assertIsNone(lane.audit_held_checks([forged], self.head))


class AutomergeJobPassesTheAuditHeldChecksTests(unittest.TestCase):
    run_main = test_lane_runner.MainFlowTests.run_main
    conflicts, role, attempt, state_dir, ops = [], '', '1', None, mock.Mock()

    def run_auto_job(self, github):
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests', [])) as auto, \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host', return_value=(None, None)):
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        return auto

    def test_the_re_armed_run_hands_the_hold_report_s_checks_to_run_auto(self):
        wanted = lane.identity('auto', HEAD, MERGE, [])
        held = comment(lane.report('pr5-r40', 'PASS', HEAD, MERGE, 'auto', 'x', 1, 'host tests', [
            lane.checks_note(HEAD, MERGE, 'host tests', 'x'), 'not merged by the runner: it touches the lane and has no '
            'Codex or Claude audit comment yet.'], 'none', '/e', 'owner', wanted), login='github-actions[bot]',
            url='https://example.test/held')
        github = FakeGitHub(labels=('automerge',), comments=[held, CLEAN_AUDIT])
        auto = self.run_auto_job(github)
        checked = auto.call_args.kwargs['checked']
        self.assertEqual((checked['next'], checked['ran'], checked['held']),
                         (MERGE, 'host tests', 'the automerge run held for the audit (https://example.test/held)'))

    def test_a_pr_with_no_hold_report_tests_as_before(self):
        auto = self.run_auto_job(FakeGitHub(labels=('automerge',)))
        self.assertIsNone(auto.call_args.kwargs['checked'])

    def held_github(self):
        wanted = lane.identity('auto', HEAD, MERGE, [])
        held = comment(lane.report('pr5-r40', 'PASS', HEAD, MERGE, 'auto', 'x', 1, 'host tests', [
            lane.checks_note(HEAD, MERGE, 'host tests', 'x'), 'not merged by the runner: it touches the lane and has no '
            'Codex or Claude audit comment yet.'], 'none', '/e', 'owner', wanted), login='github-actions[bot]')
        return FakeGitHub(labels=('automerge',), comments=[held, CLEAN_AUDIT])

    def run_on_build_runner(self, github, moves):
        self.role = 'build'
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests', [])), \
                mock.patch.object(lane, 'untested_moves', return_value=moves), \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host', return_value=(None, None)) as wait:
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        return wait

    def test_a_run_that_only_reuses_the_pass_waits_for_no_room(self):
        # Waiting 90 minutes for room, then reporting INCONCLUSIVE, would be the newest report and lose the PASS.
        self.run_on_build_runner(self.held_github(), ([], '')).assert_not_called()

    def test_a_run_that_has_to_test_again_still_waits_for_room(self):
        self.run_on_build_runner(self.held_github(), (None, 'its commits touch build inputs')).assert_called_once()


if __name__ == '__main__':
    unittest.main()
