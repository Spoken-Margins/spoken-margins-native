"""scripts/merge_policy.py, the merge queue's "merge policy" check (#4693).

Real git repositories in temp folders; GitHub is faked at the `gh` boundary (GitHub.run) or as a small object.
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('merge_policy', SCRIPTS / 'merge_policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

SIGNED = 'Signed-off-by: Pat Example <pat@example.test>'


def git(tree, *args):
    return subprocess.run(['git', '-C', str(tree), *args], check=True, capture_output=True, text=True).stdout.strip()


class Repo:
    """A bare 'origin' with main, and a clone where a PR branch adds files. head is the PR's head commit."""

    def __init__(self, files: dict[str, str], message: str = f'Change\n\n{SIGNED}'):
        self.dir = tempfile.TemporaryDirectory()
        base = Path(self.dir.name)
        origin, self.tree = base / 'origin.git', base / 'tree'
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(origin)], check=True)
        subprocess.run(['git', 'clone', '-q', str(origin), str(self.tree)], check=True, capture_output=True)
        for key, value in (('user.name', 'Pat'), ('user.email', 'pat@example.test')):
            git(self.tree, 'config', key, value)
        (self.tree / 'README.md').write_text('base\n')
        git(self.tree, 'add', '.')
        git(self.tree, 'commit', '-q', '-m', f'Base\n\n{SIGNED}')
        git(self.tree, 'push', '-q', 'origin', 'main')
        git(self.tree, 'checkout', '-q', '-b', 'pr')
        for path, text in files.items():
            (self.tree / path).parent.mkdir(parents=True, exist_ok=True)
            (self.tree / path).write_text(text)
        git(self.tree, 'add', '.')
        git(self.tree, 'commit', '-q', '-m', message)
        self.head = git(self.tree, 'rev-parse', 'HEAD')
        git(self.tree, 'checkout', '-q', 'main')

    def close(self):
        self.dir.cleanup()


class FakeGitHub:
    repo = 'o/r'

    def __init__(self, labels=(), comments=(), association='OWNER', login='owner', body='', issues=None):
        self.labels, self._comments = labels, list(comments)
        self.association, self.login, self.body, self.issues = association, login, body, issues or {}

    def pull(self, number):
        return {'labels': [{'name': name} for name in self.labels], 'author_association': self.association,
                'user': {'login': self.login}, 'body': self.body, 'created_at': '2026-11-22T09:00:00Z'}

    def issue(self, number):
        return self.issues[number]

    def issue_comments(self, number):
        return []

    def issue_timeline(self, number):
        return []

    def comments(self, number):
        return self._comments


def scope_of(paths, diffs, *, lane_paths=(), category='scripts'):
    return {'files': [{'path': p, 'category': category} for p in paths], 'lane_paths': list(lane_paths)}


def audit(head, verdict='No blocking findings.'):
    return {'body': f'**Claude audit on `{head[:7]}`**\n\n{verdict}', 'author_association': 'OWNER',
            'user': {'login': 'owner'}}


