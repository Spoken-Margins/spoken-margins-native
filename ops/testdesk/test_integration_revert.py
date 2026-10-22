import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import contextlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import integration_revert as revert
import sm_integration_run as run

ROOT = run.REPO_ROOT
SCOPE = revert.load_test_scope(ROOT)
APP = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/'
TEST = 'SpokenMarginsAppTests/PlaybackTests/testResume'
OTHER = 'SpokenMarginsAppTests/ImportTests/testPaste'


def commit(n, subject=None, parents=2):
    return {'sha': f'{n:040x}', 'parents': [f'{n - 1:040x}', f'{n + 100:040x}'][:parents],
            'subject': subject or f'Merge pull request #{n} from uncomposed/ws/{n}-x', 'body': f'Change {n}'}


def summary(tests, verdict='FAIL'):
    return {'verdict': verdict, 'tests': tests}


class CheckVerdictTests(unittest.TestCase):
    def test_a_failing_test_that_still_fails_is_a_fail(self):
        self.assertEqual(revert.check_verdict([TEST], summary({TEST: 'failed'})), 'fail')
        self.assertEqual(revert.check_verdict([TEST, OTHER], summary({TEST: 'failed', OTHER: 'failed'})), 'fail')
        # One still fails and one passes: different merges broke them, so this commit is not a single culprit.
        self.assertEqual(revert.check_verdict([TEST, OTHER], summary({TEST: 'passed', OTHER: 'failed'})), 'unknown')

    def test_only_passing_every_failing_test_is_a_pass(self):
        self.assertEqual(revert.check_verdict([TEST, OTHER], summary({TEST: 'passed', OTHER: 'passed'}, 'PASS')), 'pass')

    def test_a_missing_skipped_or_stopped_run_says_nothing(self):
        # The test did not exist yet, was skipped, or the target did not build: not evidence the merge is innocent.
        for tests, verdict in (({}, 'INCONCLUSIVE'), ({TEST: 'skipped'}, 'PASS'), ({TEST: 'passed'}, 'INCONCLUSIVE'),
                               ({TEST: 'passed'}, 'PASS')):
            with self.subTest(tests=tests, verdict=verdict):
                got = revert.check_verdict([TEST, OTHER], summary(tests, verdict))
                self.assertEqual(got, 'unknown')


class FindCulpritTests(unittest.TestCase):
    def search(self, count, first_bad, unknown=(), **kw):
        commits = [commit(n) for n in range(1, count + 1)]
        calls = []

        def check(c):
            n = int(c['sha'], 16)
            calls.append(n)
            return 'unknown' if n in unknown else ('fail' if n >= first_bad else 'pass')
        return revert.find_culprit(commits, check, **kw), calls

    def test_finds_the_first_merge_where_the_tests_fail_at_every_position(self):
        for count in (1, 2, 3, 5, 8, 13):
            for first_bad in range(1, count + 1):
                with self.subTest(count=count, first_bad=first_bad):
                    found, calls = self.search(count, first_bad)
                    self.assertEqual(found['status'], 'found')
                    self.assertEqual(int(found['commit']['sha'], 16), first_bad)
                    self.assertNotIn(count, calls)  # the tip is known to fail: never built again
                    self.assertLessEqual(len(calls), 4)

    def test_a_single_merge_since_the_last_pass_is_the_culprit_without_a_build(self):
        found, calls = self.search(1, 1)
        self.assertEqual((found['status'], calls), ('found', []))

    def test_an_unclear_answer_is_no_single_culprit(self):
        found, _ = self.search(8, 3, unknown={4})
        self.assertEqual(found['status'], 'unknown')
        self.assertIn('no clear answer', found['why'])
        self.assertEqual(found['checks'], [('0' * 6 + '4', 'unknown')][:0] or found['checks'])

    def test_it_stops_after_the_build_budget(self):
        found, calls = self.search(64, 40, max_checks=2)
        self.assertEqual(found['status'], 'unknown')
        self.assertEqual(len(calls), 2)

    def test_nothing_to_search(self):
        self.assertEqual(revert.find_culprit([], lambda c: 'fail')['status'], 'unknown')


