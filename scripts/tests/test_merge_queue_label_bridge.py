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
    """The GitHub class's calls, answered from a dict of PRs. `merge_answer` and `disable_answer` are gh's
    (code, text) for `pr merge` and `pr merge --disable-auto`."""

    def __init__(self, prs, merge_answer=(0, ''), disable_answer=(0, ''), comments='', fail_list=False):
        self.prs = prs
        self.merge_answer = merge_answer
        self.disable_answer = disable_answer
        self.existing_comments = comments
        self.fail_list = fail_list
        self.merged, self.disabled, self.dequeued, self.posted, self.removed = [], [], [], [], []

    def pull(self, number):
        return self.prs[number]

    def open_pulls(self):
        if self.fail_list:
            raise bridge.Failed('HTTP 502')
        return [p for _, p in sorted(self.prs.items()) if p['state'] == 'OPEN']

    def comments(self, number):
        return self.existing_comments

    def comment(self, number, body):
        self.posted.append((number, body))

    def remove_label(self, number, name):
        self.removed.append((number, name))

    def merge(self, number):
        self.merged.append(number)
        return self.merge_answer

    def disable_auto(self, number):
        self.disabled.append(number)
        return self.disable_answer

    def dequeue(self, node_id):
        self.dequeued.append(node_id)


def pr(number, title='Fix a thing', draft=False, armed=True, queued=False, auto=None, state='OPEN', extra=()):
    names = (['automerge'] if armed else []) + list(extra)
    auto = (armed or queued) if auto is None else auto
    return {'id': f'PR_{number}', 'number': number, 'isDraft': draft, 'title': title, 'state': state,
            'labels': {'nodes': [{'name': name} for name in names]},
            'autoMergeRequest': {'enabledAt': '2026-11-19T10:00:00Z'} if auto else None,
            'mergeQueueEntry': {'id': f'MQE_{number}'} if queued else None}


def run(github, *argv):
    out = io.StringIO()
    code = bridge.main(['--repo', 'o/r', *argv], github=github, out=out)
    return code, out.getvalue()


HELD_TITLES = [
    'DO NOT MERGE: mutation proof for #4314', 'Throwaway: live proof of the rearm job (do not merge to main)',
    'Mutation proof, do not merge', 'throwaway check', 'Do-not-merge: x', 'DO_NOT_MERGE x', 'do  not merge',
    'do not merge', "Don't merge yet", 'Don’t merge yet', 'Dont merge', 'DNM: proof', '[DNM] proof',
    'WIP: half done', '  wip : half done', '[Throwaway] probe', '(throwaway) probe', '\U0001f9ea Throwaway probe',
    'Probe lane rearm (throwaway)', 'Probe lane rearm - THROWAWAY', 'Ｔｈｒｏｗａｗａｙ probe',
]
QUEUED_TITLES = [
    'Fix a thing', 'dnmx parser', 'Add DNMS support', 'Wipe the cache', 'WIP-free cleanup', 'Don merge tool',
    'Do not mergesort twice', 'Throwaways list in docs', 'Merge queue: do the merge',
]


class TitleTests(unittest.TestCase):
    def test_hold_titles_are_never_queued(self):
        for title in HELD_TITLES:
            with self.subTest(title=title):
                self.assertIsNotNone(bridge.not_queueable(pr(1, title=title)))

    def test_neighbouring_titles_are_queued(self):
        for title in QUEUED_TITLES:
            with self.subTest(title=title):
                self.assertIsNone(bridge.not_queueable(pr(1, title=title)))

    def test_a_draft_is_never_queued(self):
        self.assertEqual(bridge.not_queueable(pr(1, draft=True)), 'it is a draft')