class BlockerTests(unittest.TestCase):
    def check(self, files, github, classify=None, message=f'Change\n\n{SIGNED}'):
        repo = Repo(files, message)
        self.addCleanup(repo.close)
        reasons = policy.blockers(github, repo.tree, 'main', 7, repo.head,
                                  classify=classify or scope_of, inherited=lambda comments: [])
        return reasons, repo.head

    def test_an_ordinary_change_from_a_collaborator_may_merge(self):
        reasons, _ = self.check({'scripts/tool.py': 'x\n'}, FakeGitHub())
        self.assertEqual(reasons, [])

    def test_a_workflow_change_waits_for_the_owner_tap_label(self):
        # The rule lane-runner.py enforced by refusing to merge; nothing stopped `gh pr merge` until this check.
        files = {'.github/workflows/x.yml': 'on: push\n'}
        reasons, _ = self.check(files, FakeGitHub())
        self.assertEqual(len(reasons), 1)
        self.assertIn('`.github/workflows/x.yml`', reasons[0])
        self.assertIn('`owner-tap` label', reasons[0])
        reasons, _ = self.check(files, FakeGitHub(labels=('owner-tap',)))
        self.assertEqual(reasons, [])

    def test_the_runner_itself_waits_for_the_tap_and_the_audit_helper_labels_do_not_count(self):
        for labels in ((), ('owner-tap-check',), ('needs-owner-tap',)):
            with self.subTest(labels=labels):
                reasons, _ = self.check({'scripts/lane_merge_rules.py': 'x\n'}, FakeGitHub(labels=labels))
                self.assertTrue(any('only the owner merges' in r for r in reasons), reasons)

    def test_a_lane_change_needs_a_clean_audit_of_its_head(self):
        lane_scope = lambda paths, diffs: scope_of(paths, diffs, lane_paths=paths)  # noqa: E731
        repo = Repo({'scripts/lane_slots.py': 'x\n'})
        self.addCleanup(repo.close)
        cases = (([], 'has no Codex or Claude audit comment yet'),
                 ([audit('0' * 40)], 'the audit is on `0000000`'),
                 ([audit(repo.head, 'One blocking finding: ...')], 'has blocking findings'),
                 ([audit(repo.head)], None))
        for comments, expected in cases:
            with self.subTest(expected=expected):
                reasons = policy.blockers(FakeGitHub(comments=comments), repo.tree, 'main', 7, repo.head,
                                          classify=lane_scope, inherited=lambda c: [])
                if expected is None:
                    self.assertEqual(reasons, [])
                else:
                    self.assertEqual(len(reasons), 1, reasons)
                    self.assertIn('it touches the lane', reasons[0])
                    self.assertIn(expected, reasons[0])

    def test_an_audio_change_needs_the_audit_too(self):
        audio = lambda paths, diffs: scope_of(paths, diffs, category='audio')  # noqa: E731
        reasons, _ = self.check({'Packages/SessionKit/Sources/SessionKitAudio/A.swift': 'x\n'}, FakeGitHub(), audio)
        self.assertTrue(reasons and 'the audio session' in reasons[0], reasons)

    def test_inherited_holds_are_reported(self):
        repo = Repo({'scripts/tool.py': 'x\n'})
        self.addCleanup(repo.close)
        reasons = policy.blockers(FakeGitHub(), repo.tree, 'main', 7, repo.head, classify=scope_of,
                                  inherited=lambda comments: ['it inherits a blocking audit finding: #5'])
        self.assertEqual(reasons, ['it inherits a blocking audit finding: #5'])

    def test_an_outsiders_unsigned_commit_is_held_and_a_signed_one_is_not(self):
        outsider = FakeGitHub(association='CONTRIBUTOR', login='stranger')
        reasons, head = self.check({'scripts/tool.py': 'x\n'}, outsider, message='Change')
        self.assertEqual(len(reasons), 1)
        self.assertIn(f'no `Signed-off-by:` line ({head[:7]})', reasons[0])
        reasons, _ = self.check({'scripts/tool.py': 'x\n'}, outsider)
        self.assertEqual(reasons, [])
        reasons, _ = self.check({'scripts/tool.py': 'x\n'}, FakeGitHub(association='COLLABORATOR'), message='Change')
        self.assertEqual(reasons, [])

    def test_package_resolved_alone_is_the_linux_rewrite_and_is_held(self):
        # #4972: #4965 and #4970 carried SwiftPM's Linux rewrite of the pins file; only the audit caught it.
        resolved = {'Packages/SessionKit/Package.resolved': '{}\n'}
        reasons, _ = self.check(resolved, FakeGitHub())
        self.assertEqual(len(reasons), 1, reasons)
        self.assertIn('`Packages/SessionKit/Package.resolved`', reasons[0])
        self.assertIn('git checkout origin/main -- Packages/SessionKit/Package.resolved', reasons[0])
        # With other files beside it, and for an outsider's PR too: still held.
        reasons, _ = self.check({**resolved, 'scripts/tool.py': 'x\n'}, FakeGitHub(association='COLLABORATOR'))
        self.assertEqual(len(reasons), 1, reasons)

    def test_package_resolved_with_package_swift_is_a_deliberate_bump_and_may_merge(self):
        both = {'Packages/SessionKit/Package.resolved': '{}\n', 'Packages/SessionKit/Package.swift': '// bump\n'}
        reasons, _ = self.check(both, FakeGitHub())
        self.assertEqual(reasons, [])

    def test_a_pr_touching_neither_may_merge_and_other_pin_files_are_not_this_rule(self):
        reasons, _ = self.check({'scripts/tool.py': 'x\n'}, FakeGitHub())
        self.assertEqual(reasons, [])
        for path in ('Packages/SessionKit/Package.swift', 'Packages/SessionKitTools/Package.resolved',
                     'SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'):
            with self.subTest(path=path):
                reasons, _ = self.check({path: 'x\n'}, FakeGitHub())
                self.assertEqual(reasons, [])

    def test_closing_a_listener_issue_needs_real_use_proof_and_part_of_does_not(self):
        # #4979 (#4783): two fixture-tested web fixes closed a listener issue the owner's real link still failed.
        issues = {4783: {'labels': [{'name': 'area: pass it on'}]}, 4979: {'labels': [{'name': 'area: groundwork'}]}}
        files = {'web/share.js': 'x\n'}
        reasons, _ = self.check(files, FakeGitHub(body='Closes #4783', issues=issues))
        self.assertEqual(len(reasons), 1, reasons)
        self.assertIn('real-use proof', reasons[0])
        self.assertIn('`Part of #4783`', reasons[0])
        for body in ('Part of #4783', 'Closes #4979', 'No issue'):
            with self.subTest(body=body):
                reasons, _ = self.check(files, FakeGitHub(body=body, issues=issues))
                self.assertEqual(reasons, [])

    def test_a_closing_keyword_in_a_commit_message_counts_like_one_in_the_body(self):
        issues = {4783: {'labels': [{'name': 'area: pass it on'}]}}
        reasons, _ = self.check({'web/share.js': 'x\n'}, FakeGitHub(body='Part of #4783', issues=issues),
                                message=f'Fix share links\n\nCloses #4783\n\n{SIGNED}')
        self.assertEqual(len(reasons), 1, reasons)
        self.assertIn('`Closes #4783`', reasons[0])

    def test_a_proof_must_name_one_of_the_prs_own_commits_and_cover_its_code(self):
        issues = {4783: {'labels': [{'name': 'area: pass it on'}]}}
        record = ('Closes #4783\n\n**Real-use proof**\nReal input: a real Apple Podcasts link\nPath: link to playback\n'
                  'Steps: opened it\nResult: PASS - played\nCommit: {sha}\n')
        repo = Repo({'web/share.js': 'x\n'})
        self.addCleanup(repo.close)
        def run(sha):
            return policy.blockers(FakeGitHub(body=record.format(sha=sha), issues=issues), repo.tree, 'main', 7, repo.head,
                                   classify=scope_of, inherited=lambda c: [])
        self.assertEqual(run(repo.head), [])
        self.assertEqual(run(repo.head[:7]), [])
        self.assertIn('not one of this PR', run('1234567')[0])
        # A later code change makes the proof stale; a later note or test does not.
        git(repo.tree, 'checkout', '-q', 'pr')
        (repo.tree / 'web/share.js').write_text('y\n')
        git(repo.tree, 'commit', '-qam', f'Fix\n\n{SIGNED}')
        later = git(repo.tree, 'rev-parse', 'HEAD')
        git(repo.tree, 'checkout', '-q', 'main')
        stale = policy.blockers(FakeGitHub(body=record.format(sha=repo.head), issues=issues), repo.tree, 'main', 7, later,
                                classify=scope_of, inherited=lambda c: [])
        self.assertTrue(stale and 'run it again on the head' in stale[0], stale)

    def test_a_failure_inside_the_proof_check_holds_that_pr_and_a_read_failure_holds_the_merge(self):
        repo = Repo({'web/share.js': 'x\n'})
        self.addCleanup(repo.close)
        broken = FakeGitHub(body='Closes #4783')   # no such issue: the fake raises KeyError
        reasons = policy.blockers(broken, repo.tree, 'main', 7, repo.head, classify=scope_of, inherited=lambda c: [])
        self.assertTrue(reasons and 'real-use proof check failed' in reasons[0], reasons)
        def unreadable(number):
            raise policy.ReadFailed('gh api issues failed 3 times')
        broken.issue = unreadable
        out = io.StringIO()
        code = policy.judge(broken, repo.tree, 'main', [(7, repo.head)], out=out, classify=scope_of, inherited=lambda c: [])
        self.assertEqual(code, 1)
        self.assertIn('could not read what it needs', out.getvalue())

    def test_a_head_that_is_not_in_the_tree_and_cannot_be_fetched_holds(self):
        repo = Repo({'scripts/tool.py': 'x\n'})
        self.addCleanup(repo.close)
        out = io.StringIO()
        code = policy.judge(FakeGitHub(), repo.tree, 'main', [(7, 'f' * 40)], out=out, classify=scope_of,
                            inherited=lambda c: [])
        self.assertEqual(code, 1)
        self.assertIn('#7 at fffffff may not merge: the check could not read what it needs', out.getvalue())

    def test_the_real_rules_load_from_this_checkout(self):
        # The default classify and owner-tap rules are test-scope.py's and lane_merge_rules.py's, not copies.
        self.assertTrue(callable(policy.scope_policy().classify))
        self.assertEqual(policy.rules().OWNER_TAP_FILES, {'scripts/lane_merge_rules.py'})
        self.assertEqual(policy.rules().owner_tap_paths(scope_of(['.github/a.yml', 'b.py'], {})), ['.github/a.yml'])


