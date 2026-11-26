from pathlib import Path
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

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

    def __init__(self, pulls, comments=None, runs=(), jobs=None, queue=None):
        self.pulls = {pull['number']: pull for pull in pulls}
        self.comments = {number: list(found) for number, found in (comments or {}).items()}
        self.runs, self.jobs = list(runs), jobs or {}
        self.posted, self.deleted, self.cancelled, self.delete_errors = [], [], [], {}
        # GitHub's merge-queue state per PR: {'autoMergeRequest': ..., 'mergeQueueEntry': ...}, an exception to
        # raise, or absent (neither queued nor set to merge).
        self.queue, self.queue_reads, self.dispatched = dict(queue or {}), [], []

    def graphql(self, query, **variables):
        self.queue_reads.append(variables)
        found = self.queue.get(variables['number'], {'autoMergeRequest': None, 'mergeQueueEntry': None})
        if isinstance(found, Exception):
            raise found
        return {'data': {'repository': {'pullRequest': found}}}

    def get(self, path):
        if re.fullmatch(r'pulls/\d+', path):
            return self.pulls[int(path.split('/')[1])]
        if path.startswith('actions/workflows/lane.yml/runs?'):
            status = path.split('status=')[1].split('&')[0]
            event = path.split('event=')[1].split('&')[0]
            found = [run for run in self.runs if run['status'] == status and run.get('event', 'pull_request') == event]
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
        if path.startswith('actions/workflows/'):
            self.dispatched.append((path, fields))
            return
        self.posted.append((path, fields))
        number = int(path.split('/')[1])
        if path.endswith('/comments'):
            self.comments.setdefault(number, []).append({'body': fields['body']})
        if path.endswith('/labels'):
            self.pulls[number]['labels'].append({'name': fields['labels[]']})

    def delete(self, path):
        self.deleted.append(path)
        if self.delete_errors.get(path):
            raise self.delete_errors[path]
        number, name = int(path.split('/')[1]), path.split('/labels/')[1].replace('%3A', ':')
        self.pulls[number]['labels'] = [label for label in self.pulls[number]['labels'] if label['name'] != name]


def pull(number, head, labels=('automerge',), repo=REPO):
    return {'number': number, 'state': 'open', 'head': {'sha': head, 'repo': {'full_name': repo}},
            'labels': [{'name': name} for name in labels]}


