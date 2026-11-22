"""The automerge run takes the hosted fast checks' PASS and runs only --plan fast-mac-rest on the Mac (#1389).

Over the three days to 2026-10-18 the lane spent about 76 Mac-hours on 322 host-only automerge runs (14 minutes
each), most of it on steps a GitHub-hosted runner can run once the repo is public. What these tests guard: the
runner never takes a hosted result for a commit it didn't test (another head, another tree, a next that moved in
ways that matter, a check that didn't pass), and with the switch off nothing changes. The VPS pair in linux-t1.yml
(#2160) was read here until #2442 retired it.
"""
import contextlib
import copy as copy_module
import io
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import lane, verification  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ON = {'LANE_HOSTED_FAST': 'on'}


def notice(plan, tree, base, head, title='lane-hosted-tested', level='notice'):
    return {'title': title, 'annotation_level': level, 'message': f'plan={plan} tree={tree} parents={base} {head}'}


class FakeChecks:
    """The GitHub API reads hosted_fast_records makes: check runs on a head, one run's annotations and, for a failed
    check, when automerge was added to the PR."""

    def __init__(self, runs, annotations, pr=None, armed=(), removed=()):
        self.repo, self.runs, self.annotations, self.calls = 'o/r', runs, annotations, []
        # When `automerge` was added to the PR and when it was removed (#4584).
        self.pr, self.armed, self.removed = pr, list(armed), list(removed)

    def api(self, *args):
        path = args[-1]
        self.calls.append(path)
        if '/events' in path:  # `--paginate --jq` prints one line per matching event
            return ''.join([f'{when} labeled\n' for when in self.armed]
                           + [f'{when} unlabeled\n' for when in self.removed])
        if '/annotations' in path:
            return json.dumps(self.annotations[int(path.split('/')[-2])])
        name = next(name for name in {**lane.HOSTED_FAST_CHECKS, **lane.HOSTED_MERGED_CHECKS}
                    if 'check_name=' + lane.urllib.parse.quote(name, safe='') + '&' in path)
        return json.dumps({'check_runs': self.runs.get(name, [])})


def passing(head, base='d' * 40, tree='e' * 40, checks=None, **changes):
    """FakeChecks where both hosted checks (or <checks>) passed on <head>, each with its notice; changes override a run's
    fields."""
    runs, annotations = {}, {}
    for index, (name, plan) in enumerate((checks or lane.HOSTED_FAST_CHECKS).items(), start=1):
        run = {'id': index, 'status': 'completed', 'conclusion': 'success', 'app': {'slug': 'github-actions'},
               'started_at': '2026-10-18T10:00:00Z', 'html_url': f'https://example.test/run/{index}'}
        run.update(changes.get(name, {}))
        runs[name] = [run]
        annotations[index] = [notice(plan, tree, base, head)]
    return FakeChecks(runs, annotations)


class HostedTestedTests(unittest.TestCase):
    def test_reads_the_one_notice_and_ignores_anything_else(self):
        record = lane.hosted_tested([{'title': 'other', 'annotation_level': 'notice', 'message': 'x'},
                                     notice('fast-portable', 'e' * 40, 'd' * 40, 'a' * 40)])
        self.assertEqual(record, {'plan': 'fast-portable', 'tree': 'e' * 40, 'base': 'd' * 40, 'head': 'a' * 40})

    def test_no_record_from_a_warning_two_notices_or_a_malformed_one(self):
        good = notice('fast-portable', 'e' * 40, 'd' * 40, 'a' * 40)
        for name, annotations in (
                ('none', []),
                ('a warning, not a notice', [{**good, 'annotation_level': 'warning'}]),
                ('two notices', [good, good]),
                ('a short sha', [notice('fast-portable', 'e' * 7, 'd' * 40, 'a' * 40)]),
                ('one parent', [{**good, 'message': f'plan=fast-portable tree={"e" * 40} parents={"d" * 40}'}])):
            with self.subTest(name):
                self.assertIsNone(lane.hosted_tested(annotations))


