"""#1492: the lane, workflows, Test Desk, phone build and merge audit name the trunk in one place.

The same code has to work while PRs target next and after they target main, so these tests check the branch
choice both ways: SM_TRUNK unset (next), and SM_TRUNK=main.
"""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
WORKFLOWS = ROOT / '.github' / 'workflows'
sys.path.insert(0, str(SCRIPTS))

import trunk  # noqa: E402
import merge_audit  # noqa: E402

_spec = importlib.util.spec_from_file_location('lane_runner_for_trunk', SCRIPTS / 'lane-runner.py')
lane = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lane)

MAIN = {'SM_TRUNK': 'main'}


class TrunkBranchTests(unittest.TestCase):
    def test_unset_means_next_until_the_switch(self):
        self.assertEqual(trunk.DEFAULT_TRUNK, 'next')
        self.assertEqual(trunk.trunk_branch({}), 'next')
        self.assertEqual(trunk.trunk_branch({'SM_TRUNK': ''}), 'next')
        self.assertEqual(trunk.trunk_branch({'SM_TRUNK': '  '}), 'next')
        self.assertEqual(trunk.trunk_ref({}), 'origin/next')

    def test_sm_trunk_moves_it_to_main(self):
        self.assertEqual(trunk.trunk_branch(MAIN), 'main')
        self.assertEqual(trunk.trunk_branch({'SM_TRUNK': ' main\n'}), 'main')
        self.assertEqual(trunk.trunk_ref(MAIN), 'origin/main')

    def test_it_reads_the_process_environment_by_default(self):
        with mock.patch.dict(os.environ, MAIN):
            self.assertEqual(trunk.trunk_branch(), 'main')
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(trunk.trunk_branch(), 'next')

    def test_a_name_git_would_not_take_as_a_plain_branch_stops_the_job(self):
        for bad in ('-f', '--force', 'a..b', 'refs/heads/main', 'main/', 'main.', 'x.lock', 'ma in', 'main;rm',
                    '$(id)', 'mäin', '/main', '.main'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                trunk.trunk_branch({'SM_TRUNK': bad})

    def test_is_trunk_takes_a_branch_or_a_ref(self):
        for base in ('next', 'origin/next', 'refs/heads/next', 'refs/remotes/origin/next'):
            with self.subTest(base=base):
                self.assertTrue(trunk.is_trunk(base, {}))
                self.assertFalse(trunk.is_trunk(base, MAIN))
        for base in ('main', 'origin/main', 'refs/heads/main'):
            with self.subTest(base=base):
                self.assertFalse(trunk.is_trunk(base, {}))
                self.assertTrue(trunk.is_trunk(base, MAIN))
        self.assertFalse(trunk.is_trunk('lane-check/x', {}))
        self.assertFalse(trunk.is_trunk('nextish', {}))

    def test_the_command_line_prints_the_name(self):
        env = {k: v for k, v in os.environ.items() if k != 'SM_TRUNK'}
        out = subprocess.run([sys.executable, str(SCRIPTS / 'trunk.py')], env={**env, **MAIN},
                             capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), 'main')


