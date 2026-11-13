"""scripts/design_queue.py (#3866): what the design pass takes next. No network: issues are in `gh issue list --json`
shape. The starting queue is the real file, ops/claude/design-queue.json, checked against the order on #4187."""
import datetime as dt
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import design_queue as dq  # noqa: E402

NOW = dt.datetime(2026, 11, 12, 22, 0, tzinfo=dt.timezone.utc)


def at(**delta):
    return (NOW - dt.timedelta(**delta)).strftime('%Y-%m-%dT%H:%M:%SZ')


def comment(body, when=None, association='MEMBER', login='uncomposed'):
    return {'body': body, 'createdAt': when or at(hours=1), 'authorAssociation': association,
            'author': {'login': login}}


def stop(designed, of=6, when=None):
    return comment(f'Thread "Claude Mac worker 1" stopping: design pass, {designed} of {of} designed · capped', when)


def issue(number, labels=('needs-design',), created='2026-11-01T00:00:00Z', body='', comments=(), milestone=None,
          title=None):
    return {'number': number, 'title': title or f'Issue {number}', 'labels': [{'name': n} for n in labels],
            'createdAt': created, 'body': body, 'comments': list(comments), 'state': 'OPEN',
            'milestone': {'title': milestone} if milestone else None}


EMPTY = {'hold': {}, 'batches': []}


class DesignHeading(unittest.TestCase):
    """The matching rule, with its neighbours (AGENTS.md: a table of lookalike inputs before trusting a matcher)."""

    def test_headings_that_are_design_comments(self):
        for body in ('**Design**\n\n1. Flow', '## Design', '# Design\nx', '**Design (batch 1, 2 of 8)**',
                     '**Design:** the flow', '  **Design**  \n', '\n\n**Design**', '__Design__', '**Design** — v2',
                     '### Design (revised)'):
            with self.subTest(body=body):
                self.assertTrue(dq.is_design_comment(comment(body)))

    def test_lookalikes_that_are_not(self):
        for body in ('## Design pass: a friend\'s arrival (status)', 'Designed by hand', '**Design question**',
                     'Design comment needed', 'The **Design** comment is below', '', '**Decision for Cole**',
                     '**Designer notes**', 'Thread "Claude Mac worker 1" stopping: design pass, 0 of 3 designed',
                     '> **Design**'):
            with self.subTest(body=body):
                self.assertFalse(dq.is_design_comment(comment(body)))

    def test_only_trusted_authors_design(self):
        self.assertFalse(dq.is_design_comment(comment('**Design**', association='NONE', login='someone')))
        self.assertFalse(dq.is_design_comment(comment('**Design**', association='CONTRIBUTOR', login='someone')))
        self.assertTrue(dq.is_design_comment(comment('**Design**', association='OWNER')))


class Waiting(unittest.TestCase):
    def sort(self, *issues, queue=EMPTY):
        out = dq.classify(list(issues), queue, NOW)
        return {k: [i['number'] for i in v] for k, v in out.items()}

    def test_each_state(self):
        out = self.sort(
            issue(1), issue(2, labels=('needs-design', 'blocked')), issue(3, comments=[comment('**Design**')]),
            issue(4, milestone='Later'), issue(5, labels=('ready',)), issue(6, comments=[stop(0, when=at(minutes=5))]),
            issue(7, comments=[stop(0, when=at(days=2)), stop(0, when=at(days=1))]), issue(8),
            queue={'hold': {8: 'by hand'}, 'batches': []})
        self.assertEqual(out, {'waiting': [1], 'held': [2, 4, 8], 'designed_unlabelled': [3], 'cooling': [6],
                               'stuck': [7]})

    def test_a_decision_card_waits_on_the_owner_not_the_pass(self):
        self.assertEqual(self.sort(issue(1, labels=('needs-design', 'needs-owner')))['held'], [1])

    def test_a_run_paces_every_member_it_names_not_only_its_anchor(self):
        def run(designed, when, fault=False):
            text = ('design pass not run · Batch: #10, #11. claude failed (fault)' if fault else
                    f'design pass, {designed} of 2 designed · Batch: #10, #11. Left: #10, #11.')
            return comment(f'Thread "Claude Mac worker 1" stopping: {text}', when)
        for name, notes, expect in (
                ('just ran', [run(0, at(minutes=5))], 'cooling'),
                ('two empty runs', [run(0, at(days=2)), run(0, at(days=1))], 'stuck'),
                ('three faults today', [run(0, at(hours=h), fault=True) for h in (3, 2, 1)], 'stuck'),
                ('one empty run a day ago', [run(0, at(days=1))], 'waiting')):
            with self.subTest(name):
                out = self.sort(issue(10, comments=notes), issue(11))
                self.assertIn(11, out[expect])
        stranger = dict(run(0, at(minutes=5)), authorAssociation='NONE', author={'login': 'x'})
        self.assertEqual(self.sort(issue(10, comments=[stranger]), issue(11))['waiting'], [10, 11])

    def test_progress_or_age_unsticks_an_anchor(self):
        for name, notes in (('one empty run', [stop(0, when=at(days=1))]),
                            ('an empty run then progress', [stop(0, when=at(days=2)), stop(2, when=at(days=1))]),
                            ('empty runs over a week ago', [stop(0, when=at(days=9)), stop(0, when=at(days=8))]),
                            ('a stranger\'s copies', [dict(stop(0, when=at(days=2)), authorAssociation='NONE',
                                                           author={'login': 'x'}),
                                                      dict(stop(0, when=at(days=1)), authorAssociation='NONE',
                                                           author={'login': 'x'})])):
            with self.subTest(name):
                self.assertEqual(self.sort(issue(1, comments=notes))['waiting'], [1])


