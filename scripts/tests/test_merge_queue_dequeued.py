"""scripts/merge_queue_dequeued.py: one comment per removed group, and never a cancel of a live group's run (#4693)."""
import io
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import merge_queue_dequeued as mq  # noqa: E402

LIVE, DEAD, OTHER = 'a' * 40, 'b' * 40, 'c' * 40


class FakeGitHub:
    """The GitHub class's three calls, answered from dicts. A value that is an exception is raised."""

    def __init__(self, gets=None, heads=None, post_error=None):
        self.gets = gets or {}
        self.heads = heads if heads is not None else set()
        self.post_error = post_error
        self.posts = []
        self.deletes = []
        self.reads = []

    def get(self, path):
        self.reads.append(path)
        for prefix, value in self.gets.items():
            if path.startswith(prefix):
                if isinstance(value, Exception):
                    raise value
                return value
        return {}

    def queue_heads(self):
        if isinstance(self.heads, Exception):
            raise self.heads
        return self.heads

    def post(self, path, body):
        if self.post_error:
            raise self.post_error
        self.posts.append((path, body))

    requeue_ok = True
    requeued = 0

    def requeue(self, number):
        self.requeued += 1
        return self.requeue_ok

    def delete(self, path):
        if self.post_error:
            raise self.post_error
        self.deletes.append(path)


def run(id_, sha, branch):
    return {'id': id_, 'head_sha': sha, 'head_branch': branch, 'created_at': f'2026-11-19T10:0{id_}:00Z'}


def event(number=7, reason='CI_FAILURE', merged=False, armed=True):
    labels = [{'name': 'automerge'}] if armed else [{'name': 'docs'}]
    return {'reason': reason, 'pull_request': {'number': number, 'merged': merged, 'head': {'sha': OTHER},
                                               'labels': labels}}


class CancelTests(unittest.TestCase):
    def active(self, *runs):
        return {'actions/runs?status=in_progress': {'workflow_runs': list(runs)}}

    def test_a_run_whose_group_is_still_queued_is_never_cancelled(self):
        github = FakeGitHub(self.active(run(1, LIVE, f'{mq.QUEUE_PREFIX}pr-7-x'), run(2, DEAD, f'{mq.QUEUE_PREFIX}pr-8-y')),
                            heads={LIVE})
        self.assertEqual(mq.cancel_dead(github, out=io.StringIO()), [2])
        self.assertEqual(github.posts, [('actions/runs/2/cancel', {})])

    def test_an_unreadable_entry_list_cancels_nothing(self):
        github = FakeGitHub(self.active(run(2, DEAD, f'{mq.QUEUE_PREFIX}pr-8-y')), heads=mq.ReadFailed('graphql'))
        out = io.StringIO()
        self.assertEqual(mq.cancel_dead(github, out=out), [])
        self.assertEqual(github.posts, [])
        self.assertIn('cancelled nothing', out.getvalue())

    def test_an_unreadable_run_list_cancels_nothing(self):
        github = FakeGitHub({'actions/runs?status=': mq.ReadFailed('runs')}, heads=set())
        self.assertEqual(mq.cancel_dead(github, out=io.StringIO()), [])
        self.assertEqual(github.posts, [])

    def test_runs_on_other_branches_are_left_alone(self):
        github = FakeGitHub(self.active(run(3, DEAD, 'feature/x'), run(4, DEAD, 'main')), heads=set())
        self.assertEqual(mq.cancel_dead(github, out=io.StringIO()), [])

    def test_an_empty_queue_cancels_every_queue_run(self):
        # The last entry left: every group is gone.
        github = FakeGitHub(self.active(run(5, DEAD, f'{mq.QUEUE_PREFIX}pr-8-y')), heads=set())
        self.assertEqual(mq.cancel_dead(github, out=io.StringIO()), [5])

    def test_the_runs_are_listed_before_the_entries_are_read(self):
        # A group's entry exists before its run. Reading entries first could miss an entry created in between and
        # cancel its brand-new run; listing runs first cannot.
        order = []
        github = FakeGitHub(self.active(run(1, LIVE, f'{mq.QUEUE_PREFIX}pr-7-x')), heads={LIVE})
        get, heads = github.get, github.queue_heads
        github.get = lambda path: (order.append('runs'), get(path))[1]
        github.queue_heads = lambda: (order.append('entries'), heads())[1]
        mq.cancel_dead(github, out=io.StringIO())
        self.assertEqual(order[-1], 'entries')
        self.assertNotIn('entries', order[:-1])


