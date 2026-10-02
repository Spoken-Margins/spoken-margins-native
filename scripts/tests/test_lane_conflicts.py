"""Hosted preflight: real Git merges, with only the GitHub transport replaced."""
import copy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane_conflicts as check


class FakeGitHub:
    repo = 'owner/repo'

    def __init__(self, head, base, labels=('automerge', 'lane:queued', 'bug')):
        self.current = {'number': 7, 'state': 'open', 'head': {'sha': head, 'repo': {'full_name': self.repo}},
                        'base': {'ref': 'next'}, 'labels': [{'name': name} for name in labels]}
        self.base = base
        self.posted = []
        self.changes = []
        self.cancelled = []

    def pull(self, number):
        return copy.deepcopy(self.current)

    def base_sha(self, base):
        return self.base

    def comments(self, number):
        return [{'body': body, 'user': {'login': 'github-actions[bot]'}} for body in self.posted]

    def cancel_queued_lane_runs(self, number, head):
        self.cancelled.append((number, head))

    def comment(self, number, body):
        self.posted.append(body)

    def add_label(self, number, name):
        self.changes.append(('add', name))
        self.current['labels'].append({'name': name})

    def remove_label(self, number, name):
        self.changes.append(('remove', name))
        self.current['labels'] = [label for label in self.current['labels'] if label['name'] != name]


