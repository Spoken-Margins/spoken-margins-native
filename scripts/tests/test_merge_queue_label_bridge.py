"""scripts/merge_queue_label_bridge.py: the `automerge` label queues a PR, never a draft or throwaway one (#4693)."""
import io
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))

import merge_queue_label_bridge as bridge  # noqa: E402


class FakeGitHub:
    """The GitHub class's calls, answered from a dict of PRs. `merge_answer` is gh's (code, text) for `pr merge`."""

    def __init__(self, prs, merge_answer=(0, ''), comments='', fail_reads=()):
        self.prs = prs
        self.merge_answer = merge_answer
        self.existing_comments = comments
        self.fail_reads = set(fail_reads)
        self.merged, self.disabled, self.dequeued, self.posted = [], [], [], []

    def pull(self, number):
        if number in self.fail_reads:
            raise bridge.Failed('HTTP 502')
        return self.prs[number]

    def armed_numbers(self):
        return sorted(n for n, pr in self.prs.items() if 'automerge' in bridge.labels(pr))

    def comments(self, number):
        return self.existing_comments

    def comment(self, number, body):
        self.posted.append((number, body))

    def merge(self, number):
        self.merged.append(number)
        return self.merge_answer

    def disable_auto(self, number):
        self.disabled.append(number)
        return (0, '')

    def dequeue(self, node_id):
        self.dequeued.append(node_id)


def pr(number, title='Fix a thing', draft=False, armed=True, queued=False, state='OPEN'):
    return {'id': f'PR_{number}', 'isDraft': draft, 'title': title, 'state': state,
            'labels': {'nodes': [{'name': 'automerge'}] if armed else []},
            'mergeQueueEntry': {'id': f'MQE_{number}'} if queued else None}


def run(github, *argv):
    out = io.StringIO()
    code = bridge.main(['--repo', 'o/r', *argv], github=github, out=out)
    return code, out.getvalue()


class QueueTests(unittest.TestCase):
    def test_an_armed_pr_is_queued_with_gh_pr_merge(self):
        github = FakeGitHub({7: pr(7)})
        code, out = run(github, '--pr', '7', '--action', 'labeled')
        self.assertEqual((code, github.merged), (0, [7]))
        self.assertIn('#7: queued', out)

    def test_drafts_and_throwaway_titles_are_never_queued_and_get_one_comment(self):
        cases = {1: pr(1, draft=True), 2: pr(2, title='DO NOT MERGE: mutation proof for #4314'),
                 3: pr(3, title='Throwaway: live proof of the rearm job (do not merge to main)'),
                 4: pr(4, title='Mutation proof, do not merge'), 5: pr(5, title='throwaway check')}
        for number in cases:
            with self.subTest(number=number):
                github = FakeGitHub(cases)
                code, out = run(github, '--pr', str(number), '--action', 'labeled')
                self.assertEqual((code, github.merged), (0, []))
                self.assertEqual(len(github.posted), 1)
                self.assertIn(bridge.MARKER, github.posted[0][1])
                self.assertIn('not queued', out)

    def test_a_second_label_add_on_a_throwaway_pr_does_not_comment_again(self):
        github = FakeGitHub({3: pr(3, title='Throwaway: x')}, comments=f'earlier\n{bridge.MARKER}\nNot queued')
        run(github, '--pr', '3', '--action', 'labeled')
        self.assertEqual((github.merged, github.posted), ([], []))

    def test_a_title_that_only_mentions_throwaway_later_is_queued(self):
        github = FakeGitHub({8: pr(8, title='Delete the throwaway fixture')})
        run(github, '--pr', '8', '--action', 'labeled')
        self.assertEqual(github.merged, [8])

    def test_already_queued_or_auto_merge_already_on_counts_as_done(self):
        github = FakeGitHub({7: pr(7, queued=True)})
        self.assertEqual(run(github, '--pr', '7', '--action', 'labeled')[0], 0)
        self.assertEqual(github.merged, [])
        github = FakeGitHub({7: pr(7)}, merge_answer=(1, 'Pull request #7 is already queued to merge'))
        self.assertEqual(run(github, '--pr', '7', '--action', 'labeled')[0], 0)

    def test_a_refused_merge_is_red_so_the_sweep_tries_again(self):
        github = FakeGitHub({7: pr(7)}, merge_answer=(1, 'GraphQL: Resource not accessible by integration'))
        code, out = run(github, '--pr', '7', '--action', 'labeled')
        self.assertEqual(code, 1)
        self.assertIn('could not queue', out)

    def test_a_closed_pr_or_one_whose_label_is_gone_is_left_alone(self):
        github = FakeGitHub({7: pr(7, state='MERGED'), 9: pr(9, armed=False)})
        self.assertEqual(run(github, '--pr', '7', '--action', 'labeled')[0], 0)
        self.assertEqual(run(github, '--pr', '9', '--action', 'labeled')[0], 0)
        self.assertEqual(github.merged, [])

    def test_another_label_does_nothing(self):
        github = FakeGitHub({7: pr(7)})
        self.assertEqual(run(github, '--pr', '7', '--action', 'labeled', '--label', 'needs-fix')[0], 0)
        self.assertEqual(github.merged, [])