def run(run_id, pr, head, status='queued', event='pull_request'):
    return {'id': run_id, 'status': status, 'event': event, 'display_title': f'lane pr={pr} head={head} lane=false auto=true'}


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
        self.assertTrue(comments[0]['body'].startswith(conflicts.RESOLVER_HANDOFF))
        self.assertIn('`shared.txt`', comments[0]['body'])
        self.assertIn(conflicts.marker(head, run_git(self.origin.bare, 'rev-parse', 'next')), comments[0]['body'])
        self.assertEqual([name['name'] for name in api.pulls[7]['labels']], ['conflict-resolver'])
        self.assertEqual(sorted(api.deleted), ['issues/7/labels/automerge', 'issues/7/labels/lane%3Aqueued'])
        self.assertEqual(api.cancelled, [50])  # the run already on a Mac keeps going

    QUEUED = {'autoMergeRequest': None, 'mergeQueueEntry': {'id': 'MQE_7'}}
    AUTO_ON = {'autoMergeRequest': {'enabledAt': '2026-11-24T18:02:27Z'}, 'mergeQueueEntry': None}
    BRIDGE_DISPATCH = ('actions/workflows/merge-queue-label-bridge.yml/dispatches', {'ref': 'main', 'inputs[pr]': '7'})

    def test_a_queued_conflicting_pr_is_handed_to_the_bridge_to_dequeue_after_the_label_swap(self):
        # #5302: #5276 stayed queued 5 hours after the hand-off, and the finisher's push was refused (GH006).
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)], queue={7: self.QUEUED})
        order = []
        real_post = api.post

        def post(path, fields=None):
            order.append((path, sorted(label['name'] for label in api.pulls[7]['labels'])))
            real_post(path, fields)
        api.post = post
        self.sweep(api)
        self.assertEqual(api.dispatched, [self.BRIDGE_DISPATCH])
        # The bridge takes out only a PR that already carries a hand-off label and no arming label.
        self.assertEqual(order[-1], (self.BRIDGE_DISPATCH[0], ['conflict-resolver']))
        self.assertTrue(any('asked the merge-queue bridge to dequeue' in line for line in self.logs))

    def test_a_pr_set_to_auto_merge_but_not_yet_queued_is_handed_to_the_bridge_too(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)], queue={7: self.AUTO_ON})
        self.sweep(api)
        self.assertEqual(api.dispatched, [self.BRIDGE_DISPATCH])

    def test_a_pr_that_is_neither_queued_nor_set_to_merge_gets_no_dispatch(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)])
        self.sweep(api)
        self.assertEqual(len(api.queue_reads), 1)
        self.assertEqual(api.dispatched, [])
        self.assertEqual([label['name'] for label in api.pulls[7]['labels']], ['conflict-resolver'])

    def test_an_unreadable_queue_state_still_asks_the_bridge_which_reads_the_pr_itself(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)], queue={7: subprocess.CalledProcessError(1, 'gh', stderr='HTTP 502')})
        self.sweep(api)
        self.assertEqual(api.dispatched, [self.BRIDGE_DISPATCH])

    def test_the_dispatch_is_on_the_repositorys_default_branch(self):
        head = self.conflicting_pr()
        found = pull(7, head)
        found['base'] = {'ref': 'next', 'repo': {'default_branch': 'trunk'}}
        api = FakeApi([found], queue={7: self.QUEUED})
        self.sweep(api)
        self.assertEqual(api.dispatched, [(self.BRIDGE_DISPATCH[0], {'ref': 'trunk', 'inputs[pr]': '7'})])

    def test_a_failed_dispatch_is_a_warning_and_the_hand_off_stands(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)], queue={7: self.QUEUED})
        real_post = api.post

        def post(path, fields=None):
            if path.startswith('actions/workflows/'):
                raise subprocess.CalledProcessError(1, 'gh', stderr='HTTP 422')
            real_post(path, fields)
        api.post = post
        self.assertEqual(self.sweep(api), {7: ['shared.txt']})
        self.assertEqual([label['name'] for label in api.pulls[7]['labels']], ['conflict-resolver'])
        self.assertTrue(any('hand-off stopped' in line for line in self.logs))

    def test_a_queued_pr_github_alone_calls_unmergeable_is_handed_to_the_bridge_too(self):
        head = self.clean_pr()
        found = pull(8, head)
        found['mergeable'] = False
        api = FakeApi([found], queue={8: self.QUEUED})
        self.assertEqual(self.sweep(api), {8: []})
        self.assertEqual(api.dispatched, [(self.BRIDGE_DISPATCH[0], {'ref': 'main', 'inputs[pr]': '8'})])

    def test_a_clean_pr_is_never_read_for_its_queue_state_or_dispatched(self):
        head = self.clean_pr()
        api = FakeApi([pull(8, head)], queue={8: self.QUEUED})
        api.pulls[8]['mergeable'] = True
        self.sweep(api)
        self.assertEqual((api.queue_reads, api.dispatched), ([], []))

    def test_a_pr_git_merges_but_github_calls_unmergeable_gets_a_hand_off_with_its_own_comment(self):
        # #4538: GitHub builds no merge ref for it, so a label event starts no run and it sits armed and silent.
        head = self.clean_pr()
        pr = pull(8, head)
        pr['mergeable'] = False
        api = FakeApi([pr])
        self.assertEqual(self.sweep(api), {8: []})
        comments = [fields['body'] for path, fields in api.posted if path.endswith('/comments')]
        self.assertEqual(len(comments), 1)
        self.assertTrue(comments[0].startswith(conflicts.HANDOFF))
        self.assertIn('not mergeable', comments[0])
        self.assertIn('no lane run', comments[0].replace('starts no lane run', 'no lane run'))
        self.assertIn(conflicts.marker(head, run_git(self.origin.bare, 'rev-parse', 'next'), 'no-merge-ref'), comments[0])
        self.assertEqual([label['name'] for label in api.pulls[8]['labels']], ['needs-mac'])
        self.assertEqual(api.deleted, ['issues/8/labels/automerge'])
        self.assertEqual(self.sweep(api), {})  # no longer armed: nothing more to do

    def test_a_re_armed_github_only_hand_off_gets_a_short_reason_not_a_second_full_comment(self):
        head = self.clean_pr()
        pr = pull(8, head)
        pr['mergeable'] = False
        api = FakeApi([pr])
        self.sweep(api)
        api.pulls[8]['labels'] = [{'name': 'automerge'}]  # re-armed by hand
        self.sweep(api)
        comments = [fields['body'] for path, fields in api.posted if path.endswith('/comments')]
        self.assertEqual(len(comments), 2)
        self.assertEqual(comments[0].count('lane-conflict-no-merge-ref'), 1, 'only the first carries the marker')
        self.assertIn('came off again', comments[1])
        self.assertNotIn('<!--', comments[1])
        self.assertEqual(api.deleted, ['issues/8/labels/automerge', 'issues/8/labels/automerge'])

    def test_a_state_other_than_dirty_changes_nothing_and_a_pr_that_settles_before_the_hand_off_is_left_alone(self):
        head = self.clean_pr()
        pr = pull(8, head)
        pr['mergeable'], pr['mergeable_state'] = False, 'behind'
        api = FakeApi([pr])
        self.assertEqual(self.sweep(api), {})
        self.assertEqual((api.posted, api.deleted), ([], []))
        # GitHub settles between the check and the hand-off: act_on_conflict reads the PR again.
        pr['mergeable_state'] = 'dirty'
        original, reads = api.get, []

        def settle(path):
            result = dict(original(path))  # what this read saw
            if path == 'pulls/8':
                reads.append(path)
                if len(reads) >= 2:
                    result['mergeable'] = True  # the read inside the hand-off: GitHub has settled
            return result
        api.get = settle
        self.assertEqual(self.sweep(api), {8: []})
        self.assertEqual((api.posted, api.deleted), ([], []))

    def test_an_unknown_or_true_mergeable_state_changes_nothing(self):
        for state in (None, True):
            with self.subTest(mergeable=state):
                head = self.clean_pr(number=10, name=f'clean-{state}')
                pr = pull(10, head)
                pr['mergeable'] = state
                api = FakeApi([pr])
                self.assertEqual(self.sweep(api), {})
                self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_a_pr_with_a_live_lane_run_for_its_head_is_left_to_finish(self):
        head = self.clean_pr()
        pr = pull(8, head)
        pr['mergeable'] = False
        api = FakeApi([pr], runs=[run(60, 8, head, 'in_progress')], jobs={60: [{'name': 'automerge', 'status': 'in_progress'}]})
        self.assertEqual(self.sweep(api), {})
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_a_dispatched_lane_run_for_its_head_is_left_to_finish_too(self):
        # The release hand-off and the hosted audit dispatch lane.yml; those runs are not `pull_request` runs (#4538).
        for status in ('queued', 'in_progress', 'waiting', 'pending'):
            with self.subTest(status=status):
                head = self.clean_pr(number=11, name=f'dispatched-{status}')
                pr = pull(11, head)
                pr['mergeable'] = False
                api = FakeApi([pr], runs=[run(61, 11, head, status, event='workflow_dispatch')])
                self.assertEqual(self.sweep(api), {})
                self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_a_dispatched_run_for_another_head_or_a_finished_one_does_not_hold_the_hand_off(self):
        head = self.clean_pr(number=12, name='other-runs')
        pr = pull(12, head)
        pr['mergeable'] = False
        other = 'f' * 40
        api = FakeApi([pr], runs=[run(62, 12, other, 'queued', event='workflow_dispatch'),
                                  run(63, 12, head, 'completed', event='workflow_dispatch')])
        self.assertEqual(self.sweep(api), {12: []})
        self.assertTrue(api.deleted)

    def test_a_real_conflict_is_still_the_conflict_hand_off_even_when_github_agrees(self):
        head = self.conflicting_pr()
        pr = pull(7, head)
        pr['mergeable'] = False
        api = FakeApi([pr])
        self.assertEqual(self.sweep(api), {7: ['shared.txt']})
        body = [fields['body'] for path, fields in api.posted if path.endswith('/comments')][0]
        self.assertIn('does not merge cleanly', body)

    def test_a_failure_reading_githubs_state_leaves_the_pr_as_it_was(self):
        head = self.clean_pr()
        api = FakeApi([pull(8, head)])
        with mock.patch.object(conflicts, 'github_cannot_merge', side_effect=OSError('boom')):
            self.assertEqual(self.sweep(api), {})
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_a_clean_merge_changes_nothing(self):
        head = self.clean_pr()
        api = FakeApi([pull(8, head)], runs=[run(60, 8, head)], jobs={60: [{'name': 'automerge', 'status': 'queued'}]})
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
        api = FakeApi([pull(7, head, ('needs-mac',)), pull(6, head, ('automerge',), repo='someone/fork')],
                      runs=[run(70, 7, head), run(71, 6, head)],
                      jobs={70: [{'name': 'automerge', 'status': 'queued'}],
                            71: [{'name': 'automerge', 'status': 'queued'}]})
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
        self.assertEqual([label['name'] for label in api.pulls[7]['labels']], ['conflict-resolver'])

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
        api = FakeApi([pull(7, 'f' * 40)], runs=[run(80, 7, 'f' * 40)],  # the list says another head than the fetched ref
                      jobs={80: [{'name': 'automerge', 'status': 'queued'}]})
        self.assertEqual(self.sweep(api), {})
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_a_head_that_moves_between_the_check_and_the_hand_off_is_left_alone(self):
        head = self.conflicting_pr()
        api = FakeApi([pull(7, head)], runs=[run(90, 7, head)], jobs={90: [{'name': 'automerge', 'status': 'queued'}]})
        moved = dict(api.pulls[7], head={'sha': 'e' * 40, 'repo': {'full_name': REPO}})
        real_get = api.get
        api.get = lambda path: moved if path == 'pulls/7' else real_get(path)
        self.sweep(api)
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_one_missing_pr_ref_costs_only_that_pr_its_check(self):
        head = self.conflicting_pr(7)
        api = FakeApi([pull(99, 'c' * 40), pull(7, head)])  # refs/pull/99/head does not exist
        found = self.sweep(api)
        self.assertEqual(found, {7: ['shared.txt']})
        self.assertTrue(any('::warning::#99' in line for line in self.logs))
        self.assertFalse([path for path, _ in api.posted if path.startswith('issues/99/')])

    def test_a_base_that_cannot_be_fetched_checks_nothing(self):
        head = self.clean_pr(8)
        api = FakeApi([pull(8, head)])
        with self.assertRaises(subprocess.CalledProcessError):
            conflicts.sweep(api, str(self.origin.bare) + '-missing', 'next', self.cache, log=self.logs.append)
        self.assertEqual((api.posted, api.deleted, api.cancelled), ([], [], []))

    def test_a_failed_hand_off_leaves_the_pr_armed_with_its_queued_runs(self):
        head = self.conflicting_pr(7)
        api = FakeApi([pull(7, head, ('automerge', 'lane:queued'))], runs=[run(50, 7, head)],
                      jobs={50: [{'name': 'automerge', 'status': 'queued'}]})
        real_post = api.post

        def post(path, fields=None):
            if path == 'issues/7/comments':
                raise subprocess.CalledProcessError(1, 'gh', stderr='HTTP 502')
            real_post(path, fields)
        api.post = post
        self.sweep(api)
        self.assertEqual(api.cancelled, [])
        self.assertEqual(api.deleted, [])
        self.assertEqual(sorted(label['name'] for label in api.pulls[7]['labels']), ['automerge', 'lane:queued'])

    def test_a_label_that_is_already_gone_does_not_stop_the_other_label_or_the_cancel(self):
        head = self.conflicting_pr(7)
        api = FakeApi([pull(7, head, ('automerge', 'lane:queued'))], runs=[run(50, 7, head)],
                      jobs={50: [{'name': 'automerge', 'status': 'queued'}]})
        api.delete_errors['issues/7/labels/automerge'] = subprocess.CalledProcessError(
            1, 'gh', stderr='gh: Label does not exist (HTTP 404)')
        self.sweep(api)
        self.assertEqual(sorted(api.deleted), ['issues/7/labels/automerge', 'issues/7/labels/lane%3Aqueued'])
        self.assertEqual(api.cancelled, [50])

    def test_a_label_removal_that_really_fails_keeps_the_runs(self):
        head = self.conflicting_pr(7)
        api = FakeApi([pull(7, head, ('automerge',))], runs=[run(50, 7, head)],
                      jobs={50: [{'name': 'automerge', 'status': 'queued'}]})
        api.delete_errors['issues/7/labels/automerge'] = subprocess.CalledProcessError(1, 'gh', stderr='HTTP 500')
        self.sweep(api)
        self.assertEqual(api.cancelled, [])
        self.assertNotIn('needs-mac', [label['name'] for label in api.pulls[7]['labels']])

    def test_only_runs_for_the_conflicting_head_are_cancelled(self):
        head = self.conflicting_pr(7)
        api = FakeApi([pull(7, head)], runs=[run(50, 7, head), run(51, 7, 'a' * 40), run(52, 8, head)],
                      jobs={50: [{'name': 'automerge', 'status': 'queued'}],
                            51: [{'name': 'automerge', 'status': 'queued'}],
                            52: [{'name': 'automerge', 'status': 'queued'}]})
        self.sweep(api)
        self.assertEqual(api.cancelled, [50])

    def test_a_non_ascii_file_name_is_reported_as_written(self):
        self.origin.branch_from_start('accent')
        self.origin.write('caf\u00e9.txt', 'pr\n')
        self.origin.write('shared.txt', 'one\nTWO FROM THE PR\nthree\n')
        head = self.origin.commit('pr')
        self.origin.pull(4, head)
        self.origin.advance_next('shared.txt', 'one\nTWO FROM NEXT\nthree\n')
        self.assertEqual(self.sweep(FakeApi([pull(4, head)])), {4: ['shared.txt']})
        run_git(self.origin.work, 'checkout', '-q', 'next')
        self.origin.write('caf\u00e9.txt', 'next\n')
        self.origin.commit('next adds the accented name')
        run_git(self.origin.work, 'push', '-q', 'origin', 'next')
        self.assertEqual(self.sweep(FakeApi([pull(4, head)])), {4: ['caf\u00e9.txt', 'shared.txt']})

    def test_no_branch_or_pull_ref_in_the_origin_changes(self):
        head = self.conflicting_pr()
        before = self.origin.refs()
        self.sweep(FakeApi([pull(7, head)]))
        self.assertEqual(self.origin.refs(), before)

    def test_no_worktree_temp_folder_or_merge_in_progress_is_left_behind(self):
        head = self.conflicting_pr()
        before = set(Path(tempfile.gettempdir()).glob('sm-lane-merge-*'))
        self.sweep(FakeApi([pull(7, head)]))
        self.assertEqual(set(Path(tempfile.gettempdir()).glob('sm-lane-merge-*')), before)
        self.assertEqual(list((self.cache / '.git' / 'worktrees').glob('*')) if (self.cache / '.git' / 'worktrees').exists() else [], [])
        self.assertEqual(run_git(self.cache, 'status', '--porcelain'), '')

    def test_a_folder_left_by_a_killed_run_is_cleared_by_the_next_sweep(self):
        head = self.conflicting_pr()
        leftover = Path(tempfile.mkdtemp(prefix='sm-lane-merge-'))
        self.addCleanup(lambda: __import__('shutil').rmtree(leftover, ignore_errors=True))
        self.sweep(FakeApi([pull(7, head)]))
        self.assertFalse(leftover.exists())

    def test_the_refs_of_a_closed_pr_do_not_pile_up_in_the_cache(self):
        head = self.conflicting_pr(7)
        self.sweep(FakeApi([pull(7, head)]))
        other = self.clean_pr(8)
        self.sweep(FakeApi([pull(8, other)]))
        refs = run_git(self.cache, 'for-each-ref', '--format=%(refname)', 'refs/lane-conflicts/').split()
        self.assertEqual(sorted(refs), ['refs/lane-conflicts/base', 'refs/lane-conflicts/pr-8'])

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