class MergeConflictTests(unittest.TestCase):
    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.tree), '-c', 'user.name=Test',
                                        '-c', 'user.email=test@localhost', *args], text=True).strip()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.tree = Path(self.temporary.name) / 'repo'
        self.tree.mkdir()
        self.git('init', '-q')
        self.path = self.tree / 'shared file.txt'
        self.path.write_text('original\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'common ancestor')
        self.ancestor = self.git('rev-parse', 'HEAD')
        self.path.write_text('next version\n')
        self.git('commit', '-qam', 'next changes the line')
        self.base = self.git('rev-parse', 'HEAD')
        self.git('update-ref', 'refs/remotes/origin/next', self.base)
        self.git('checkout', '-q', '--detach', self.ancestor)
        self.path.write_text('PR version\n')
        self.git('commit', '-qam', 'PR changes the same line')
        self.head = self.git('rev-parse', 'HEAD')
        self.github = FakeGitHub(self.head, self.base)

    def preflight(self, **kwargs):
        # The merge uses real local commits. Only fetching from GitHub is omitted.
        with mock.patch.object(check, 'fetch_pull'):
            return check.check_pull(self.github, 7, self.tree, **kwargs)

    def test_conflicting_pr_is_taken_out_of_both_mac_queues(self):
        self.assertFalse(self.preflight())
        self.assertEqual(self.github.changes, [('add', 'needs-mac'), ('remove', 'lane:queued'),
                                               ('remove', 'automerge')])
        self.assertEqual({l['name'] for l in self.github.current['labels']}, {'needs-mac', 'bug'})
        self.assertEqual(len(self.github.posted), 1)
        self.assertEqual(self.github.cancelled, [(7, self.head)])
        self.assertIn('shared file.txt', self.github.posted[0])
        self.assertIn(self.head[:7], self.github.posted[0])
        self.assertIn(self.base[:7], self.github.posted[0])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.head)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('rev-parse', 'origin/next'), self.base)
        self.assertEqual(self.path.read_text(), 'PR version\n')

    def test_conflict_labels_preserve_unrelated_labels(self):
        self.preflight()
        self.assertEqual({label['name'] for label in self.github.current['labels']}, {'needs-mac', 'bug'})

    def test_clean_merge_changes_no_labels_or_comments_and_leaves_no_merge_commit(self):
        self.git('checkout', '-q', '--detach', self.ancestor)
        (self.tree / 'other.txt').write_text('independent change\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'clean PR')
        head = self.git('rev-parse', 'HEAD')
        self.github.current['head']['sha'] = head
        self.assertTrue(self.preflight())
        self.assertEqual((self.github.changes, self.github.posted, self.github.cancelled), ([], [], []))
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_fast_forward_merge_is_clean(self):
        self.github.base = self.ancestor
        self.git('update-ref', 'refs/remotes/origin/next', self.ancestor)
        self.assertTrue(self.preflight())
        self.assertEqual((self.github.changes, self.github.posted), ([], []))

    def test_repeated_request_posts_only_one_comment_for_the_same_head_and_base(self):
        self.assertFalse(self.preflight())
        self.github.current['labels'].extend([{'name': 'lane:queued'}, {'name': 'automerge'}])
        self.assertFalse(self.preflight())
        self.assertEqual(len(self.github.posted), 1)
        self.assertEqual(self.github.changes.count(('add', 'needs-mac')), 1)
        self.assertEqual(self.github.changes.count(('remove', 'lane:queued')), 2)

    def test_stale_event_closed_or_unarmed_pull_cannot_change_labels(self):
        self.assertFalse(self.preflight(expected_head=self.ancestor))
        self.github.current['state'] = 'closed'
        self.assertFalse(self.preflight())
        self.github.current['state'] = 'open'
        self.github.current['labels'] = []
        self.assertFalse(self.preflight())
        self.assertEqual((self.github.changes, self.github.posted), ([], []))

    def test_lane_comment_is_checked_before_the_queue_label_is_added(self):
        self.github.current['labels'] = []
        self.assertFalse(self.preflight(request=True))
        self.assertEqual(self.github.changes, [('add', 'needs-mac')])
        self.assertEqual(len(self.github.posted), 1)

    def test_head_or_base_moving_during_the_merge_does_not_disarm_new_work(self):
        real = check.conflicting_files
        for moved in ('head', 'base'):
            with self.subTest(moved=moved):
                self.github = FakeGitHub(self.head, self.base)

                def move(*args):
                    files = real(*args)
                    if moved == 'head':
                        self.github.current['head']['sha'] = self.ancestor
                    else:
                        self.github.base = self.ancestor
                    return files

                with mock.patch.object(check, 'conflicting_files', side_effect=move):
                    self.assertFalse(self.preflight())
                self.assertEqual((self.github.changes, self.github.posted), ([], []))

    def test_fetches_real_next_and_pull_refs_before_merging(self):
        self.git('update-ref', 'refs/heads/next', self.base)
        self.git('update-ref', 'refs/pull/7/head', self.head)
        clone = Path(self.temporary.name) / 'hosted'
        subprocess.run(['git', 'clone', '--quiet', str(self.tree), str(clone)],
                       check=True, capture_output=True)
        with mock.patch.dict(check.os.environ, {'GH_TOKEN': 'local-test-token'}), \
                mock.patch.object(check, 'git', wraps=check.git) as commands:
            self.assertFalse(check.check_pull(self.github, 7, clone))
        self.assertTrue(any('fetch' in call.args for call in commands.call_args_list))
        self.assertFalse(any('push' in call.args for call in commands.call_args_list))
        self.assertEqual(check.git(clone, 'rev-parse', 'HEAD').stdout.strip(), self.head)
        self.assertEqual(check.git(clone, 'status', '--porcelain').stdout.strip(), '')
        self.assertEqual({label['name'] for label in self.github.current['labels']}, {'needs-mac', 'bug'})

    def test_non_conflict_git_error_does_not_disarm_the_pull(self):
        self.github.current['head']['sha'] = 'f' * 40
        with self.assertRaises(subprocess.CalledProcessError):
            self.preflight()
        self.assertEqual((self.github.changes, self.github.posted), ([], []))


class QueuedRunTests(unittest.TestCase):
    def test_only_this_prs_queued_lane_runs_on_the_conflicting_head_are_cancelled(self):
        github = check.GitHub('owner/repo')
        runs = [dict(id=i, status='in_progress', display_title='Lane PR #7 head abcdef') for i in range(1, 5)]
        runs += [dict(id=5, status='queued', display_title='Lane PR #9 head abcdef'),
                 dict(id=6, status='completed', display_title='Lane PR #7 head abcdef'),
                 dict(id=7, status='queued', display_title='Lane PR #7 head older')]
        jobs = {1: [{'status': 'completed'}, {'status': 'queued'}],
                2: [{'status': 'in_progress'}, {'status': 'queued'}],
                3: [{'status': 'completed'}]}

        def pages(path, selector):
            if 'workflows/lane.yml/runs' in path:
                self.assertIn('event=pull_request_target', path)
                return runs
            run_id = int(path.split('/runs/')[1].split('/')[0])
            return jobs[run_id]

        with mock.patch.dict(check.os.environ, {'GITHUB_RUN_ID': '4'}), \
                mock.patch.object(github, 'pages', side_effect=pages), \
                mock.patch.object(github, 'api') as api:
            github.cancel_queued_lane_runs(7, 'abcdef')
        api.assert_called_once_with('repos/owner/repo/actions/runs/1/cancel', '-X', 'POST')

    def test_label_transport_adds_needs_mac_and_removes_only_named_labels(self):
        github = check.GitHub('owner/repo')
        with mock.patch.object(github, 'api') as api:
            github.add_label(7, 'needs-mac')
            github.remove_label(7, 'lane:queued')
            github.remove_label(7, 'automerge')
        self.assertEqual(api.call_args_list, [
            mock.call('repos/owner/repo/issues/7/labels', '-X', 'POST', '-f', 'labels[]=needs-mac'),
            mock.call('repos/owner/repo/issues/7/labels/lane%3Aqueued', '-X', 'DELETE'),
            mock.call('repos/owner/repo/issues/7/labels/automerge', '-X', 'DELETE')])


class EntrypointTests(unittest.TestCase):
    def test_conflict_output_holds_the_mac_job_and_sweep_checks_all_armed_pulls(self):
        github = FakeGitHub('head', 'base')
        pulls = [github.pull(7), dict(github.pull(8), number=8),
                 dict(github.pull(9), number=9, labels=[])]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            with mock.patch.dict(check.os.environ, {'GH_REPO': github.repo, 'GITHUB_OUTPUT': str(output)}), \
                    mock.patch.object(check, 'GitHub', return_value=github), \
                    mock.patch.object(check, 'check_pull', side_effect=[False, True]) as preflight, \
                    mock.patch.object(github, 'pulls', return_value=pulls, create=True):
                self.assertEqual(check.main([]), 0)
            self.assertEqual([call.args[1] for call in preflight.call_args_list], [7, 8])
            self.assertEqual(output.read_text(), 'clean=false\n')


class WorkflowTests(unittest.TestCase):
    def test_both_mac_jobs_depend_on_the_hosted_clean_merge(self):
        root = Path(__file__).resolve().parents[2]
        lane = (root / '.github/workflows/lane.yml').read_text()
        self.assertIn('uses: ./.github/workflows/lane-conflicts.yml', lane)
        for job in ('lane', 'automerge'):
            body = lane.split(f'\n  {job}:\n')[1]
            self.assertTrue(body.startswith('    needs: merge-check\n'))
            self.assertIn("needs.merge-check.outputs.clean == 'true' &&", body.split('runs-on:')[0])
        hosted = (root / '.github/workflows/lane-conflicts.yml').read_text()
        self.assertIn('workflow_call:', hosted)
        for trigger in ('pull_request_target:', 'issue_comment:', 'push:'):
            self.assertIn(trigger, lane)
        self.assertIn('branches: [next]', lane)
        self.assertNotIn('  pull_request:\n', lane)
        self.assertIn('run-name: >-\n  Lane PR #', lane)
        self.assertIn('runs-on: ubuntu-latest', hosted)
        self.assertIn('persist-credentials: false', hosted)
        self.assertIn("ref: ${{ inputs.base || 'next' }}", hosted)
        self.assertNotIn('ref: ${{ github.event.pull_request.head.sha }}', hosted)
        self.assertIn('python3 scripts/lane_conflicts.py', hosted)
        self.assertIn('group: lane-conflicts-${{ github.repository }}-${{ matrix.pr }}', hosted)
        self.assertIn('fail-fast: false', hosted)
        self.assertIn('if [ -f scripts/lane_conflicts.py ]; then', hosted)
        self.assertIn('Base predates hosted preflight', hosted)


if __name__ == '__main__':
    unittest.main()
