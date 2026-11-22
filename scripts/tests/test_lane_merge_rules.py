"""The merge rules in scripts/lane_merge_rules.py that scripts/merge_policy.py applies to the merge queue:
which audits clear a head, and which comments are trusted. Moved out of test_lane_runner.py with the code
(#4769). A test that still calls `runner.` reaches the retired dispatcher in lane-runner.py."""
import os

os.environ.pop('SM_TRUNK', None)
os.environ.pop('GITHUB_EVENT_NAME', None)

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS / 'tests'))

spec = importlib.util.spec_from_file_location('lane_merge_rules', SCRIPTS / 'lane_merge_rules.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)
# The retired per-PR dispatcher, for the tests that still reach it (#4769).
runner_spec = importlib.util.spec_from_file_location('lane_runner', SCRIPTS / 'lane-runner.py')
runner = importlib.util.module_from_spec(runner_spec)
runner_spec.loader.exec_module(runner)

HEAD = 'a' * 40


def comment(body, login='uncomposed', url='https://example.test/c'):
    return {'body': body, 'user': {'login': login}, 'html_url': url}


class ClaudeAuditGateTests(unittest.TestCase):
    def test_claude_head_audit_clears_lane_and_risky_changes(self):
        clean = comment('**Claude audit on `aaaaaaa`**\n\nNo blocking findings.')
        scope = {'files': [{'category': 'audio'}, {'category': 'persistence'}, {'category': 'packet'}],
                 'lane_paths': ['scripts/lane-runner.py']}
        self.assertIsNone(lane.audit_blocker([clean], HEAD))
        self.assertEqual(lane.merge_blockers(scope, [clean], HEAD), [])

    def test_pr1654_host_domain_persistence_requires_its_head_audit(self):
        paths = [
            'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel+RemoteProvider.swift',
            'App/SpokenMarginsAppTests/SummaryFailureOwnershipWorkflowTests.swift',
            'App/SpokenMarginsAppTests/SummarySuccessOwnershipWorkflowTests.swift',
            'Packages/SessionKit/Sources/SessionKit/LocalSummaryRequestOrigin.swift',
            'Packages/SessionKit/Sources/SessionKit/SessionEngine.swift',
            'Packages/SessionKit/Tests/SessionKitTests/LocalSummaryCompletionTests.swift',
        ]
        spec = importlib.util.spec_from_file_location('audit_gate_scope', SCRIPTS / 'test-scope.py')
        scope_policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scope_policy)
        scope = scope_policy.classify(paths)
        self.assertEqual(scope['tier'], 'T3')
        engine = next(f for f in scope['files'] if f['path'].endswith('/SessionEngine.swift'))
        self.assertEqual(engine['category'], 'sessionkit')  # audit risk must not change test tiers
        self.assertEqual(lane.merge_blockers(scope, [], HEAD),
                         ['it touches persistence and has no Codex or Claude audit comment yet'])
        stale = comment('**Claude audit on `ccccccc`**\n\nNo blocking findings.')
        self.assertTrue(lane.merge_blockers(scope, [stale], HEAD))
        blocked = comment('**Claude audit on `aaaaaaa`**\n\n[P1] Wrong owner.')
        self.assertTrue(lane.merge_blockers(scope, [blocked], HEAD))
        clean = comment('**Claude audit on `aaaaaaa`**\n\nNo blocking findings.')
        self.assertEqual(lane.merge_blockers(scope, [clean], HEAD), [])

    def test_existing_persistence_path_policy_and_neighbor_exemptions(self):
        cases = {
            'Packages/SessionKit/Sources/SessionKit/SessionEngine+Retry.swift': True,
            'Packages/SessionKit/Sources/SessionKit/LocalSummaryRequestOrigin.swift': False,
            'Packages/SessionKit/Tests/SessionKitTests/SessionEngineTests.swift': False,
            'scripts/tests/test_persistence.py': False,
            'docs/SessionEngine.swift': False,
            'research/SessionEngine.swift': False,
            'Design/SessionEngine.swift': False,
            'docs/persistence.md': False,
        }
        for path, required in cases.items():
            with self.subTest(path=path):
                scope = {'files': [{'path': path, 'category': 'sessionkit'}]}
                self.assertEqual(bool(lane.merge_blockers(scope, [], HEAD)), required)

    def test_rules_copied_out_of_the_tree_still_load_and_apply_the_persistence_gate(self):
        # The rules import their helper (lane_audit_policy) only when merge_blockers runs, so a copy loaded from outside
        # scripts/ still loads once the caller puts scripts/ on sys.path (#1659, found in the runner this came from).
        driver = (
            'import importlib.util, sys\n'
            'spec = importlib.util.spec_from_file_location("lane_merge_rules", sys.argv[1])\n'
            'rules = importlib.util.module_from_spec(spec)\n'
            'spec.loader.exec_module(rules)\n'
            'sys.path.insert(0, sys.argv[2])\n'
            'files = [{"path": "Packages/SessionKit/Sources/SessionKit/SessionEngine.swift", "category": "sessionkit"}]\n'
            'print(rules.merge_blockers({"files": files}, [], "a" * 40))\n'
        )
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp) / '_work' / '_temp'
            temp.mkdir(parents=True)
            copied = temp / 'lane_merge_rules.py'
            copied.write_text((SCRIPTS / 'lane_merge_rules.py').read_text())
            env = {k: v for k, v in os.environ.items() if k != 'PYTHONPATH'}
            run = subprocess.run([sys.executable, '-c', driver, str(copied), str(SCRIPTS)],
                                 cwd=tmp, env=env, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr[-800:])
            self.assertIn('no Codex or Claude audit comment yet', run.stdout)

    def test_newest_head_audit_wins_across_reviewers(self):
        claude = comment('**Claude audit on `aaaaaaa`**\n\nNo blocking findings.')
        codex = comment('**Codex audit (Astra) on `aaaaaaa`**\n\n[P1] Broken.')
        self.assertIsNone(lane.audit_blocker([codex, claude], HEAD))
        self.assertIsNotNone(lane.audit_blocker([claude, codex], HEAD))