class UnqueueTests(unittest.TestCase):
    def test_removing_the_label_turns_auto_merge_off_and_dequeues_a_queued_pr(self):
        github = FakeGitHub({7: pr(7, armed=False, queued=True)})
        code, out = run(github, '--pr', '7', '--action', 'unlabeled')
        self.assertEqual((code, github.disabled, github.dequeued), (0, [7], ['PR_7']))
        self.assertIn('taken out of the merge queue', out)

    def test_removing_it_from_a_pr_not_yet_queued_only_turns_auto_merge_off(self):
        github = FakeGitHub({7: pr(7, armed=False)})
        self.assertEqual(run(github, '--pr', '7', '--action', 'unlabeled')[0], 0)
        self.assertEqual((github.disabled, github.dequeued), ([7], []))

    def test_a_label_put_back_before_the_run_leaves_the_pr_queued(self):
        # A remove-and-re-add (the audit's re-arm) must not end with the PR out of the queue.
        github = FakeGitHub({7: pr(7, queued=True)})
        run(github, '--pr', '7', '--action', 'unlabeled')
        self.assertEqual((github.disabled, github.dequeued), ([], []))


class SweepTests(unittest.TestCase):
    def test_the_sweep_queues_every_armed_pr_and_skips_the_rest(self):
        github = FakeGitHub({1: pr(1), 2: pr(2, title='DO NOT MERGE: x'), 3: pr(3, armed=False), 4: pr(4),
                             5: pr(5, queued=True)})
        code, out = run(github, '--sweep')
        self.assertEqual((code, github.merged), (0, [1, 4]))
        self.assertIn('4 open PRs carry `automerge`', out)

    def test_one_unreadable_pr_does_not_stop_the_others_but_turns_the_run_red(self):
        github = FakeGitHub({1: pr(1), 2: pr(2), 3: pr(3)}, fail_reads={2})
        code, out = run(github, '--sweep')
        self.assertEqual((code, github.merged), (1, [1, 3]))
        self.assertIn('#2: could not read', out)


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import yaml
        cls.text = (ROOT / '.github/workflows/merge-queue-label-bridge.yml').read_text()
        cls.workflow = yaml.safe_load(cls.text)

    def test_every_job_is_inert_until_the_merge_queue_variable_is_on(self):
        for name, job in self.workflow['jobs'].items():
            with self.subTest(job=name):
                self.assertTrue(job['if'].startswith("vars.MERGE_QUEUE == 'on' &&"), job['if'])

    def test_it_runs_main_s_script_and_no_pr_code(self):
        on = self.workflow[True]
        self.assertEqual(on['pull_request_target'], {'types': ['labeled', 'unlabeled']})
        self.assertNotIn('pull_request', on)
        checkout = self.workflow['jobs']['bridge']['steps'][0]
        self.assertEqual(checkout['with']['ref'], 'main')
        self.assertEqual(checkout['with']['sparse-checkout'], 'scripts/merge_queue_label_bridge.py')
        self.assertFalse(checkout['with']['persist-credentials'])
        self.assertNotIn('github.head_ref', self.text)
        self.assertNotIn('pull_request.head.ref', self.text)
        # PR data reaches the shell only through env, never interpolated into the script.
        self.assertFalse(re.search(r'\$\{\{[^}]*\}\}', self.workflow['jobs']['bridge']['steps'][1]['run']))

    def test_it_names_the_lane_jobs_that_must_stop_at_switch_over(self):
        for job in ('route', 'automerge', 'automerge-mac', 'release'):
            self.assertIn(f'`{job}`', self.text)


if __name__ == '__main__':
    unittest.main()
