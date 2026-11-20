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

    def delete(self, path):
        if self.post_error:
            raise self.post_error
        self.deletes.append(path)


def run(id_, sha, branch):
    return {'id': id_, 'head_sha': sha, 'head_branch': branch, 'created_at': f'2026-11-19T10:0{id_}:00Z'}


def event(number=7, reason='CI_FAILURE', merged=False):
    return {'reason': reason, 'pull_request': {'number': number, 'merged': merged, 'head': {'sha': OTHER}}}


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

    def test_a_merged_or_manual_removal_keeps_automerge(self):
        for e in (event(reason='MANUAL'), event(reason='DEQUEUED_MANUALLY'), event(merged=True)):
            github = self.github()
            mq.notify(github, e, out=io.StringIO())
            self.assertEqual(github.deletes, [])

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