class QueueTests(unittest.TestCase):
    def test_an_armed_pr_is_queued_with_gh_pr_merge(self):
        github = FakeGitHub({7: pr(7, auto=False)})
        code, out = run(github, '--pr', '7', '--action', 'labeled')
        self.assertEqual((code, github.merged), (0, [7]))
        self.assertIn('#7: queued', out)

    def test_drafts_and_hold_titles_are_never_queued_and_get_one_comment(self):
        cases = {1: pr(1, draft=True, auto=False), 2: pr(2, title='DO NOT MERGE: x', auto=False),
                 3: pr(3, title='Throwaway: x', auto=False)}
        for number in cases:
            with self.subTest(number=number):
                github = FakeGitHub(cases)
                code, out = run(github, '--pr', str(number), '--action', 'labeled')
                self.assertEqual((code, github.merged), (0, []))
                self.assertEqual(len(github.posted), 1)
                self.assertIn(bridge.MARKER, github.posted[0][1])
                self.assertIn('not queued', out)

    def test_a_second_label_add_on_a_throwaway_pr_does_not_comment_again(self):
        github = FakeGitHub({3: pr(3, title='Throwaway: x', auto=False)}, comments=f'earlier\n{bridge.MARKER}\nNot')
        run(github, '--pr', '3', '--action', 'labeled')
        self.assertEqual((github.merged, github.posted), ([], []))

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


class NeedsFixTests(unittest.TestCase):
    """Finding 1: a PR whose group failed must not be queued again until someone re-arms it."""

    def test_an_edit_or_sweep_never_queues_a_pr_carrying_needs_fix(self):
        github = FakeGitHub({7: pr(7, auto=False, extra=['needs-fix'])})
        code, out = run(github, '--pr', '7', '--action', 'edited')
        self.assertEqual((code, github.merged, github.removed), (0, [], []))
        self.assertIn('carries `needs-fix`', out)
        code, out = run(github, '--sweep')
        self.assertEqual((code, github.merged, github.removed), (0, [], []))

    def test_adding_automerge_again_removes_needs_fix_and_queues(self):
        github = FakeGitHub({7: pr(7, auto=False, extra=['needs-fix'])})
        code, out = run(github, '--pr', '7', '--action', 'labeled')
        self.assertEqual((code, github.removed, github.merged), (0, [(7, 'needs-fix')], [7]))

    def test_a_dispatch_for_one_pr_does_not_count_as_re_arming(self):
        text = (ROOT / '.github/workflows/merge-queue-label-bridge.yml').read_text()
        self.assertIn('--pr "$PR" --action edited', text)


class RetitleTests(unittest.TestCase):
    """Finding 2: retitling or drafting an armed, queued PR takes it out."""

    def test_retitling_a_queued_pr_to_a_hold_title_turns_auto_merge_off_and_dequeues(self):
        github = FakeGitHub({7: pr(7, title='[DNM] probe', queued=True)})
        code, out = run(github, '--pr', '7', '--action', 'edited')
        self.assertEqual((code, github.disabled, github.dequeued, github.merged), (0, [7], ['PR_7'], []))
        self.assertIn('taken out of the merge queue', out)

    def test_drafting_an_armed_pr_turns_auto_merge_off(self):
        github = FakeGitHub({7: pr(7, draft=True)})
        code, _ = run(github, '--pr', '7', '--action', 'converted_to_draft')
        self.assertEqual((code, github.disabled, github.dequeued), (0, [7], []))

    def test_an_ordinary_edit_of_a_queued_pr_changes_nothing(self):
        github = FakeGitHub({7: pr(7, queued=True)})
        self.assertEqual(run(github, '--pr', '7', '--action', 'edited')[0], 0)
        self.assertEqual((github.disabled, github.dequeued, github.merged), ([], [], []))


