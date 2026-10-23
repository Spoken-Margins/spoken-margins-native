"""scripts/pipeline_events.py (#2377): lane reports and Actions results as one event file, and the report over it."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import lane_event  # noqa: E402
import pipeline_events as events  # noqa: E402

BOT = {'login': 'github-actions[bot]'}
HEAD, TRUNK, TRUNK_2 = 'a' * 40, 'b' * 40, 'c' * 40


def report_body(request, verdict, tier='auto', where='host only', seconds='9m21s', ran='host tests (--plan fast): passed',
                extra='', head=HEAD, trunk=TRUNK, trunk_name='next', tests=()):
    return (f'Lane report {request} — {verdict}\n'
            f'commit {head[:7]} (tested merged with {trunk_name} at {trunk[:7]}) · tier {tier} · {where} · {seconds}\n'
            f'ran: {ran}\n{extra}crashes: none\nevidence: /x/artifacts/lane/{request} (on the Mac)\n'
            f'not verified: journeys and anything a listener notices (T4), audible content (owner)\n'
            f'<!-- lane-request: {json.dumps({"commit": head, "next": trunk, "tests": list(tests), "tier": tier}, sort_keys=True)} -->\n')


_ids = iter(range(1000, 100000))


def comment(body, pr=500, at='2026-10-20T10:00:00Z', login='github-actions[bot]', association='CONTRIBUTOR', **more):
    return {'id': next(_ids), 'body': body, 'created_at': at, 'issue_url': f'https://api.github.com/x/issues/{pr}',
            'user': {'login': login}, 'author_association': association, **more}


# Real report shapes (paths shortened), the kinds the issue lists.
EXIT_15 = report_body(
    'pr2120-r39288638067', 'FAIL', seconds='12m20s', ran='host tests (--plan fast): fail',
    extra='host tests (--plan fast) — expected: verified. observed: exit -15. evidence: /x/verify-fast.log\n'
          '  [lane] waiting for a host-test slot (662s so far): pid 87904 in /Users/x/actions-runner-3\n')
FAIL_WITH_PASSED_STEPS = report_body(
    'pr1804-r39000126980', 'FAIL', seconds='12m47s',
    extra='ran beside a simulator job (trial): memory pressure normal, 70 GiB free\n'
          'not merged: held for T3: the newest T3 lane report on this PR is FAIL (on 8575bc5)\n')
COMPILE_ERROR = report_body(
    'pr2012-r39092647419', 'FAIL', tier='T3', where='no simulator', seconds='56s', ran='nothing',
    extra='Build before simulator boot: Process exit 65; /x/Gate1AppModel+WrittenMarginDrafts.swift:46:48: error: '
          "cannot find type 'SQLiteSessionStore' in scope\n")
NAMED_FAILURE = report_body(
    'pr1869-r39035318666', 'INCONCLUSIVE', seconds='27m56s', ran='host tests (--plan fast): inconclusive',
    extra='host tests (--plan fast) — expected: verified. observed: exit 1. evidence: /x/verify-fast.log\n'
          '  Process exit 1; Failed: SessionKitCoreTests/VoiceModelInstallerTests/testResumesATransfer (see /x/log)\n'
          'fails on next bb27927 too: not this PR. The failing tests (1) were re-run on plain next bb27927 and failed '
          'there as well. evidence: /x/next-rerun.log\n')
APP_FAIL = report_body(
    'pr1804-r39006743168', 'FAIL', tier='T3', where='cloned iPhone 17, iOS 26.5', seconds='41m09s',
    ran='SupertonicSpeechTests (132 passed, 2 failed; app plan, build and tests, 5m03s); '
        'SupertonicSpeechTests (1 passed; adapters plan, build and tests, 32s)',
    extra='SpokenMarginsAppTests/SupertonicSpeechTests/testAChunkNotRendered — expected: passes. observed: failed\n',
    tests=['SupertonicSpeechTests'])
MAIN_PASS = report_body('pr2490-r39700000000', 'PASS', trunk_name='main', seconds='5m15s',
                        ran='host tests (GitHub-hosted: --plan fast-portable with next at 9717093; Mac: '
                            '--plan fast-mac-rest): passed; ops folder tests: pass')


def lanes(*bodies, **fields):
    return events.lane_events([comment(body, **fields) for body in bodies])


class ReadingReportsTests(unittest.TestCase):
    def test_a_pass_with_main_wording_and_a_pass_with_next_wording(self):
        main, nxt = lanes(MAIN_PASS), lanes(report_body('pr1-r2', 'PASS'))
        self.assertEqual((main[0]['verdict'], main[0]['trunk_name'], main[0]['seconds'], main[0]['tier']),
                         ('PASS', 'main', 315, 'auto'))
        self.assertEqual((nxt[0]['trunk_name'], nxt[0]['head'], nxt[0]['trunk']), ('next', HEAD[:12], TRUNK[:12]))
        self.assertEqual([(s['step'], s['result']) for s in main[0]['steps']],
                         [('host tests', 'pass'), ('ops tests', 'pass')])
        self.assertEqual((main[0]['via'], main[0]['run'], main[0]['pr']), ('pr', 39700000000, 500))

    def test_exit_minus_15_is_a_runner_kill_not_a_failure_of_the_pr(self):
        event = lanes(EXIT_15)[0]
        self.assertEqual(event['label'], {'class': 'fault', 'by': 'heuristic', 'signal': 'runner-kill'})
        self.assertEqual(event['steps'], [{'step': 'host tests', 'result': 'fault', 'seconds': None}])

    def test_a_fail_with_passed_steps_has_no_signal_of_its_own_and_waits_for_later_runs(self):
        event = lanes(FAIL_WITH_PASSED_STEPS)[0]
        self.assertEqual((event['verdict'], event['steps'][0]['result'], 'label' in event), ('FAIL', 'pass', False))

    def test_a_compile_error_is_compile(self):
        self.assertEqual(lanes(COMPILE_ERROR)[0]['label'],
                         {'class': 'compile', 'by': 'heuristic', 'signal': 'swift-error'})

    def test_an_inconclusive_that_fails_on_the_trunk_too_is_trunk_red_and_names_its_test(self):
        found = lanes(NAMED_FAILURE)
        self.assertEqual(found[0]['label']['class'], 'trunk-red')
        self.assertEqual([(e['kind'], e.get('test'), e['label']['class']) for e in found[1:]],
                         [('test-failure', 'SessionKitCoreTests/VoiceModelInstallerTests/testResumesATransfer',
                           'trunk-red')])

    def test_the_app_plans_become_one_step_with_their_summed_seconds(self):
        event = lanes(APP_FAIL)[0]
        self.assertEqual(event['steps'], [{'step': 'app tests (T3)', 'result': 'fail', 'seconds': 335}])
        self.assertEqual((event['requested'], event['seconds']), (['SupertonicSpeechTests'], 2469))

    def test_a_report_with_a_lane_event_line_uses_the_line(self):
        line = lane_event.note(lane_event.build('PASS', 'T3', HEAD, TRUNK, 120, 30, [
            {'step': 'host tests', 'verdict': 'PASS', 'seconds': 40, 'zero_tests': False}], {}))
        event = lanes(report_body('pr1-r9', 'PASS', tier='T3') + line + '\n')[0]
        self.assertEqual((event['source'], event['queue_seconds'], event['seconds']), ('line', 30, 120))
        self.assertEqual(event['steps'], [{'step': 'host tests', 'result': 'pass', 'seconds': 40}])

    def test_hosted_and_desk_reports_are_told_apart_by_their_request_id(self):
        found = lanes(report_body('integration-bf3c3c', 'PASS'), report_body('2-desk-1-2-3', 'PASS'))
        self.assertEqual([e['via'] for e in found], ['integration', 'desk'])

    def test_events_hold_no_text_from_the_report(self):
        text = json.dumps(lanes(EXIT_15, COMPILE_ERROR, NAMED_FAILURE, APP_FAIL))
        for leak in ('/Users', '/x/', 'cannot find', 'SQLiteSessionStore', 'actions-runner', 'pid 87904'):
            self.assertNotIn(leak, text)

    def test_a_test_name_that_is_not_a_test_name_is_not_taken(self):
        body = report_body('pr3-r4', 'FAIL', extra='Failed: not a test; rm -rf / (see /x)\n'
                           'Failed: SessionKitCoreTests/AThingTests/testIt\n')
        self.assertEqual([e['test'] for e in lanes(body) if e['kind'] == 'test-failure'],
                         ['SessionKitCoreTests/AThingTests/testIt'])


    def test_a_slot_wait_line_alone_does_not_make_a_failure_a_fault(self):
        body = report_body('pr5-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n'
                           '  [lane] waiting for a host-test slot (30s so far): pid 1 in /x\n')
        self.assertNotIn('label', lanes(body)[0])

    def test_a_kill_makes_the_host_step_a_fault(self):
        self.assertEqual(lanes(EXIT_15)[0]['steps'][0]['result'], 'fault')

    def test_main_wording_on_a_failing_report_that_fails_on_the_trunk_too(self):
        body = report_body('pr6-r1', 'FAIL', trunk_name='main',
                           extra='  FAIL: test_one (test_mod.AThingTests)\nfails on main bb27927 too: not this PR.\n')
        found = lanes(body)
        self.assertEqual((found[0]['label']['class'], found[1]['test'], found[1]['label']['class']),
                         ('trunk-red', 'test_mod.AThingTests.test_one', 'trunk-red'))
        per_test = report_body('pr6-r2', 'FAIL', trunk_name='main',
                               extra='re-run on plain main bb27927: SessionKitCoreTests/AThingTests/testOne (failed on main), '
                                     'SessionKitCoreTests/AThingTests/testTwo (passed on main)\n'
                                     'Failed: SessionKitCoreTests/AThingTests/testTwo\n')
        self.assertEqual({e['test'][-7:]: e['label']['class'] for e in events.label(lanes(per_test)) if e['kind'] == 'test-failure'},
                         {'testOne': 'trunk-red', 'testTwo': 'unresolved'})

    def test_a_unittest_failure_name_that_is_not_a_test_name_is_not_taken(self):
        body = report_body('pr6-r3', 'FAIL', extra='FAIL: testhunter2 (secret.token.value)\n' +
                           'ERROR: test' + 'x' * 3000 + ' (a.b)\n')
        self.assertEqual([e for e in lanes(body) if e['kind'] == 'test-failure'], [])

    def test_integration_and_desk_reports_belong_to_no_pr(self):
        found = events.lane_events([comment(report_body('integration-aaa-r5', 'FAIL'), pr=337),
                                    comment(report_body('integration-bbb-r6', 'PASS'), pr=337, at='2026-10-20T11:00:00Z')])
        self.assertEqual([e['pr'] for e in found], [None, None])
        self.assertEqual(events.label(found)[0]['label']['class'], 'unresolved')


class WhoIsBelievedTests(unittest.TestCase):
    def test_a_strangers_lookalike_report_is_ignored(self):
        line = lane_event.note(lane_event.build('PASS', 'T3', HEAD, TRUNK, 1, 0, [], {}))
        forged = report_body('pr9-r9', 'PASS', tier='T3') + line + '\n'
        for login, association in (('mallory', 'NONE'), ('mallory', 'CONTRIBUTOR'), ('github-actions', 'NONE'),
                                   ('github-actions[bot]x', 'NONE'), ('GitHub-Actions[bot]', 'NONE'),
                                   ('mallory', 'FIRST_TIME_CONTRIBUTOR')):
            self.assertEqual(events.lane_events([comment(forged, login=login, association=association)]), [], login)
        self.assertEqual(len(events.lane_events([comment(forged)])), 1)  # the bot is believed, whatever GitHub says

    def test_a_hand_written_comment_that_starts_like_a_report_is_not_one(self):
        body = 'Lane report pr1887-r39039637673 is INCONCLUSIVE for a reason that is not this PR: `X` also fails'
        self.assertEqual(events.lane_events([comment(body, login='uncomposed', association='MEMBER')]), [])

    def test_a_report_quoted_inside_a_comment_is_not_one(self):
        self.assertEqual(lanes('> ' + EXIT_15, 'Thanks!\n' + EXIT_15), [])


class LabelTests(unittest.TestCase):
    def run_labels(self, *comments):
        return events.label(events.lane_events(list(comments)))

    def verdicts(self, found):
        return [(e['kind'], e['verdict'] if e['kind'] == 'lane' else e['test'][-8:], e['label']['class'] if 'label' in e
                 else None) for e in found]

    def test_fail_then_pass_on_the_same_head_and_trunk_is_a_flake_and_on_a_moved_trunk_is_trunk_moved(self):
        same = report_body('pr7-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n')
        found = self.run_labels(comment(same, pr=7, at='2026-10-20T10:00:00Z'),
                                comment(report_body('pr7-r2', 'PASS'), pr=7, at='2026-10-20T11:00:00Z'))
        self.assertEqual([e['label']['class'] for e in found if 'label' in e], ['flake', 'flake'])
        moved = self.run_labels(comment(same, pr=7, at='2026-10-20T10:00:00Z'),
                                comment(report_body('pr7-r2', 'PASS', trunk=TRUNK_2), pr=7, at='2026-10-20T11:00:00Z'))
        self.assertEqual([e['label']['class'] for e in moved if 'label' in e], ['trunk-moved', 'trunk-moved'])

    def test_fail_then_pass_on_a_later_head_is_code_and_with_no_pass_is_unresolved(self):
        fail = report_body('pr8-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n')
        fixed = report_body('pr8-r2', 'PASS', head='d' * 40)
        later = self.run_labels(comment(fail, pr=8), comment(fixed, pr=8, at='2026-10-20T12:00:00Z'))
        self.assertEqual([e['label']['class'] for e in later if 'label' in e], ['code', 'code'])
        alone = self.run_labels(comment(fail, pr=8))
        self.assertEqual([e['label']['class'] for e in alone if 'label' in e], ['unresolved', 'unresolved'])

    def test_an_app_test_is_closed_only_by_a_t3_pass_that_asked_for_it(self):
        fail = report_body('pr9-r1', 'FAIL', tier='T3', where='iPhone',
                           extra='SpokenMarginsAppTests/ThingTests/testIt — expected: passes. observed: failed\n',
                           tests=['ThingTests'])
        host_pass = report_body('pr9-r2', 'PASS')
        other_pass = report_body('pr9-r3', 'PASS', tier='T3', tests=['OtherTests'])
        asked = report_body('pr9-r4', 'PASS', tier='T3', tests=['ThingTests'])
        at = ['2026-10-20T10:00:00Z', '2026-10-20T11:00:00Z', '2026-10-20T11:10:00Z', '2026-10-20T11:20:00Z']

        def failure_class(*passes):
            found = self.run_labels(comment(fail, pr=9, at=at[0]),
                                    *[comment(body, pr=9, at=when) for body, when in zip(passes, at[1:])])
            return [e for e in found if e['kind'] == 'test-failure'][0]['label']['class']
        self.assertEqual(failure_class(host_pass, other_pass), 'unresolved')
        self.assertEqual(failure_class(host_pass, other_pass, asked), 'flake')

    def test_a_pass_on_another_pr_or_before_the_failure_closes_nothing(self):
        fail = report_body('pr60-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n')
        other_pr = comment(report_body('pr61-r1', 'PASS'), pr=61, at='2026-10-20T11:00:00Z')
        earlier = comment(report_body('pr60-r0', 'PASS'), pr=60, at='2026-10-20T09:00:00Z')
        found = self.run_labels(comment(fail, pr=60, at='2026-10-20T10:00:00Z'), other_pr, earlier)
        self.assertEqual({e['label']['class'] for e in found if e.get('pr') == 60 and 'label' in e}, {'unresolved'})

    def test_the_same_test_on_different_trunk_commits_stays_separate_in_the_collapsed_count(self):
        body = report_body('prX-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n')
        found = self.run_labels(comment(body.replace('prX', 'pr71'), pr=71),
                                comment(report_body('pr72-r1', 'FAIL', trunk=TRUNK_2,
                                                    extra='Failed: SessionKitCoreTests/AThingTests/testOne\n'), pr=72))
        self.assertIn('2 failing-test rows are 2 distinct (test, trunk commit) pairs', events.report(found))

    def test_a_host_test_failure_is_closed_only_by_a_later_auto_pass(self):
        fail = report_body('pr80-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n')
        at = ['2026-10-20T10:00:00Z', '2026-10-20T11:00:00Z']

        def failure_class(tier):
            found = self.run_labels(comment(fail, pr=80, at=at[0]),
                                    comment(report_body('pr80-r2', 'PASS', tier=tier), pr=80, at=at[1]))
            return [e for e in found if e['kind'] == 'test-failure'][0]['label']['class']
        self.assertEqual([failure_class(tier) for tier in ('T2', 'T3', 'auto')], ['unresolved', 'unresolved', 'flake'])

    def test_a_request_may_name_the_class_with_or_without_its_module(self):
        fail = report_body('pr82-r1', 'FAIL', tier='T3', where='iPhone',
                           extra='SpokenMarginsAppTests/ThingTests/testIt — expected: passes. observed: failed\n',
                           tests=['ThingTests'])

        def failure_class(*asked):
            found = self.run_labels(
                comment(fail, pr=82, at='2026-10-20T10:00:00Z'),
                comment(report_body('pr82-r2', 'PASS', tier='T3', tests=list(asked)), pr=82, at='2026-10-20T11:00:00Z'))
            return [e for e in found if e['kind'] == 'test-failure'][0]['label']['class']
        self.assertEqual([failure_class('SpokenMarginsAppTests/ThingTests'), failure_class('ThingTests'),
                          failure_class('SpokenMarginsAppTests/ThingTests/testIt'), failure_class('OtherTests'),
                          failure_class('SpokenMarginsAppTests'), failure_class('SpokenMarginsAppUITests'),
                          failure_class('SpokenMarginsAppUITests/ThingTests')],
                         ['flake', 'flake', 'flake', 'unresolved', 'flake', 'unresolved', 'unresolved'])

    def test_an_app_test_named_without_its_module_is_still_an_app_test(self):
        fail = report_body('pr81-r1', 'FAIL', tier='T3', where='iPhone', tests=['Gate1AppModelWorkflowTests'],
                           extra='Failed: Gate1AppModelWorkflowTests/testX\n')
        found = self.run_labels(comment(fail, pr=81, at='2026-10-20T10:00:00Z'),
                                comment(report_body('pr81-r2', 'PASS'), pr=81, at='2026-10-20T11:00:00Z'))
        self.assertEqual([e['label']['class'] for e in found if e['kind'] == 'test-failure'], ['unresolved'])
        found = self.run_labels(comment(fail, pr=81, at='2026-10-20T10:00:00Z'),
                                comment(report_body('pr81-r3', 'PASS', tier='T3', tests=['SpokenMarginsAppTests/'
                                                                                          'Gate1AppModelWorkflowTests']),
                                        pr=81, at='2026-10-20T12:00:00Z'))
        self.assertEqual([e['label']['class'] for e in found if e['kind'] == 'test-failure'], ['flake'])

    def test_one_red_trunk_counts_once_however_many_prs_ran_into_it(self):
        body = report_body('prX-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n')
        found = self.run_labels(*[comment(body.replace('prX', f'pr{n}'), pr=n) for n in (21, 22, 23)])
        self.assertEqual({e['label']['signal'] for e in found if e['kind'] == 'test-failure'}, {'multi-pr'})
        text = events.report(found)
        self.assertIn('3 failing-test rows are 1 distinct (test, trunk commit) pairs', text)

    def test_a_step_no_pr_passed_on_one_trunk_commit_is_a_red_trunk(self):
        def failing(n):
            return comment(report_body(f'pr{n}-r1', 'FAIL', ran='host tests (--plan fast): fail'), pr=n)
        three = self.run_labels(failing(31), failing(32), failing(33))
        self.assertEqual({e['label']['signal'] for e in three}, {'multi-pr-step'})
        two = self.run_labels(failing(31), failing(32))
        self.assertEqual({e['label']['class'] for e in two}, {'unresolved'})
        passing = comment(report_body('pr34-r1', 'PASS'), pr=34)
        self.assertEqual({e['label']['class'] for e in self.run_labels(failing(31), failing(32), failing(33), passing)
                          if e['verdict'] != 'PASS'}, {'unresolved'})

    def test_a_label_set_by_someone_else_survives_a_collect(self):
        fail = comment(report_body('pr41-r1', 'FAIL'), pr=41)
        first = events.collect_events([fail], [], [], '2026-10-01T00:00:00Z', [], 'main')
        first[0]['label'] = {'class': 'code', 'by': 'owner', 'signal': 'read-it'}
        again = events.collect_events([fail], [], [], '2026-10-01T00:00:00Z', first, 'main')
        self.assertEqual(again[0]['label']['by'], 'owner')


def run(**fields):
    base = {'id': 7001, 'name': 'hosted-portable', 'path': '.github/workflows/hosted-portable.yml@refs/heads/main',
            'event': 'push', 'head_branch': 'main', 'head_sha': TRUNK, 'conclusion': 'failure', 'run_attempt': 1,
            'created_at': '2026-10-21T10:00:00Z', 'run_started_at': '2026-10-21T10:00:05Z',
            'updated_at': '2026-10-21T10:05:05Z'}
    return {**base, **fields}


def job(**fields):
    base = {'id': 8001, 'run_id': 7001, 'run_attempt': 1, 'name': 'portable tests', 'conclusion': 'failure',
            'created_at': '2026-10-21T10:00:10Z', 'started_at': '2026-10-21T10:00:40Z',
            'completed_at': '2026-10-21T10:04:40Z', 'labels': ['ubuntu-latest'], 'runner_group_name': 'GitHub Actions',
            'steps': [{'name': 'Run tests', 'conclusion': 'failure'}]}
    return {**base, **fields}


class JobTests(unittest.TestCase):
    def labelled(self, *pairs):
        found = []
        for a_run, a_job in pairs:
            summary = events.run_event(a_run, 'main')
            found.append(events.job_event(a_job, summary))
        events.label_jobs(found)
        return found

    def test_run_and_job_events_hold_enums_and_numbers(self):
        summary = events.run_event(run(), 'main')
        self.assertEqual((summary['workflow'], summary['branch'], summary['seconds'], summary['event']),
                         ('hosted-portable', 'trunk', 300, 'push'))
        only = events.job_event(job(), summary)
        self.assertEqual((only['runner'], only['seconds'], only['queue_seconds'], only['failed_step']),
                         ('hosted', 240, 30, 'Run tests'))

    def test_text_in_a_name_is_dropped(self):
        summary = events.run_event(run(path='.github/workflows/x y; curl evil.yml@main', event='surprise'), 'main')
        self.assertEqual((summary['workflow'], summary['event']), ('other', 'other'))
        self.assertEqual(events.job_event(job(name='${{ github.event.pull_request.title }}', labels=['self-hosted']),
                                          summary)['job'], 'other')

    def test_failed_jobs_are_classed_trunk_red_flake_fault_or_code(self):
        trunk, pr = self.labelled((run(), job())), self.labelled(
            (run(event='pull_request', head_branch='ws/1-x'), job()))
        self.assertEqual(trunk[0]['label']['class'], 'trunk-red')
        self.assertEqual(pr[0]['label']['class'], 'code')
        rerun = self.labelled((run(), job()), (run(run_attempt=2), job(id=8002, run_attempt=2, conclusion='success')))
        self.assertEqual([j.get('label', {}).get('class') for j in rerun], ['flake', None])
        setup = self.labelled((run(), job(steps=[{'name': 'Set up job', 'conclusion': 'failure'}])))
        self.assertEqual(setup[0]['label']['signal'], 'job-setup')
        self.assertEqual(self.labelled((run(), job(conclusion='timed_out')))[0]['label']['class'], 'fault')
        self.assertEqual(self.labelled((run(), job(conclusion='cancelled')))[0]['label']['class'], 'cancelled')

    def test_a_failed_lane_job_takes_the_class_of_its_lane_report(self):
        lane_run = run(id=39000000001, path='.github/workflows/lane.yml@refs/heads/main', event='pull_request',
                       head_branch='ws/1-x')
        report = comment(report_body('pr1-r39000000001', 'FAIL', ran='host tests (--plan fast): fail',
                                     extra='exit 124: package ran past its 600s budget\n'), pr=1)
        found = events.collect_events([report], [(lane_run, [job(run_id=39000000001, name='automerge')])], [],
                                      '2026-10-01T00:00:00Z', [], 'main')
        self.assertEqual([e['label']['class'] for e in found if e['kind'] == 'job'], ['fault'])


class FetchTests(unittest.TestCase):
    class Fake:
        def __init__(self):
            self.paths = []

        def get(self, path):
            self.paths.append(path)
            if path.startswith('actions/runs?created='):
                page = int(path.rsplit('page=', 1)[1])
                made = [{'id': 5000 + page * 1000 + n, 'conclusion': 'success'} for n in range(100 if page == 1 else 2)]
                return {'workflow_runs': made if '2026-10-22' in path else []}
            if '/7001/' in path:
                raise RuntimeError('HTTP 502')
            return {'jobs': [{'id': 1}]}

    def test_runs_come_a_day_at_a_time_with_their_jobs_and_a_failed_jobs_call_leaves_the_run_without_jobs(self):
        fake, notes = self.Fake(), []
        found = events.fetch_runs(fake, '2026-10-22T00:00:00Z', True, 'main', notes.append)
        self.assertEqual(len(found), 102)
        self.assertTrue(any(path.endswith('page=2') for path in fake.paths))
        self.assertEqual([jobs for run, jobs in found if run['id'] == 6000][:1], [[{'id': 1}]])
        self.assertEqual([jobs for run, jobs in found if run['id'] == 7001], [[]])
        self.assertEqual(len(notes), 1)
        self.assertTrue(notes[0].startswith('warning: no jobs for run 7001: '))
        self.assertEqual(len(events.fetch_runs(self.Fake(), '2026-10-22T00:00:00Z', False, 'main')), 102)


class CatchTests(unittest.TestCase):
    LINE = json.dumps({'step': 'host tests', 'test': 'SessionKitCoreTests/AThingTests/testOne', 'key': 'pr:12',
                       'from': 'a' * 40, 'to': 'd' * 40, 'class': 'catch', 'seconds': 12.5, 'at': 1792000000})

    def test_a_catch_line_becomes_an_event_with_a_stable_id(self):
        first, second = events.catch_events([self.LINE]), events.catch_events([self.LINE])
        self.assertEqual(first, second)
        self.assertEqual((first[0]['class'], first[0]['pr'], first[0]['at'][:10]), ('catch', 12, '2026-10-14'))

    def test_text_and_junk_lines_are_dropped(self):
        bad = json.dumps({'step': 'x; evil', 'test': '/Users/x/log says boom', 'key': 'pr:12; ls', 'class': 'rm'})
        found = events.catch_events(['not json', '[1]', bad])
        self.assertEqual([(e['step'], e['test'], e['pr'], e['class']) for e in found], [('other', 'other', None, 'other')])


class FileTests(unittest.TestCase):
    def comments(self):
        return [comment(EXIT_15, pr=1, at='2026-10-20T10:00:00Z'), comment(NAMED_FAILURE, pr=2),
                comment(MAIN_PASS, pr=3, at='2026-10-21T10:00:00Z'), comment('Lane report pr1 is nothing')]

    def test_collecting_again_does_not_double_count(self):
        comments = self.comments()
        found = events.collect_events(comments, [(run(), [job()])], [CatchTests.LINE], '2026-10-01T00:00:00Z', [],
                                      'main')
        again = events.collect_events(comments, [(run(), [job()])], [CatchTests.LINE], '2026-10-01T00:00:00Z',
                                      found, 'main')
        self.assertEqual(found, again)
        self.assertEqual(len({e['id'] for e in found}), len(found))
        self.assertEqual(sorted({e['kind'] for e in found}), ['catch', 'job', 'lane', 'run', 'test-failure'])

    def test_since_leaves_older_reports_out_and_keeps_what_the_file_has(self):
        comments = self.comments()
        found = events.collect_events(comments, [], [], '2026-10-21T00:00:00Z', [], 'main')
        self.assertEqual([e['kind'] for e in found], ['lane'])
        older = events.collect_events(comments[:1], [], [], '2026-10-01T00:00:00Z', [], 'main')
        kept = events.collect_events([], [], [], '2026-10-21T00:00:00Z', older, 'main')
        self.assertEqual(kept, older)

    def test_the_command_writes_one_json_object_per_line_and_is_repeatable(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'comments.json'
            source.write_text(json.dumps(self.comments()))
            arguments = ['collect', '--since', '2026-10-01', '--comments-file', str(source), '--out', folder,
                         '--catches', str(Path(folder) / 'none.jsonl')]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(events.main(arguments), 0)
                first = (Path(folder) / 'events.jsonl').read_text()
                self.assertEqual(events.main(arguments), 0)
            self.assertEqual((Path(folder) / 'events.jsonl').read_text(), first)
            self.assertTrue(all(isinstance(json.loads(line), dict) for line in first.splitlines()))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(events.main(['report', '--out', folder]), 0)
            self.assertIn('## Lane reports by tier', out.getvalue())

    def test_a_bad_line_in_the_file_does_not_drop_the_rest(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'events.jsonl'
            good = {'id': 'lane:1', 'kind': 'lane', 'at': '2026-10-20T10:00:00Z'}
            path.write_text(json.dumps(good) + '\n[1]\n{"id": 3}\n{"truncated": tru')
            self.assertEqual(events.read_events(path), [good])
            events.write_events(path, [good])
            self.assertEqual(events.read_events(path), [good])
            self.assertEqual(sorted(p.name for p in Path(folder).iterdir()), ['events.jsonl'])

    def test_since_takes_a_date_or_a_time_and_nothing_else(self):
        self.assertEqual(events.normalise_since('2026-10-17'), '2026-10-17T00:00:00Z')
        with self.assertRaises(SystemExit):
            events.normalise_since('last tuesday')


class ReportTests(unittest.TestCase):
    def test_an_empty_file_reports_no_events(self):
        self.assertIn('No events.', events.report([]))

    def test_the_report_counts_what_it_says(self):
        found = events.collect_events(
            [comment(report_body('pr1-r1', 'FAIL', extra='Failed: SessionKitCoreTests/AThingTests/testOne\n'), pr=1),
             comment(report_body('pr1-r2', 'PASS'), pr=1, at='2026-10-20T11:00:00Z'),
             comment(report_body('pr2-r1', 'PASS'), pr=2, at='2026-10-20T12:00:00Z')],
            [(run(), [job()])], [], '2026-10-01T00:00:00Z', [], 'main')
        text = events.report(found)
        self.assertIn('| auto | 3 | 67% (2/3) | 33% (1/3) | 0% (0/3) | 9m21s | - |', text)
        self.assertIn('FAIL reports that later passed on the same head: 100% (1/1)', text)
        self.assertIn('| hosted-portable / portable tests | hosted | 1 | 0% (0/1) | 100% (1/1) | 0 | trunk-red 1 |', text)
        self.assertIn('No test-catches.jsonl was read', text)


if __name__ == '__main__':
    unittest.main()