class NotifyTests(unittest.TestCase):
    def github(self, comments=(), check_conclusion='failure', group=True):
        runs = [run(1, DEAD, f'{mq.QUEUE_PREFIX}pr-7-old'), run(2, LIVE, f'{mq.QUEUE_PREFIX}pr-7-new'),
                run(3, OTHER, f'{mq.QUEUE_PREFIX}pr-70-z')] if group else []
        return FakeGitHub({
            'actions/runs?event=merge_group': {'workflow_runs': runs},
            f'commits/{LIVE}/check-runs': {'check_runs': [
                {'name': 'hosted fast: portable', 'conclusion': 'success', 'completed_at': '2026-11-19T10:05:00Z'},
                {'name': 'hosted fast: Mac rest', 'conclusion': check_conclusion, 'completed_at': '2026-11-19T10:09:00Z',
                 'html_url': 'https://example.test/run/9'}]},
            'issues/7/comments': list(comments),
        })

    def test_it_names_the_failed_check_of_the_latest_group_and_labels_the_pr(self):
        github = self.github()
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
        (path, body), label = github.posts
        self.assertEqual(path, 'issues/7/comments')
        self.assertIn('"hosted fast: Mac rest"', body['body'])
        self.assertIn('https://example.test/run/9', body['body'])
        self.assertIn(mq.MARKER.format(head=LIVE), body['body'])  # the newest group, not pr-70's or the old one
        self.assertIn('then add `automerge` again', body['body'])
        self.assertNotIn('gh pr merge', body['body'])
        self.assertEqual(label, ('issues/7/labels', {'labels': ['needs-fix']}))

    def test_a_failure_removal_takes_automerge_off_so_the_bridge_does_not_queue_it_again(self):
        # Without this the label bridge's 15-minute sweep would queue the failing PR again at once, rebuilding every
        # group behind it four times an hour. Re-arming is adding `automerge` again, as with the old lane.
        for reason in ('CI_FAILURE', 'MERGE_CONFLICT', 'CI_TIMEOUT', ''):
            with self.subTest(reason=reason):
                github = self.github()
                mq.notify(github, event(reason=reason), out=io.StringIO())
                self.assertEqual(github.deletes, ['issues/7/labels/automerge'])

    def test_a_merged_pr_keeps_automerge(self):
        for e in (event(merged=True), event(reason='MERGED')):
            github = self.github()
            mq.notify(github, e, out=io.StringIO())
            self.assertEqual(github.deletes, [])

    def test_a_manual_removal_takes_automerge_off_without_needs_fix(self):
        # Taking a PR out by hand means "stop". If `automerge` stayed, the bridge's sweep would queue it again
        # within 15 minutes.
        for reason in ('MANUAL', 'DEQUEUED_MANUALLY'):
            with self.subTest(reason=reason):
                github = self.github()
                mq.notify(github, event(reason=reason), out=io.StringIO())
                self.assertEqual(github.deletes, ['issues/7/labels/automerge'])
                self.assertEqual([path for path, _ in github.posts], ['issues/7/comments'])
                body = github.posts[0][1]['body']
                self.assertIn('taken out by hand', body)
                self.assertIn('add `automerge` again', body)
                self.assertNotIn('Failed check', body)

    def test_a_manual_removal_of_an_unlabelled_pr_removes_nothing_and_claims_nothing(self):
        # The owner's own Merge tap on a `.github/` PR carries no `automerge`.
        github = self.github()
        mq.notify(github, event(reason='MANUAL', armed=False), out=io.StringIO())
        self.assertEqual(github.deletes, [])
        body = github.posts[0][1]['body']
        self.assertIn('taken out by hand', body)
        self.assertNotIn('automerge', body)

    def test_a_failure_of_an_unlabelled_pr_adds_needs_fix_but_deletes_no_label(self):
        github = self.github()
        mq.notify(github, event(armed=False), out=io.StringIO())
        self.assertEqual(github.deletes, [])
        self.assertIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)

    def test_a_group_cancelled_by_its_time_limit_stays_armed_once(self):
        # 2026-11-20: #4746 and #4684 left the queue when "hosted fast: portable" hit timeout-minutes, which ends as
        # `cancelled`. Nothing in either PR failed, yet both got needs-fix and lost automerge.
        github = self.github(check_conclusion='cancelled')
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told: retry')
        self.assertEqual(github.deletes, [])
        self.assertEqual([path for path, _ in github.posts], ['issues/7/comments'])
        body = github.posts[0][1]['body']
        self.assertIn('"hosted fast: Mac rest"', body)
        self.assertIn('cancelled, not failed', body)
        self.assertIn(mq.RETRY_MARKER, body)

    def test_a_cancelled_group_is_set_to_merge_again_here_not_left_for_the_sweep(self):
        # #4937: the retry used to wait for the bridge's sweep, which runs only when the VPS backstop or a schedule
        # GitHub mostly drops starts it; with the backstop's token refused the PR sat armed and unqueued, its comment
        # promising "within 15 minutes".
        github = self.github(check_conclusion='cancelled')
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told: retry')
        self.assertEqual(github.requeued, 1)
        self.assertIn('set to merge again now', github.posts[0][1]['body'])
        self.assertEqual(github.deletes, [])

    def test_a_failed_requeue_says_the_sweep_will_do_it(self):
        github = self.github(check_conclusion='cancelled')
        github.requeue_ok = False
        mq.notify(github, event(), out=io.StringIO())
        self.assertIn("label bridge's sweep will queue it", github.posts[0][1]['body'])

    def test_a_queue_timeout_with_no_check_reported_is_retried_once(self):
        # A merge group whose Mac check never started (no runner free for 120 minutes) times out with no failed and
        # no cancelled check. Nothing in the PR failed, yet it got needs-fix and lost automerge (#4937 harness:
        # */mac-slow-once).
        for reason in ('CI_TIMEOUT', 'CHECKS_TIMED_OUT'):
            with self.subTest(reason=reason):
                github = self.github(check_conclusion='in_progress')
                self.assertEqual(mq.notify(github, event(reason=reason), out=io.StringIO()), 'told: retry')
                self.assertEqual(github.requeued, 1)
                self.assertEqual(github.deletes, [])
                self.assertNotIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)
                self.assertIn('did not report before the queue', github.posts[0][1]['body'])

    def test_a_second_queue_timeout_is_held_as_a_failure(self):
        earlier = {'body': f'{mq.MARKER.format(head="0" * 40)}\n{mq.RETRY_MARKER}'}
        github = self.github(check_conclusion='in_progress', comments=[earlier])
        self.assertEqual(mq.notify(github, event(reason='CI_TIMEOUT'), out=io.StringIO()), 'told')
        self.assertEqual(github.requeued, 0)
        self.assertIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)

    def test_an_unlabelled_pr_that_times_out_is_told_to_tap_merge_again(self):
        # #4942 audit: the owner's own Merge tap carries no `automerge`. Its retry comment promised the bridge's sweep,
        # which only queues labelled PRs, so the PR sat out of the queue while its comment said it would be retried.
        for reason, conclusion in (('CI_TIMEOUT', 'in_progress'), ('CI_FAILURE', 'cancelled')):
            with self.subTest(reason=reason):
                github = self.github(check_conclusion=conclusion)
                self.assertEqual(mq.notify(github, event(reason=reason, armed=False), out=io.StringIO()), 'told: retry')
                self.assertEqual((github.requeued, github.deletes), (0, []))
                body = github.posts[0][1]['body']
                self.assertIn('tap Merge again', body)
                self.assertNotIn('sweep', body)
                self.assertNotIn('It keeps', body)

    def test_a_failure_with_no_failed_check_found_still_needs_a_fix(self):
        # Not a timeout and nothing cancelled: the reason says the group failed, so the PR is held as before.
        github = self.github(check_conclusion='in_progress')
        self.assertEqual(mq.notify(github, event(reason='CI_FAILURE'), out=io.StringIO()), 'told')
        self.assertEqual(github.requeued, 0)

    def test_a_second_cancelled_group_is_held_as_a_failure(self):
        earlier = {'body': mq.MARKER.format(head=DEAD) + '\n' + mq.RETRY_MARKER}
        github = self.github(check_conclusion='cancelled', comments=[earlier])
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
        self.assertEqual(github.deletes, ['issues/7/labels/automerge'])
        self.assertIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)
        body = github.posts[0][1]['body']
        self.assertIn('cancelled on its last try too', body)
        self.assertNotIn(mq.RETRY_MARKER, body)

    def test_a_real_failure_beside_a_cancel_is_still_a_failure(self):
        github = self.github()
        github.gets[f'commits/{LIVE}/check-runs']['check_runs'].append(
            {'name': 'hosted web: build and Playwright', 'conclusion': 'cancelled', 'completed_at': '2026-11-19T10:10:00Z'})
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
        self.assertEqual(github.deletes, ['issues/7/labels/automerge'])
        self.assertIn('"hosted fast: Mac rest"', github.posts[0][1]['body'])

    def test_a_manual_removal_of_a_cancelled_group_still_means_stop(self):
        github = self.github(check_conclusion='cancelled')
        mq.notify(github, event(reason='MANUAL'), out=io.StringIO())
        self.assertEqual(github.deletes, ['issues/7/labels/automerge'])

    def test_deleting_a_label_that_is_already_gone_is_fine(self):
        github = mq.GitHub('o/r', sleep=lambda _: None)

        def gone(args, data=None):
            raise subprocess.CalledProcessError(1, 'gh', stderr='gh: Label does not exist (HTTP 404)')
        github._gh = gone
        github.delete('issues/7/labels/automerge')  # no raise

        def broken(args, data=None):
            raise subprocess.CalledProcessError(1, 'gh', stderr='HTTP 500')
        github._gh = broken
        with self.assertRaises(subprocess.CalledProcessError):
            github.delete('issues/7/labels/automerge')

    def test_one_comment_per_group(self):
        told = {'body': 'earlier\n' + mq.MARKER.format(head=LIVE)}
        github = self.github(comments=[told])
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'skipped: already told')
        self.assertEqual(github.posts, [])

    def test_a_new_group_gets_a_new_comment(self):
        github = self.github(comments=[{'body': mq.MARKER.format(head=DEAD)}])
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')

    def test_a_merged_pr_gets_nothing(self):
        for e in (event(merged=True), event(reason='MERGED')):
            github = self.github()
            self.assertEqual(mq.notify(github, e, out=io.StringIO()), 'skipped: merged')
            self.assertEqual(github.posts, [])

    def test_a_manual_removal_gets_a_comment_but_no_label(self):
        github = self.github()
        mq.notify(github, event(reason='MANUAL'), out=io.StringIO())
        self.assertEqual([path for path, _ in github.posts], ['issues/7/comments'])

    def test_a_conflict_with_no_group_run_says_so_and_keys_on_the_pr_head(self):
        github = self.github(group=False)
        mq.notify(github, event(reason='MERGE_CONFLICT'), out=io.StringIO())
        body = github.posts[0][1]['body']
        self.assertIn('conflicts with main', body)
        self.assertIn(mq.MARKER.format(head=OTHER), body)

    def test_an_invalid_merge_commit_is_a_conflict_not_a_retry(self):
        # #4942, 2026-11-22: dequeued with INVALID_MERGE_COMMIT after #4941 and #4930 merged ahead of it. The comment
        # said "No failed check found" and told an unlabelled PR to add `automerge`; merging main in was the fix.
        for armed in (True, False):
            with self.subTest(armed=armed):
                github = self.github(check_conclusion='in_progress')
                self.assertEqual(mq.notify(github, event(reason='INVALID_MERGE_COMMIT', armed=armed),
                                           out=io.StringIO()), 'told')
                self.assertEqual(github.requeued, 0)
                body = github.posts[0][1]['body']
                self.assertIn('Merge main into the branch', body)
                self.assertNotIn('No failed check found', body)
                self.assertNotIn(mq.RETRY_MARKER, body)
                self.assertIn('add `automerge` again' if armed else 'tap Merge again', body)

    def test_a_failed_read_posts_nothing_and_does_not_raise(self):
        github = self.github()
        github.gets['issues/7/comments'] = mq.ReadFailed('comments')
        out = io.StringIO()
        self.assertEqual(mq.notify(github, event(), out=out), 'skipped: read failed')
        self.assertEqual(github.posts, [])
        self.assertIn('::warning::', out.getvalue())

    def test_a_failed_post_does_not_raise(self):
        github = self.github()
        github.post_error = subprocess.CalledProcessError(1, 'gh')
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'skipped: post failed')


