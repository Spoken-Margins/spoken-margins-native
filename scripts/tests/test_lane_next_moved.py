"""When next moves under a tested merge, push without re-testing if next's new commits can't matter.

In the 48 hours to 2026-10-01, 26 pushes were refused because next moved, and each PR was tested again
in full (about 150 runner-minutes), plus 10 runs that ended "next kept moving" (64 minutes). The
owner's standing call is that the Test Desk tests next's merged tip end to end.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import FakeGitHub, lane  # noqa: E402


class RealGit(unittest.TestCase):
    """A bare origin, the runner's tree on a PR branch, and another clone that moves next."""
    setUp = test_lane_runner.PushTests.setUp
    commit = test_lane_runner.PushTests.commit
    rev = test_lane_runner.PushTests.rev

    def move_next(self, name, text='someone else merged\n', subject=None):
        path = self.other / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        subprocess.run(self.git + ['-C', str(self.other), 'add', '.'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'commit', '-q', '-m', subject or f'Change {name}'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)

    def pr_head(self, *names):
        for name in names:
            path = self.tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            self.commit(self.tree, name, 'pr\n')
        return self.rev(self.tree, 'HEAD')


class UntestedMovesTests(RealGit):
    def moves(self, head, tested):
        new = lane.fetch_base(self.tree, 'main')
        return lane.untested_moves(self.tree, tested, new, head)

    def test_commits_touching_other_files_are_listed_and_can_be_skipped(self):
        head = self.pr_head('App/Feature.swift')
        tested = lane.fetch_base(self.tree, 'main')
        self.move_next('App/Other.swift', subject='Merge pull request #7: Other')
        self.move_next('docs/notes.md', subject='Merge pull request #8: Notes')
        commits, why = self.moves(head, tested)
        self.assertEqual(why, '')
        self.assertEqual([c.split(' ', 1)[1] for c in commits],
                         ['Merge pull request #8: Notes', 'Merge pull request #7: Other'])

    def test_a_commit_touching_one_of_the_pr_s_files_needs_a_re_test(self):
        head = self.pr_head('App/Feature.swift', 'App/Shared.swift')
        tested = lane.fetch_base(self.tree, 'main')
        self.move_next('App/Unrelated.swift')
        self.move_next('App/Shared.swift', text='next side\n')
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('App/Shared.swift', why)

    def test_a_file_the_pr_changed_in_an_earlier_commit_still_counts_as_the_pr_s(self):
        # Every other test has a one-commit PR, where "the PR's files" and "its last commit's files" are the
        # same set. Here the last commit only adds a doc, and next changes the file the first commit touched.
        self.pr_head('App/Sharing.swift')
        head = self.pr_head('docs/notes.md')
        tested = lane.fetch_base(self.tree, 'main')
        self.move_next('App/Sharing.swift', text='next side\n')
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('touch this PR\'s files (App/Sharing.swift)', why)

    def test_a_commit_touching_a_build_input_needs_a_re_test(self):
        for name in ('project.yml', 'SpokenMarginsNative.xcodeproj/project.pbxproj', 'Config/Base.xcconfig',
                     'Packages/SessionKit/Package.swift', 'Packages/SessionKit/Package.resolved',
                     '.github/workflows/lane.yml', 'scripts/verify-tests.py', 'scripts/xcodebuild-lane',
                     'Contracts/schemas/x.schema.json', 'package-lock.json'):
            with self.subTest(name=name):
                self.assertTrue(lane.is_build_input(name), name)
        for name in ('App/X.swift', 'Packages/SessionKit/Sources/SessionKit/X.swift', 'docs/x.md',
                     'Contracts/fixtures/x.json', 'ops/dial/dial_gate.py'):
            with self.subTest(name=name):
                self.assertFalse(lane.is_build_input(name), name)
        head = self.pr_head('App/Feature.swift')
        tested = lane.fetch_base(self.tree, 'main')
        self.move_next('project.yml')
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('project.yml', why)

    def test_a_next_that_no_longer_contains_the_tested_commit_needs_a_re_test(self):
        head = self.pr_head('App/Feature.swift')
        self.move_next('App/Other.swift')
        tested = lane.fetch_base(self.tree, 'main')
        subprocess.run(self.git + ['-C', str(self.other), 'reset', '-q', '--hard', 'HEAD~1'], check=True)
        self.commit(self.other, 'Rewritten.swift', 'x\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', '-f', 'origin', 'HEAD:main'], check=True)
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('no longer contains', why)

    def test_a_merge_on_next_counts_every_file_it_brought_in(self):
        # next's history is merge commits; the files a merge brought in count, not just its own diff.
        head = self.pr_head('App/Feature.swift')
        tested = lane.fetch_base(self.tree, 'main')
        subprocess.run(self.git + ['-C', str(self.other), 'checkout', '-q', '-b', 'side'], check=True)
        (self.other / 'project.yml').write_text('side\n')
        subprocess.run(self.git + ['-C', str(self.other), 'add', '.'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'commit', '-q', '-m', 'side'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'checkout', '-q', 'main'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'merge', '-q', '--no-ff', '-m', 'Merge pull request #9: Side',
                                   'side'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('project.yml', why)


class ScriptsTheChecksDontReadTests(RealGit):
    """#1208: a lane tool on next that a PR's checks never read doesn't make the PR test again."""

    def moves(self, head, tested):
        return lane.untested_moves(self.tree, tested, lane.fetch_base(self.tree, 'main'), head)

    def test_a_lane_tool_the_pr_s_checks_never_read_is_skipped(self):
        head = self.pr_head('App/Feature.swift', 'Packages/SessionKit/Sources/SessionKit/Feature.swift')
        tested = lane.fetch_base(self.tree, 'main')
        self.move_next('scripts/phone-build', subject='Merge pull request #7: Phone builds')
        self.move_next('scripts/tests/test_phone_build.py', subject='Merge pull request #8: Phone build tests')
        self.move_next('scripts/lane_dedupe.py', subject='Merge pull request #9: Dedupe')
        commits, why = self.moves(head, tested)
        self.assertEqual(why, '')
        self.assertEqual(len(commits), 3)

    def test_a_script_the_checks_read_still_needs_a_re_test(self):
        # lane-runner.py: the readers' T3 classes load it; the rest run as --plan fast steps or decide its tier.
        for name in ('scripts/lane-runner.py', 'scripts/verify-tests.py', 'scripts/test-scope.py',
                     'scripts/hot_file_ratchet.py', 'scripts/tests/test_verification.py', 'scripts/a_new_tool.py'):
            with self.subTest(name=name):
                self.setUp()
                head = self.pr_head('App/Feature.swift')
                tested = lane.fetch_base(self.tree, 'main')
                self.move_next(name, text=f'{name} changed\n')
                commits, why = self.moves(head, tested)
                self.assertIsNone(commits)
                self.assertIn(name, why)

    def test_a_lane_tool_counts_for_a_pr_whose_own_diff_runs_every_runner_test(self):
        for mine in ('scripts/lane_sim.py', '.github/workflows/lane.yml', 'ops/dial/dial_gate.py', 'project.yml',
                     'TestPlans/AppBehavior.xctestplan', 'AGENTS.md', '.gitignore'):
            with self.subTest(mine=mine):
                self.setUp()  # a fresh origin and PR each time, so only this path is the PR's
                head = self.pr_head(mine)
                tested = lane.fetch_base(self.tree, 'main')
                self.move_next('scripts/phone-build', text=f'for {mine}\n')
                commits, why = self.moves(head, tested)
                self.assertIsNone(commits)
                self.assertIn('scripts/phone-build', why)

    def test_a_pr_that_moves_a_script_out_of_scripts_still_counts_as_a_lane_change(self):
        self.move_next('scripts/old_tool.py', text='old\n')
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', '--no-rebase', 'origin', 'main'], check=True)
        (self.tree / 'tools').mkdir()
        subprocess.run(self.git + ['-C', str(self.tree), 'mv', 'scripts/old_tool.py', 'tools/old_tool.py'], check=True)
        subprocess.run(self.git + ['-C', str(self.tree), 'commit', '-q', '-m', 'Move the tool'], check=True)
        head = self.rev(self.tree, 'HEAD')
        tested = lane.fetch_base(self.tree, 'main')
        self.move_next('scripts/phone-build')
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('scripts/phone-build', why)


    def test_a_lane_change_with_a_quoted_name_still_counts(self):
        head = self.pr_head('scripts/tests/test_caf\u00e9.py')
        tested = lane.fetch_base(self.tree, 'main')
        self.move_next('scripts/phone-build')
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('scripts/phone-build', why)

    def test_a_file_next_renames_is_still_the_pr_s_file(self):
        self.move_next('App/Old.swift', text='old\n')
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', '--no-rebase', 'origin', 'main'], check=True)
        head = self.pr_head('App/Old.swift')
        tested = lane.fetch_base(self.tree, 'main')
        subprocess.run(self.git + ['-C', str(self.other), 'mv', 'App/Old.swift', 'App/New.swift'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'commit', '-q', '-m', 'Rename'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('App/Old.swift', why)


class HostUnreadScriptsListTests(unittest.TestCase):
    """Cheap checks that HOST_UNREAD_SCRIPTS still matches what a non-lane PR's checks run. The trace described
    beside the list is the full measurement; these catch the obvious drift."""
    ROOT = Path(__file__).resolve().parents[2]
    verification = test_lane_runner.verification

    def test_every_listed_file_exists_and_is_under_scripts(self):
        for path in sorted(lane.HOST_UNREAD_SCRIPTS):
            with self.subTest(path=path):
                self.assertTrue(path.startswith('scripts/'), path)
                self.assertTrue((self.ROOT / path).is_file(), path)

    def test_the_full_run_triggers_cover_verify_tests_own(self):
        for trigger in (*self.verification.RUNNER_TEST_TRIGGERS, *self.verification.OPS_TEST_TRIGGERS):
            with self.subTest(trigger=trigger):
                self.assertTrue(lane.widens_host_checks([trigger]), trigger)
                self.assertTrue(lane.widens_host_checks([trigger.rstrip('/') + '/x' if trigger.endswith('/')
                                                             else trigger]), trigger)

    def test_no_listed_test_module_is_a_reader(self):
        readers = {name.split('.')[0] for name in self.verification.RUNNER_TEST_READERS}
        for path in lane.HOST_UNREAD_SCRIPTS:
            with self.subTest(path=path):
                self.assertNotIn(Path(path).stem, readers)

    def test_the_fast_plan_and_the_sessionkit_runner_name_no_listed_file(self):
        import inspect
        run = self.verification.Run
        source = ''.join(inspect.getsource(getattr(run, name))
                         for name in ('fast', 'host_steps', 'package_steps', 'package_core'))
        sources = {'verify-tests.py fast steps': source,
                   'sessionkit_pass.RUNNERS': ' '.join(self.verification.sessionkit_pass.RUNNERS),
                   'run-sessionkit-tests.sh': (self.ROOT / 'scripts/run-sessionkit-tests.sh').read_text(),
                   'host-test-lane': (self.ROOT / 'scripts/host-test-lane').read_text(),
                   'package.json': (self.ROOT / 'package.json').read_text()}
        for path in lane.HOST_UNREAD_SCRIPTS:
            for where, text in sources.items():
                with self.subTest(path=path, where=where):
                    self.assertNotIn(Path(path).name, text)

    def test_nothing_the_checks_import_is_listed(self):
        # Python modules the checks load, and what they import from scripts/ at module level in turn, plus
        # files loaded by path. Imports inside functions and paths named in strings (test-scope.py's lane paths,
        # lane-runner.py's helpers for other jobs) are left to the trace: most of them never run in these checks.
        import ast
        scripts = self.ROOT / 'scripts'
        readers = {name.split('.')[0] for name in self.verification.RUNNER_TEST_READERS}
        todo = [scripts / name for name in ('verify-tests.py', 'test-scope.py', 'hot_file_ratchet.py',
                                            'validate-contracts.py', 'validate-surface-contracts.py',
                                            'test_inventory.py', 'research_tests.py', 'sessionkit_pass.py',
                                            'validate-supertonic-assets.py')]
        todo += [scripts / 'tests' / f'{name}.py' for name in readers]
        seen = set()
        while todo:
            path = todo.pop()
            if path in seen or not path.is_file():
                continue
            seen.add(path)
            tree = ast.parse(path.read_text())
            top, stack = [], list(tree.body)
            while stack:  # every node outside a function body: what importing the module runs
                node = stack.pop()
                if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                    top.append(node)
                    stack.extend(ast.iter_child_nodes(node))
            for node in ast.walk(tree):
                names = []
                if isinstance(node, ast.Import) and node in top:
                    names = [alias.name.split('.')[0] for alias in node.names]
                elif isinstance(node, ast.ImportFrom) and node.module and not node.level and node in top:
                    names = [node.module.split('.')[0]]
                elif isinstance(node, ast.Call) and getattr(node.func, 'attr', '') == 'spec_from_file_location':
                    # spec_from_file_location('lane_runner', SCRIPTS / 'lane-runner.py')
                    names = [Path(arg.value).stem for arg in ast.walk(node)
                             if isinstance(arg, ast.Constant) and isinstance(arg.value, str)
                             and arg.value.endswith('.py')]
                for name in names:
                    for candidate in (scripts / f'{name}.py', scripts / 'tests' / f'{name}.py'):
                        if candidate.is_file():
                            todo.append(candidate)
        loaded = {str(path.relative_to(self.ROOT)) for path in seen}
        self.assertIn('scripts/lane-runner.py', loaded)  # the readers' T3 classes load it
        self.assertEqual(sorted(loaded & lane.HOST_UNREAD_SCRIPTS), [])


class RunAutoAfterNextMovedTests(RealGit):
    """run_auto with real git: the refused push, the decision, and the second push."""
    SCOPE = {'tier': 'T2', 'why': ['app UI'], 'files': [{'path': 'App/Feature.swift', 'category': 'app-ui'}]}

    def run_auto(self, move):
        head = self.pr_head('App/Feature.swift')
        base_sha = lane.fetch_base(self.tree, 'main')
        real_push, pushes = lane.push_merge, []

        def push(tree, sha, base):
            if not pushes:
                move()  # someone merged while this PR was tested
            pushes.append(sha)
            return real_push(tree, sha, base)

        github = FakeGitHub(labels=('automerge',), head=head)
        with tempfile.TemporaryDirectory() as evidence, \
                mock.patch.object(lane, 'ROOT', self.tree), \
                mock.patch.object(lane, 'push_merge', side_effect=push), \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'host_build_folders', return_value='build folders: in the workspace (test)'), \
                mock.patch.object(lane, 'diff_scope', return_value=self.SCOPE), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []), \
                mock.patch.object(lane, 'run_automerge',
                                  return_value=('PASS', 'no simulator (compile only)', 'host tests; builds', [])) as tests:
            result = lane.run_auto(github, {'title': 'Feature'}, 5, 'main', head, base_sha, Path(evidence), [])
        return result, tests, github, head, pushes

    def test_next_moving_elsewhere_lands_the_re_merge_without_testing_again(self):
        (verdict, _, ran, details), tests, github, head, pushes = self.run_auto(
            lambda: self.move_next('App/Other.swift', subject='Merge pull request #7: Other'))
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(tests.call_count, 1)
        self.assertEqual(len(pushes), 2)
        landed = self.rev(self.origin, 'main')
        self.assertEqual(landed, pushes[1])
        parents = subprocess.check_output(['git', '-C', str(self.tree), 'rev-list', '--parents', '-n', '1', landed],
                                          text=True).split()[1:]
        self.assertEqual(parents[1], head)
        text = '\n'.join(details)
        self.assertIn('not re-tested', text)
        self.assertIn('Merge pull request #7: Other', text)
        self.assertTrue(details[-1].startswith(f'merged into main as {landed[:7]}'), details)
        # The second merge check satisfies the merge audit but doesn't tell phone-build the tip was tested.
        second = github.posted[-1]
        import merge_audit
        self.assertTrue(merge_audit.has_merge_check([dict(body=second, created_at='2026-10-01T10:00:00Z', user={'login': 'github-actions[bot]'})],
                                                    head, '2026-10-01T10:00:01Z'))
        self.assertNotIn(f'Pushing `{landed[:7]}`', second)
        self.assertIn('not re-tested', second)

    def test_next_touching_the_pr_s_files_or_a_build_input_is_tested_again(self):
        (verdict, _, _, details), tests, _, _, pushes = self.run_auto(lambda: self.move_next('project.yml'))
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(tests.call_count, 2)
        self.assertEqual(len(pushes), 2)
        self.assertIn('tested again', '\n'.join(details))
        self.assertIn('project.yml', '\n'.join(details))


if __name__ == '__main__':
    unittest.main()
