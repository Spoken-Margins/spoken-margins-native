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
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:next'], check=True)

    def pr_head(self, *names):
        for name in names:
            path = self.tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            self.commit(self.tree, name, 'pr\n')
        return self.rev(self.tree, 'HEAD')


class UntestedMovesTests(RealGit):
    def moves(self, head, tested):
        new = lane.fetch_base(self.tree, 'next')
        return lane.untested_moves(self.tree, tested, new, head)

    def test_commits_touching_other_files_are_listed_and_can_be_skipped(self):
        head = self.pr_head('App/Feature.swift')
        tested = lane.fetch_base(self.tree, 'next')
        self.move_next('App/Other.swift', subject='Merge pull request #7: Other')
        self.move_next('docs/notes.md', subject='Merge pull request #8: Notes')
        commits, why = self.moves(head, tested)
        self.assertEqual(why, '')
        self.assertEqual([c.split(' ', 1)[1] for c in commits],
                         ['Merge pull request #8: Notes', 'Merge pull request #7: Other'])

    def test_a_commit_touching_one_of_the_pr_s_files_needs_a_re_test(self):
        head = self.pr_head('App/Feature.swift', 'App/Shared.swift')
        tested = lane.fetch_base(self.tree, 'next')
        self.move_next('App/Unrelated.swift')
        self.move_next('App/Shared.swift', text='next side\n')
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('App/Shared.swift', why)

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
        tested = lane.fetch_base(self.tree, 'next')
        self.move_next('project.yml')
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('project.yml', why)

    def test_a_next_that_no_longer_contains_the_tested_commit_needs_a_re_test(self):
        head = self.pr_head('App/Feature.swift')
        self.move_next('App/Other.swift')
        tested = lane.fetch_base(self.tree, 'next')
        subprocess.run(self.git + ['-C', str(self.other), 'reset', '-q', '--hard', 'HEAD~1'], check=True)
        self.commit(self.other, 'Rewritten.swift', 'x\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', '-f', 'origin', 'HEAD:next'], check=True)
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('no longer contains', why)

    def test_a_merge_on_next_counts_every_file_it_brought_in(self):
        # next's history is merge commits; the files a merge brought in count, not just its own diff.
        head = self.pr_head('App/Feature.swift')
        tested = lane.fetch_base(self.tree, 'next')
        subprocess.run(self.git + ['-C', str(self.other), 'checkout', '-q', '-b', 'side'], check=True)
        (self.other / 'project.yml').write_text('side\n')
        subprocess.run(self.git + ['-C', str(self.other), 'add', '.'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'commit', '-q', '-m', 'side'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'checkout', '-q', 'next'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'merge', '-q', '--no-ff', '-m', 'Merge pull request #9: Side',
                                   'side'], check=True)
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:next'], check=True)
        commits, why = self.moves(head, tested)
        self.assertIsNone(commits)
        self.assertIn('project.yml', why)


class RunAutoAfterNextMovedTests(RealGit):
    """run_auto with real git: the refused push, the decision, and the second push."""
    SCOPE = {'tier': 'T2', 'why': ['app UI'], 'files': [{'path': 'App/Feature.swift', 'category': 'app-ui'}]}

    def run_auto(self, move):
        head = self.pr_head('App/Feature.swift')
        base_sha = lane.fetch_base(self.tree, 'next')
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
                mock.patch.object(lane, 'warm_build_folders', return_value='build folders: warm (test)'), \
                mock.patch.object(lane, 'diff_scope', return_value=self.SCOPE), \
                mock.patch.object(lane, 'run_automerge',
                                  return_value=('PASS', 'no simulator (compile only)', 'host tests; builds', [])) as tests:
            result = lane.run_auto(github, {'title': 'Feature'}, 5, 'next', head, base_sha, Path(evidence), [])
        return result, tests, github, head, pushes

    def test_next_moving_elsewhere_lands_the_re_merge_without_testing_again(self):
        (verdict, _, ran, details), tests, github, head, pushes = self.run_auto(
            lambda: self.move_next('App/Other.swift', subject='Merge pull request #7: Other'))
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(tests.call_count, 1)
        self.assertEqual(len(pushes), 2)
        landed = self.rev(self.origin, 'next')
        self.assertEqual(landed, pushes[1])
        parents = subprocess.check_output(['git', '-C', str(self.tree), 'rev-list', '--parents', '-n', '1', landed],
                                          text=True).split()[1:]
        self.assertEqual(parents[1], head)
        text = '\n'.join(details)
        self.assertIn('not re-tested', text)
        self.assertIn('Merge pull request #7: Other', text)
        self.assertTrue(details[-1].startswith(f'merged into next as {landed[:7]}'), details)
        # The second merge check satisfies the merge audit but doesn't tell phone-build the tip was tested.
        second = github.posted[-1]
        import merge_audit
        self.assertTrue(merge_audit.has_merge_check([dict(body=second, created_at='2026-10-01T10:00:00Z')],
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