class JudgeTests(unittest.TestCase):
    def test_one_line_per_pr_and_exit_one_when_any_is_blocked(self):
        ok = Repo({'scripts/tool.py': 'x\n'})
        tap = Repo({'.github/x.yml': 'x\n'})
        self.addCleanup(ok.close)
        self.addCleanup(tap.close)
        out = io.StringIO()
        self.assertEqual(policy.judge(FakeGitHub(), ok.tree, 'main', [(1, ok.head)], out=out, classify=scope_of,
                                      inherited=lambda c: []), 0)
        self.assertEqual(out.getvalue(), f'#1 at {ok.head[:7]} may merge.\n')
        out = io.StringIO()
        self.assertEqual(policy.judge(FakeGitHub(), tap.tree, 'main', [(2, tap.head)], out=out, classify=scope_of,
                                      inherited=lambda c: []), 1)
        self.assertTrue(out.getvalue().startswith(f'#2 at {tap.head[:7]} may not merge: it touches `.github/x.yml`'))


class GroupTests(unittest.TestCase):
    def entry(self, position, head, number):
        return {'position': position, 'headCommit': {'oid': head}, 'pullRequest': {'number': number, 'headRefOid': f'h{number}'}}

    def test_a_group_is_the_entries_up_to_its_head_in_queue_order(self):
        entries = [self.entry(3, 'g3', 30), self.entry(1, 'g1', 10), self.entry(2, 'g2', 20)]
        self.assertEqual(policy.group_prs(entries, 'g2'), [(10, 'h10'), (20, 'h20')])
        self.assertEqual(policy.group_prs(entries, 'g1'), [(10, 'h10')])
        self.assertEqual(len(policy.group_prs(entries, 'g3')), 3)

    def test_a_group_head_not_in_the_queue_holds(self):
        with self.assertRaises(policy.ReadFailed):
            policy.group_prs([self.entry(1, 'g1', 10)], 'gone')

    def test_the_queue_is_read_through_graphql(self):
        answer = {'data': {'repository': {'mergeQueue': {'entries': {'nodes': [self.entry(1, 'g1', 10)]}}}}}
        calls = []

        def run(cmd, **kwargs):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 0, json.dumps(answer), '')
        github = policy.GitHub('o/r', run=run, sleep=lambda s: None)
        self.assertEqual(github.queue_entries('main'), answer['data']['repository']['mergeQueue']['entries']['nodes'])
        self.assertEqual(calls[0][:3], ['gh', 'api', 'graphql'])
        self.assertIn('branch=main', calls[0])
        missing = {'data': {'repository': {'mergeQueue': None}}}
        github = policy.GitHub('o/r', run=lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, json.dumps(missing), ''),
                               sleep=lambda s: None)
        with self.assertRaises(policy.ReadFailed):
            github.queue_entries('main')


