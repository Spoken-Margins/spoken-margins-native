from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane_conflicts as conflicts  # noqa: E402

REPO = 'owner/app'


def run_git(cwd, *args):
    return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *args], cwd=cwd, text=True,
                          capture_output=True, check=True).stdout.strip()


class TempOrigin:
    """A real bare origin with `next` and GitHub-style refs/pull/N/head refs, built through a scratch clone."""

    def __init__(self, root):
        self.bare, self.work = Path(root) / 'origin.git', Path(root) / 'work'
        run_git(root, 'init', '-q', '--bare', '-b', 'next', str(self.bare))
        run_git(root, 'clone', '-q', str(self.bare), str(self.work))
        run_git(self.work, 'checkout', '-q', '-b', 'next')
        self.write('shared.txt', 'one\ntwo\nthree\n')
        self.write('keep.txt', 'keep\n')
        self.commit('start')
        run_git(self.work, 'push', '-q', 'origin', 'next')

    def write(self, name, text):
        path = self.work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        run_git(self.work, 'add', '-A')
        run_git(self.work, 'commit', '-q', '-m', message)
        return run_git(self.work, 'rev-parse', 'HEAD')

    def branch_from_start(self, name):
        run_git(self.work, 'checkout', '-q', '-B', name, 'origin/next')

    def pull(self, number, sha):
        run_git(self.work, 'push', '-q', '-f', 'origin', f'{sha}:refs/pull/{number}/head')

    def advance_next(self, name, text):
        run_git(self.work, 'checkout', '-q', 'next')
        self.write(name, text)
        sha = self.commit('next moves')
        run_git(self.work, 'push', '-q', 'origin', 'next')
        return sha

    def refs(self):
        return run_git(self.bare, 'for-each-ref', '--format=%(refname) %(objectname)')


class FakeApi:
    repo = REPO

    def __init__(self, pulls, comments=None, runs=(), jobs=None):
        self.pulls = {pull['number']: pull for pull in pulls}
        self.comments = {number: list(found) for number, found in (comments or {}).items()}
        self.runs, self.jobs = list(runs), jobs or {}
        self.posted, self.deleted, self.cancelled = [], [], []

    def get(self, path):
        if re.fullmatch(r'pulls/\d+', path):
            return self.pulls[int(path.split('/')[1])]
        if path.startswith('actions/workflows/lane.yml/runs?'):
            status = path.split('status=')[1].split('&')[0]
            found = [run for run in self.runs if run['status'] == status]
            return {'total_count': len(found), 'workflow_runs': found}
        if path.startswith('actions/runs/'):
            jobs = self.jobs.get(int(path.split('/')[2]), [])
            return {'total_count': len(jobs), 'jobs': jobs}
        raise AssertionError(path)

    def get_all(self, path):
        if path.startswith('pulls?'):
            return list(self.pulls.values())
        match = re.match(r'issues/(\d+)/comments', path)
        if match:
            return self.comments.get(int(match.group(1)), [])
        raise AssertionError(path)

    def post(self, path, fields=None):
        if path.endswith('/cancel'):
            self.cancelled.append(int(path.split('/')[2]))
            return
        self.posted.append((path, fields))
        number = int(path.split('/')[1])
        if path.endswith('/comments'):
            self.comments.setdefault(number, []).append({'body': fields['body']})
        if path.endswith('/labels'):
            self.pulls[number]['labels'].append({'name': fields['labels[]']})

    def delete(self, path):
        self.deleted.append(path)
        number, name = int(path.split('/')[1]), path.split('/labels/')[1].replace('%3A', ':')
        self.pulls[number]['labels'] = [label for label in self.pulls[number]['labels'] if label['name'] != name]


def pull(number, head, labels=('automerge',), repo=REPO):
    return {'number': number, 'state': 'open', 'head': {'sha': head, 'repo': {'full_name': repo}},
            'labels': [{'name': name} for name in labels]}


def run(run_id, pr, head, status='queued'):
    return {'id': run_id, 'status': status, 'display_title': f'lane pr={pr} head={head} lane=false auto=true'}


class ConflictCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.origin = TempOrigin(self.tmp.name)
        self.cache = Path(self.tmp.name) / 'cache'
        self.logs = []

    def sweep(self, api, **kwargs):
        return conflicts.sweep(api, str(self.origin.bare), 'next', self.cache, log=self.logs.append, **kwargs)

    def conflicting_pr(self, number=7, name='conflicts', file='shared.txt'):
        """A PR editing a file, then `next` editing the same line: a real conflict."""
        self.origin.branch_from_start(name)
        self.origin.write(file, 'one\nTWO FROM THE PR\nthree\n')
        head = self.origin.commit('pr edit')
        self.origin.pull(number, head)
        self.origin.advance_next(file, 'one\nTWO FROM NEXT\nthree\n')
        return head

    def clean_pr(self, number=8, name='clean'):
        self.origin.branch_from_start(name)
        self.origin.write('elsewhere.txt', 'new file\n')
        head = self.origin.commit('pr adds a file')
        self.origin.pull(number, head)
        return head

    def test_a_conflicting_armed_pr_gets_one_comment_the_label_swap_and_no_queued_slot(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head, ('automerge', 'lane:queued'))],
                      runs=[run(50, 7, head), run(51, 7, head, 'in_progress')],
                      jobs={50: [{'name': 'automerge', 'status': 'queued'}],
                            51: [{'name': 'automerge', 'status': 'in_progress'}]})
        self.assertEqual(self.sweep(api), {7: ['shared.txt']})
        comments = [fields for path, fields in api.posted if path.endswith('/comments')]
        self.assertEqual(len(comments), 1)
        self.assertTrue(comments[0]['body'].startswith(conflicts.HANDOFF))
        self.assertIn('`shared.txt`', comments[0]['body'])
        self.assertIn(conflicts.marker(head, run_git(self.origin.bare, 'rev-parse', 'next')), comments[0]['body'])
        self.assertEqual([name['name'] for name in api.pulls[7]['labels']], ['needs-mac'])
        self.assertEqual(sorted(api.deleted), ['issues/7/labels/automerge', 'issues/7/labels/lane%3Aqueued'])
        self.assertEqual(api.cancelled, [50])  # the run already on a Mac keeps going

    def test_a_clean_merge_changes_nothing(self):
        head = self.clean_pr()
        api = FakeApi([pull(8, head)])
        self.assertEqual(self.sweep(api), {})
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))
        self.assertEqual([label['name'] for label in api.pulls[8]['labels']], ['automerge'])

    def test_a_pr_that_is_already_up_to_date_with_next_is_clean(self):
        run_git(self.origin.work, 'checkout', '-q', 'next')
        head = run_git(self.origin.work, 'rev-parse', 'HEAD')
        self.origin.pull(9, head)
        self.assertEqual(self.sweep(FakeApi([pull(9, head)])), {})

    def test_other_conflict_kinds_are_found_and_every_file_is_named(self):
        self.origin.branch_from_start('kinds')
        self.origin.write('both-add.txt', 'from the PR\n')
        (self.origin.work / 'keep.txt').write_text('PR edit\n')
        head = self.origin.commit('pr')
        self.origin.pull(3, head)
        run_git(self.origin.work, 'checkout', '-q', 'next')
        self.origin.write('both-add.txt', 'from next\n')
        run_git(self.origin.work, 'rm', '-q', 'keep.txt')
        self.origin.commit('next adds one file and deletes another')
        run_git(self.origin.work, 'push', '-q', 'origin', 'next')
        found = self.sweep(FakeApi([pull(3, head)]))
        self.assertEqual(found, {3: ['both-add.txt', 'keep.txt']})

    def test_only_armed_same_repo_prs_are_checked(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head, ('needs-mac',)), pull(6, head, ('automerge',), repo='someone/fork')])
        self.assertEqual(self.sweep(api), {})
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_the_same_conflict_is_not_commented_twice_but_a_re_armed_label_is_removed_again(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)])
        self.sweep(api)
        api.pulls[7]['labels'].append({'name': 'automerge'})
        self.sweep(api)
        comments = [path for path, _ in api.posted if path.endswith('/comments')]
        self.assertEqual(len(comments), 1)
        self.assertEqual(api.deleted.count('issues/7/labels/automerge'), 2)
        self.assertEqual([label['name'] for label in api.pulls[7]['labels']], ['needs-mac'])

    def test_a_new_head_or_a_moved_next_gets_a_fresh_comment(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)])
        self.sweep(api)
        self.origin.advance_next('third.txt', 'more\n')
        api.pulls[7]['labels'].append({'name': 'automerge'})
        self.sweep(api)
        self.assertEqual(len([path for path, _ in api.posted if path.endswith('/comments')]), 2)

    def test_a_head_that_moved_after_the_pr_list_is_left_alone(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, 'f' * 40)])  # the list says another head than the fetched ref
        self.assertEqual(self.sweep(api), {})
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_a_head_that_moves_between_the_check_and_the_hand_off_is_left_alone(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)])
        moved = dict(api.pulls[7], head={'sha': 'e' * 40, 'repo': {'full_name': REPO}})
        real_get = api.get
        api.get = lambda path: moved if path == 'pulls/7' else real_get(path)
        self.sweep(api)
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_an_unreadable_pr_ref_changes_nothing(self):
        head = self.clean_pr(8)
        api = FakeApi([pull(8, head), pull(99, 'c' * 40)])  # refs/pull/99/head does not exist
        with self.assertRaises(subprocess.CalledProcessError):
            self.sweep(api)
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_no_branch_or_pull_ref_in_the_origin_changes(self):
        head = self.conflicting_pr()
        before = self.origin.refs()
        self.sweep(FakeApi([pull(7, head)]))
        self.assertEqual(self.origin.refs(), before)

    def test_the_throwaway_worktree_is_gone_and_the_cache_has_no_merge_in_progress(self):
        head = self.conflicting_pr()
        self.sweep(FakeApi([pull(7, head)]))
        self.assertEqual(run_git(self.cache, 'worktree', 'list').count('\n'), 0)
        self.assertFalse((self.cache / '.git' / 'MERGE_HEAD').exists())

    def test_an_api_failure_while_acting_does_not_stop_the_other_steps_or_the_sweep(self):
        head = self.conflicting_pr(7)
        other = self.conflicting_pr(5, 'second', 'keep.txt')
        api = FakeApi([pull(7, head), pull(5, other)])
        real_post = api.post

        def post(path, fields=None):
            if path.startswith('issues/7/'):
                raise subprocess.CalledProcessError(1, 'gh')
            real_post(path, fields)
        api.post = post
        found = self.sweep(api)
        self.assertEqual(sorted(found), [5, 7])
        self.assertTrue(any('::warning::#7' in line for line in self.logs))
        self.assertIn('issues/5/labels/automerge', api.deleted)

    def test_main_never_fails_the_check_when_github_is_unreachable(self):
        class Broken:
            repo = REPO

            def get_all(self, path):
                raise subprocess.CalledProcessError(1, 'gh')
        original = conflicts.GitHubApi
        conflicts.GitHubApi = lambda repo: Broken()
        try:
            self.assertEqual(conflicts.main(['--repo', REPO, '--remote', str(self.origin.bare),
                                             '--workdir', str(self.cache)]), 0)
        finally:
            conflicts.GitHubApi = original


class WorkflowWiringTests(unittest.TestCase):
    workflow = (Path(__file__).resolve().parents[2] / '.github' / 'workflows' / 'lane-conflicts.yml')

    def test_it_runs_on_the_vps_from_the_base_branch_and_cannot_push(self):
        text = self.workflow.read_text()
        self.assertIn('runs-on: [self-hosted, Linux, sm-vps]', text)
        self.assertIn('ref: ${{ github.event.pull_request.base.sha || github.sha }}', text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('contents: read', text)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('git push', text)
        self.assertNotIn('--force', text)

    def test_it_starts_when_next_moves_and_when_a_lane_label_or_push_lands(self):
        text = self.workflow.read_text()
        for needle in ('push:', 'branches: [next]', 'pull_request:', 'types: [labeled, synchronize, reopened]',
                       'workflow_dispatch:', "'automerge'", "'lane:queued'"):
            self.assertIn(needle, text)


if __name__ == '__main__':
    unittest.main()