class UnqueueTests(unittest.TestCase):
    def test_removing_the_label_turns_auto_merge_off_and_dequeues_a_queued_pr(self):
        github = FakeGitHub({7: pr(7, armed=False, queued=True)})
        code, out = run(github, '--pr', '7', '--action', 'unlabeled')
        self.assertEqual((code, github.disabled, github.dequeued), (0, [7], ['PR_7']))
        self.assertIn('taken out of the merge queue', out)

    def test_removing_it_from_a_pr_not_yet_queued_only_turns_auto_merge_off(self):
        github = FakeGitHub({7: pr(7, armed=False, auto=True)})
        self.assertEqual(run(github, '--pr', '7', '--action', 'unlabeled')[0], 0)
        self.assertEqual((github.disabled, github.dequeued), ([7], []))

    def test_a_label_put_back_before_the_run_leaves_the_pr_queued(self):
        github = FakeGitHub({7: pr(7, queued=True)})
        run(github, '--pr', '7', '--action', 'unlabeled')
        self.assertEqual((github.disabled, github.dequeued), ([], []))

    def test_auto_merge_already_off_counts_as_done(self):
        # Finding 3: gh's wording varies; any "not enabled" reply means there is nothing left to turn off.
        for text in ('auto-merge is not enabled for this pull request',
                     'GraphQL: Pull request does not have auto-merge enabled (disablePullRequestAutoMerge)',
                     "auto merge hasn't been enabled", 'Auto-merge is already disabled'):
            with self.subTest(text=text):
                github = FakeGitHub({7: pr(7, armed=False, auto=True)}, disable_answer=(1, text))
                self.assertEqual(run(github, '--pr', '7', '--action', 'unlabeled')[0], 0)

    def test_a_real_disable_failure_is_red_and_tells_the_pr(self):
        # Nothing retries a failed unqueue, so the author must hear about it.
        github = FakeGitHub({7: pr(7, armed=False, auto=True)}, disable_answer=(1, 'HTTP 502: Bad Gateway'))
        code, out = run(github, '--pr', '7', '--action', 'unlabeled')
        self.assertEqual(code, 1)
        self.assertIn('could not turn auto-merge off', out)
        self.assertEqual(github.posted, [(7, '`automerge` was removed but this PR is still set to merge. Take it out '
                                             'with `gh pr merge 7 --disable-auto` or by hand.')])

    def test_a_failed_dequeue_tells_the_pr(self):
        github = FakeGitHub({7: pr(7, armed=False, queued=True)})

        def fail(node_id):
            raise bridge.Failed('HTTP 502')
        github.dequeue = fail
        code, out = run(github, '--pr', '7', '--action', 'unlabeled')
        self.assertEqual(code, 1)
        self.assertEqual(len(github.posted), 1)
        self.assertIn('still set to merge', github.posted[0][1])

    def test_a_successful_unqueue_posts_nothing(self):
        github = FakeGitHub({7: pr(7, armed=False, queued=True)})
        run(github, '--pr', '7', '--action', 'unlabeled')
        self.assertEqual(github.posted, [])


class SweepTests(unittest.TestCase):
    def test_the_sweep_queues_every_armed_pr_and_skips_the_rest(self):
        github = FakeGitHub({1: pr(1, auto=False), 2: pr(2, title='DO NOT MERGE: x', auto=False),
                             3: pr(3, armed=False), 4: pr(4, auto=False), 5: pr(5, queued=True)})
        code, out = run(github, '--sweep')
        self.assertEqual((code, github.merged), (0, [1, 4]))
        self.assertIn('4 open PRs carry `automerge`', out)

    def test_the_sweep_leaves_a_pr_set_to_merge_without_the_label_alone(self):
        # The owner's own Merge tap on a `.github/` PR, or a maintainer's `gh pr merge`, carries no label.
        github = FakeGitHub({1: pr(1, armed=False, queued=True), 2: pr(2, armed=False, auto=True)})
        self.assertEqual(run(github, '--sweep')[0], 0)
        self.assertEqual((github.disabled, github.dequeued, github.merged), ([], [], []))

    def test_the_sweep_acts_on_each_pr_as_it_is_now_not_as_listed(self):
        # Stopped after the list was read: label removed, needs-fix added by a failed group, retitled DNM.
        listed = {1: pr(1, auto=False), 2: pr(2, auto=False), 3: pr(3, auto=False), 4: pr(4, auto=False)}
        now = {1: pr(1, armed=False, auto=False), 2: pr(2, auto=False, extra=['needs-fix']),
               3: pr(3, title='DNM: x', auto=False), 4: pr(4, auto=False)}
        github = FakeGitHub(now, comments=bridge.MARKER)
        github.open_pulls = lambda: [listed[n] for n in sorted(listed)]
        self.assertEqual(run(github, '--sweep')[0], 0)
        self.assertEqual(github.merged, [4])

    def test_an_unreadable_pr_list_turns_the_run_red(self):
        code, out = run(FakeGitHub({}, fail_list=True), '--sweep')
        self.assertEqual(code, 1)
        self.assertIn('could not reach GitHub', out)

    def test_one_failed_pr_does_not_stop_the_others_but_turns_the_run_red(self):
        github = FakeGitHub({1: pr(1, auto=False), 2: pr(2, auto=False), 3: pr(3, auto=False)})
        answers = {2: (1, 'HTTP 502')}
        github.merge = lambda n: (github.merged.append(n), answers.get(n, (0, '')))[1]
        code, out = run(github, '--sweep')
        self.assertEqual((code, github.merged), (1, [1, 2, 3]))
        self.assertIn('#2: could not queue', out)