class HostedRecordsTests(unittest.TestCase):
    HEAD = 'a' * 40

    def test_both_checks_passed_and_said_what_they_tested(self):
        found, why = lane.hosted_fast_records(passing(self.HEAD), self.HEAD)
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))
        self.assertEqual({record['plan'] for record in found.values()}, set(lane.HOSTED_FAST_CHECKS.values()))

    def test_any_missing_unfinished_failed_or_foreign_check_means_no(self):
        portable = 'hosted fast: portable'
        for name, changes, expected in (
                ('not finished', {'status': 'in_progress', 'conclusion': None}, 'had not finished'),
                ('failed', {'conclusion': 'failure'}, 'ended failure'),
                ('skipped (switch off on GitHub)', {'conclusion': 'skipped'}, 'ended skipped'),
                ('another app', {'app': {'slug': 'someone-else'}}, 'no "hosted fast: portable" check')):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(passing(self.HEAD, **{portable: changes}), self.HEAD)
                self.assertIsNone(found)
                self.assertIn(expected, why)

    def test_the_newest_run_decides(self):
        checks = passing(self.HEAD)
        name = 'hosted fast: portable'
        checks.runs[name].append({**checks.runs[name][0], 'id': 9, 'conclusion': 'failure',
                                  'started_at': '2026-10-18T11:00:00Z'})
        checks.annotations[9] = []
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertIsNone(found)
        self.assertIn('ended failure', why)

    def lane_fault(self, message='setup fault: no DNS', title='lane-fault', level='failure'):
        return {'title': title, 'annotation_level': level, 'message': message}

    def failed(self, conclusion, annotations, earlier=()):
        """FakeChecks where "hosted fast: portable" has run id 1 last and failed with <annotations>; <earlier> is a list of
        (conclusion, annotations) for older runs of it on the same head."""
        portable = 'hosted fast: portable'
        checks = passing(self.HEAD, **{portable: {'conclusion': conclusion}})
        checks.annotations[1] = annotations
        for index, (old_conclusion, old_annotations) in enumerate(earlier, start=10):
            checks.runs[portable].append({**checks.runs[portable][0], 'id': index, 'conclusion': old_conclusion,
                                          'started_at': f'2026-10-18T09:0{index - 10}:00Z'})
            checks.annotations[index] = old_annotations
        return checks

    def test_a_check_that_failed_with_a_lane_fault_annotation_is_the_runners_not_the_prs(self):
        # #4085: #4082's swift container had no DNS; `hosted fast: portable` went red on three PRs and the lane said FAIL.
        for conclusion in ('failure', 'timed_out'):
            with self.subTest(conclusion):
                found, why = lane.hosted_fast_records(self.failed(conclusion, [self.lane_fault()]), self.HEAD)
                self.assertIsNone(found)
                self.assertTrue(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertEqual(lane.HOSTED_LANE_FAULT.search(why).group(1), '1')
                self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'INCONCLUSIVE')
                self.assertEqual(lane.hosted_checks_missing(why)[0], 'INCONCLUSIVE')  # even where the Mac is the fallback

    def test_an_ordinary_failure_or_a_lookalike_annotation_is_still_a_fail(self):
        for name, annotations in (
                ('no annotation', []),
                ('another title', [self.lane_fault(title='lane-hosted-tested')]),
                ('the title as a notice', [self.lane_fault(level='notice')]),
                ('the title as a warning', [self.lane_fault(level='warning')]),
                ('the title in the message only', [self.lane_fault(title='error', message='lane-fault')]),
                ('the title with other letters', [self.lane_fault(title='Lane-Fault')]),
                ('an ordinary test failure', [self.lane_fault(title='test failure')])):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(self.failed('failure', annotations), self.HEAD)
                self.assertIsNone(found)
                self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')

    def test_only_a_check_that_failed_can_be_a_lane_fault(self):
        for conclusion in ('cancelled', 'skipped', 'neutral'):
            with self.subTest(conclusion):
                checks = self.failed(conclusion, [self.lane_fault()])
                found, why = lane.hosted_fast_records(checks, self.HEAD)
                self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertFalse(any('/annotations' in call for call in checks.calls))

    def test_a_passing_check_reads_no_extra_annotations(self):
        checks = passing(self.HEAD)
        lane.hosted_fast_records(checks, self.HEAD)
        self.assertFalse(any('filter=all' in call for call in checks.calls))

    def test_the_same_fault_twice_on_one_head_is_a_fail(self):
        # #4085 done-when 3: a fault that keeps happening is the PR's (or the pipeline's) to look at, not retried forever.
        faulty = [self.lane_fault()]
        for name, earlier, marked in (
                ('first fault', [], True),
                ('an ordinary failure before it', [('failure', [])], True),
                ('a cancelled run before it', [('cancelled', faulty)], True),
                ('second fault', [('failure', faulty)], False),
                ('second fault after an ordinary one', [('failure', []), ('timed_out', faulty)], False),
                ('third fault', [('failure', faulty), ('failure', faulty)], False)):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(self.failed('failure', faulty, earlier), self.HEAD)
                self.assertIsNone(found)
                self.assertEqual(bool(lane.HOSTED_LANE_FAULT.search(why)), marked, why)
                self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'INCONCLUSIVE' if marked else 'FAIL')

    def test_a_fault_annotation_another_app_posted_does_not_count_as_an_earlier_one(self):
        faulty = [self.lane_fault()]
        checks = self.failed('failure', faulty, [('failure', faulty)])
        checks.runs['hosted fast: portable'][1]['app'] = {'slug': 'someone-else'}
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertTrue(lane.HOSTED_LANE_FAULT.search(why), why)

    def test_annotations_that_cannot_be_read_leave_the_failure_a_fail(self):
        checks = self.failed('failure', [self.lane_fault()])
        real = checks.api

        def broken(path):
            if '/annotations' in path:
                raise OSError('rate limited')
            return real(path)
        checks.api = broken
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertIsNone(found)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
        self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')

    def test_an_earlier_run_whose_annotations_cannot_be_read_leaves_the_failure_a_fail(self):
        faulty = [self.lane_fault()]
        checks = self.failed('failure', faulty, [('failure', faulty)])
        real = checks.api

        def broken(path):
            if '/annotations' in path and path.split('/')[-2] == '10':
                raise OSError('rate limited')
            return real(path)
        checks.api = broken
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)

    def test_the_annotation_message_is_one_line_with_no_mention(self):
        checks = self.failed('failure', [self.lane_fault('no DNS\n@someone look\n::error::x' + ' y' * 200)])
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertTrue(lane.HOSTED_LANE_FAULT.search(why), why)
        self.assertNotIn('\n', why)
        self.assertNotIn('@', why)
        self.assertLessEqual(len(why), 400)

    def rearmed(self, armed, earlier=(), completed='2026-10-18T10:30:00Z', conclusion='failure', annotations=(),
                removed=('2026-10-18T10:45:00Z',)):
        """A failed "hosted fast: portable" (run 1, finished at <completed>) on PR 7, with `automerge` added at <armed>
        and removed at <removed>."""
        checks = self.failed(conclusion, list(annotations), earlier)
        checks.pr, checks.armed, checks.removed = 7, list(armed), list(removed)
        checks.runs['hosted fast: portable'][0]['completed_at'] = completed
        return checks

    def test_a_failed_check_is_started_again_once_when_automerge_was_added_again_after_it(self):
        # #4584: after #4568 about 68 PRs had automerge removed and re-added; the lane re-read the same failed run and
        # reported it again. The failed run is a fact about the head, so the re-add has to be what starts another.
        for conclusion in ('failure', 'timed_out'):
            with self.subTest(conclusion):
                found, why = lane.hosted_fast_records(
                    self.rearmed(['2026-10-18T09:00:00Z', '2026-10-18T11:00:00Z'], conclusion=conclusion), self.HEAD)
                self.assertIsNone(found)
                self.assertTrue(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertTrue(lane.HOSTED_REARMED.search(why), why)
                self.assertEqual(lane.HOSTED_LANE_FAULT.search(why).group(1), '1')
                verdict, _, _, details = lane.hosted_checks_missing(why, 'INCONCLUSIVE')
                self.assertEqual(verdict, 'INCONCLUSIVE')
                self.assertIn('second failure', details[0])

    def test_the_newest_arming_counts_whatever_order_the_events_come_in(self):
        found, why = lane.hosted_fast_records(self.rearmed(['2026-10-18T11:00:00Z', '2026-10-18T09:00:00Z']), self.HEAD)
        self.assertTrue(lane.HOSTED_REARMED.search(why), why)
        found, why = lane.hosted_fast_records(self.rearmed(['2026-10-18T09:00:00Z', '2026-10-18T10:00:00Z']), self.HEAD)
        self.assertFalse(lane.HOSTED_REARMED.search(why), why)

    def test_a_failure_that_is_the_first_answer_to_the_arming_is_still_a_fail(self):
        # The label was added before the run finished (a PR armed while its checks ran, the audit's re-arm and the rearm
        # job's dispatch all come after the failure and add no label event newer than it): a plain FAIL, as before.
        for name, armed in (('armed before it finished', ['2026-10-18T10:00:00Z']),
                            ('armed at the moment it finished', ['2026-10-18T10:30:00Z']),
                            ('never armed', [])):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(self.rearmed(armed), self.HEAD)
                self.assertIsNone(found)
                self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')

    def test_a_first_arming_after_a_failure_is_not_a_re_add(self):
        # #4584 audit, finding 3: a PR whose checks failed before anyone armed it is answered with that failure; only a
        # removal and a re-add after the lane has answered asks for another try.
        for name, removed in (('never removed', ()),
                              ('removed only before the failure', ('2026-10-18T10:00:00Z',)),
                              ('removed after the newest arming', ('2026-10-18T11:30:00Z',))):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(self.rearmed(['2026-10-18T11:00:00Z'], removed=removed), self.HEAD)
                self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')

    def test_a_re_added_runs_lane_fault_is_a_fail_in_a_later_job_too(self):
        # #4584 audit, finding 2: the rerun outlives the job that started it (an 8-minute wait against mac-rest's 75), so
        # the job that reads its failure starts with nothing remembered. The cap has to come from the head's own runs:
        # run 10 failed with no annotation, automerge was removed and re-added after it, and the rerun (run 1) failed with
        # a lane-fault annotation. Without this, it was started a third time.
        checks = self.rearmed(['2026-10-18T09:00:00Z', '2026-10-18T09:20:00Z'], [('failure', [])],
                              completed='2026-10-18T09:40:00Z', annotations=[self.lane_fault()],
                              removed=('2026-10-18T09:10:00Z',))
        checks.runs['hosted fast: portable'][0]['started_at'] = '2026-10-18T09:25:00Z'
        checks.runs['hosted fast: portable'][1]['completed_at'] = '2026-10-18T09:05:00Z'
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertIsNone(found)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
        self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')
        # The same runs with no re-add between them: the earlier failure was never started again, so the fault is one.
        checks.removed = []
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertIn('with a lane-fault annotation', why)

    def test_a_lane_fault_with_unreadable_events_for_an_earlier_failure_is_a_fail(self):
        checks = self.rearmed(['2026-10-18T09:20:00Z'], [('failure', [])], annotations=[self.lane_fault()])
        real = checks.api

        def broken(*args):
            if '/events' in args[-1]:
                raise OSError('rate limited')
            return real(*args)
        checks.api = broken
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)

    def test_a_second_failure_on_one_head_is_a_fail_however_often_automerge_is_added(self):
        # Run 10 failed at 09:00 and automerge was removed and re-added at 09:10/09:20, before run 1 started at 10:00: run
        # 1 was the lane's one more try, so its failure is final whatever happens to the label after it.
        again, retried = ['2026-10-18T09:20:00Z', '2026-10-18T11:00:00Z'], ('2026-10-18T09:10:00Z', '2026-10-18T10:45:00Z')
        for name, earlier in (('an ordinary failure before it', [('failure', [])]),
                              ('a timeout before it', [('timed_out', [])])):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(self.rearmed(again, earlier, removed=retried), self.HEAD)
                self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')
        # An earlier failure the lane started again for its lane-fault annotation used the try too.
        found, why = lane.hosted_fast_records(self.rearmed(again[-1:], [('failure', [self.lane_fault()])]), self.HEAD)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
        # A cancelled or passing earlier run, or another app's failed one, is not an earlier try of this check.
        for name, earlier in (('a cancelled run before it', [('cancelled', [])]),
                              ('a passing run before it', [('success', [])])):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(self.rearmed(again, earlier, removed=retried), self.HEAD)
                self.assertTrue(lane.HOSTED_REARMED.search(why), why)
        checks = self.rearmed(again, [('failure', [])], removed=retried)
        checks.runs['hosted fast: portable'][1]['app'] = {'slug': 'someone-else'}
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertTrue(lane.HOSTED_REARMED.search(why), why)

    def two_dispatches(self, first=(), rerun=(), armed=('2026-10-18T08:50:00Z', '2026-10-18T09:20:00Z'),
                       removed=('2026-10-18T09:10:00Z',)):
        """PR 7 with two hosted dispatches on one head. W1: portable (run 20) failed at 09:05 with <first>, and
        stop-macs-on-red cancelled Mac rest (run 21). W2 (09:25): portable passed (run 1), Mac rest (run 2) failed at
        09:40 with <rerun>. `automerge` was added at <armed> and removed at <removed>."""
        portable, rest = 'hosted fast: portable', 'hosted fast: Mac rest'
        w2 = {'started_at': '2026-10-18T09:25:00Z'}
        checks = passing(self.HEAD, checks=lane.HOSTED_MERGED_CHECKS,
                         **{portable: w2, rest: {**w2, 'conclusion': 'failure', 'completed_at': '2026-10-18T09:40:00Z'}})
        checks.annotations[2] = list(rerun)
        w1 = {'app': {'slug': 'github-actions'}, 'status': 'completed', 'started_at': '2026-10-18T09:00:00Z',
              'completed_at': '2026-10-18T09:05:00Z'}
        checks.runs[portable].append({**w1, 'id': 20, 'conclusion': 'failure'})
        checks.runs[rest].append({**w1, 'id': 21, 'conclusion': 'cancelled'})
        checks.annotations[20], checks.annotations[21] = list(first), []
        checks.pr, checks.armed, checks.removed = 7, list(armed), list(removed)
        return checks

    def test_the_one_more_try_belongs_to_the_head_not_to_one_check(self):
        # #4584 audit on 78177ac: W1's portable failed and its Mac rest was cancelled; a re-add started W2, whose Mac rest
        # failed on the PR's own code. A second re-add found no earlier failed Mac rest run, so no try used, and started
        # a third run that could merge over W2's red result.
        rest = lane.HOSTED_MERGED_CHECKS
        again = ('2026-10-18T08:50:00Z', '2026-10-18T09:20:00Z', '2026-10-18T09:50:00Z')
        twice = ('2026-10-18T09:10:00Z', '2026-10-18T09:45:00Z')
        fault = [self.lane_fault()]
        for name, checks in (
                ('a second re-add', self.two_dispatches(armed=again, removed=twice)),
                ('a re-add after a lane-fault rerun', self.two_dispatches(fault, armed=again[::2], removed=twice[1:])),
                ('a lane fault after a lane-fault rerun', self.two_dispatches(fault, fault, armed=again[:1], removed=())),
                ('a lane fault after a re-add rerun', self.two_dispatches(rerun=fault))):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(checks, self.HEAD, rest)
                self.assertIsNone(found)
                self.assertIn('"hosted fast: Mac rest" ended failure', why)
                self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')
        # W2 dispatched by hand (no re-add before it): the lane has granted nothing, so a re-add after it is the try.
        found, why = lane.hosted_fast_records(self.two_dispatches(armed=again[::2], removed=twice[1:]), self.HEAD, rest)
        self.assertTrue(lane.HOSTED_REARMED.search(why), why)

    def test_another_checks_fault_in_the_same_dispatch_is_not_an_earlier_try(self):
        # Both jobs of one dispatch hit the runner fault: that is one try, not two (it finished after run 1 started).
        faulty = [self.lane_fault()]
        checks = self.failed('failure', faulty)
        checks.runs['hosted fast: Mac rest'] = [{**checks.runs['hosted fast: portable'][0], 'id': 30,
                                                 'completed_at': '2026-10-18T10:20:00Z'}]
        checks.annotations[30] = faulty
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertIn('with a lane-fault annotation', why)

    def test_failures_someone_re_ran_by_hand_do_not_use_up_the_try(self):
        # #4560 on 2026-11-18: "hosted fast: Mac rest" failed at 13:46, 14:11 and 14:21 on 800b6e8 (a rerun of the failed
        # jobs and a dispatch, no label change between), all on the package-clone fault. automerge was removed and re-added
        # at 17:10 and the lane re-reported the 14:21 failure in 3 s. Counting every earlier failure would leave it so.
        checks = self.rearmed(['2026-10-18T08:00:00Z', '2026-10-18T11:00:00Z'], [('failure', []), ('failure', [])],
                              removed=('2026-10-18T10:45:00Z',))
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertTrue(lane.HOSTED_REARMED.search(why), why)
        self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'INCONCLUSIVE')

    def test_the_failed_run_that_was_started_again_is_a_fail_when_it_fails_too(self):
        # The run the lane starts after the re-add finishes after the label was added: no marker, a FAIL.
        checks = self.rearmed(['2026-10-18T11:00:00Z'], completed='2026-10-18T11:20:00Z')
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')

    def test_a_lane_fault_annotation_keeps_its_own_marker_and_cap(self):
        again = ['2026-10-18T11:00:00Z']
        found, why = lane.hosted_fast_records(self.rearmed(again, annotations=[self.lane_fault()]), self.HEAD)
        self.assertIn('with a lane-fault annotation', why)
        self.assertFalse(lane.HOSTED_REARMED.search(why), why)
        found, why = lane.hosted_fast_records(
            self.rearmed(again, [('failure', [self.lane_fault()])], annotations=[self.lane_fault()]), self.HEAD)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)  # the second fault: a FAIL, even though automerge was re-added

    def test_only_a_check_that_failed_is_started_again_for_a_re_add(self):
        for conclusion in ('cancelled', 'skipped', 'neutral'):
            with self.subTest(conclusion):
                checks = self.rearmed(['2026-10-18T11:00:00Z'], conclusion=conclusion)
                found, why = lane.hosted_fast_records(checks, self.HEAD)
                self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
                self.assertFalse(any('/events' in call for call in checks.calls))

    def test_events_that_cannot_be_read_leave_the_failure_a_fail(self):
        checks = self.rearmed(['2026-10-18T11:00:00Z'])
        real = checks.api

        def broken(*args):
            if '/events' in args[-1]:
                raise OSError('rate limited')
            return real(*args)
        checks.api = broken
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertIsNone(found)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
        self.assertEqual(lane.hosted_checks_missing(why, 'INCONCLUSIVE')[0], 'FAIL')

    def test_no_pr_number_means_no_event_read(self):
        checks = self.failed('failure', [])
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertFalse(lane.HOSTED_LANE_FAULT.search(why), why)
        self.assertFalse(any('/events' in call for call in checks.calls))

    def test_a_record_for_another_plan_or_head_is_not_this_run(self):
        for name, annotation in (('another plan', notice('fast', 'e' * 40, 'd' * 40, self.HEAD)),
                                 ('another head', notice('fast-portable', 'e' * 40, 'd' * 40, 'f' * 40))):
            with self.subTest(name):
                checks = passing(self.HEAD)
                checks.annotations[1] = [annotation]
                found, why = lane.hosted_fast_records(checks, self.HEAD)
                self.assertIsNone(found)
                self.assertIn('did not record', why)