class RateLimitTests(unittest.TestCase):
    """#4990: a read refused because the API budget is spent waits for the reset instead of holding the PR."""
    LIMITED = 'gh: API rate limit exceeded for installation. If you reach out to GitHub Support for help'

    def github(self, answers, rate_wait=3700, now=1000.0):
        calls, sleeps = [], []

        def run(cmd, **kwargs):
            calls.append(cmd)
            code, out, err = answers.pop(0)
            return subprocess.CompletedProcess(cmd, code, out, err)
        return policy.GitHub('o/r', run=run, sleep=sleeps.append, clock=lambda: now, rate_wait=rate_wait,
                             out=io.StringIO()), calls, sleeps

    def test_a_spent_budget_is_waited_out_and_the_read_then_succeeds(self):
        github, calls, sleeps = self.github([(1, '', self.LIMITED), (0, '2500\n', ''), (0, '{"number": 7}', '')])
        self.assertEqual(github.pull(7), {'number': 7})
        self.assertEqual(sleeps, [1500 + policy.RATE_WAIT_SLACK])
        self.assertEqual(calls[1][:3], ['gh', 'api', 'rate_limit'])
        self.assertIn('.resources.core.reset', calls[1])

    def test_the_budget_asked_about_is_the_one_the_read_spends(self):
        for args, resource in ((['api', 'graphql', '-f', 'query=x'], 'graphql'), (['api', 'search/issues?q=x'], 'search'),
                               (['api', 'repos/o/r/pulls/7'], 'core')):
            github, calls, _ = self.github([(1, '', self.LIMITED), (0, '1001', ''), (0, '{}', '')])
            github._gh(args)
            self.assertIn(f'.resources.{resource}.reset', calls[1])

    def test_a_reset_further_off_than_the_job_may_wait_fails_as_before(self):
        answers = [(1, '', self.LIMITED), (0, '4600', '')] + [(1, '', self.LIMITED)] * 2
        github, calls, sleeps = self.github(answers, rate_wait=policy.DEFAULT_RATE_WAIT)
        with self.assertRaises(policy.ReadFailed) as raised:
            github.pull(7)
        self.assertIn('rate limit', str(raised.exception))
        self.assertEqual(sleeps, [policy.RETRY_WAIT, policy.RETRY_WAIT * 2])  # the ordinary retries only

    def test_the_reset_is_waited_for_once_per_read(self):
        answers = [(1, '', self.LIMITED), (0, '1010', ''), (1, '', self.LIMITED), (1, '', self.LIMITED), (1, '', self.LIMITED)]
        github, calls, sleeps = self.github(answers)
        with self.assertRaises(policy.ReadFailed):
            github.pull(7)
        self.assertEqual(len([c for c in calls if 'rate_limit' in c]), 1)

    def test_an_unreadable_reset_and_a_secondary_limit_are_ordinary_failures(self):
        github, _, sleeps = self.github([(1, '', self.LIMITED), (1, '', 'HTTP 500'), (0, '{"number": 7}', '')])
        self.assertEqual(github.pull(7), {'number': 7})
        self.assertEqual(sleeps, [policy.RETRY_WAIT])
        secondary = 'gh: You have exceeded a secondary rate limit. Please wait a few minutes'
        github, calls, _ = self.github([(1, '', secondary), (0, '{"number": 7}', '')])
        self.assertEqual(github.pull(7), {'number': 7})
        self.assertFalse([c for c in calls if 'rate_limit' in c])

    def test_a_single_try_dispatch_never_waits(self):
        github, calls, sleeps = self.github([(1, '', self.LIMITED)])
        with self.assertRaises(policy.ReadFailed):
            github.dispatch('hosted-web.yml', 'branch', {})
        self.assertEqual((len(calls), sleeps), (1, []))

    def test_the_wait_comes_from_the_workflow_and_defaults_to_what_an_old_copy_of_it_allows(self):
        with mock.patch.dict(os.environ, {'RATE_LIMIT_WAIT': '3700'}):
            self.assertEqual(policy.rate_wait_from_env(), 3700)
        with mock.patch.dict(os.environ, {'RATE_LIMIT_WAIT': ''}):
            self.assertEqual(policy.rate_wait_from_env(), policy.DEFAULT_RATE_WAIT)
        text = (Path(policy.__file__).resolve().parents[1] / '.github/workflows/merge-policy.yml').read_text()
        self.assertIn("RATE_LIMIT_WAIT: '3700'", text)
        self.assertIn('timeout-minutes: 75', text)  # longer than the wait