class BlockerTests(unittest.TestCase):
    def blockers(self, paths, c=None, open_reverts=(), done=None):
        return revert.revert_blockers(c or commit(7), list(paths), SCOPE, ROOT, list(open_reverts), done)

    def test_an_app_ui_change_is_safe_to_revert(self):
        self.assertEqual(self.blockers([APP + 'Gate1RootView.swift']), [])

    def test_each_no_revert_rule(self):
        cases = {
            'persistence (SessionKit)': (['Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift'], 'persistence'),
            'persistence (fixtures)': (['Contracts/fixtures/persistence/build29.json'], 'persistence'),
            'packet (SessionKit)': (['Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift'], 'packet'),
            'packet (schema)': (['Contracts/schemas/spoken-margins-package.schema.json'], 'packet'),
            'migration': ([APP + 'LibraryMigrationStep.swift'], 'migration'),
            'workflow': (['.github/workflows/lane.yml'], 'the lane'),
            'runner': (['scripts/lane-runner.py'], 'the lane'),
            'scope': (['scripts/test-scope.py'], 'the lane'),
        }
        for name, (paths, word) in cases.items():
            with self.subTest(name):
                reasons = self.blockers([APP + 'Gate1RootView.swift', *paths])
                self.assertEqual(len(reasons), 1, reasons)
                self.assertIn(word, reasons[0])

    def test_a_merge_that_cannot_reach_the_app_build_is_not_reverted_for_an_app_test(self):
        # #1417: #1407 changed only ops/ledger and an ops README.
        for paths in (['ops/ledger/ledger.py', 'ops/README.md'], ['docs/journeys.md'], ['research/B4/server.go'],
                      ['scripts/some-helper.py'], ['ops/testdesk/integration_revert.py', 'docs/a.md']):
            with self.subTest(paths=paths):
                reasons = self.blockers(paths)
                self.assertEqual(len(reasons), 1, reasons)
                self.assertIn('outside the app build', reasons[0])
                self.assertIn(paths[0], reasons[0])

    def test_anything_that_can_reach_the_app_build_or_its_tests_keeps_the_revert_open(self):
        for path in (APP + 'Gate1RootView.swift', 'App/SpokenMarginsAppTests/FooTests.swift',
                     'Packages/SessionKit/Sources/SessionKit/Session.swift', 'Contracts/docs/recovery-mvp.md',
                     'Contracts/fixtures/other.json', 'TestPlans/scripted-journeys.json', 'project.yml',
                     'Tools/BrowserExtraction/extract.js', 'Site/onboarding/catalog/v1/catalog.json', 'App/SpokenMarginsApp/README.md'):
            with self.subTest(path=path):
                self.assertEqual(self.blockers(['ops/ledger/ledger.py', path]), [])

    def test_a_script_the_xcode_build_runs_can_reach_the_app(self):
        built = sorted(SCOPE.build_scripts(ROOT))
        self.assertTrue(built, 'project.yml no longer names a build script; pick another example')
        self.assertEqual(self.blockers([built[0]]), [])

    def test_the_lane_scripts_that_run_the_tests_can_reach_the_app_result(self):
        reasons = self.blockers(['scripts/verify-tests.py', 'ops/README.md'])
        self.assertEqual(len(reasons), 1, reasons)
        self.assertIn('the lane', reasons[0])

    def test_another_open_revert_or_one_already_on_next(self):
        self.assertIn('#1234', self.blockers([APP + 'Gate1RootView.swift'], open_reverts=['#1234'])[0])
        self.assertIn('already reverts', self.blockers([APP + 'Gate1RootView.swift'], done='abc1234' + '0' * 33)[0])

    def test_a_direct_push_or_a_revert_is_not_reverted(self):
        self.assertIn('not a merged pull request', self.blockers([], commit(7, 'Fix typo', parents=1))[0])
        again = dict(commit(7), body='Revert #6: Something')
        self.assertIn('itself a revert', self.blockers([], again)[0])

    def test_an_unreadable_classification_blocks_rather_than_passes(self):
        class Broken:
            def is_lane_path(self, path):
                return False

            def classify_path(self, root, path):
                raise OSError('gone')
        reasons = revert.revert_blockers(commit(7), [APP + 'X.swift'], Broken(), ROOT, [], None)
        self.assertIn('could not classify', reasons[0])