class HostedChecksStandTests(unittest.TestCase):
    """hosted_fast_checks with real git: the tree must match, and next's moves since must not matter."""
    setUp = test_lane_runner.PushTests.setUp
    commit = test_lane_runner.PushTests.commit
    rev = test_lane_runner.PushTests.rev

    def move_next(self, name, text='someone else merged\n'):
        path = self.other / name
        path.parent.mkdir(parents=True, exist_ok=True)
        self.commit(self.other, name, text)
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)
        return lane.fetch_base(self.tree, 'main')

    def pr(self):
        self.commit(self.tree, 'pr.txt', 'pr\n')
        head = self.rev(self.tree, 'HEAD')
        tested = lane.fetch_base(self.tree, 'main')
        return head, tested, lane.merged_tree(self.tree, tested, head)

    def stands(self, head, base_sha, records, env=ON):
        return lane.hosted_fast_checks(None, self.tree, 'main', head, base_sha, env=env, records=records)

    def records(self, head, base, tree, only=None):
        """A records reader whose checks all passed and recorded <tree>; with <only>, just that set of checks."""
        def read(github, h, checks):
            if only is not None and checks is not only:
                return None, f'no "{next(iter(checks))}" check ran on {h[:7]}'
            return {name: {'plan': plan, 'tree': tree, 'base': base, 'head': head, 'url': 'u'}
                    for name, plan in checks.items()}, ''
        return read

    def test_it_waits_for_checks_still_running_then_takes_them(self):
        # The first lane runs after the switch went on found the hosted checks still running and ran the whole
        # --plan fast on the Mac (#1389). Inside a lane job the runner now waits for them.
        head, tested, tree = self.pr()
        passed = self.records(head, tested, tree)
        reads, slept, now = [], [], [0.0]

        def running_twice(github, h, checks):
            reads.append(checks)
            if len(reads) <= 2:  # two polls
                return None, f'"{next(iter(checks))}" had not finished on {h[:7]}'
            return passed(github, h, checks)

        def sleep(seconds):
            slept.append(seconds)
            now[0] += seconds
        found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env={**ON, 'GITHUB_ACTIONS': 'true'},
                                             records=running_twice, clock=lambda: now[0], sleep=sleep,
                                             out=io.StringIO())
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))
        self.assertEqual(slept, [lane.HOSTED_FAST_POLL] * 2)

    def test_the_wait_is_bounded_and_skipped_outside_a_lane_job(self):
        head, tested, _ = self.pr()

        def running(github, h, checks):
            return None, f'"{next(iter(checks))}" had not finished on {h[:7]}'
        for env, polls in (({**ON, 'GITHUB_ACTIONS': 'true'}, lane.HOSTED_FAST_WAIT // lane.HOSTED_FAST_POLL), (ON, 0)):
            with self.subTest(env):
                slept, now = [], [0.0]

                def sleep(seconds):
                    slept.append(seconds)
                    now[0] += seconds
                found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env=env, records=running,
                                                     clock=lambda: now[0], sleep=sleep, out=io.StringIO())
                self.assertIsNone(found)
                self.assertIn('had not finished', why)
                self.assertEqual(len(slept), polls)

    def test_a_failed_or_missing_check_is_not_waited_for(self):
        head, tested, _ = self.pr()
        slept = []
        for why in ('"hosted fast: portable" ended failure on abc1234', 'no "hosted fast: portable" check ran'):
            found, said = lane.hosted_fast_checks(None, self.tree, 'main', head, tested,
                                                  env={**ON, 'GITHUB_ACTIONS': 'true'},
                                                  records=lambda github, h, checks, why=why: (None, why),
                                                  sleep=slept.append, out=io.StringIO())
            self.assertIsNone(found)
        self.assertEqual(slept, [])

    def test_off_reads_no_checks(self):
        # The Mac runs the whole --plan fast, and nothing off the Mac is read: no VPS pair since #2442.
        head, tested, tree = self.pr()
        for env in ({}, {'LANE_HOSTED_FAST': ''}, {'LANE_HOSTED_FAST': 'off'}, {'LANE_HOSTED_FAST': 'yes'}):
            with self.subTest(env):
                reads = []

                def passed(github, h, checks):
                    reads.append(checks)
                    return self.records(head, tested, tree)(github, h, checks)
                found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env=env, records=passed)
                self.assertIsNone(found)
                self.assertIn('the hosted fast checks are off', why)
                self.assertEqual(reads, [])

    def test_with_the_switch_on_the_hosted_pair_stands_and_says_so(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, tree))
        self.assertEqual(why, '')
        self.assertEqual({record['runner'] for record in found.values()}, {'GitHub-hosted'})
        self.assertIn('GitHub-hosted: --plan fast-portable and SessionKitCoreTests', lane.hosted_fast_ran(found))
        self.assertTrue(all(line.startswith('GitHub-hosted check "') for line in lane.hosted_fast_lines(found)))

    def test_another_tree_does_not_stand(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, '0' * 40))
        self.assertIsNone(found)
        self.assertIn('"hosted fast: portable" tested a tree that is not', why)

    def test_the_same_merge_stands(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, tree))
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))
        # The tree the runner's own merge commit holds is the one the hosted job reported.
        sha, _ = lane.build_merge_commit(self.tree, 'main', head, 5, 'A change')
        self.assertEqual(self.rev(self.tree, sha + '^{tree}'), tree)

    def test_a_tree_that_is_not_this_merge_is_refused(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, '0' * 40))
        self.assertIsNone(found)
        self.assertIn('tested a tree that is not', why)

    def test_next_moving_elsewhere_lets_it_stand_and_says_so(self):
        head, tested, tree = self.pr()
        newest = self.move_next('docs/notes.md')
        found, why = self.stands(head, newest, self.records(head, tested, tree))
        self.assertEqual(why, '')
        self.assertTrue(all(len(record['moved']) == 1 for record in found.values()))
        lines = lane.hosted_fast_lines(found)
        self.assertTrue(all('moved 1 commit since, and this PR still merges cleanly' in line for line in lines))
        self.assertIn(tested[:7], lane.hosted_fast_ran(found))

    def test_next_touching_the_prs_files_or_a_global_input_still_lets_a_clean_merge_stand(self):
        # 2026-11-19: every move of next that touched project.yml, a lockfile or the PR's own file made the check
        # stale and started hosted-portable.yml again (115 cancelled to 47 passed in one afternoon). Main's own
        # scheduled run (#4573) catches merge skew now, as #4572 took per-PR T3 off the merge, so a check stands
        # while the PR still merges cleanly onto the newest next.
        for name, path in (('a file the PR did not touch', 'other-pr.txt'), ('project.yml', 'project.yml'),
                           ('Package.swift', 'Packages/SessionKit/Package.swift'),
                           ('Package.resolved', 'Package.resolved'), ('package-lock.json', 'web/package-lock.json'),
                           ('package.json', 'package.json')):
            with self.subTest(name):
                self.setUp()
                head, tested, tree = self.pr()
                newest = self.move_next(path)
                found, why = self.stands(head, newest, self.records(head, tested, tree))
                self.assertEqual(why, '')
                self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))

    def test_a_pr_that_conflicts_with_the_newest_next_does_not_stand(self):
        head, tested, tree = self.pr()
        newest = self.move_next('pr.txt', 'someone else wrote this file first\n')
        self.assertIsNone(lane.merged_tree(self.tree, newest, head))
        found, why = self.stands(head, newest, self.records(head, tested, tree))
        self.assertIsNone(found)
        self.assertIn(f'tested it on main at {tested[:7]}', why)
        self.assertIn('conflicts with', why)
        self.assertTrue(lane.HOSTED_STALE.search(why), why)  # a conflict is started again, as a stale check was

    def test_next_moving_in_scripts_or_workflows_lets_a_hosted_check_stand(self):
        # 6 of 7 fallbacks on 2026-10-24 were a scripts/ file merged by someone else while the check ran.
        for path in ('scripts/verify-tests.py', 'scripts/lane-runner.py', '.github/workflows/lane.yml',
                     'ops/testdesk/x.py', 'App/SpokenMarginsApp/Sources/Other.swift'):
            with self.subTest(path):
                self.setUp()
                head, tested, tree = self.pr()
                newest = self.move_next(path)
                found, why = self.stands(head, newest, self.records(head, tested, tree))
                self.assertEqual(why, '')
                self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))

    def test_a_base_commit_the_runner_lacks_is_fetched_not_read_as_another_tree(self):
        # The job's checkout can be older than the tip a fresh hosted run merged onto: git merge-tree cannot merge a
        # commit it lacks, and that read as "tested a tree that is not ..." (#2596: 4 of 7 fallbacks).
        head, tested, tree = self.pr()
        lagging = Path(self.temporary.name) / 'lagging'
        subprocess.run(self.git + ['clone', '-q', '-b', 'main', str(self.origin), str(lagging)], check=True,
                       capture_output=True)
        subprocess.run(self.git + ['-C', str(lagging), 'fetch', '-q', str(self.tree), 'HEAD'], check=True)
        newest = self.move_next('docs/notes.md')
        expected = lane.merged_tree(self.tree, newest, head)
        self.assertIsNotNone(expected)
        self.assertIsNone(lane.merged_tree(lagging, newest, head))
        self.assertEqual(lane.merged_tree(lagging, newest, head, fetch='main'), expected)
        found, why = lane.hosted_fast_checks(None, lagging, 'main', head, newest, env=ON,
                                             records=self.records(head, newest, expected))
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))

    def test_a_record_naming_a_next_the_runner_does_not_have_falls_back(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, 'f' * 40, tree))
        self.assertIsNone(found)
        self.assertTrue(why)

    def test_a_read_error_falls_back(self):
        head, tested, _ = self.pr()

        def broken(github, h, checks):
            raise subprocess.CalledProcessError(1, ['gh', 'api'])
        found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env=ON, records=broken)
        self.assertIsNone(found)
        self.assertIn('could not read the fast checks off the Mac', why)