class RetryTests(unittest.TestCase):
    def test_a_blip_is_retried_and_a_lasting_failure_raises(self):
        answers = [subprocess.CompletedProcess([], 1, '', 'HTTP 502'), subprocess.CompletedProcess([], 1, '', 'HTTP 502'),
                   subprocess.CompletedProcess([], 0, '{"number": 7}', '')]
        slept = []
        github = policy.GitHub('o/r', run=lambda cmd, **k: answers.pop(0), sleep=slept.append)
        self.assertEqual(github.pull(7), {'number': 7})
        self.assertEqual(slept, [policy.RETRY_WAIT, policy.RETRY_WAIT * 2])
        github = policy.GitHub('o/r', run=lambda cmd, **k: subprocess.CompletedProcess(cmd, 1, '', 'HTTP 502'),
                               sleep=lambda s: None)
        with self.assertRaisesRegex(policy.ReadFailed, 'failed 3 times: HTTP 502'):
            github.pull(7)

    def test_only_trusted_comments_count(self):
        found = [{'body': 'a', 'author_association': 'NONE', 'user': {'login': 'stranger'}},
                 {'body': 'b', 'author_association': 'OWNER', 'user': {'login': 'owner'}},
                 {'body': 'c', 'author_association': 'NONE', 'user': {'login': 'github-actions[bot]'}}]
        out = '\n'.join(json.dumps(c) for c in found)
        github = policy.GitHub('o/r', run=lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, out, ''),
                               sleep=lambda s: None)
        self.assertEqual([c['body'] for c in github.comments(7)], ['b', 'c'])


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.safe_load((ROOT / '.github/workflows/merge-policy.yml').read_text())

    def test_one_check_named_merge_policy_on_prs_the_queue_and_by_hand(self):
        on = self.workflow[True]  # YAML reads `on:` as true
        self.assertEqual(on['pull_request']['types'], ['opened', 'synchronize', 'reopened', 'labeled', 'unlabeled'])
        self.assertEqual(on['pull_request']['branches'], ['main'])
        self.assertEqual(on['merge_group'], {'types': ['checks_requested'], 'branches': ['main']})
        self.assertIn('pr', on['workflow_dispatch']['inputs'])
        for trigger in on.values():
            self.assertNotIn('paths', trigger or {})
            self.assertNotIn('paths-ignore', trigger or {})
        # The job is not named `merge policy`: the script writes the check run of that name (#4986), so that it can stay
        # in progress while a PR waits for an audit or the owner, without a runner holding it.
        self.assertEqual([job['name'] for job in self.workflow['jobs'].values()], ['merge policy run'])
        self.assertEqual(self.workflow['jobs']['policy']['env']['SM_REPORTS_CHECK'], 'merge policy')
        self.assertEqual(policy.CHECK_NAME, 'merge policy')

    def test_no_run_of_the_check_can_cancel_another(self):
        # Two label events in one second (a re-arm) started two runs; the concurrency group cancelled one, and a
        # cancelled run with the newer id left the required check cancelled and the PR out of the queue (#4905).
        self.assertNotIn('concurrency', self.workflow)
        for name, job in self.workflow['jobs'].items():
            self.assertNotIn('concurrency', job, name)

    def test_the_rules_come_from_main_with_a_read_only_token(self):
        # `checks: write` only for the job's own check run (#4986); never `contents: write` or `pull-requests: write`.
        self.assertEqual(self.workflow['permissions'], {'contents': 'read', 'pull-requests': 'read', 'checks': 'write'})
        job = self.workflow['jobs']['policy']
        checkout = job['steps'][0]
        self.assertTrue(checkout['uses'].startswith('actions/checkout@'))
        self.assertEqual(checkout['with']['ref'], 'main')
        self.assertFalse(checkout['with']['persist-credentials'])
        run = job['steps'][1]['run']
        self.assertNotIn('${{', run)  # event data reaches the shell only through env
        self.assertNotIn('pull_request_target', (ROOT / '.github/workflows/merge-policy.yml').read_text())

    def run_step(self, event, *, knows_report_flag, exit_code=0):
        """Run the workflow's real shell step with a fake script and a fake `gh`; return (exit code, script args, gh calls)."""
        run = self.workflow['jobs']['policy']['steps'][1]['run']
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'scripts').mkdir()
            help_text = 'usage: merge_policy.py [--report-sha SHA]' if knows_report_flag else 'usage: merge_policy.py [--pr PR]'
            (tmp / 'scripts/merge_policy.py').write_text(
                'import sys\n'
                f'if "--help" in sys.argv: print({help_text!r}); sys.exit(0)\n'
                'open("args.txt", "a").write(" ".join(sys.argv[1:]) + "\\n")\n'
                'print("verdict line")\n'
                f'sys.exit({exit_code})\n')
            (tmp / 'bin').mkdir()
            gh = tmp / 'bin/gh'
            gh.write_text('#!/bin/sh\necho "$@" >> "' + str(tmp / 'gh.txt') + '"\n')
            gh.chmod(0o755)
            env = {'PATH': f'{tmp / "bin"}:/usr/bin:/bin', 'GITHUB_STEP_SUMMARY': str(tmp / 'summary.md'),
                   'GH_REPO': 'o/r', 'EVENT': event, 'PR': '7', 'HEAD_SHA': 'a' * 40 if event != 'merge_group' else '',
                   'GROUP_HEAD': 'b' * 40 if event == 'merge_group' else '', 'DETAILS_URL': 'https://example.test/run/1'}
            done = subprocess.run(['bash', '-e', '-c', run], cwd=tmp, env=env, capture_output=True, text=True)
            read = lambda name: (tmp / name).read_text().splitlines() if (tmp / name).exists() else []  # noqa: E731
            return done.returncode, read('args.txt'), read('gh.txt')

    def test_with_the_new_script_a_pull_request_and_the_queue_report_and_a_dispatch_does_not(self):
        code, args, gh = self.run_step('pull_request', knows_report_flag=True)
        self.assertEqual((code, gh), (0, []))  # the script writes the check run, not the workflow
        self.assertIn('--pr 7 --head ' + 'a' * 40, args[0])
        self.assertIn('--report-sha ' + 'a' * 40, args[0])
        self.assertIn('--details-url https://example.test/run/1', args[0])
        _, args, _ = self.run_step('merge_group', knows_report_flag=True)
        self.assertIn('--group-head ' + 'b' * 40, args[0])
        self.assertIn('--report-sha ' + 'b' * 40, args[0])
        code, args, gh = self.run_step('workflow_dispatch', knows_report_flag=True)
        self.assertNotIn('--report-sha', args[0])
        self.assertEqual(gh, [])

    def test_with_the_new_script_a_failing_verdict_fails_the_step(self):
        code, _, _ = self.run_step('pull_request', knows_report_flag=True, exit_code=1)
        self.assertEqual(code, 1)

    def test_before_main_has_the_flag_the_workflow_writes_the_check_run_itself(self):
        # The PR that adds --report-sha runs main's script (checkout ref: main) under its own workflow file, so the
        # first run saw "unrecognized arguments" and no `merge policy` check was ever written (#5011, 2026-11-22).
        for event, sha in (('pull_request', 'a' * 40), ('merge_group', 'b' * 40)):
            for exit_code, conclusion in ((0, 'success'), (1, 'failure')):
                with self.subTest(event=event, exit_code=exit_code):
                    code, args, gh = self.run_step(event, knows_report_flag=False, exit_code=exit_code)
                    # The step exits 0 either way: main's audit and owner-tap alert ignore a red `merge policy` but
                    # not a red `merge policy run`, so a red job would stop the PR being audited (#5011).
                    self.assertEqual(code, 0)
                    self.assertNotIn('--report-sha', args[0])
                    self.assertEqual(len(gh), 1, gh)
                    self.assertIn('repos/o/r/check-runs', gh[0])
                    self.assertIn('name=merge policy', gh[0])
                    self.assertIn(f'head_sha={sha}', gh[0])
                    self.assertIn(f'conclusion={conclusion}', gh[0])
        code, args, gh = self.run_step('workflow_dispatch', knows_report_flag=False)
        self.assertEqual((code, gh), (0, []))  # a dispatched run never writes a check run