class TextTests(unittest.TestCase):
    def test_pr_number_and_title(self):
        c = commit(1170)
        self.assertEqual(revert.pr_number(c['subject']), 1170)
        self.assertIsNone(revert.pr_number('Fix typo'))
        self.assertEqual(revert.pr_title(c['subject'], 'Packet export: store an entry\n\nmore'), 'Packet export: store an entry')
        self.assertEqual(revert.pr_title('Merge pull request #5: Title here'), 'Title here')
        self.assertEqual(revert.pr_title('Merge pull request #5 from uncomposed/ws/5-x', ''), 'uncomposed/ws/5-x')

    def test_hot_files_only_count_when_they_grow(self):
        a, b = revert.HOT_FILES
        self.assertEqual(revert.grows_hot_file(f'3\t1\t{a}\n2\t2\t{b}\n9\t0\tdocs/x.md\n-\t-\t{b}\n'), [a])
        self.assertEqual(revert.grows_hot_file(''), [])

    def test_titles_follow_the_scheduled_tasks_form(self):
        self.assertEqual(revert.revert_title(1170, 'Packet export', 'f' * 40), 'Revert #1170: Packet export (integration-fffffff FAIL)')
        self.assertEqual(revert.revert_branch(1170), 'revert/pr1170')
        self.assertTrue(revert.reland_title(1170, 'Packet export').startswith('Re-land #1170'))


# The real git half of opening a revert, against throwaway repositories.

def git(cwd, *args):
    subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *args], cwd=cwd, check=True,
                   capture_output=True, text=True)


class Repos:
    """origin (bare) and a clone with main = base + a merged PR (#7) that adds lines to a hot file."""

    def __init__(self, tmp, conflict=False):
        self.origin, self.clone = Path(tmp) / 'origin.git', Path(tmp) / 'clone'
        subprocess.run(['git', 'init', '--bare', '-b', 'main', str(self.origin)], check=True, capture_output=True)
        subprocess.run(['git', 'clone', '-q', str(self.origin), str(self.clone)], check=True, capture_output=True)
        git(self.clone, 'checkout', '-q', '-b', 'main')
        hot = self.clone / revert.HOT_FILES[0]
        hot.parent.mkdir(parents=True)
        hot.write_text('a\nb\nc\n')
        (self.clone / 'other.txt').write_text('1\n')
        git(self.clone, 'add', '-A')
        git(self.clone, 'commit', '-q', '-m', 'base')
        self.green = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.clone, text=True).strip()
        git(self.clone, 'checkout', '-q', '-b', 'ws/7-x')
        hot.write_text('a\nc\n')                # the PR removes a line ...
        git(self.clone, 'commit', '-q', '-am', 'PR 7 work')
        git(self.clone, 'checkout', '-q', 'main')
        git(self.clone, 'merge', '--no-ff', '-q', '-m', 'Merge pull request #7 from uncomposed/ws/7-x', '-m', 'Shrink the model', 'ws/7-x')
        if conflict:
            hot.write_text('a\ncc\n')        # ... and a later commit edits the lines next to it
            git(self.clone, 'commit', '-q', '-am', 'later change')
        git(self.clone, 'push', '-q', 'origin', 'main')
        self.tip = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.clone, text=True).strip()
        self.merge = subprocess.check_output(['git', 'rev-parse', 'HEAD' if not conflict else 'HEAD~1'], cwd=self.clone,
                                             text=True).strip()
        git(self.clone, 'checkout', '-q', '--detach', self.tip)