class OwnFailureTests(unittest.TestCase):
    """#5281: a test that failed in a group of only main and this PR is this PR's; a second such failure of the same
    commit holds it out of the queue. On 2026-11-24 #5207 was re-armed with no push after three failed groups."""
    BASE = 'd' * 40

    def github(self, compare='behind', comments=(), heads=None, cls=FakeGitHub):
        runs = [run(2, LIVE, f'{mq.QUEUE_PREFIX}pr-7-{self.BASE}')]
        return cls({
            'actions/runs?event=merge_group': {'workflow_runs': runs},
            f'commits/{LIVE}/check-runs': {'check_runs': [
                {'name': 'hosted fast: portable', 'conclusion': 'failure', 'completed_at': '2026-11-24T19:26:00Z',
                 'html_url': 'https://example.test/run/9'}]},
            f'compare/main...{self.BASE}': compare if isinstance(compare, Exception) else {'status': compare},
            'issues/7/comments': list(comments),
        }, heads=heads)

    def body(self, github):
        return github.posts[0][1]['body']

    def test_a_failure_alone_on_main_is_marked_as_the_prs_and_allows_one_retry(self):
        for status in ('behind', 'identical'):
            with self.subTest(status=status):
                github = self.github(status)
                self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
                self.assertIn(mq.OWN_FAILURE_MARKER.format(head=OTHER), self.body(github))  # the PR's head, not the group's
                self.assertIn('retries this commit once', self.body(github))

    def test_a_second_failure_alone_says_the_commit_is_held(self):
        earlier = {'body': mq.OWN_FAILURE_MARKER.format(head=OTHER), 'user': {'login': mq.BOT}}
        github = self.github(comments=[earlier])
        mq.notify(github, event(), out=io.StringIO())
        self.assertIn('will not take this commit again', self.body(github))

    def test_a_marker_from_anyone_else_does_not_count(self):
        forged = {'body': mq.OWN_FAILURE_MARKER.format(head=OTHER), 'user': {'login': 'someone'}}
        github = self.github(comments=[forged])
        mq.notify(github, event(), out=io.StringIO())
        self.assertIn('retries this commit once', self.body(github))

    def test_a_group_built_on_another_entry_or_unreadable_is_not_marked(self):
        for compare in ('diverged', 'ahead', mq.ReadFailed('HTTP 502')):
            with self.subTest(compare=compare):
                github = self.github(compare)
                mq.notify(github, event(), out=io.StringIO())
                self.assertNotIn('own-failure', self.body(github))

    def test_a_manual_removal_or_a_conflict_is_never_marked(self):
        for reason in ('MANUAL', 'MERGE_CONFLICT'):
            with self.subTest(reason=reason):
                github = self.github()
                mq.notify(github, event(reason=reason), out=io.StringIO())
                self.assertNotIn('own-failure', self.body(github))

    def test_a_requeue_that_slipped_in_before_the_label_came_off_is_undone(self):
        # #5207 at 10:38:14 on 2026-11-24: the bridge's sweep queued it 5 s after GitHub removed it.
        class WithStop(FakeGitHub):
            stopped = None

            def stop_merging(self, number, node_id, in_queue):
                self.stopped = (number, node_id, in_queue)
                return True
        github = self.github(heads={OTHER}, cls=WithStop)
        ev = event()
        ev['pull_request']['node_id'] = 'PR_7'
        mq.notify(github, ev, out=io.StringIO())
        self.assertEqual(github.stopped, (7, 'PR_7', True))
        github = self.github(heads=set(), cls=WithStop)
        mq.notify(github, event(reason='MANUAL'), out=io.StringIO())
        self.assertIsNone(github.stopped)  # a removal by hand already took it out

    def test_the_bridge_reads_the_same_marker_and_limit(self):
        sys.path.insert(0, str(ROOT / 'scripts'))
        import merge_queue_label_bridge as bridge
        self.assertEqual(bridge.OWN_FAILURE.findall(mq.OWN_FAILURE_MARKER.format(head=LIVE)), [LIVE])
        self.assertEqual(bridge.OWN_FAILURE_LIMIT, mq.OWN_FAILURE_LIMIT)