class FakeChecksGitHub:
    """Records the Checks API calls CheckRun makes through GitHub._gh, so a test reads what GitHub would show."""
    repo = 'o/r'

    def __init__(self, fail_start=False, fail_finish=False):
        self.calls, self.fail_start, self.fail_finish = [], fail_start, fail_finish

    def _gh(self, args):
        self.calls.append(list(args))
        if args[:3] == ['api', '-X', 'POST'] and self.fail_start:
            raise policy.ReadFailed('no')
        if args[:3] == ['api', '-X', 'PATCH'] and self.fail_finish:
            raise policy.ReadFailed('no')
        return json.dumps({'id': 99})

    def fields(self, call):
        return dict(arg.split('=', 1) for arg in call if '=' in arg and not arg.startswith('/'))

    @property
    def shown(self):
        """(status, conclusion) of the check run after the last call."""
        patch = [c for c in self.calls if c[:3] == ['api', '-X', 'PATCH']]
        last = self.fields(patch[-1] if patch else next(c for c in self.calls if c[:3] == ['api', '-X', 'POST']))
        return last.get('status'), last.get('conclusion')


def found_for(*reasons_per_pr, unread=False):
    return [(n + 1, 'a' * 40, list(reasons), unread) for n, reasons in enumerate(reasons_per_pr)]


TAP = 'it touches `.github/x.yml`, which only the owner merges (owner rule 2026-10-09, #1203); it needs the `owner-tap` label, which only the owner adds'
AUDIT = 'it touches the lane, which has no Codex or Claude audit comment yet'
FINDINGS = 'it touches the lane, whose audit of its head has blocking findings'
HOLDS = ('real-use proof is missing for #5', '1 commit(s) have no `Signed-off-by:` line (abc1234); see CONTRIBUTING.md',
         'the check could not read what it needs (rate limit), so it holds the merge')