class WorkflowTrunkTests(unittest.TestCase):
    """Every workflow names the trunk as `vars.SM_TRUNK || '<DEFAULT_TRUNK>'`, and listens on both branches."""

    FALLBACK = re.compile(r"vars\.SM_TRUNK \|\| '([^']*)'")

    def workflows(self):
        return {path.name: path.read_text() for path in sorted(WORKFLOWS.glob('*.yml'))}

    def test_every_fallback_is_the_default_trunk(self):
        found = 0
        for name, text in self.workflows().items():
            for fallback in self.FALLBACK.findall(text):
                found += 1
                with self.subTest(workflow=name):
                    self.assertEqual(fallback, trunk.DEFAULT_TRUNK)
        self.assertGreater(found, 10)

    def test_no_workflow_hard_codes_next_as_a_branch_outside_its_trigger_list(self):
        branch_use = re.compile(r"refs/heads/next|'next'|\"next\"|base=next|origin/next")
        for name, text in self.workflows().items():
            for number, line in enumerate(text.splitlines(), 1):
                code = line.split('#', 1)[0]
                if branch_use.search(code) and 'vars.SM_TRUNK' not in code:
                    self.fail(f'{name}:{number} names next: {line.strip()}')

    def test_triggers_that_name_next_name_main_too(self):
        for name, text in self.workflows().items():
            for line in text.splitlines():
                if re.match(r'\s+branches: \[', line) and re.search(r'\bnext\b', line):
                    with self.subTest(workflow=name, line=line.strip()):
                        self.assertIn('main', line)

    def test_workflows_that_push_or_post_run_only_for_the_trunk(self):
        """A push to main before the switch (the fast-forward itself) starts nothing that writes."""
        gated = {'lane.yml': 4, 'merge-audit.yml': 1, 'hosted-integration.yml': 1, 'substack-canary.yml': 1,
                 'lane-conflicts.yml': 2}
        texts = self.workflows()
        for name, count in gated.items():
            with self.subTest(workflow=name):
                gates = re.findall(r"(?:base\.ref|ref_name) == \(vars\.SM_TRUNK \|\| 'next'\)", texts[name])
                self.assertEqual(len(gates), count)

    def test_sparse_checkouts_that_run_a_trunk_reader_carry_trunk_py(self):
        for name in ('merge-audit.yml', 'owner-tap-alert.yml'):
            with self.subTest(workflow=name):
                self.assertIn('scripts/trunk.py', self.workflows()[name])

    def test_lane_jobs_pass_sm_trunk_to_the_runner(self):
        text = self.workflows()['lane.yml']
        self.assertEqual(text.count("SM_TRUNK: ${{ vars.SM_TRUNK || 'next' }}"), 3)


class LaneRunnerTrunkTests(unittest.TestCase):
    IN_JOB = {'GITHUB_ACTIONS': 'true', 'GH_TOKEN': 't', 'GH_REPO': 'o/r'}

    def dispatch(self, base, env):
        with mock.patch.dict(os.environ, {**self.IN_JOB, **env}, clear=True), \
                mock.patch.object(lane.subprocess, 'run',
                                  return_value=subprocess.CompletedProcess([], 0, '', '')) as run:
            return lane.dispatch_hosted_integration(base), run

    def test_hosted_integration_follows_the_trunk(self):
        said, run = self.dispatch('next', {})
        self.assertIn('-f', run.call_args.args[0])
        self.assertEqual(run.call_args.args[0][-1], 'ref=next')
        said, run = self.dispatch('main', MAIN)
        self.assertEqual(run.call_args.args[0][-1], 'ref=main')
        said, run = self.dispatch('next', MAIN)
        run.assert_not_called()
        self.assertEqual(said, 'hosted integration not started: it tests main, not next')
        said, run = self.dispatch('main', {})
        run.assert_not_called()

    def test_the_report_names_the_trunk_when_no_base_is_given(self):
        with mock.patch.dict(os.environ, MAIN):
            body = lane.report('r1', 'PASS', 'a' * 40, 'b' * 40, 'T2', 'here', 1.0, 'ran', [], '', '', '', {})
        self.assertIn('tested merged with main at bbbbbbb', body)

    def test_a_local_run_without_base_uses_the_trunk(self):
        seen = {}

        def stop(tree, base, into=None):
            seen['base'] = base
            raise SystemExit(0)

        with mock.patch.dict(os.environ, MAIN), mock.patch.object(lane, 'base_scripts_fallback', side_effect=stop):
            with self.assertRaises(SystemExit):
                lane.main(['--pr', '1', '--event-head', 'a' * 40, '--run-id', '1', '--tree', str(ROOT)])
        self.assertEqual(seen['base'], 'main')