class RunAutomergeTests(unittest.TestCase):
    SCOPE = {'tier': 'T2', 'why': ['App/x.swift']}
    FOUND = {name: {'plan': plan, 'tree': 'e' * 40, 'base': 'd' * 40, 'head': 'a' * 40}
             for name, plan in lane.HOSTED_FAST_CHECKS.items()}

    def run_it(self, **kwargs):
        calls = []

        def fast(evidence, changed=None):
            calls.append('fast')
            return 'PASS', []

        def mac_rest(evidence, changed=None):
            calls.append('mac-rest')
            return 'PASS', []
        with tempfile.TemporaryDirectory() as temporary:
            result = lane.run_automerge(self.SCOPE, Path(temporary), fast=fast, mac_rest=mac_rest, **kwargs)
        return calls, result

    def test_without_hosted_results_the_whole_fast_plan_runs(self):
        calls, (verdict, where, ran, _) = self.run_it()
        self.assertEqual(calls, ['fast'])
        self.assertEqual((verdict, ran), ('PASS', 'host tests (--plan fast): passed'))

    def test_with_hosted_results_only_the_mac_rest_runs_and_the_report_says_where_each_part_ran(self):
        calls, (verdict, where, ran, details) = self.run_it(hosted_fast=self.FOUND)
        self.assertEqual(calls, ['mac-rest'])
        self.assertEqual(verdict, 'PASS')
        self.assertIn('Mac: --plan fast-mac-rest', ran)
        self.assertIn('next at ddddddd', ran)
        self.assertTrue(any(line.startswith('GitHub-hosted check "hosted fast: portable": PASS') for line in details))

    def test_a_mac_rest_failure_fails_the_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            verdict, _, ran, _ = lane.run_automerge(self.SCOPE, Path(temporary), hosted_fast=self.FOUND,
                                                    mac_rest=lambda evidence, changed=None: ('FAIL', ['x']))
        self.assertEqual(verdict, 'FAIL')
        self.assertTrue(ran.endswith('fast-mac-rest): fail'))

    def test_the_mac_rest_plan_is_what_the_runner_asks_verify_tests_for(self):
        commands = []

        def runner(command, log, timeout):
            commands.append(command)
            return None
        with tempfile.TemporaryDirectory() as temporary:
            verdict, details = lane.run_mac_rest(Path(temporary), runner=runner)
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertIn('--plan fast-mac-rest', details[0])
        self.assertEqual(commands[0][commands[0].index('--plan') + 1], 'fast-mac-rest')