class PromoteStaleTests(unittest.TestCase):
    """A `conflict-resolver` PR the resolver left alone goes to the Mac finisher, so a broken resolver strands nothing."""
    NOW = __import__('datetime').datetime(2026, 11, 26, 12, 0, tzinfo=__import__('datetime').timezone.utc)

    def handed(self, hours_ago, marker=True):
        at = (self.NOW - __import__('datetime').timedelta(hours=hours_ago)).strftime('%Y-%m-%dT%H:%M:%SZ')
        body = f'{conflicts.RESOLVER_HANDOFF} the PR does not merge.'
        if marker:
            body += '\n<!-- lane-conflict head=aaaaaaa base=bbbbbbb -->'
        return {'created_at': at, 'body': body, 'user': {'login': 'github-actions[bot]'}}

    def promote(self, api):
        return conflicts.promote_stale(api, 'main', now=self.NOW, log=lambda line: None)

    def test_a_pr_left_past_the_limit_goes_to_the_finisher_with_the_marker(self):
        api = FakeApi([pull(7, 'a' * 40, ('conflict-resolver',))], comments={7: [self.handed(3)]})
        self.assertEqual(self.promote(api), [7])
        body = [f['body'] for p, f in api.posted if p.endswith('/comments')][0]
        self.assertTrue(body.startswith(conflicts.HANDOFF))
        self.assertIn('<!-- lane-conflict head=aaaaaaa base=bbbbbbb -->', body)
        self.assertEqual([label['name'] for label in api.pulls[7]['labels']], ['needs-mac'])

    def test_a_recent_hand_off_is_left_to_the_resolver(self):
        api = FakeApi([pull(7, 'a' * 40, ('conflict-resolver',))], comments={7: [self.handed(1)]})
        self.assertEqual(self.promote(api), [])
        self.assertEqual((api.posted, api.deleted), ([], []))

    def test_other_prs_and_forks_are_not_touched(self):
        api = FakeApi([pull(7, 'a' * 40, ('needs-mac',)), pull(8, 'a' * 40, ('conflict-resolver',), repo='x/fork')],
                      comments={7: [self.handed(5)], 8: [self.handed(5)]})
        self.assertEqual(self.promote(api), [])
        self.assertEqual((api.posted, api.deleted), ([], []))