class NextBatch(unittest.TestCase):
    def test_the_queue_goes_first_cut_to_what_still_waits(self):
        queue = {'hold': {}, 'batches': [{'name': 'A', 'issues': [10, 11, 12]}, {'name': 'B', 'issues': [20]}]}
        issues = [issue(10, comments=[comment('**Design**')]), issue(11), issue(12), issue(20), issue(1, labels=(
            'needs-design', 'priority'))]
        self.assertEqual(dq.next_batch(issues, queue, NOW), {'name': 'A', 'issues': [11, 12], 'source': 'queue'})

    def test_a_finished_batch_gives_way_to_the_next(self):
        queue = {'hold': {}, 'batches': [{'name': 'A', 'issues': [10]}, {'name': 'B', 'issues': [20, 21]}]}
        batch = dq.next_batch([issue(10, labels=('ready',)), issue(20), issue(21)], queue, NOW)
        self.assertEqual((batch['name'], batch['issues']), ('B', [20, 21]))

    def test_a_stuck_issue_rides_along_but_never_anchors(self):
        stuck = [stop(0, when=at(days=2)), stop(0, when=at(days=1))]
        queue = {'hold': {}, 'batches': [{'name': 'A', 'issues': [10, 11]}]}
        self.assertEqual(dq.next_batch([issue(10, comments=stuck), issue(11)], queue, NOW)['issues'], [11, 10])
        self.assertIsNone(dq.next_batch([issue(10, comments=stuck)], queue, NOW))

    def test_the_anchor_leads_even_behind_a_stuck_rider(self):
        # The worker re-checks numbers[0]; a stuck issue there would skip the run every tick and starve the queue.
        stuck = [stop(0, when=at(days=2)), stop(0, when=at(days=1))]
        queue = {'hold': {}, 'batches': [{'name': 'A', 'issues': [1, 2, 3]}, {'name': 'B', 'issues': [9]}]}
        batch = dq.next_batch([issue(1, comments=stuck), issue(3), issue(9)], queue, NOW)
        self.assertEqual(batch['issues'], [3, 1])

    def test_a_failing_batch_does_not_re_anchor_on_its_next_member(self):
        note = comment('Thread "Claude Mac worker 1" stopping: design pass, 0 of 3 designed · Batch: #10, #11, #12.',
                       at(minutes=5))
        queue = {'hold': {}, 'batches': [{'name': 'A', 'issues': [10, 11, 12]}, {'name': 'B', 'issues': [20]}]}
        batch = dq.next_batch([issue(10, comments=[note]), issue(11), issue(12), issue(20)], queue, NOW)
        self.assertEqual((batch['name'], batch['issues']), ('B', [20]))

    def test_after_the_queue_priority_then_oldest_with_its_flow(self):
        issues = [issue(30, created='2026-10-01T00:00:00Z', body='Part of #9'),
                  issue(31, created='2026-11-05T00:00:00Z', labels=('needs-design', 'priority'), body='Part of #3216'),
                  issue(32, created='2026-11-06T00:00:00Z', body='Part of #3216.'),
                  issue(33, created='2026-11-07T00:00:00Z', body='Follows on from #31'),
                  issue(34, created='2026-09-01T00:00:00Z', body='Part of #77')]
        batch = dq.next_batch(issues, EMPTY, NOW)
        self.assertEqual((batch['source'], batch['issues']), ('flow', [31, 32, 33]))
        self.assertTrue(batch['name'].startswith('#31 '))

    def test_queued_issues_are_not_pulled_into_a_flow_batch(self):
        queue = {'hold': {}, 'batches': [{'name': 'A', 'issues': [40]}]}
        issues = [issue(40, labels=('needs-design', 'blocked'), body='Part of #5'), issue(41, body='Part of #5')]
        self.assertEqual(dq.next_batch(issues, queue, NOW)['issues'], [41])

    def test_a_batch_is_capped(self):
        issues = [issue(100 + n, body='Part of #5', created=f'2026-11-0{1 + n % 9}T00:00:00Z') for n in range(12)]
        self.assertEqual(len(dq.next_batch(issues, EMPTY, NOW)['issues']), dq.MAX_BATCH)

    def test_nothing_waiting_is_none(self):
        self.assertIsNone(dq.next_batch([issue(1, labels=('ready',))], EMPTY, NOW))


class StartingQueue(unittest.TestCase):
    """The file the worker reads matches #4187's order on 2026-11-12, and holds the batch designed by hand."""

    def test_batches_and_hold(self):
        queue = dq.load_queue()
        self.assertEqual([b['issues'][0] for b in queue['batches']], [4101, 3902, 3731, 3839, 3862, 4018, 3769])
        self.assertEqual(sorted(queue['hold']), [3782, 3788, 3789, 3790, 3794, 3800, 3801, 3889, 3890])
        every = [n for b in queue['batches'] for n in b['issues']]
        self.assertEqual(len(every), len(set(every)))
        self.assertFalse(set(every) & set(queue['hold']))
        self.assertTrue(all(len(b['issues']) <= dq.MAX_BATCH for b in queue['batches']))


if __name__ == '__main__':
    unittest.main()