class TrustedCommentTests(unittest.TestCase):
    """Once the repository is public, only the owner, collaborators and the project's bot steer the lane (#1719)."""

    @staticmethod
    def comment(body, login, association):
        return {'body': body, 'user': {'login': login}, 'author_association': association,
                'html_url': f'https://example.test/{login}'}

    def test_who_is_trusted(self):
        for login, association, trusted in (
                ('uncomposed', 'OWNER', True),
                ('a-member', 'MEMBER', True),
                ('a-collaborator', 'COLLABORATOR', True),
                ('github-actions[bot]', 'NONE', True),
                ('stranger', 'NONE', False),
                ('past-contributor', 'CONTRIBUTOR', False),
                ('first-timer', 'FIRST_TIME_CONTRIBUTOR', False),
                ('first-timer', 'FIRST_TIMER', False),
                ('mannequin', 'MANNEQUIN', False),
                ('chatgpt-codex-connector[bot]', 'NONE', False),
                ('github-actions', 'NONE', False),  # not the bot: the [bot] suffix is reserved for apps
                ('owner-lookalike', 'owner', False),  # GitHub sends it upper case; anything else is not trusted
                ('no-association', None, False)):
            with self.subTest(login=login, association=association):
                self.assertEqual(lane.trusted_comment(self.comment('/lane T3', login, association)), trusted)
        self.assertFalse(lane.trusted_comment({'body': '/lane T3'}))  # no author at all

    def comments_from(self, *comments):
        github = runner.GitHub('o/r', 5)
        lines = '\n'.join(json.dumps(c) for c in comments)
        with mock.patch.object(github, 'api', return_value=lines), mock.patch('builtins.print') as printed:
            return github.comments(), printed

    def test_a_strangers_lane_request_is_never_run(self):
        kept, printed = self.comments_from(
            self.comment('/lane T3\ntests: SpeechTests', 'uncomposed', 'OWNER'),
            self.comment('/lane T2\ncommit: deadbeef', 'stranger', 'NONE'))
        request, _ = runner.pending_requests(kept)
        self.assertEqual((request['tier'], request['author']), ('T3', 'uncomposed'))
        self.assertIn('ignored 1 comment(s)', printed.call_args.args[0])
        self.assertIn('stranger', printed.call_args.args[0])

    def test_a_contributors_request_alone_leaves_nothing_to_run(self):
        kept, _ = self.comments_from(self.comment('/lane T3\ntests: SpeechTests', 'drive-by', 'CONTRIBUTOR'))
        self.assertEqual(runner.pending_requests(kept), (None, False))

    def test_a_fake_report_cannot_answer_a_request(self):
        identity = json.dumps(runner.identity('T3', HEAD, 'b' * 40, []))
        fake = f'Lane report r1 — PASS\n<!-- lane-request: {identity} -->'
        kept, _ = self.comments_from(self.comment('/lane T3\ncommit: aaaaaaa', 'uncomposed', 'OWNER'),
                                     self.comment(fake, 'stranger', 'NONE'))
        request, _ = runner.pending_requests(kept)
        self.assertIsNotNone(request)  # still waiting for the real runner

    def test_the_project_bots_reports_still_count(self):
        identity = json.dumps(runner.identity('T3', HEAD, 'b' * 40, []))
        report = f'Lane report r1 — PASS\n<!-- lane-request: {identity} -->'
        kept, printed = self.comments_from(self.comment('/lane T3\ncommit: aaaaaaa', 'uncomposed', 'OWNER'),
                                           self.comment(report, 'github-actions[bot]', 'NONE'))
        self.assertEqual(len(kept), 2)
        self.assertEqual(runner.pending_requests(kept), (None, False))
        printed.assert_not_called()


if __name__ == '__main__':
    unittest.main()