class SplitPlanTests(unittest.TestCase):
    """verify-tests.py: the three plans together run every step of --plan fast, each on the machine it needs."""

    def test_the_three_plans_cover_every_fast_step(self):
        import test_fast_portable
        covered = (set(verification.PORTABLE_STEPS) | set(verification.HOSTED_SESSIONKIT_STEPS)
                   | set(verification.MAC_REST_STEPS))
        self.assertEqual(test_fast_portable.literal_steps() - covered, set())
        # What the portable plan leaves out, the other two run.
        self.assertEqual(set(verification.PORTABLE_LEFT_OUT) - covered, set())
        self.assertIn('package', verification.MAC_REST_STEPS)  # the sound-output step never leaves the Mac
        self.assertNotIn('package', verification.HOSTED_SESSIONKIT_STEPS)

    def run_plan(self, plan, changed):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / 'node_modules').mkdir()
            run = verification.Run(Path(temporary) / 'run', plan, changed)
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    mock.patch.object(run, 'ops_steps', side_effect=lambda **kw: calls.append(('ops', kw))), \
                    mock.patch.object(run, 'package_core', side_effect=lambda core: calls.append(('package-core', core))), \
                    mock.patch.object(run, 'package_steps',
                                      side_effect=lambda expected, **kw: calls.append(('package-steps', kw))), \
                    mock.patch.object(verification, 'ROOT', Path(temporary)), \
                    mock.patch.object(verification, 'swift_tests', return_value={'T/test'}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    mock.patch.object(verification.sessionkit_pass, 'toolchain', return_value=None), \
                    mock.patch.object(verification.sessionkit_pass, 'find', return_value=None), \
                    mock.patch.object(verification, 'host_test_slot',
                                      side_effect=lambda *a, **k: calls.append(('slot', None)) or contextlib.nullcontext({})), \
                    mock.patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']), \
                    contextlib.redirect_stdout(io.StringIO()):
                run.fast()
            skipped = {step['name'] for step in run.manifest['steps'] if 'skipped' in step}
        return calls, skipped

    def test_hosted_sessionkit_builds_and_runs_the_core_tests_without_a_mac_slot(self):
        calls, skipped = self.run_plan('fast-hosted-sessionkit', None)
        self.assertEqual([name for name, _ in calls], ['package-build', 'package-core'])
        self.assertEqual(calls[1][1], {'SessionKitCoreTests/T/test'})
        self.assertEqual(skipped, {'package'})

    def test_mac_rest_for_an_app_diff_runs_only_the_sessionkit_rest(self):
        calls, skipped = self.run_plan('fast-mac-rest', ['App/SpokenMarginsApp/X.swift'])
        self.assertEqual(calls, [('slot', None), ('package-steps', {'core_elsewhere': True})])
        self.assertEqual(skipped, {'hot-file-ratchet', 'runner-tests', 'ops', 'tools', 'shipped-compat'})

    def test_mac_rest_for_a_lane_diff_also_runs_the_apple_tool_tests_and_ops_disk(self):
        calls, _ = self.run_plan('fast-mac-rest', ['scripts/phone-build'])
        by_name = dict(calls)
        self.assertEqual(by_name['runner-tests'][1:3], ['-c', verification.MAC_REST_RUNNER_LOADER])
        self.assertEqual(by_name['runner-tests'][3:], list(verification.PORTABLE_RUNNER_TESTS_LEFT_OUT))
        self.assertEqual(by_name['ops'], {'only': verification.PORTABLE_OPS_LEFT_OUT})

    def test_the_mac_rest_loader_runs_only_the_listed_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            tests = Path(temporary) / 'scripts' / 'tests'
            tests.mkdir(parents=True)
            (tests / 'test_apple.py').write_text(
                'import unittest\nclass A(unittest.TestCase):\n    def test_needs_xcode(self): pass\n')
            (tests / 'test_other.py').write_text(
                'import unittest\nclass B(unittest.TestCase):\n    def test_elsewhere(self): self.fail("ran")\n')
            done = subprocess.run([sys.executable, '-c', verification.MAC_REST_RUNNER_LOADER, 'test_apple.'],
                                  cwd=temporary, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn('Ran 1 test', done.stderr)

    def test_package_steps_with_the_core_elsewhere_runs_only_the_rest(self):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast-mac-rest')
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args, kw))), \
                    mock.patch.object(run, 'package_core', side_effect=lambda core: calls.append(('package-core',))), \
                    mock.patch.object(verification.host_audio, 'audio_output', return_value={'usable': True}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False):
                run.package_steps({'SessionKitTests/A/test'}, core_elsewhere=True)
        self.assertEqual([call[0] for call in calls], ['package-build', 'package'])
        self.assertIn('--rest', calls[1][1])
        self.assertEqual(calls[1][2]['expected'], {'SessionKitTests/A/test'})