class SetupFailureTests(unittest.TestCase):
    """A group whose every failed job failed outside the PR gets one delayed retry (#4940)."""

    NOW = mq.datetime.datetime(2026, 11, 23, 5, 0, 0, tzinfo=mq.datetime.timezone.utc)
    WHEN = '2026-11-23T05:30:00Z'

    def github(self, jobs, comments=(), logs=None):
        """`jobs`: {check name: [(step name, conclusion), ...]}; each check gets its own job id."""
        checks, gets = [], {}
        for index, (name, steps) in enumerate(jobs.items(), start=100):
            checks.append({'id': index, 'name': name, 'conclusion': 'failure', 'completed_at': f'2026-11-23T04:5{index - 100}:00Z',
                           'html_url': f'https://example.test/run/9/job/{index}',
                           'details_url': f'https://example.test/run/9/job/{index}'})
            gets[f'actions/jobs/{index}'] = {'steps': [{'number': n, 'name': step, 'conclusion': conclusion}
                                                       for n, (step, conclusion) in enumerate(steps, start=1)]}
        github = FakeGitHub({
            'actions/runs?event=merge_group': {'workflow_runs': [run(2, LIVE, f'{mq.QUEUE_PREFIX}pr-7-new')]},
            f'commits/{LIVE}/check-runs': {'check_runs': checks},
            'issues/7/comments': list(comments), **gets})
        github.now = lambda: self.NOW
        github.log_tail = lambda job_id: (logs or {}).get(job_id, '')
        return github

    SETUP = [('Set up job', 'success'), ('Install BlackHole (virtual audio output)', 'failure'),
             ('Mac rest of the fast plan', 'skipped')]
    TEST = [('Set up job', 'success'), ('Install BlackHole (virtual audio output)', 'success'),
            ('Mac rest of the fast plan', 'failure')]

    def test_a_setup_failure_stays_armed_with_a_not_before_time_and_no_label(self):
        github = self.github({'hosted fast: Mac rest': self.SETUP})
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told: setup retry')
        (path, body), = github.posts
        self.assertEqual(path, 'issues/7/comments')
        self.assertIn(mq.SETUP_RETRY_MARKER.format(when=self.WHEN), body['body'])
        self.assertIn('"hosted fast: Mac rest" in its step "Install BlackHole (virtual audio output)"', body['body'])
        self.assertIn('keeps `automerge`', body['body'])
        self.assertEqual(github.deletes, [])      # no `automerge` removal, no `needs-fix`
        self.assertEqual(github.requeued, 0)      # the bridge's sweep queues it after the delay, not now

    def test_every_failed_job_must_have_failed_outside_the_pr(self):
        github = self.github({'hosted fast: Mac rest': self.SETUP, 'hosted app: build (no tests)': self.TEST})
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
        self.assertIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)
        self.assertEqual(github.deletes, ['issues/7/labels/automerge'])

    def test_a_failed_test_step_is_a_failure_at_once(self):
        github = self.github({'hosted fast: Mac rest': self.TEST})
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
        self.assertIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)

    def test_a_second_setup_failure_is_held_as_a_failure(self):
        first = self.github({'hosted fast: Mac rest': self.SETUP})
        mq.notify(first, event(), out=io.StringIO())
        told = [{'body': first.posts[0][1]['body'].replace(LIVE, 'f' * 40), 'user': {'login': mq.BOT}}]   # the earlier group's comment
        github = self.github({'hosted fast: Mac rest': self.SETUP}, comments=told)
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
        comment = github.posts[0][1]['body']
        self.assertIn('held as a failure this time', comment)
        self.assertNotIn('setup-retry not-before', comment)   # a held failure must not start another retry
        self.assertIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)
        self.assertEqual(github.deletes, ['issues/7/labels/automerge'])

    def test_a_pr_without_automerge_is_never_retried_here(self):
        # An owner-tap PR would be queued by the bridge without his tap, and a hand-tapped Merge would spend its one
        # retry on nothing: both get the plain failure, as before #4940.
        github = self.github({'hosted fast: Mac rest': self.SETUP})
        self.assertEqual(mq.notify(github, event(armed=False), out=io.StringIO()), 'told')
        self.assertNotIn('setup-retry', github.posts[0][1]['body'])
        self.assertNotIn('held as a failure', github.posts[0][1]['body'])
        self.assertEqual(github.deletes, [])

    def test_a_marker_from_anyone_but_the_workflow_does_not_count_as_a_retry(self):
        marker = mq.SETUP_RETRY_MARKER.format(when='2026-11-23T05:30:00Z')
        for login in ('someone', '', None):
            github = self.github({'hosted fast: Mac rest': self.SETUP}, comments=[{'body': marker, 'user': {'login': login}}])
            self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told: setup retry', login)

    def test_the_retry_cap_reads_past_the_first_hundred_comments(self):
        marker = {'body': mq.SETUP_RETRY_MARKER.format(when='2026-11-23T05:30:00Z'), 'user': {'login': mq.BOT}}
        filler = [{'body': 'lane report', 'user': {'login': mq.BOT}}] * 100
        github = self.github({'hosted fast: Mac rest': self.SETUP})
        get = github.get
        github.get = lambda path: (filler if 'issues/7/comments' in path and '&page=1' in path else
                                   [marker] if 'issues/7/comments' in path and '&page=2' in path else get(path))
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')   # held: the marker on page 2 was found
        self.assertIn('held as a failure', github.posts[0][1]['body'])

    def test_a_job_that_cannot_be_read_is_the_prs_failure(self):
        github = self.github({'hosted fast: Mac rest': self.SETUP})
        github.gets['actions/jobs/100'] = mq.ReadFailed('jobs')
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')
        self.assertIn(('issues/7/labels', {'labels': ['needs-fix']}), github.posts)

    def test_a_check_with_no_job_id_is_the_prs_failure(self):
        github = self.github({'hosted fast: Mac rest': self.SETUP})
        for check in github.gets[f'commits/{LIVE}/check-runs']['check_runs']:
            check.pop('id'), check.pop('details_url'), check.pop('html_url')
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')

    def test_the_first_failed_step_decides_not_a_later_one(self):
        # An `if: failure()` upload step after a failed test step also reads `failure` when it fails: the earlier step decides.
        steps = [('Mac rest of the fast plan', 'failure'), ('Run actions/upload-artifact@ea165f8', 'failure')]
        github = self.github({'hosted fast: Mac rest': steps})
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')

    PLAN = [('Mac rest of the fast plan', 'failure')]
    ONNX = ('swift package resolve\nfatal: unable to access \'https://download.onnxruntime.ai/pod.zip\': '
            'SSL certificate problem: certificate has expired\nerror: tools failed')

    def test_a_plan_step_that_ends_in_a_network_error_from_an_outside_host_is_outside_the_pr(self):
        github = self.github({'hosted fast: Mac rest': self.PLAN}, logs={100: self.ONNX})
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told: setup retry')

    def test_a_network_word_without_an_outside_host_on_the_line_is_a_test_failure(self):
        # A test that prints "connection refused" while checking its own error handling is not an outage.
        for log in ('testOfflineBanner: Connection refused (expected)\nFAILED', 'GET https://pypi.org/simple 200 OK\nFAILED 3 tests',
                    'AssertionError: certificate row 3 differs\nFAILED'):
            github = self.github({'hosted fast: Mac rest': self.PLAN}, logs={100: log})
            self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told', log)

    def test_a_failed_test_that_quotes_a_network_error_stays_the_prs(self):
        # #5070's audit: an assertion message can quote an outside host next to "certificate", "TLS" or "HTTP 502".
        quoted = "fatal: unable to access 'https://github.com/x/y': SSL certificate problem: certificate has expired"
        stamp = '2026-11-23T06:48:40.7049815Z '
        for log in (f'Failed: test_cert_log at /work/scripts/tests/test_x.py:12 — {quoted}',
                    f'tools: 41s — FAILED\nProcess exit 1; Failed: test_cert_log at /w/test_x.py:12 — {quoted}',
                    f'FAIL: test_onnx (test_main_t3.Tests)\n{quoted}', f'{quoted}\nFAILED scripts/tests/test_x.py::T::t',
                    '--- FAIL: TestFetch (0.01s)\n    fetch_test.go:9: GET https://github.com/a: HTTP 502',
                    f'{quoted}\nAssertionError: lists differ',
                    f'/w/T.swift:12: error: -[SessionKitTests.T testFetch] : XCTAssertEqual failed: {quoted}',
                    f'{quoted}\n✘ Test fetchFails() recorded an issue at T.swift:9:5',
                    f'{stamp}FAIL: test_onnx (test_main_t3.Tests)\n{stamp}{quoted}'):
            github = self.github({'hosted fast: Mac rest': self.PLAN}, logs={100: log})
            self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told', log)

    # What verify-tests prints when its `tools` step fails on #4795's bad certificate, as the Actions log shows it: the
    # step's own `FAILED` summary line is not a failed test (second audit of #5070).
    VERIFY_TESTS_OUTAGE = '\n'.join('2026-11-21T14:02:1{}.1234567Z {}'.format(i, line) for i, line in enumerate((
        'swift package resolve',
        "fatal: unable to access 'https://download.onnxruntime.ai/pod.zip': SSL certificate problem: certificate has expired",
        'tools: 41s — FAILED',
        "Process exit 1; fatal: unable to access 'https://download.onnxruntime.ai/pod.zip': SSL certificate problem: "
        'certificate has expired (see artifacts/verification/fast-mac-rest/tools.log)',
        'Evidence: artifacts/verification/fast-mac-rest/manifest.json')))

    def test_verify_tests_real_failure_lines_stay_the_prs(self):
        # Third audit of #5070: verify-tests prints its own lines, not the runners'. Build them with its functions.
        import importlib.util
        spec = importlib.util.spec_from_file_location('verify_tests', ROOT / 'scripts/verify-tests.py')
        vt = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vt)
        quoted = "AssertionError: \"fatal: unable to access 'https://github.com/x/y': SSL certificate problem\""
        unittest_lines = vt.report_unittest_failures('ops', [(
            'test_equal (test_main_t3.Sample.test_equal)', '/home/runner/work/r/r/scripts/tests/test_main_t3.py:380',
            quoted)])
        xctest = 'Failed: SessionKitTests/FetchTests/testCert' + vt.failure_reason(
            {'retry_failures': ["GET https://github.com/a/b: HTTP 502 Bad Gateway"]})
        stamp = '2026-11-23T07:20:00.1234567Z '
        for first in (*unittest_lines, xctest):
            for log in (first, f'{first}\nops: 30s — FAILED\nProcess exit 1; {first}',
                        f'{stamp}ops: 30s — FAILED\n{stamp}Process exit 1; {first}'):
                with self.subTest(log=log):
                    self.assertFalse(mq.outside_network_error(log))
                    github = self.github({'hosted fast: Mac rest': self.PLAN}, logs={100: log})
                    self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told')

    def test_verify_tests_own_failed_line_does_not_hide_an_outside_outage(self):
        github = self.github({'hosted fast: Mac rest': self.PLAN}, logs={100: self.VERIFY_TESTS_OUTAGE})
        self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told: setup retry')
        self.assertTrue(mq.outside_network_error(self.VERIFY_TESTS_OUTAGE))

    def test_ssl_and_tls_count_only_as_words(self):
        # #4940 committed `\b` as a literal backspace, so SSL and TLS never matched; as words they do, and not inside
        # another word (#5070 audit).
        for line in ('see https://github.com/a/classless-tlsish 200 OK', 'https://github.com/a/SSLKit fixture loaded'):
            self.assertFalse(mq.outside_network_error(line), line)
        self.assertTrue(mq.outside_network_error('curl https://github.com/a: TLS handshake timeout'))
        self.assertTrue(mq.outside_network_error('pip: SSL: WRONG_VERSION_NUMBER for https://pypi.org/simple'))
        self.assertNotIn('\x08', (ROOT / 'scripts/merge_queue_dequeued.py').read_text())

    def test_a_step_that_runs_the_prs_own_files_needs_the_network_error_too(self):
        # npm ci, pip, go build, LFS pointers and `actions/setup-*` read the PR's own manifests: their failure is the
        # PR's unless the log names an outside host and a network error (review of #4940).
        for step in ('Python tools and Node packages', 'Install packages', 'Fetch LFS files',
                     'Caddy and smserver for the Caddyfile tests', 'Run actions/setup-node@49933ea'):
            github = self.github({'hosted fast: portable': [(step, 'failure')]}, logs={100: 'npm ERR! code EUSAGE lockfile'})
            self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told', step)
            github = self.github({'hosted fast: portable': [(step, 'failure')]}, logs={100: self.ONNX})
            self.assertEqual(mq.notify(github, event(), out=io.StringIO()), 'told: setup retry', step)

    def test_the_log_is_cut_at_the_failing_steps_error_line(self):
        # A real log (2026-11-23): the failing step ends at `##[error]Process completed with exit code 1.`; the steps
        # after it (`if: always()` uploads, post steps) must not push its last lines out of the window.
        lines = ['early step output'] * 500 + ['download.onnxruntime.ai: SSL certificate problem', '##[error]Process completed with exit code 1.'] \
            + ['post step noise'] * 500
        stub = mq.GitHub('o/r', sleep=lambda seconds: None)
        stub._gh = lambda args, data=None: subprocess.CompletedProcess(args, 0, '\n'.join(lines), '')
        tail = stub.log_tail(1)
        self.assertIn('SSL certificate problem', tail)
        self.assertNotIn('post step noise', tail)
        self.assertLessEqual(len(tail.splitlines()), mq.LOG_TAIL_LINES)
        lines[:] = ['no error marker'] * 200
        self.assertEqual(len(stub.log_tail(1).splitlines()), mq.LOG_TAIL_LINES)

    def test_the_log_is_read_only_for_a_plan_step(self):
        github = self.github({'hosted fast: Mac rest': self.SETUP})
        reads = []
        github.log_tail = lambda job_id: reads.append(job_id) or ''
        mq.notify(github, event(), out=io.StringIO())
        self.assertEqual(reads, [])

    def test_a_conflict_or_a_manual_removal_never_looks_at_jobs(self):
        for reason in ('MANUAL', 'INVALID_MERGE_COMMIT', 'MERGE'):
            github = self.github({'hosted fast: Mac rest': self.SETUP})
            mq.notify(github, event(reason=reason), out=io.StringIO())
            self.assertFalse(any(path.startswith('actions/jobs') for path in github.reads), reason)

    def test_the_marker_in_the_comment_is_the_one_the_bridge_reads(self):
        import merge_queue_label_bridge as bridge
        text = mq.SETUP_RETRY_MARKER.format(when=self.WHEN)
        self.assertEqual(bridge.SETUP_RETRY.findall(text), [self.WHEN])
        self.assertEqual(bridge.SETUP_RETRY_MINUTES, int(mq.SETUP_RETRY_DELAY.total_seconds() // 60))


class StepTableTests(unittest.TestCase):
    """Every step of the workflows that run in a merge group has a decision here, so a new step is never classified by
    accident (#4940). `uses:` steps appear in the Actions API as `Run <action>@<ref>`."""

    SETUP, PLAN, TEST = 'setup', 'plan', 'test'
    KINDS = {
        'Start the clock': SETUP, 'Merge the base in (dispatch with a base)': TEST,
        'Read the Go toolchain from go.mod': TEST, 'Caddy and smserver for the Caddyfile tests': PLAN,
        'Python tools and Node packages': PLAN, 'Portable fast plan': PLAN, 'Pipeline harness': TEST,
        'SessionKitCoreTests on Linux': PLAN, 'Keep the Linux test list': TEST, 'Keep the step logs': TEST,
        'Record what was tested, for the lane runner': TEST, 'Report time': TEST,
        'Do the Mac checks have anything to test?': TEST, 'Python tools': PLAN,
        'SessionKit build and SessionKitCoreTests': PLAN, 'List LFS objects': PLAN, 'Fetch LFS files': PLAN,
        'Unpack the compilation cache': SETUP, 'Build the app for the simulator (build-for-testing, no tests)': PLAN,
        'Keep the build log': TEST, 'How long it took': TEST, 'Keep the Mac test list': TEST,
        'Install BlackHole (virtual audio output)': SETUP, 'Changed files': TEST, 'Mac rest of the fast plan': PLAN,
        'Mac build (merge queue, no tests)': PLAN,
        'Cancel the Mac jobs of this run': TEST, 'Tally the Linux retry-passes on': TEST,
        'Alert the owner if this PR is ready for his merge tap': TEST,
        'Start the merge run of each armed PR on this head': TEST, 'Changed web paths': TEST,
        'Is there a web app to test yet?': TEST, 'Install packages': PLAN, 'Build': TEST,
        'Install Playwright browsers': PLAN, 'Speech model cache': SETUP, 'Playwright suite': TEST,
        'List tests that passed on retry': TEST, 'Keep the Playwright report': TEST, 'Check the merge rules': TEST,
    }

    def steps(self):
        import yaml
        for path in sorted((ROOT / '.github/workflows').glob('*.yml')):
            workflow = yaml.safe_load(path.read_text())
            triggers = workflow.get(True) or workflow.get('on') or {}
            if 'merge_group' not in triggers:
                continue
            for job_id, job in workflow['jobs'].items():
                for step in job.get('steps') or []:
                    if step.get('name'):
                        yield path.name, job_id, str(step['name']).strip()
                    else:
                        yield path.name, job_id, 'Run ' + step['uses'].split('@')[0]

    def test_every_named_step_of_a_merge_group_workflow_has_a_decision(self):
        names = {name for _, _, name in self.steps() if not name.startswith('Run ')}
        self.assertEqual(sorted(names - set(self.KINDS)), [], 'a new step: decide whether a failure in it is the PR\'s')
        self.assertEqual(sorted(set(self.KINDS) - names), [], 'a step that no longer exists: remove it from the table')

    def test_the_notifiers_lists_agree_with_the_table(self):
        for name, kind in self.KINDS.items():
            self.assertEqual(mq.step_kind(name), kind, name)

    def test_every_action_step_is_setup_and_the_plan_steps_are_named_in_the_workflows(self):
        for file, job, name in self.steps():
            if name.startswith('Run '):
                kind = 'plan' if name.startswith('Run actions/setup-') else 'setup'
                self.assertEqual(mq.step_kind(name + '@0123456789abcdef'), kind, f'{file} {job} {name}')
        self.assertEqual(mq.step_kind('Post Run actions/cache@abc'), 'setup')
        self.assertEqual(mq.step_kind('A step nobody has heard of'), 'test')
        self.assertEqual(mq.step_kind(None), 'test')
        self.assertEqual(sorted(mq.PLAN_STEPS), sorted(n for n, k in self.KINDS.items() if k == self.PLAN))
        self.assertEqual(mq.step_kind('Run actions/setup-go@40f1582'), 'plan')
        self.assertEqual(sorted(mq.SETUP_STEPS - {'Set up job', 'Initialize containers', 'Complete job'}),
                         sorted(n for n, k in self.KINDS.items() if k == self.SETUP))


class RetryTests(unittest.TestCase):
    def test_reads_retry_then_raise_read_failed(self):
        github = mq.GitHub('o/r', sleep=lambda _: None)
        calls = []

        def failing(args, data=None):
            calls.append(args)
            raise subprocess.CalledProcessError(1, 'gh')
        github._gh = failing
        with self.assertRaises(mq.ReadFailed):
            github.get('pulls/1')
        with self.assertRaises(mq.ReadFailed):
            github.queue_heads()
        self.assertEqual(len(calls), 2 * mq.TRIES)

    def test_a_blip_then_an_answer_reads_the_queue(self):
        github = mq.GitHub('o/r', sleep=lambda _: None)
        answers = [subprocess.CalledProcessError(1, 'gh'),
                   subprocess.CompletedProcess([], 0, stdout='{"data":{"repository":{"mergeQueue":{"entries":'
                                                             '{"nodes":[{"headCommit":{"oid":"%s"}}]}}}}}' % LIVE)]

        def answer(args, data=None):
            value = answers.pop(0)
            if isinstance(value, Exception):
                raise value
            return value
        github._gh = answer
        self.assertEqual(github.queue_heads(), {LIVE})


class WorkflowTests(unittest.TestCase):
    def test_the_workflow_runs_mains_script_on_dequeue_and_no_pr_code(self):
        import yaml
        workflow = yaml.safe_load((ROOT / '.github/workflows/merge-queue-dequeued.yml').read_text())
        self.assertEqual(workflow[True], {'pull_request_target': {'types': ['dequeued']}})
        steps = workflow['jobs']['dequeued']['steps']
        checkout = steps[0]['with']
        self.assertEqual(checkout['ref'], 'main')
        self.assertEqual(checkout['sparse-checkout'], 'scripts/merge_queue_dequeued.py')
        self.assertFalse(checkout['persist-credentials'])
        text = (ROOT / '.github/workflows/merge-queue-dequeued.yml').read_text()
        self.assertNotIn('github.event.pull_request.head', text)  # no PR ref checked out or interpolated


if __name__ == '__main__':
    unittest.main()