class VerdictTests(unittest.TestCase):
    """Which holds only wait (pending, no runner) and which are failures (#4986)."""

    def test_nothing_held_succeeds(self):
        self.assertEqual(policy.verdict(found_for([]), queue=False), 'success')
        self.assertEqual(policy.verdict(found_for([]), queue=True), 'success')

    def test_a_missing_audit_or_a_missing_owner_tap_alone_or_together_waits(self):
        for reasons in ([AUDIT], [TAP], [AUDIT, TAP]):
            with self.subTest(reasons=reasons):
                self.assertEqual(policy.verdict(found_for(reasons), queue=False), 'waiting')

    def test_every_other_hold_fails_even_beside_a_wait(self):
        for hold in HOLDS + (FINDINGS,):
            for reasons in ([hold], [AUDIT, hold], [hold, TAP]):
                with self.subTest(reasons=reasons):
                    self.assertEqual(policy.verdict(found_for(reasons), queue=False), 'failure')

    def test_an_unread_pr_fails_even_when_its_text_looks_like_a_wait(self):
        self.assertEqual(policy.verdict(found_for([AUDIT], unread=True), queue=False), 'failure')

    def test_the_queue_never_waits(self):
        # A held entry must fail and leave the queue, or the whole queue waits behind it.
        for reasons in ([AUDIT], [TAP], [AUDIT, TAP]):
            with self.subTest(reasons=reasons):
                self.assertEqual(policy.verdict(found_for(reasons), queue=True), 'failure')

    def test_one_failing_pr_in_a_group_fails_the_group(self):
        self.assertEqual(policy.verdict(found_for([AUDIT], [HOLDS[0]]), queue=False), 'failure')
        self.assertEqual(policy.verdict(found_for([AUDIT], []), queue=False), 'waiting')

    def test_the_wait_words_are_what_the_rules_say(self):
        # is_waiting reads the rules' own words, so a reworded reason can't turn a wait into a failure silently.
        rules = policy.rules()
        repo = Repo({'scripts/lane_slots.py': 'x\n'})
        self.addCleanup(repo.close)
        lane = lambda paths, diffs: scope_of(paths, diffs, lane_paths=paths)  # noqa: E731
        cases = (([], True), ([audit('0' * 40)], True), ([audit(repo.head, 'One blocking finding: x')], False))
        for comments, waits in cases:
            with self.subTest(waits=waits):
                reasons = policy.blockers(FakeGitHub(comments=comments), repo.tree, 'main', 7, repo.head,
                                          classify=lane, inherited=lambda c: [])
                self.assertEqual(len(reasons), 1, reasons)
                self.assertEqual(policy.is_waiting(reasons[0]), waits, reasons[0])
        self.assertTrue(rules.AUDIT_MISSING in AUDIT)
        tap = Repo({'.github/x.yml': 'x\n'})
        self.addCleanup(tap.close)
        reasons = policy.blockers(FakeGitHub(), tap.tree, 'main', 7, tap.head, classify=scope_of, inherited=lambda c: [])
        self.assertTrue(all(policy.is_waiting(r) for r in reasons) and reasons, reasons)

    def test_a_missing_real_use_proof_and_unsigned_commits_are_not_waits(self):
        repo = Repo({'scripts/tool.py': 'x\n'}, message='Change without sign-off')
        self.addCleanup(repo.close)
        reasons = policy.blockers(FakeGitHub(association='NONE', login='stranger'), repo.tree, 'main', 7, repo.head,
                                  classify=scope_of, inherited=lambda c: [])
        self.assertTrue(reasons and not any(policy.is_waiting(r) for r in reasons), reasons)