class GitHubApiTests(unittest.TestCase):
    """The real GitHubApi against a fake `gh` that records its arguments."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name)
        self.log = self.bin / 'calls.txt'
        self.reply = self.bin / 'reply.json'
        gh = self.bin / 'gh'
        gh.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{self.log}"\ncat "{self.reply}"\n[ -f "{self.bin}/fail" ] && {{ echo "HTTP 404" >&2; exit 1; }}\nexit 0\n')
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        patcher = mock.patch.dict(os.environ, {'PATH': f'{self.bin}:{os.environ["PATH"]}'})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.reply.write_text('[]')
        self.api = conflicts.GitHubApi(REPO)

    def test_get_all_flattens_the_pages_gh_slurps(self):
        self.reply.write_text('[[{"number": 1}, {"number": 2}], [{"number": 3}]]')
        self.assertEqual([item['number'] for item in self.api.get_all('pulls?state=open&per_page=100')], [1, 2, 3])
        self.assertEqual(self.log.read_text().strip(),
                         f'api --paginate --slurp repos/{REPO}/pulls?state=open&per_page=100')

    def test_post_and_delete_build_the_calls_the_workflow_depends_on(self):
        self.api.post('issues/7/labels', {'labels[]': 'needs-mac'})
        self.api.post('actions/runs/5/cancel')
        self.api.delete('issues/7/labels/lane%3Aqueued')
        self.assertEqual(self.log.read_text().splitlines(), [
            f'api -X POST repos/{REPO}/issues/7/labels -f labels[]=needs-mac',
            f'api -X POST repos/{REPO}/actions/runs/5/cancel',
            f'api -X DELETE repos/{REPO}/issues/7/labels/lane%3Aqueued'])

    def test_a_404_is_kept_on_the_error_so_an_already_removed_label_can_be_told_apart(self):
        (self.bin / 'fail').write_text('')
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.api.delete('issues/7/labels/automerge')
        self.assertIn('404', caught.exception.stderr)
        self.assertTrue(conflicts.remove_label(self.api, 7, 'automerge'))


class TokenHandlingTests(unittest.TestCase):
    def test_the_token_reaches_git_through_the_environment_never_the_command_line(self):
        captured = {}

        def fake_run(cmd, **kwargs):
            captured.update(cmd=cmd, env=kwargs['env'])
            return subprocess.CompletedProcess(cmd, 0, '', '')
        with mock.patch.object(subprocess, 'run', fake_run), mock.patch('builtins.print') as printed:
            conflicts.git('.', 'fetch', auth='SECRETTOKEN')
        basic = __import__('base64').b64encode(b'x-access-token:SECRETTOKEN').decode()
        self.assertNotIn(basic, ' '.join(captured['cmd']))
        self.assertNotIn('SECRETTOKEN', ' '.join(captured['cmd']))
        self.assertEqual(captured['env']['GIT_CONFIG_VALUE_0'], f'Authorization: basic {basic}')
        printed.assert_any_call(f'::add-mask::{basic}')
        self.assertEqual(captured['env']['GIT_CONFIG_GLOBAL'], os.devnull)

    def test_a_failed_fetch_is_described_without_its_command_line(self):
        error = subprocess.CalledProcessError(128, ['git', '-c', 'x=Authorization: basic SECRET', 'fetch'],
                                              stderr='fatal: repository not found')
        text = conflicts.describe(error)
        self.assertNotIn('SECRET', text)
        self.assertIn('fatal: repository not found', text)


class WorkflowWiringTests(unittest.TestCase):
    workflow = (Path(__file__).resolve().parents[2] / '.github' / 'workflows' / 'lane-conflicts.yml')

    def test_it_runs_hosted_from_the_base_branch_and_cannot_push(self):
        text = self.workflow.read_text()
        self.assertIn('runs-on: ubuntu-latest', text)
        self.assertIn("ref: ${{ github.event.pull_request.base.ref || vars.SM_TRUNK || 'main' }}", text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('contents: read', text)
        self.assertNotIn('contents: write', text)
        self.assertNotIn('git push', text)
        self.assertNotIn('--force', text)

    def test_it_also_runs_without_an_event_because_runner_merges_and_merge_less_prs_start_nothing(self):
        # #4538: the lane runner merges with the workflow token, which starts no workflow, and GitHub starts no
        # pull_request run for a PR it can't build a merge ref for. Without a schedule such a PR sits armed and silent.
        # Since #4866 the hourly start is the VPS's workflow_dispatch (ops/dispatch-backstop/), and the cron is the
        # one daily last resort.
        text = self.workflow.read_text()
        self.assertRegex(text, r"schedule:\n\s+- cron: '\d+ \d+ \* \* \*'")
        self.assertIn('workflow_dispatch:', text)
        self.assertIn('(github.event_name != \'push\' || github.ref_name == (vars.SM_TRUNK || \'main\'))', text)

    def test_it_starts_when_next_moves_and_when_a_lane_label_or_push_lands(self):
        text = self.workflow.read_text()
        self.assertIn('ONLY_PR: ${{ inputs.pr }}', text)  # a PR event sweeps everything; only a dispatch narrows
        for needle in ('push:', 'branches: [next, main]', 'pull_request:', 'types: [labeled, synchronize, reopened]',
                       'workflow_dispatch:', "'automerge'", "'lane:queued'"):
            self.assertIn(needle, text)

    def test_the_dequeue_dispatch_has_what_it_needs_from_both_workflows(self):
        # #5302: dispatching needs `actions: write` here; the bridge must take a one-PR dispatch and run it as a
        # one-PR check (where a handed-off PR is taken out).
        self.assertIn('actions: write', self.workflow.read_text())
        bridge = (self.workflow.parent / conflicts.BRIDGE).read_text()
        self.assertIn('workflow_dispatch:', bridge)
        self.assertRegex(bridge, r'inputs:\n\s+pr:')
        self.assertIn('PR: ${{ github.event.pull_request.number || inputs.pr }}', bridge)
        self.assertIn('--pr "$PR" --action edited', bridge)


if __name__ == '__main__':
    unittest.main()
