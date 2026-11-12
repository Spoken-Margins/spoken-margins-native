"""The lane report's machine-readable event line (#2378): what it carries, and that it never carries text."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_lane_runner import FakeGitHub, HEAD, MERGE, comment, lane, runner_report  # noqa: E402
import lane_event  # noqa: E402

BASE = 'd' * 40


def runs():
    return [{'step': 'host tests', 'verdict': 'PASS', 'seconds': 41.6, 'zero_tests': False},
            {'step': 'app tests (T3)', 'verdict': 'FAIL', 'seconds': 300.2, 'zero_tests': False},
            {'step': 'LFS files', 'verdict': 'INCONCLUSIVE', 'seconds': 2.0, 'zero_tests': False},
            {'step': 'ops tests', 'verdict': 'PASS', 'seconds': 1.0, 'zero_tests': True}]


def records():
    return {'AppTests/PlayerTests/testPlay': {'status': 'passed', 'seconds': 1.5},
            'AppTests/PlayerTests/testPause': {'status': 'failed', 'seconds': 9.25},
            'AppTests/QueueTests/testAdd': {'status': 'passed', 'seconds': 0.2}}


def build(**changes):
    arguments = dict(verdict='FAIL', tier='T3', head=HEAD, trunk=BASE, seconds=345.4, queue_seconds=61.2,
                     runs=runs(), records=records())
    arguments.update(changes)
    return lane_event.build(**arguments)


class BuildTests(unittest.TestCase):
    def test_the_event_carries_steps_with_fault_kept_apart_from_fail(self):
        event = build()
        self.assertEqual([(step['step'], step['result']) for step in event['steps']],
                         [('host tests', 'pass'), ('app tests (T3)', 'fail'), ('LFS files', 'fault'),
                          ('ops tests', 'fault')])  # a PASS that ran no test is a runner fault
        self.assertEqual(event['steps'][0]['seconds'], 42)
        self.assertEqual((event['verdict'], event['fault'], event['seconds'], event['queue_seconds']),
                         ('FAIL', False, 345, 61))
        self.assertTrue(build(verdict='INCONCLUSIVE')['fault'])

    def test_the_trunk_and_head_are_short_commits(self):
        event = build()
        self.assertEqual((event['head'], event['trunk']), (HEAD[:12], BASE[:12]))
        event = build(head='unknown', trunk='')
        self.assertEqual((event['head'], event['trunk']), ('', ''))

    def test_tests_ran_and_failed_per_class_and_the_slowest_first(self):
        event = build()
        self.assertEqual(event['tests'], {'ran': 3, 'failed': 1})
        self.assertEqual(event['classes'], {'AppTests/PlayerTests': [2, 1], 'AppTests/QueueTests': [1, 0]})
        self.assertEqual(event['slowest'][0], ['AppTests/PlayerTests/testPause', 9])

    def test_only_the_20_slowest_are_kept(self):
        many = {f'M/C{n % 5}/test{n}': {'status': 'passed', 'seconds': n} for n in range(60)}
        event = build(records=many)
        self.assertEqual(len(event['slowest']), 20)
        self.assertEqual(event['slowest'][0], ['M/C4/test59', 59])
        self.assertEqual(event['tests']['ran'], 60)

    def test_an_automerge_run_has_no_queue_wait(self):
        self.assertIsNone(build(queue_seconds=None)['queue_seconds'])

    def test_the_line_stays_under_the_cap_and_keeps_the_failures(self):
        many = {f'Mod/Class{n}/test{n}': {'status': 'failed' if n == 7 else 'passed', 'seconds': n % 9}
                for n in range(3000)}
        event = build(records=many)
        line = lane_event.note(event)
        self.assertLessEqual(len(line), lane_event.MAX_BYTES + 100)
        self.assertEqual(event['tests'], {'ran': 3000, 'failed': 1})
        self.assertEqual(event['classes'], {'Mod/Class7': [1, 1]})
        self.assertTrue(event['classes_trimmed'])
        self.assertEqual(lane_event.parse(line)['tests'], {'ran': 3000, 'failed': 1})


class NeverCarriesTextTests(unittest.TestCase):
    """Nothing in the line can be a path or a message, whatever the step runs and the manifests hold."""

    PATHS = ['/Users/colemiller/Documents/GitHub/x/Tests/PlayerTests.swift:88',
             'XCTAssertEqual failed: ("a") is not equal to ("b")',
             'AppTests/PlayerTests/testPlay: /Users/colemiller/x.swift:3 failed',
             '../../etc/passwd', 'AppTests/Player Tests/test play', 'C:\\Users\\x', 'AppTests/PlayerTests/',
             'a' * 500 + '/b/c', '--> <!-- lane-event', 'AppTests/PlayerTests/test\n--> injected']

    def test_hostile_test_ids_are_dropped(self):
        hostile = {name: {'status': 'failed', 'seconds': 1} for name in self.PATHS}
        hostile.update(records())
        event = build(records=hostile)
        self.assertEqual(event['tests']['ran'], 3)
        line = lane_event.note(event)
        for text in ('Users', 'XCTAssert', 'passwd', 'injected', '.swift', 'Documents'):
            self.assertNotIn(text, line)

    def test_hostile_step_names_and_verdicts_are_dropped(self):
        hostile = runs() + [{'step': path, 'verdict': 'FAIL', 'seconds': 1} for path in self.PATHS]
        hostile.append({'step': 'host tests', 'verdict': '/Users/x/log.txt: failed', 'seconds': 1})
        event = build(runs=hostile, verdict='/Users/x', tier='/Users/x')
        self.assertEqual(len(event['steps']), 5)  # the four real ones, and the one whose verdict is mapped to a fault
        self.assertEqual((event['verdict'], event['tier']), ('INCONCLUSIVE', 'auto'))
        self.assertNotIn('Users', lane_event.note(event))

    def test_every_string_in_the_line_matches_its_pattern(self):
        event = json.loads(lane_event.note(build()).split(' ', 3)[3].rsplit(' -->', 1)[0])
        strings = [event['verdict'], event['tier'], event['head'], event['trunk']]
        strings += [step['step'] for step in event['steps']] + [step['result'] for step in event['steps']]
        strings += list(event['classes']) + [name for name, _ in event['slowest']]
        for text in strings:
            self.assertRegex(text, r'^[A-Za-z0-9 ()#./_-]*$', text)
            self.assertNotIn('..', text)
            self.assertFalse(text.startswith('/'), text)

    def test_the_line_has_no_end_of_comment_marker_inside_it(self):
        line = lane_event.note(build())
        self.assertEqual(line.count('-->'), 1)
        self.assertTrue(line.endswith(' -->'))


class ParseTests(unittest.TestCase):
    def test_a_line_round_trips(self):
        event = build()
        self.assertEqual(lane_event.parse('Lane report x — FAIL\n' + lane_event.note(event) + '\n'), event)

    def test_a_forged_line_with_text_in_a_field_is_refused(self):
        event = build()
        forgeries = [dict(event, head='/Users/x/secret'), dict(event, verdict='PASS and more'),
                     dict(event, steps=[{'step': '/Users/x', 'result': 'pass', 'seconds': 1}]),
                     dict(event, classes={'/etc/passwd': [1, 0]}), dict(event, slowest=[['a b', 1]]),
                     dict(event, v=2), {k: v for k, v in event.items() if k != 'steps'}]
        for forged in forgeries:
            with self.subTest(forged=forged):
                self.assertIsNone(lane_event.parse(lane_event.note(forged)))

    def test_unknown_fields_are_dropped_and_no_line_is_none(self):
        parsed = lane_event.parse(lane_event.note(dict(build(), message='hello')))
        self.assertNotIn('message', parsed)
        self.assertIsNone(lane_event.parse('Lane report x — PASS\n'))
        self.assertIsNone(lane_event.parse('<!-- lane-event v1 {not json} -->'))
        self.assertIsNone(lane_event.parse(None))


class HoldTests(unittest.TestCase):
    """#4089: a report held for T3 says so, and a hold is not a runner fault."""

    def test_a_hold_is_not_a_fault_and_says_so(self):
        event = build(verdict='INCONCLUSIVE', hold=True, runs=[])
        self.assertEqual((event['verdict'], event['fault'], event['hold']), ('INCONCLUSIVE', False, True))
        self.assertTrue(build(verdict='INCONCLUSIVE', hold=False)['fault'])  # a runner INCONCLUSIVE still is
        self.assertTrue(build(verdict='INCONCLUSIVE')['fault'])

    def test_a_line_that_is_no_hold_is_byte_for_byte_what_it_was(self):
        for verdict in ('PASS', 'FAIL', 'INCONCLUSIVE'):
            self.assertNotIn('hold', build(verdict=verdict))
        self.assertNotIn('"hold"', lane_event.note(build(verdict='INCONCLUSIVE')))

    def test_only_an_inconclusive_report_can_be_held(self):
        for verdict in ('PASS', 'FAIL'):
            self.assertNotIn('hold', build(verdict=verdict, hold=True))
            self.assertEqual(build(verdict=verdict, hold=True)['fault'], False)

    def test_a_hold_round_trips_and_an_old_reader_still_reads_the_line(self):
        event = build(verdict='INCONCLUSIVE', hold=True, runs=[])
        line = lane_event.note(event)
        self.assertEqual(lane_event.parse(line), event)
        # A reader from before the key: it builds the event from the keys it knows and ignores `hold`.
        old_reader_keys = {'v', 'verdict', 'fault', 'tier', 'head', 'trunk', 'seconds', 'queue_seconds', 'steps', 'tests',
                           'classes', 'slowest'}
        self.assertLessEqual(old_reader_keys, set(json.loads(line.split(' ', 3)[3][:-4])))

    def test_a_hold_key_on_a_line_that_says_fault_cannot_make_both_true_and_a_line_without_it_is_no_hold(self):
        forged = dict(build(verdict='INCONCLUSIVE'), hold=True)  # fault true, hold true
        self.assertEqual((lane_event.parse(lane_event.note(forged))['hold'], lane_event.parse(lane_event.note(forged))['fault']),
                         (True, False))
        self.assertNotIn('hold', lane_event.parse(lane_event.note(dict(build(verdict='FAIL'), hold=True))))
        self.assertNotIn('hold', lane_event.parse(lane_event.note(dict(build(verdict='INCONCLUSIVE'), hold='yes'))))

    def test_the_prose_fallback_never_guesses_a_hold(self):
        body = lane.report('pr1-r1', 'INCONCLUSIVE', HEAD, BASE, 'auto', 'hosted', 0, 'nothing',
                           ['not merged: held for T3: the /lane T3 request has no lane report yet'], 'none', '/e', 'n', {})
        event = lane_event.collect(body)
        self.assertEqual((event['source'], event['fault']), ('prose', True))
        self.assertNotIn('hold', event)