class ReportTests(unittest.TestCase):
    """The check run the script writes (#4986): in progress first, finished last, and an interrupted run stays blocked."""

    def run_report(self, repo, github, *, queue=False, prs_of=None, **kwargs):
        out = io.StringIO()
        code = policy.report(github, repo.tree, 'main', prs_of or (lambda: [(7, repo.head)]), repo.head, queue,
                             'https://example.test/run/1', out=out, classify=scope_of, inherited=lambda c: [],
                             **kwargs)
        return code, out.getvalue()

    def make(self, files):
        repo = Repo(files)
        self.addCleanup(repo.close)
        return repo

    def test_a_clean_pr_completes_the_check_as_success(self):
        repo, checks = self.make({'scripts/tool.py': 'x\n'}), FakeChecksGitHub()
        code, out = self.run_report(repo, _Both(FakeGitHub(), checks))
        self.assertEqual(code, 0)
        self.assertEqual(checks.shown, ('completed', 'success'))
        self.assertIn('may merge', out)

    def test_the_check_is_created_first_under_the_required_name_on_the_head(self):
        repo, checks = self.make({'scripts/tool.py': 'x\n'}), FakeChecksGitHub()
        self.run_report(repo, _Both(FakeGitHub(), checks))
        post = checks.calls[0]
        self.assertEqual(post[:4], ['api', '-X', 'POST', 'repos/o/r/check-runs'])
        fields = checks.fields(post)
        self.assertEqual((fields['name'], fields['head_sha'], fields['status']), ('merge policy', repo.head, 'in_progress'))
        self.assertEqual(fields['details_url'], 'https://example.test/run/1')
        self.assertEqual(checks.calls[1][:4], ['api', '-X', 'PATCH', 'repos/o/r/check-runs/99'])

    def test_an_owner_tap_wait_leaves_the_check_in_progress_and_exits_zero(self):
        repo, checks = self.make({'.github/x.yml': 'x\n'}), FakeChecksGitHub()
        code, out = self.run_report(repo, _Both(FakeGitHub(), checks))
        self.assertEqual(code, 0)
        self.assertEqual(checks.shown, ('in_progress', None))
        self.assertIn('may not merge', out)  # the log and the summary still say why
        self.assertEqual(checks.fields(checks.calls[-1])['output[title]'], "Waiting for the owner's tap")

    def test_the_same_pr_in_the_queue_fails(self):
        repo, checks = self.make({'.github/x.yml': 'x\n'}), FakeChecksGitHub()
        code, _ = self.run_report(repo, _Both(FakeGitHub(), checks), queue=True)
        self.assertEqual(code, 1)
        self.assertEqual(checks.shown, ('completed', 'failure'))

    def test_a_real_hold_fails_the_check(self):
        repo, checks = Repo({'.github/x.yml': 'x\n'}, message='No sign-off here'), FakeChecksGitHub()
        self.addCleanup(repo.close)
        code, _ = self.run_report(repo, _Both(FakeGitHub(association='NONE', login='stranger'), checks))
        self.assertEqual(code, 1)  # an outsider's unsigned commit is held beside the tap wait
        self.assertEqual(checks.shown, ('completed', 'failure'))

    def test_the_label_that_clears_the_tap_completes_it_as_success(self):
        repo, checks = self.make({'.github/x.yml': 'x\n'}), FakeChecksGitHub()
        code, _ = self.run_report(repo, _Both(FakeGitHub(labels=('owner-tap',)), checks))
        self.assertEqual((code, checks.shown), (0, ('completed', 'success')))

    def test_a_failed_read_of_the_prs_fails_the_check_rather_than_leaving_it_waiting(self):
        repo, checks = self.make({'scripts/tool.py': 'x\n'}), FakeChecksGitHub()

        def prs_of():
            raise policy.ReadFailed('queue unreadable')
        code, out = self.run_report(repo, _Both(FakeGitHub(), checks), prs_of=prs_of)
        self.assertEqual((code, checks.shown), (1, ('completed', 'failure')))
        self.assertIn('so it holds the merge', out)

    def test_a_rate_limited_read_of_a_pr_fails_even_though_nothing_else_is_wrong(self):
        repo, checks = self.make({'scripts/tool.py': 'x\n'}), FakeChecksGitHub()

        class Limited(FakeGitHub):
            def pull(self, number):
                raise policy.ReadFailed('HTTP 403 rate limit')
        code, _ = self.run_report(repo, _Both(Limited(), checks))
        self.assertEqual((code, checks.shown), (1, ('completed', 'failure')))

    def test_a_cancel_marks_the_check_cancelled_and_never_success(self):
        repo, checks = self.make({'scripts/tool.py': 'x\n'}), FakeChecksGitHub()

        class Cancelled(FakeGitHub):
            def pull(self, number):
                raise KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            self.run_report(repo, _Both(Cancelled(), checks))
        self.assertEqual(checks.shown, ('completed', 'cancelled'))

    def test_a_crash_fails_the_check_and_still_raises(self):
        repo, checks = self.make({'scripts/tool.py': 'x\n'}), FakeChecksGitHub()

        class Broken(FakeGitHub):
            def pull(self, number):
                raise ZeroDivisionError('boom')
        with self.assertRaises(ZeroDivisionError):
            self.run_report(repo, _Both(Broken(), checks))
        self.assertEqual(checks.shown, ('completed', 'failure'))

    def test_a_check_run_that_cannot_be_created_stops_before_any_verdict(self):
        repo, checks = self.make({'scripts/tool.py': 'x\n'}), FakeChecksGitHub(fail_start=True)
        with self.assertRaises(policy.ReadFailed):
            self.run_report(repo, _Both(FakeGitHub(), checks))
        self.assertEqual(len(checks.calls), 1)  # nothing was patched: no check run exists, so the merge is blocked

    def test_a_long_summary_is_cut_to_what_the_api_accepts(self):
        checks = FakeChecksGitHub()
        run = policy.CheckRun(checks, 'a' * 40)
        run.start()
        run.finish('failure', 'T' * 1000, 'S' * 70000)
        fields = checks.fields(checks.calls[-1])
        self.assertLessEqual(len(fields['output[title]']), 250)
        self.assertLessEqual(len(fields['output[summary]']), 65535)


class _Both:
    """The rule reads (FakeGitHub) and the Checks API writes (FakeChecksGitHub) behind one object, as GitHub is."""

    def __init__(self, reads, writes):
        self.reads, self.writes = reads, writes
        self.repo = writes.repo

    def __getattr__(self, name):
        return getattr(self.reads, name)

    def _gh(self, args):
        return self.writes._gh(args)


if __name__ == '__main__':
    unittest.main()