class OpenRevertTests(unittest.TestCase):
    def ops(self, tmp, repos):
        self.calls = []

        def fake(cmd, cwd=None, timeout=None, stdin=None, env=None):
            cmd = [str(c) for c in cmd]
            if cmd[0] == 'gh':
                self.calls.append(cmd)
                if cmd[1:3] == ['pr', 'create']:
                    return run.Result(0, 'https://github.com/x/y/pull/9001\n')
                if cmd[1:3] == ['issue', 'create']:
                    return run.Result(0, 'https://github.com/x/y/issues/9002\n')
                return run.Result(0, '')
            return run.default_run(cmd, cwd=cwd, timeout=timeout, stdin=stdin, env=env)
        return run.Ops(home=Path(tmp) / 'home', repo_root=repos.clone, run=fake, echo=False)

    def merge_commit(self, repos):
        out = subprocess.check_output(['git', 'log', '-1', '--format=%H%x1f%P%x1f%s%x1f%b', repos.merge], cwd=repos.clone,
                                      text=True).strip().split('\x1f')
        return {'sha': out[0], 'parents': out[1].split(), 'subject': out[2], 'body': out[3]}

    def open(self, repos, tmp):
        ops = self.ops(tmp, repos)
        evidence = Path(tmp) / 'evidence'
        evidence.mkdir(exist_ok=True)
        return ops.open_revert(repos.clone, evidence, self.merge_commit(repos), repos.tip, 'https://report/1',
                               [TEST], [('abc1234', 'pass')], ['Failing tests: `x`\n## Steps\ns']), evidence

    def test_pushes_a_revert_branch_and_opens_the_pr_with_automerge_and_the_reland_issue(self):
        with tempfile.TemporaryDirectory() as tmp:
            repos = Repos(tmp)
            (url, why), evidence = self.open(repos, tmp)
            self.assertEqual((url, why), ('https://github.com/x/y/pull/9001', ''))
            pushed = subprocess.check_output(['git', 'log', '-1', '--format=%B', 'revert/pr7'], cwd=repos.origin, text=True)
            self.assertIn('Revert #7: Shrink the model (integration-', pushed)
            self.assertIn(f'This reverts commit {repos.merge}', pushed)
            content = subprocess.check_output(['git', 'show', f'revert/pr7:{revert.HOT_FILES[0]}'], cwd=repos.origin, text=True)
            self.assertEqual(content, 'a\nb\nc\n')
            create = next(c for c in self.calls if c[1:3] == ['pr', 'create'])
            self.assertEqual(create[create.index('--label') + 1], 'automerge,hot-file-ok')  # the revert adds a line back
            self.assertEqual(create[create.index('--base') + 1], 'main')
            issue = next(c for c in self.calls if c[1:3] == ['issue', 'create'])
            self.assertEqual(issue[issue.index('--label') + 1], 'ready,regression')
            self.assertTrue(any(c[1:3] == ['pr', 'edit'] for c in self.calls))
            self.assertIn('issues/9002', (evidence / 'revert-pr.md').read_text())
            # The scratch worktree is left on the tip with no leftover branch.
            head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repos.clone, text=True).strip()
            self.assertEqual(head, repos.tip)
            branches = subprocess.check_output(['git', 'branch', '--list', 'revert/*'], cwd=repos.clone, text=True)
            self.assertEqual(branches.strip(), '')

    def test_a_failed_reland_issue_still_reports_the_open_revert_pr(self):
        # The automerge revert PR exists and will merge, so the caller must not say "not reverted".
        with tempfile.TemporaryDirectory() as tmp:
            repos = Repos(tmp)
            ops = self.ops(tmp, repos)
            plain = ops.run

            def fake(cmd, **kw):
                if [str(c) for c in cmd][1:3] == ['issue', 'create']:
                    return run.Result(1, '', 'HTTP 502')
                return plain(cmd, **kw)
            ops.run = fake
            evidence = Path(tmp) / 'evidence'
            evidence.mkdir()
            url, why = ops.open_revert(repos.clone, evidence, self.merge_commit(repos), repos.tip, 'r', [TEST], [], [])
            self.assertEqual((url, why), ('https://github.com/x/y/pull/9001', ''))

    def test_a_stale_remote_branch_does_not_block_a_new_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            repos = Repos(tmp)
            git(repos.clone, 'push', '-q', 'origin', f'{repos.green}:refs/heads/revert/pr7')   # left by an earlier try
            (url, why), _ = self.open(repos, tmp)
            self.assertEqual(why, '')
            self.assertTrue(url)

    def test_a_revert_that_does_not_apply_cleanly_pushes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            repos = Repos(tmp, conflict=True)
            (url, why), _ = self.open(repos, tmp)
            self.assertIsNone(url)
            self.assertIn('does not apply cleanly', why)
            heads = subprocess.check_output(['git', 'branch', '--list'], cwd=repos.origin, text=True)
            self.assertNotIn('revert/pr7', heads)
            self.assertFalse(any(c[1] in ('pr', 'issue') for c in self.calls))
            head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repos.clone, text=True).strip()
            self.assertEqual(head, repos.tip)

    def test_nothing_is_opened_when_next_already_undoes_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            repos = Repos(tmp)
            (url, why), _ = self.open(repos, tmp)   # the first revert is only pushed, not merged ...
            self.assertTrue(url)
            hot = repos.clone / revert.HOT_FILES[0]
            git(repos.clone, 'checkout', '-q', '-B', 'main', repos.tip)
            hot.write_text('a\nb\nc\n')              # ... so make main itself already undo it
            git(repos.clone, 'commit', '-q', '-am', 'someone reverted by hand')
            git(repos.clone, 'push', '-q', 'origin', 'main')
            git(repos.clone, 'checkout', '-q', '--detach', repos.tip)
            self.calls.clear()
            (url, why), _ = self.open(repos, tmp)
            self.assertIsNone(url)
            self.assertIn('already undoes it', why)


if __name__ == '__main__':
    unittest.main()