class CollectTests(unittest.TestCase):
    def test_the_line_wins_when_it_is_there(self):
        body = lane.report('pr1-r1', 'FAIL', HEAD, BASE, 'T3', 'x', 345, 'x', [], 'none', '/e', 'n', {},
                           event=lane_event.note(build()))
        event = lane_event.collect(body)
        self.assertEqual((event['source'], event['verdict'], event['tests']['failed']), ('line', 'FAIL', 1))

    def test_a_report_without_the_line_falls_back_to_the_prose(self):
        body = lane.report('pr1-r1', 'INCONCLUSIVE', HEAD, BASE, 'T3', 'no runner', 0, 'nothing', [], 'none', '/e', 'n',
                           {})
        event = lane_event.collect(body)
        self.assertEqual((event['source'], event['verdict'], event['fault'], event['tier']),
                         ('prose', 'INCONCLUSIVE', True, 'T3'))
        self.assertEqual((event['head'], event['trunk']), (HEAD[:7], BASE[:7]))
        self.assertEqual(event['steps'], [])

    def test_an_older_report_whose_base_was_not_a_commit_still_gives_its_tier_and_head(self):
        body = lane.report('pr1-r1', 'INCONCLUSIVE', HEAD, 'unknown', 'T3', 'no runner', 0, 'nothing', [], 'none', '/e',
                           'n', {})
        event = lane_event.collect(body)
        self.assertEqual((event['tier'], event['head'], event['trunk']), ('T3', HEAD[:7], ''))

    def test_a_forged_line_falls_back_to_the_prose_and_other_comments_are_none(self):
        body = lane.report('pr1-r1', 'PASS', HEAD, BASE, 'T2', 'x', 5, 'x', [], 'none', '/e', 'n', {},
                           event=lane_event.note(dict(build(), head='/Users/x')))
        self.assertEqual(lane_event.collect(body)['source'], 'prose')
        self.assertIsNone(lane_event.collect('Looks good to me'))