class MergeAuditTrunkTests(unittest.TestCase):
    @staticmethod
    def pr(number, sha, base):
        return {'number': number, 'merge_commit_sha': sha, 'merged_at': '2026-10-19T00:00:00Z', 'base': {'ref': base}}

    def test_a_push_counts_only_prs_into_the_pushed_branch(self):
        recent = [self.pr(1, 'm1', 'next'), self.pr(2, 'm2', 'main')]
        self.assertEqual(list(merge_audit.classify_push(['m1', 'm2'], 'm2', recent, 'main')[0]), [2])
        self.assertEqual(list(merge_audit.classify_push(['m1', 'm2'], 'm1', recent, 'next')[0]), [1])
        with mock.patch.dict(os.environ, MAIN):
            self.assertEqual(list(merge_audit.classify_push(['m1', 'm2'], 'm2', recent)[0]), [2])
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(list(merge_audit.classify_push(['m1', 'm2'], 'm1', recent)[0]), [1])

    def test_the_sweep_and_the_flag_name_the_base(self):
        import datetime
        now = datetime.datetime(2026, 10, 19, 1)
        recent = [self.pr(1, 'm1', 'next'), self.pr(2, 'm2', 'main')]
        self.assertEqual([p['number'] for p in merge_audit.recently_merged(recent, 2, now, 'main')], [2])
        self.assertTrue(merge_audit.failure_comment('c' * 40, None, 'main').startswith('Merged into main without'))
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertTrue(merge_audit.failure_comment('c' * 40).startswith('Merged into next without'))


class MacJobsTrunkTests(unittest.TestCase):
    """The phone build and the Test Desk's integration run read the trunk when they load."""

    def load(self, name, path, env):
        with mock.patch.dict(os.environ, env):
            if not env:
                os.environ.pop('SM_TRUNK', None)
            loader = importlib.machinery.SourceFileLoader(name, str(path))
            spec = importlib.util.spec_from_loader(name, loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
        return module

    def test_the_phone_build_builds_the_trunk(self):
        self.assertEqual(self.load('phone_build_next', SCRIPTS / 'phone-build', {}).BRANCH, 'next')
        self.assertEqual(self.load('phone_build_main', SCRIPTS / 'phone-build', MAIN).BRANCH, 'main')

    def test_the_integration_run_tests_the_trunk(self):
        path = ROOT / 'ops' / 'testdesk' / 'sm_integration_run.py'
        self.assertEqual(self.load('integration_next', path, {}).BASE_BRANCH, 'next')
        self.assertEqual(self.load('integration_main', path, MAIN).BASE_BRANCH, 'main')


class NoHardCodedNextTests(unittest.TestCase):
    """The scripts #1492 step 1 covers name no branch literally; prose and stored record keys may still say next."""

    FILES = ['scripts/lane-runner.py', 'scripts/merge_audit.py', 'scripts/phone-build', 'scripts/daily-phone-plan',
             'scripts/sm_status.py', 'scripts/lane_conflicts.py', 'scripts/owner_tap_alert.py',
             'scripts/hot_file_ratchet.py', 'scripts/test-scope.py', 'scripts/split_move.py',
             'scripts/integration-precheck.py', 'scripts/sim-build-latest', 'scripts/verify-tests.py',
             'ops/testdesk/sm_integration_run.py', 'ops/claude/sm_claude_worker.py', 'ops/codex/sm_codex_audit.py',
             'ops/disk/sm_disk_relief.py', 'ops/away/away_check.py']
    # A quoted ref, a query string, or a bare 'next' given as a value (a default, a comparison, an argument). Not
    # prose, and not the 'next' key the lane's stored records keep for compatibility ({'next': sha}, ['next']).
    BRANCH_USE = re.compile(r"""['"](?:origin/|refs/heads/|refs/remotes/origin/)next\b|base=next\b"""
                            r"""|(?<!get)(?:==|=|\(|,)\s*['"]next['"](?!\s*:)""")

    def test_no_branch_literal_left(self):
        for name in self.FILES:
            for number, line in enumerate((ROOT / name).read_text().splitlines(), 1):
                code = line.split('  # ', 1)[0]
                with self.subTest(file=name, line=number):
                    self.assertIsNone(self.BRANCH_USE.search(code), line.strip())


if __name__ == '__main__':
    unittest.main()