class WorkflowTests(unittest.TestCase):
    """The hosted jobs and the lane agree on names, the switch and what is recorded."""

    @classmethod
    def setUpClass(cls):
        cls.hosted = (ROOT / '.github/workflows/hosted-portable.yml').read_text()
        cls.lane_yml = (ROOT / '.github/workflows/lane.yml').read_text()

    def test_each_required_check_is_a_job_name_that_records_its_plan(self):
        for name, plan in {**lane.HOSTED_FAST_CHECKS, **lane.HOSTED_REST_CHECK}.items():
            with self.subTest(name):
                self.assertIn(f"name: '{name}'", self.hosted)
                self.assertIn(f'::notice title={lane.HOSTED_TESTED_TITLE}::plan={plan} tree=', self.hosted)
                for part in plan.split('+'):  # Mac rest records both plans it runs (#2596)
                    self.assertIn(f'--plan {part}', self.hosted)

    def test_both_jobs_run_on_a_pr_only_from_this_repo_and_only_with_the_switch_on(self):
        guard = ("(github.event.pull_request.head.repo.full_name == github.repository && "
                 f"vars.{lane.HOSTED_FAST_SWITCH} == 'on')")
        # The pair, and the Mac-rest check (#2459), which runs on a PR only with LANE_HOSTED_MAC_REST `on` too.
        # plus the `scope` job (#2596), which has the same guard
        self.assertEqual(self.hosted.count(guard), len(lane.HOSTED_FAST_CHECKS) + len(lane.HOSTED_REST_CHECK) + 1)
        self.assertIn(f"vars.{lane.HOSTED_REST_SWITCH} == 'on')", self.hosted)
        self.assertNotIn('pull_request_target:', self.hosted)

    def test_a_red_portable_job_cancels_the_run_so_its_mac_jobs_free_their_slots(self):
        # #2596: the cancel job runs on Linux, only after `portable` ended `failure`, and holds no more than actions: write.
        # The Mac jobs may wait only for the ~20 s `scope` job: the lane runner gives a missing check only 5 minutes.
        jobs = yaml.safe_load(self.hosted)['jobs']
        stop = jobs['stop-macs-on-red']
        self.assertEqual(stop['needs'], 'portable')
        self.assertEqual(stop['runs-on'], 'ubuntu-latest')
        self.assertEqual(stop['permissions'], {'actions': 'write'})
        self.assertIn("needs.portable.result == 'failure'", stop['if'])
        self.assertIn('gh run cancel', stop['steps'][0]['run'])
        for name in ('sessionkit', 'mac-rest'):
            self.assertEqual(self.slow_needs(jobs[name]), [], name)
        # Only `scope` (a Linux job of about 20 seconds, #2650) may come first; any other need fails the check.
        for allowed in ('scope', ['scope']):
            copy = copy_module.deepcopy(jobs['mac-rest'])
            copy['needs'] = allowed
            self.assertEqual(self.slow_needs(copy), [], allowed)
        for slow in ('portable', ['scope', 'portable'], ['sessionkit']):
            copy = copy_module.deepcopy(jobs['mac-rest'])
            copy['needs'] = slow
            self.assertNotEqual(self.slow_needs(copy), [], slow)

    @staticmethod
    def slow_needs(job):
        needs = job.get('needs', [])
        needs = [needs] if isinstance(needs, str) else list(needs)
        return [name for name in needs if name != 'scope']

    def test_no_workflow_job_runs_on_the_vps(self):
        # #2442, #2383: CI left the owner's VPS. linux-t1.yml is gone, and the lane-open pings keep their 10-minute
        # limit on a data branch (a compare-and-swap in ops/lane/sm_lane_open.py), not on the VPS runner's disk.
        workflows = ROOT / '.github/workflows'
        self.assertFalse((workflows / 'linux-t1.yml').exists())
        on_vps = {}
        for path in sorted(workflows.glob('*.yml')):
            text = path.read_text()
            self.assertNotIn('sm-vps-t1]', text, path.name)
            jobs = text.split('\njobs:\n', 1)[-1]
            for job, body in re.findall(r'(?ms)^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', jobs):
                if any('sm-vps' in runs_on for runs_on in re.findall(r'(?m)^    runs-on: (.*)$', body)):
                    on_vps.setdefault(path.name, []).append(job)
        self.assertEqual(on_vps, {})

    def test_the_lane_hands_the_switch_to_the_automerge_and_release_runs_and_may_read_checks(self):
        # The route job (hosted_merge_routing), the automerge job, its automerge-mac fallback and the release job
        # (#2459). The lane job no longer reads them: a T3 PASS merges nothing since #4572.
        for switch in (lane.HOSTED_FAST_SWITCH, lane.HOSTED_REST_SWITCH):
            self.assertEqual(self.lane_yml.count(f'{switch}: ${{{{ vars.{switch} }}}}'), 4, switch)
        self.assertIn('  checks: read\n', self.lane_yml)


if __name__ == '__main__':
    unittest.main()