class TestRecordsTests(unittest.TestCase):
    def test_manifests_one_folder_down_are_read_and_skips_and_odd_ids_are_left_out(self):
        with tempfile.TemporaryDirectory() as folder:
            for name, steps in (('fast', [{'tests': records()}]),
                                ('verify-app', [{'tests': {'A/B/testC': {'status': 'skipped', 'seconds': 1},
                                                           '/Users/x.swift:1': {'status': 'failed', 'seconds': 1}}},
                                                {'superseded': True, 'tests': {'A/B/testOld': {'status': 'passed'}}}])):
                (Path(folder) / name).mkdir()
                (Path(folder) / name / 'manifest.json').write_text(json.dumps({'steps': steps}))
            (Path(folder) / 'broken').mkdir()
            (Path(folder) / 'broken' / 'manifest.json').write_text('{')
            self.assertEqual(sorted(lane_event.test_records(Path(folder))), sorted(records()))

    def test_a_missing_folder_is_no_records(self):
        self.assertEqual(lane_event.test_records(Path('/nonexistent-evidence')), {})


class RunnerTests(unittest.TestCase):
    def setUp(self):
        lane.STEP_RUNS.clear()
        self.addCleanup(lane.STEP_RUNS.clear)

    def test_the_report_ends_with_the_line_and_still_reads_as_before(self):
        lane.note_step('host tests', 'PASS', 12.0)
        note = lane.event_note('PASS', 'T2', HEAD, BASE, 20, None)
        wanted = lane.identity('T2', HEAD, BASE, [])
        body = lane.report('pr1-r1', 'PASS', HEAD, BASE, 'T2', 'x', 20, 'x', [], 'none', '/e', 'n', wanted, event=note)
        self.assertTrue(body.rstrip().endswith('-->'))
        self.assertEqual(body.rstrip().splitlines()[-1], note)
        self.assertEqual(lane.report_identity(body), wanted)
        self.assertEqual(body, lane.report('pr1-r1', 'PASS', HEAD, BASE, 'T2', 'x', 20, 'x', [], 'none', '/e', 'n',
                                           wanted, event='') + note + '\n')

    def test_the_visible_report_is_the_same_with_or_without_the_line(self):
        without = lane.report('pr1-r1', 'PASS', HEAD, BASE, 'T2', 'x', 20, 'x', [], 'none', '/e', 'n', {})
        with_line = lane.report('pr1-r1', 'PASS', HEAD, BASE, 'T2', 'x', 20, 'x', [], 'none', '/e', 'n', {},
                                event=lane.event_note('PASS', 'T2', HEAD, BASE, 20, None))
        self.assertTrue(with_line.startswith(without))

    def test_the_queue_wait_is_the_time_from_the_request_to_the_job_start(self):
        lane.note_step('host tests', 'PASS', 12.0)
        with mock.patch.object(lane.time, 'gmtime', return_value=__import__('time').gmtime(1_700_000_300)):
            note = lane.event_note('PASS', 'T3', HEAD, BASE, 100, None, '2023-11-14T22:13:20Z')  # 1_700_000_000
        self.assertEqual(lane_event.parse(note)['queue_seconds'], 200)

    def test_the_automerge_run_a_t3_pass_releases_counts_only_its_own_steps(self):
        # The T3 job's steps are in STEP_RUNS when merge_after_t3 runs in the same process; its report must not repeat them.
        t3_request = comment(f'/lane T3\ncommit: {HEAD[:7]}\ntests: SupertonicSpeechTests')
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[t3_request])
        lane.note_step('app tests (T3)', 'PASS', 300.0)
        lane.note_step('LFS files', 'PASS', 2.0)

        def auto(*args, **kwargs):
            lane.note_step('host tests', 'PASS', 40.0)
            return 'PASS', 'x', 'host tests', ['merged into main as abc1234']
        github._comments.append(comment(lane.report('pr5-r1', 'INCONCLUSIVE', HEAD, MERGE, 'auto', 'x', 1, 'x',
                                                    [lane.HELD_FOR_T3[0]], 'none', '/e', 'n',
                                                    lane.identity('auto', HEAD, MERGE, []), event=''),
                                        login='github-actions[bot]'))
        github._comments.append(runner_report('PASS', lane.identity('T3', HEAD, MERGE, ['SupertonicSpeechTests'])))
        with mock.patch.object(lane, 'run_auto', side_effect=auto), \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), mock.patch.object(lane, 'clean_tree'), \
                mock.patch('builtins.print'), tempfile.TemporaryDirectory() as evidence:
            released = lane.merge_after_t3(github, 5, 'main', HEAD, 'pr5-r43-auto', Path(evidence), MERGE,
                                           'started by the T3 PASS')
        event = lane_event.parse(released)
        self.assertIsNotNone(event, released)
        self.assertEqual((event['tier'], [step['step'] for step in event['steps']]), ('auto', ['host tests']))

    def test_held_for_t3_report_reads_the_line_the_auto_revert_reads(self):
        held = ['not merged: held for T3: the /lane T3 request for this head (abc) has no lane report yet.']
        self.assertTrue(lane.held_for_t3_report('INCONCLUSIVE', held))
        self.assertTrue(lane.held_for_t3_report('INCONCLUSIVE', ['moved', *held]))
        for verdict, lines in (('FAIL', held), ('PASS', held), ('INCONCLUSIVE', []),
                               ('INCONCLUSIVE', ['no Mac build slot was free']),
                               # other "not merged" holds are not the T3 hold (is_hold, the green/red rule, is broader)
                               ('INCONCLUSIVE', ['not merged by the runner: it touches .github/']),
                               ('INCONCLUSIVE', ['not merged: the PR moved on']),
                               ('INCONCLUSIVE', ['not merged: no Codex or Claude audit of its head']),
                               # words in the middle of a line, as the "checks did not finish" note has them: a fault
                               ('INCONCLUSIVE', ['The checks did not finish, so: ' + held[0]]),
                               ('INCONCLUSIVE', ['  not merged: held for T3: indented test output'])):
            with self.subTest(verdict=verdict, lines=lines):
                self.assertFalse(lane.held_for_t3_report(verdict, lines))

    def test_a_held_report_is_no_fault_to_the_event_the_ledger_or_the_auto_revert(self):
        lane.STEP_RUNS.clear()
        held = ['not merged: held for T3: the /lane T3 request for this head (abc1234) has no lane report yet.']
        wanted = lane.identity('auto', HEAD, BASE, [])
        note = lane.event_note('INCONCLUSIVE', 'auto', HEAD, BASE, 0, None, hold=lane.held_for_t3_report('INCONCLUSIVE', held))
        body = lane.report('pr1-r1', 'INCONCLUSIVE', HEAD, BASE, 'auto', 'hosted', 0, 'nothing', held, 'none', '/e', 'n',
                           wanted, event=note)
        event = lane_event.parse(body)
        self.assertEqual((event['fault'], event['hold'], event['steps']), (False, True, []))
        # The ledger takes its results from the step runs, and a hold ran no step: nothing for it to call a fault.
        import lane_ledger
        with tempfile.TemporaryDirectory() as state:
            self.assertEqual(lane_ledger.record_runs(Path(state), list(lane.STEP_RUNS), 1, HEAD), [])
            self.assertEqual(json.loads(lane_ledger.path(Path(state)).read_text())['steps'], {})
        # The auto-revert already reads a hold as no fault (PENDING_T3_HOLD), and still reads a runner fault as one.
        self.assertEqual(lane.lane_report_verdict(body)[0], False)
        fault = lane.report('pr1-r2', 'INCONCLUSIVE', HEAD, BASE, 'auto', 'hosted', 0, 'nothing',
                            ['The lane itself failed: x'], 'none', '/e', 'n', wanted)
        self.assertEqual(lane.lane_report_verdict(fault)[0], True)
        # "The checks did not finish" is a fault that also waits for T3: its event line keeps fault true.
        unfinished = ['The checks did not finish, so: ' + held[0]]
        self.assertFalse(lane.held_for_t3_report('INCONCLUSIVE', unfinished))
        self.assertEqual(lane.lane_report_verdict(lane.report('pr1-r3', 'INCONCLUSIVE', HEAD, BASE, 'auto', 'x', 0, 'nothing',
                                                              unfinished, 'none', '/e', 'n', wanted))[0], True)

    def test_a_failing_measurement_leaves_the_report_without_a_line(self):
        with mock.patch.object(lane_event, 'build', side_effect=RuntimeError('boom')):
            self.assertEqual(lane.event_note('PASS', 'T2', HEAD, BASE, 1, None), '')

    def test_a_pending_request_keeps_when_it_was_commented(self):
        found = lane.pending_requests([dict(comment('/lane T2'), created_at='2026-10-23T01:02:03Z')])[0]
        self.assertEqual(found['created_at'], '2026-10-23T01:02:03Z')


if __name__ == '__main__':
    unittest.main()