class GhRetryTests(unittest.TestCase):
    def test_an_auto_merge_off_reply_is_not_retried(self):
        github = bridge.GitHub('o/r', sleep=lambda _: None)
        calls = []

        class Done:
            returncode, stdout, stderr = 1, '', 'Pull request does not have auto-merge enabled'
        original = bridge.subprocess.run
        bridge.subprocess.run = lambda *a, **k: (calls.append(a), Done)[1]
        try:
            code, _ = github.disable_auto(7)
        finally:
            bridge.subprocess.run = original
        self.assertEqual((code, len(calls)), (1, 1))


class Ctx:
    """A GitHub expression context: missing properties are null and falsy, as in Actions."""

    def __init__(self, value):
        self.value = value

    def __getattr__(self, name):
        value = self.value.get(name) if isinstance(self.value, dict) else None
        return Ctx(value) if isinstance(value, dict) or value is None else value

    def __bool__(self):
        return bool(self.value)

    def __eq__(self, other):
        return False

    __hash__ = object.__hash__


def evaluate(expression, github, merge_queue='on', pr_input=''):
    """Evaluate the small subset of GitHub expressions this workflow uses (||, &&, ==, parentheses, paths)."""
    python = expression.replace('||', ' or ').replace('&&', ' and ')
    # contains(github.event.pull_request.labels.*.name, 'x'): the one `.*` filter this workflow uses
    python = re.sub(r"contains\(github\.event\.pull_request\.labels\.\*\.name,\s*'([^']+)'\)", r"has_label('\1')", python)
    names = [label.get('name') for label in ((github.get('event') or {}).get('pull_request') or {}).get('labels') or []]
    return eval(f'({python})', {'__builtins__': {}},  # noqa: S307 - our own workflow file, test only
                {'github': Ctx(github), 'vars': Ctx({'MERGE_QUEUE': merge_queue}), 'inputs': Ctx({'pr': pr_input}),
                 'has_label': lambda name: name in names})


def interpolate(template, github):
    return re.sub(r'\$\{\{(.*?)\}\}', lambda m: str(evaluate(m.group(1), github)), template)


def event(action, armed=None, **extra):
    pull = {'number': 7}
    if armed is not None:
        pull['labels'] = [{'name': 'automerge'}] if armed else [{'name': 'docs'}]
    payload = {'action': action, 'pull_request': pull, **extra}
    return {'event_name': 'pull_request_target', 'event': payload}


class WorkflowExpressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import yaml
        workflow = yaml.safe_load((ROOT / '.github/workflows/merge-queue-label-bridge.yml').read_text())
        cls.job, cls.workflow_on = workflow['jobs']['bridge'], workflow[True]

    def runs(self, github):
        return bool(evaluate(self.job['if'], github))

    def group(self, github):
        return interpolate(self.job['concurrency']['group'], github)

    def test_an_edit_run_never_shares_a_group_with_a_label_run(self):
        # A group keeps only its newest pending run: an `edited` run must not replace a pending `unlabeled` one.
        label = self.group(event('unlabeled', label={'name': 'automerge'}))
        self.assertEqual(label, self.group(event('labeled', label={'name': 'automerge'})))
        self.assertNotEqual(label, self.group(event('edited', changes={'title': {'from': 'x'}})))
        self.assertNotEqual(label, self.group(event('converted_to_draft')))
        self.assertIn('-7-', label)

    def test_a_body_only_edit_does_not_run_the_job(self):
        self.assertFalse(self.runs(event('edited', changes={'body': {'from': 'old'}})))
        self.assertTrue(self.runs(event('edited', changes={'title': {'from': 'old'}})))

    def test_a_pr_event_checks_an_armed_pr_and_skips_one_that_is_not_armed(self):
        # #4866: the PR's own events replace the 15-minute sweep. A push to an unarmed PR starts no job at all.
        for action in ('opened', 'reopened', 'synchronize', 'ready_for_review'):
            with self.subTest(action):
                self.assertTrue(self.runs(event(action, armed=True)))
                self.assertFalse(self.runs(event(action, armed=False)))
                self.assertFalse(self.runs(event(action)))

    def test_no_check_finishing_starts_a_sweep(self):
        # A sweep when a check finishes would queue a PR whose merge group just failed (or that was taken out by hand)
        # before merge_queue_dequeued.py took `automerge` off it: a second failing group (ci_model scenario d).
        self.assertNotIn('workflow_run', self.workflow_on)

    def test_which_events_run_the_job(self):
        self.assertTrue(self.runs(event('labeled', label={'name': 'automerge'})))
        self.assertTrue(self.runs(event('unlabeled', label={'name': 'automerge'})))
        self.assertFalse(self.runs(event('labeled', label={'name': 'docs'})))
        self.assertTrue(self.runs(event('converted_to_draft')))
        self.assertTrue(self.runs({'event_name': 'schedule', 'event': {}}))
        self.assertFalse(bool(evaluate(self.job['if'], {'event_name': 'schedule', 'event': {}}, merge_queue='')))


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

    def test_retitles_and_drafts_trigger_the_check(self):
        types = self.workflow[True]['pull_request_target']['types']
        self.assertEqual(set(types), {'labeled', 'unlabeled', 'edited', 'converted_to_draft', 'opened', 'reopened',
                                      'synchronize', 'ready_for_review'})
        condition = self.workflow['jobs']['bridge']['if']
        for action in bridge.CHECK_ACTIONS:
            self.assertIn(f"github.event.action == '{action}'", condition)

    def test_concurrency_is_on_the_job_so_skipped_runs_never_replace_a_pending_one(self):
        self.assertNotIn('concurrency', self.workflow)
        concurrency = self.workflow['jobs']['bridge']['concurrency']
        self.assertFalse(concurrency['cancel-in-progress'])
        self.assertIn('pull_request.number', concurrency['group'])

    def test_it_runs_main_s_script_and_no_pr_code(self):
        on = self.workflow[True]
        self.assertNotIn('pull_request', on)
        checkout = self.workflow['jobs']['bridge']['steps'][0]
        self.assertEqual(checkout['with']['ref'], 'main')
        self.assertEqual(checkout['with']['sparse-checkout'], 'scripts/merge_queue_label_bridge.py')
        self.assertFalse(checkout['with']['persist-credentials'])
        self.assertNotIn('github.head_ref', self.text)
        self.assertNotIn('pull_request.head.ref', self.text)
        self.assertFalse(re.search(r'\$\{\{[^}]*\}\}', self.workflow['jobs']['bridge']['steps'][1]['run']))

    def test_it_names_the_lane_jobs_that_must_stop_at_switch_over(self):
        for job in ('route', 'automerge', 'automerge-mac', 'release'):
            self.assertIn(f'`{job}`', self.text)


if __name__ == '__main__':
    unittest.main()
