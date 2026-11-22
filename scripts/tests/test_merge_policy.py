"""scripts/merge_policy.py, the merge queue's "merge policy" check (#4693).

Real git repositories in temp folders; GitHub is faked at the `gh` boundary (GitHub.run) or as a small object.
"""
from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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

    def __init__(self, labels=(), comments=(), association='OWNER', login='owner'):
        self.labels, self._comments = labels, list(comments)
        self.association, self.login = association, login

    def pull(self, number):
        return {'labels': [{'name': name} for name in self.labels], 'author_association': self.association,
                'user': {'login': self.login}}

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
        self.assertEqual([job['name'] for job in self.workflow['jobs'].values()], ['merge policy'])

    def test_no_run_of_the_check_can_cancel_another(self):
        # Two label events in one second (a re-arm) started two runs; the concurrency group cancelled one, and a
        # cancelled run with the newer id left the required check cancelled and the PR out of the queue (#4905).
        self.assertNotIn('concurrency', self.workflow)
        for name, job in self.workflow['jobs'].items():
            self.assertNotIn('concurrency', job, name)

    def test_the_rules_come_from_main_with_a_read_only_token(self):
        self.assertEqual(self.workflow['permissions'], {'contents': 'read', 'pull-requests': 'read'})
        job = self.workflow['jobs']['policy']
        checkout = job['steps'][0]
        self.assertTrue(checkout['uses'].startswith('actions/checkout@'))
        self.assertEqual(checkout['with']['ref'], 'main')
        self.assertFalse(checkout['with']['persist-credentials'])
        run = job['steps'][1]['run']
        self.assertNotIn('${{', run)  # event data reaches the shell only through env
        self.assertNotIn('pull_request_target', (ROOT / '.github/workflows/merge-policy.yml').read_text())


if __name__ == '__main__':
    unittest.main()
