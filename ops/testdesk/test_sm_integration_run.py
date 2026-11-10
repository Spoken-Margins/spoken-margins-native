import contextlib
import os
import shutil
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_integration_run as run

# sim_builds copies and zips apps with ditto, which only macOS has; the lane runs these tests on the Linux VPS.
needs_ditto = unittest.skipUnless(shutil.which('ditto'), 'ditto is macOS-only')

SHA = 'a' * 40
OLD = 'b' * 40
TEST = 'SpokenMarginsAppTests/PlaybackTests/testResume'
OTHER = 'SpokenMarginsAppTests/ImportTests/testPaste'
JOURNEY = 'SpokenMarginsAppUITests/J1ListenToAnArticleJourneyUITests'
GB = 10**9
REPORTED_AT = 1791514182.0  # 2026-10-09T02:49:42Z, the time FakeOps gives its reports


def manifest(tests: dict, interrupted=False, probation=None, retried=()):
    step = {'name': 'xcode-tests', 'tests': {t: {'status': s} for t, s in tests.items()},
            'probation': probation or {}, 'errors': [], 'exit_code': 0, 'passed_on_retry': list(retried)}
    if interrupted:
        step.update(interrupted=True, exit_code=124, simulator_crash_report='SpringBoard.ips')
    failed = any(s == 'failed' and t not in (probation or {}) for t, s in tests.items())
    return {'status': 'failed_or_incomplete' if failed or interrupted else 'verified', 'steps': [step]}


SCREENS = ['01-library-light.png', '01-library-dark.png', '02-item-light.png']


def tour_manifest(tests=None, screens=SCREENS):
    """What verify-tests.py --plan tour writes: the plan's UI test and the exported screenshot names (#381)."""
    done = manifest(tests or {'SpokenMarginsUISeamsUITests/ScreenTourTests/testTour': 'passed'})
    return dict(done, screenshots=list(screens))


def report_comment(sha7, verdict, by='SM integration run'):
    return f'```text\nLane report integration-{sha7} — {verdict}\ncommit {sha7}\nrun by: {by}\n```\n'


def load_phone_build():
    path = run.REPO_ROOT / 'scripts' / 'phone-build'
    loader = importlib.machinery.SourceFileLoader('phone_build', str(path))
    spec = importlib.util.spec_from_loader('phone_build', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


_STATE = tempfile.TemporaryDirectory()
os.environ['SM_LANE_STATE_DIR'] = _STATE.name  # the catch ledger (#1789) must not write to the real lane state
os.environ['SM_SIM_BUILDS'] = str(Path(_STATE.name) / 'sim-builds')  # nor the kept simulator builds


class ReportsTests(unittest.TestCase):
    def test_reads_every_runner_s_reports_as_phone_build_does(self):
        bodies = [report_comment('1111111', 'PASS'), 'chatter about integration-2222222',
                  '**Lane report integration-3333333 — FAIL**\nrun by: Test Desk',
                  report_comment('4444444', 'INCONCLUSIVE', by=run.RUN_BY),
                  report_comment('5555555', 'PASS', by=run.RUN_BY), 'Lane report journeys-6666666 — PASS']
        reports = run.reported(bodies)
        self.assertEqual(reports, [('1111111', 'PASS'), ('3333333', 'FAIL'),
                                   ('4444444', 'INCONCLUSIVE'), ('5555555', 'PASS')])
        self.assertEqual(run.last_green(reports), '5555555')
        self.assertEqual(run.last_green(reports[:3]), '1111111')
        self.assertIsNone(run.last_green([('3333333', 'FAIL')]))


class HoldTests(unittest.TestCase):
    def hold(self, **over):
        args = dict(sha=SHA, state={'results': {}}, reports=[], now=10_000, pressure=1,
                    free_bytes=20 * GB, builds=0, slot_busy=False)
        args.update(over)
        return run.hold_reason(**args)

    def test_runs_when_the_tip_is_new_and_the_mac_has_room(self):
        self.assertIsNone(self.hold())

    def test_each_reason_to_wait(self):
        cases = [(dict(state={'results': {SHA: {}}}), 'already tested'),
                 (dict(reports=[(SHA[:7], 'PASS')]), 'already has an integration report'),
                 (dict(pressure=2), 'warn'),
                 (dict(pressure=None), 'unreadable'),
                 (dict(free_bytes=9 * GB), 'needs 10 GB'),
                 (dict(free_bytes=17 * GB, builds=2), 'needs 18 GB'),
                 (dict(slot_busy=True), 'simulator slot')]
        for over, words in cases:
            with self.subTest(over=over):
                self.assertIn(words, self.hold(**over))
        # No fixed spacing: a new tip right after the last run is tested at once.
        self.assertIsNone(self.hold(state={'results': {OLD: {}}, 'last_started': 10_000 - 60}))
        self.assertIsNone(self.hold(free_bytes=18 * GB, builds=2))

    def test_another_runner_s_report_on_this_tip_counts_once_per_tip(self):
        # The scheduled task and the standing Test Desk post the same heading.
        self.assertIsNone(self.hold(reports=[(OLD[:7], 'PASS')]))
        self.assertIn('already', self.hold(reports=[(OLD[:7], 'PASS'), (SHA[:7], 'FAIL')]))


class LaneYieldTests(unittest.TestCase):
    HOUR = 3600

    def hold(self, waiting, since_tested):
        return run.hold_reason(SHA, {'results': {}}, [], 100_000, 1, 50 * GB, 0, False,
                               waiting, None if since_tested is None else 100_000 - since_tested)

    def test_waiting_lane_app_tests_go_first(self):
        self.assertIn('lane app tests are waiting (#1179, #1172)', self.hold([1179, 1172], 600))
        self.assertIsNone(self.hold([], 600))

    def test_a_busy_lane_cannot_starve_next_for_more_than_three_hours(self):
        self.assertIn('waiting', self.hold([1179], 3 * self.HOUR - 1))
        self.assertIsNone(self.hold([1179], 3 * self.HOUR))
        self.assertIsNone(self.hold([1179], None))  # never tested: test now

    def test_reads_waiting_requests_from_lane_run_names(self):
        runs = [{'status': 'queued', 'displayTitle': 'lane pr=1179 head=debe880 lane=true auto=false'},
                {'status': 'queued', 'displayTitle': 'lane pr=1179 head=ebe9ebc lane=true auto=false'},
                {'status': 'in_progress', 'displayTitle': 'lane pr=1172 head=270f77e lane=true auto=false'},
                {'status': 'queued', 'displayTitle': 'lane pr=1182 head=fdb2ddc lane=false auto=true'},
                {'status': 'waiting', 'displayTitle': 'lane pr=1166 head=3fcf206 lane=true auto=true'},
                {'status': 'completed', 'displayTitle': 'lane pr=1176 head=cce1788 lane=true auto=false'}]
        self.assertEqual(run.lane_requests_waiting(runs), [1179, 1166])

    def test_only_a_t3_or_higher_request_needs_the_simulator(self):
        self.assertTrue(run.needs_simulator(['/lane T2', 'LGTM', '/lane T3\ntests: PlaybackTests']))
        self.assertFalse(run.needs_simulator(['/lane T3', 'later:\n/lane T2']))  # the newest request counts
        self.assertFalse(run.needs_simulator(['Lane report 1179-t3 — PASS', 'no request here']))
        self.assertTrue(run.needs_simulator(['  /lane T4\nrun: J1']))

    def test_newest_report_time_from_any_runner(self):
        comments = [{'created_at': '2026-10-09T02:49:42Z', 'body': report_comment('00769a9', 'PASS')},
                    {'created_at': '2026-10-09T05:00:00Z', 'body': 'Test Desk hand-off'},
                    {'created_at': '2026-10-08T20:00:00Z', 'body': report_comment('eed64d1', 'PASS', by='Test Desk')}]
        self.assertEqual(run.report_time(comments), REPORTED_AT)
        self.assertIsNone(run.report_time(comments[1:2]))


class VerdictTests(unittest.TestCase):
    def test_infrastructure_never_becomes_a_bug_and_probation_never_gates(self):
        self.assertEqual(run.summarize(manifest({TEST: 'failed'}))['verdict'], 'FAIL')
        self.assertEqual(run.summarize(manifest({TEST: 'failed'}, interrupted=True))['verdict'], 'INCONCLUSIVE')
        self.assertEqual(run.summarize({'status': 'failed_or_incomplete', 'steps': []})['verdict'], 'INCONCLUSIVE')
        self.assertEqual(run.summarize({'error': 'boom'})['verdict'], 'INCONCLUSIVE')
        probation = run.summarize(manifest({TEST: 'passed', JOURNEY: 'failed'}, probation={JOURNEY: 'failed'}))
        self.assertEqual(probation['verdict'], 'PASS')
        self.assertEqual(probation['tests'], {TEST: 'passed'})

    def test_a_plan_that_ran_no_test_is_inconclusive_whatever_its_status(self):
        # #2590: no xcodegen on the hosted Mac, so --plan app ran nothing and the job still showed green.
        for plan in ({'status': 'verified', 'steps': []}, manifest({}), manifest({TEST: 'skipped'}),
                     manifest({JOURNEY: 'passed'}, probation={JOURNEY: 'passed'})):
            result = run.summarize(plan)
            self.assertEqual(result['verdict'], 'INCONCLUSIVE', plan)
            self.assertIn('no test ran', result['errors'])
        crashed = run.summarize({'error': "[Errno 2] No such file or directory: 'xcodegen'"})
        self.assertEqual(crashed['errors'], ["[Errno 2] No such file or directory: 'xcodegen'"])
        self.assertEqual(run.summarize(manifest({TEST: 'passed'}))['verdict'], 'PASS')

    def test_the_hosted_job_is_green_only_for_a_pass_or_a_tip_already_reported(self):
        self.assertEqual({v: run.hosted_exit_code(v) for v in ('PASS', 'held', 'FAIL', 'INCONCLUSIVE')},
                         {'PASS': 0, 'held': 0, 'FAIL': 1, 'INCONCLUSIVE': 1})
        with patch.object(run, 'hosted_run', return_value='INCONCLUSIVE'), patch.object(run, 'Ops'), \
                patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': os.devnull}):
            self.assertEqual(run.main(['--hosted', '--sha', SHA]), 1)
        with patch.object(run, 'hosted_run', return_value='PASS'), patch.object(run, 'Ops'), \
                patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': os.devnull}):
            self.assertEqual(run.main(['--hosted', '--sha', SHA]), 0)

    def test_fail_then_pass_on_retry_is_green_and_fail_then_fail_is_red(self):
        # Owner, 2026-10-24: a green run overrides a red one; the flake is reported, not hidden.
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        reruns = [run.summarize(manifest({TEST: 'passed', OTHER: 'failed'}))] * 2
        settled = run.settle(first, reruns)
        self.assertEqual((settled['verdict'], settled['failed'], settled['flaky']), ('FAIL', [OTHER], [TEST]))
        clean = run.settle(first, [run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))] * 2)
        self.assertEqual((clean['verdict'], clean['failed'], clean['flaky']), ('PASS', [], sorted([TEST, OTHER])))
        red = run.settle(first, [run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))] * 2)
        self.assertEqual((red['verdict'], red['flaky']), ('FAIL', []))

    def test_a_rerun_cannot_clear_a_test_it_did_not_pass(self):
        first = run.summarize(manifest({TEST: 'failed'}))
        stopped = run.summarize(manifest({TEST: 'passed'}, interrupted=True))
        failed = run.summarize(manifest({TEST: 'failed'}))
        other_only = run.summarize(manifest({OTHER: 'passed'}))  # the failing test never ran
        for reruns in ([stopped, stopped], [failed, failed], [stopped], [other_only, other_only], [failed, stopped], []):
            with self.subTest(reruns=len(reruns)):
                self.assertEqual(run.settle(first, reruns)['verdict'], 'FAIL')

    def test_a_pass_in_any_completed_rerun_clears_the_test_even_when_the_other_rerun_stopped(self):
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        passed = run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))
        stopped = run.summarize({'status': 'failed_or_incomplete', 'steps': []})
        for reruns in ([passed, stopped], [stopped, passed], [passed]):
            with self.subTest(reruns=[r['verdict'] for r in reruns]):
                settled = run.settle(first, reruns)
                self.assertEqual((settled['verdict'], settled['failed'], settled['flaky']),
                                 ('PASS', [], sorted([TEST, OTHER])))

    def test_a_test_xcodebuild_retried_is_named_in_the_report_and_tallied_once(self):
        # verify-tests.py runs xcodebuild with -retry-tests-on-failure: fail-then-pass is status passed with
        # passed_on_retry in the step. The manifest is the source of retry-passes; the script's own re-runs add to it.
        counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        first = run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}, retried=[TEST]))
        settled = run.settle(first, [])
        self.assertEqual((settled['verdict'], settled['flaky']), ('PASS', [TEST]))
        text = run.report_text('a' * 40, dict(settled, reruns=0, crashes=[], counts=counts),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn(f'passed on retry: {TEST}', text)
        ops = types.SimpleNamespace(posted=[], post_tally=lambda body: ops.posted.append(body),
                                    tally_comments=lambda: [], open_flake_markers=lambda: [],
                                    closed_flake_markers=lambda: {}, log=print)
        run.record_flakes(ops, settled['flaky'], SHA, '1')
        self.assertEqual(len(ops.posted), 1)
        self.assertIn(TEST, ops.posted[0])
        # and a retry inside xcodebuild plus a script re-run of another test are both named, each once
        failing = run.summarize(manifest({TEST: 'passed', OTHER: 'failed'}, retried=[TEST]))
        both = run.settle(failing, [run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}, retried=[TEST]))] * 2)
        self.assertEqual((both['verdict'], both['flaky']), ('PASS', sorted([TEST, OTHER])))

    def test_a_retry_pass_reports_what_its_first_attempt_said(self):
        # #3286: "passed on retry: <name>" alone gave a flake no cause to fix.
        said = 'XCTAssertTrue failed - A tap at the leading edge did not move to the next chapter'
        raw = manifest({TEST: 'passed', OTHER: 'passed'}, retried=[TEST])
        raw['steps'][0]['retry_failures'] = {TEST: [said], OTHER: ['not a retry-pass, so not reported']}
        first = run.summarize(raw)
        self.assertEqual(first['retry_failures'], {TEST: [said], OTHER: ['not a retry-pass, so not reported']})
        settled = run.settle(first, [])
        counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        text = run.report_text('a' * 40, dict(settled, reruns=0, crashes=[], counts=counts),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn(f'passed on retry: {TEST}\n  first attempt said (1 test, e.g. testResume): {said}\n', text)
        self.assertNotIn('not a retry-pass', text)
        ops = types.SimpleNamespace(posted=[], post_tally=lambda body: ops.posted.append(body),
                                    tally_comments=lambda: [], open_flake_markers=lambda: [],
                                    closed_flake_markers=lambda: {}, log=print)
        run.record_flakes(ops, settled['flaky'], SHA, '1', settled['retry_failures'])
        self.assertIn(f"Its first attempt said: `{said}`", ops.posted[0])
        # a re-run that cleared a failed test brings its own message when the first run had none
        failing = run.summarize(manifest({TEST: 'failed'}))
        rerun = manifest({TEST: 'passed'}, retried=[TEST])
        rerun['steps'][0]['retry_failures'] = {TEST: [said]}
        both = run.settle(failing, [run.summarize(rerun)])
        self.assertEqual(both['retry_failures'], {TEST: [said]})
        # no message recorded: today's wording, unchanged
        plain = run.settle(run.summarize(manifest({TEST: 'passed'}, retried=[TEST])), [])
        self.assertNotIn('first attempt said', run.report_text(
            'a' * 40, dict(plain, reruns=0, crashes=[], counts=counts), started=0, finished=1, previous=None,
            suspects=[], evidence=Path('/e')))

    def test_hundreds_of_retry_passes_cannot_make_the_report_too_long_to_post(self):
        # Audit on 6d4e4cf: one note per flaky test could push the report past GitHub's 65,536-character limit.
        counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        tests = [f'SpokenMarginsAppTests/BigTests/test{n:04d}' for n in range(400)]
        launch = 'Failed to launch app with identifier: ' + 'x' * 200
        said = {t: [launch if n % 3 else f'distinct failure number {n} ' + 'y' * 200] for n, t in enumerate(tests)}
        result = dict(verdict='PASS', failed=[], confirmed=[], flaky=tests, retry_failures=said, errors=[], reruns=0,
                      crashes=[], counts=counts, first_failures=[])
        text = run.report_text('a' * 40, result, started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        said_lines = [l for l in text.splitlines() if 'first attempt said' in l]
        self.assertLessEqual(len(said_lines), run.RETRY_SAID_SHOWN)
        self.assertIn('  first attempt said (266 tests, e.g. test0001):', said_lines[0])
        self.assertIn(f'and {len(set(m[0] for m in said.values())) - run.RETRY_SAID_SHOWN} more messages', text)
        self.assertLess(len(text), 30000)

    def test_a_journey_that_passes_on_retry_carries_its_first_message_into_the_report(self):
        # Audit on 6d4e4cf: the journeys' retry-passes were copied but not what their first attempts said (#3669: now
        # the journeys run alone, in run_journeys, and report as their own scripted-journeys report).
        said = "XCTAssertTrue failed - The friend's Margin never started playing"
        listing = {'gating': [{'test': f'{JOURNEY}/testOpen', 'journey': 'J1'}], 'probation': []}
        journeys = manifest({f'{JOURNEY}/testOpen': 'passed'}, retried=[f'{JOURNEY}/testOpen'])
        journeys['steps'][0]['gating'] = {f'{JOURNEY}/testOpen': 'passed'}
        journeys['steps'][0]['retry_failures'] = {f'{JOURNEY}/testOpen': [said]}
        journeys['status'] = 'verified'
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [journeys], listing=listing)
            wt = Path(tmp) / 'wt'
            (wt / 'TestPlans').mkdir(parents=True)
            (wt / 'TestPlans' / 'scripted-journeys.json').write_text(json.dumps(listing))
            result = run.run_journeys(ops, wt, Path(tmp) / 'evidence', (7, 8))
        self.assertEqual(result['verdict'], 'PASS')
        self.assertIn(f'{JOURNEY}/testOpen', result['flaky'])
        self.assertEqual(result['retry_failures'][f'{JOURNEY}/testOpen'], [said])
        text = run.journeys_report_text('a' * 40, result, started=0, finished=1, previous=None, suspects=[],
                                        evidence=Path('/e'), why='a phone build was cut')
        self.assertIn(f'first attempt said (1 test, e.g. testOpen): {said}', text)

    def test_a_test_the_scripts_own_rerun_clears_keeps_its_first_runs_message(self):
        # Audit on e0ffbf2: xcodebuild's retries failed too, so no message was kept for the later re-run pass.
        said = 'XCTAssertTrue failed - A tap at the leading edge did not move'
        raw = manifest({TEST: 'failed'})
        raw['steps'][0]['retry_failures'] = {TEST: [said]}
        first = run.summarize(raw)
        self.assertEqual(first['failed'], [TEST])
        settled = run.settle(first, [run.summarize(manifest({TEST: 'passed'})), run.summarize(manifest({TEST: 'passed'}))])
        self.assertEqual((settled['verdict'], settled['flaky']), ('PASS', [TEST]))
        counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        text = run.report_text('a' * 40, dict(settled, reruns=2, crashes=[], counts=counts),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn(f'first attempt said (1 test, e.g. testResume): {said}', text)
        # a test that stays failed is not a retry-pass, so no message rides on the pass line
        stays = run.settle(first, [run.summarize(manifest({TEST: 'failed'}))] * 2)
        self.assertEqual((stays['verdict'], stays['flaky']), ('FAIL', []))
        self.assertNotIn('first attempt', run.report_text(
            'a' * 40, dict(stays, reruns=2, crashes=[], counts=counts), started=0, finished=1, previous=None,
            suspects=[], evidence=Path('/e')))

    def test_a_run_with_no_retries_says_none(self):
        counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        settled = run.settle(run.summarize(manifest({TEST: 'passed'})), [])
        self.assertEqual((settled['verdict'], settled['flaky']), ('PASS', []))
        text = run.report_text('a' * 40, dict(settled, reruns=0, crashes=[], counts=counts),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn('passed on retry: none', text)

    def test_a_test_that_fails_both_attempts_is_still_a_fail_and_never_a_retry_pass(self):
        # Even if a manifest wrongly lists it, a test that ended failed is not a retry-pass.
        first = run.summarize(manifest({TEST: 'failed'}, retried=[TEST]))
        self.assertEqual((first['verdict'], first['failed'], first['retried']), ('FAIL', [TEST], []))
        settled = run.settle(first, [run.summarize(manifest({TEST: 'failed'}))] * 2)
        self.assertEqual((settled['verdict'], settled['failed'], settled['flaky']), ('FAIL', [TEST], []))

    def test_every_report_has_a_passed_on_retry_line(self):
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        mixed = run.settle(first, [run.summarize(manifest({TEST: 'passed', OTHER: 'passed'})),
                                   run.summarize(manifest({TEST: 'failed', OTHER: 'passed'}))])
        counts = {'passed': 0, 'failed': 0, 'skipped': 0}
        text = run.report_text('a' * 40, dict(mixed, reruns=2, crashes=[], counts=counts),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn('passed on retry: ', text)
        self.assertIn(f'{TEST} (passed in 1 of 2 re-runs, failed in the rest)', text)
        red = run.settle(first, [run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))] * 2)
        text = run.report_text('a' * 40, dict(red, reruns=2, crashes=[], counts=counts),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn('— FAIL', text)
        self.assertIn('passed on retry: none', text)

    def test_settle_leaves_pass_and_inconclusive_alone(self):
        for m in (manifest({TEST: 'passed'}), manifest({TEST: 'failed'}, interrupted=True)):
            first = run.summarize(m)
            self.assertEqual(run.settle(first, [])['verdict'], first['verdict'])


class ReportTextTests(unittest.TestCase):
    def text(self, result, suspects=()):
        return run.report_text(SHA, result, started=1_791_550_000, finished=1_791_550_600,
                               previous=OLD[:7], suspects=list(suspects), evidence=Path('/mac/evidence'))

    def test_pass_report_is_read_by_phone_build_and_names_the_candidate(self):
        result = dict(run.settle(run.summarize(manifest({TEST: 'passed'})), []), reruns=0)
        body = self.text(result)
        phone = load_phone_build()
        self.assertEqual(phone.latest_verdict(SHA, [body]), f'Lane report integration-{SHA[:7]} — PASS')
        self.assertEqual(run.reported([body]), [(SHA[:7], 'PASS')])
        for words in (f'run by: {run.RUN_BY}', f'{run.BASE_BRANCH} moved from {OLD[:7]}', '1 passed, 0 failed',
                      'passed on retry: none', run.NOT_RUN, run.NOT_VERIFIED, '/mac/evidence',
                      f'{SHA[:7]} is the current phone candidate: app tests passed; scripted journeys run when the '
                      'phone build is cut (#3669); attended journeys not run.', run.JOURNEYS_NOT_ON_TIP):
            self.assertIn(words, body)

    def journeys_text(self, journeys, verdict='PASS', gating_failed=(), probation_failed=(), suspects=()):
        result = {'verdict': verdict, 'journeys': journeys, 'gating_failed': list(gating_failed),
                  'probation_failed': list(probation_failed), 'flaky': [], 'crashes': [], 'errors': ['why not'],
                  'minutes': {'scripted journeys': 41}}
        return run.journeys_report_text(SHA, result, started=1_791_550_000, finished=1_791_550_600, previous=OLD[:7],
                                        suspects=list(suspects), evidence=Path('/mac/evidence'),
                                        why='a phone build was cut from this commit')

    def test_a_tip_report_never_lists_journeys_and_says_where_they_run(self):
        """#3669: the integration report is app tests and the tour; a journeys list in it would be stale or invented."""
        body = self.text(dict(run.settle(run.summarize(manifest({TEST: 'passed'})), []), reruns=0,
                              journeys={'J1Tests/testOpen': 'failed'}, minutes={'app': 22, 'screen tour': 5}))
        self.assertNotIn('scripted journeys (only those on gating', body)
        self.assertIn(run.JOURNEYS_NOT_ON_TIP, body)
        self.assertIn('minutes: app 22, screen tour 5', body)
        phone = load_phone_build()
        kinds = {what: (status, detail) for what, status, detail in phone.commit_record([body], SHA)}
        self.assertEqual(kinds['App tests'][0], 'pass')
        self.assertEqual(kinds['Scripted journeys'][0], 'not run')
        self.assertIn('no scripted-journeys report for this commit yet', kinds['Scripted journeys'][1])

    def test_the_journeys_report_says_what_a_pass_covers(self):
        """#1465, #1901: one passing script among skipped and unrun ones is never "scripted journeys passed"."""
        for journeys, words, status in (
                ({'J1Tests/testOpen': 'passed'}, 'scripted journeys passed (1 of 1)', 'pass'),
                ({'J1Tests/testOpen': 'passed', 'J2Tests/b': 'skipped', 'J3Tests/c': 'not_run', 'J7Tests/d': 'passed'},
                 'scripted journeys 2 passed, 0 failed, 1 skipped, 1 not run', 'not run'),
                ({'a/b': 'passed', 'c/d': 'missing'}, 'scripted journeys 1 passed, 1 failed, 0 skipped, 0 not run',
                 'fail')):
            with self.subTest(journeys=journeys):
                body = self.journeys_text(journeys)
                self.assertIn(f'{SHA[:7]}: {words}', body)
                self.assertTrue(body.startswith(f'```text\nLane report scripted-journeys-{SHA[:7]} — PASS\n'))
                self.assertEqual(run.reported([body]), [])          # never an integration report: no previous, no last PASS
                self.assertEqual(run.journey_reported([body]), [(SHA[:7], 'PASS')])
                phone = load_phone_build()
                kinds = {what: st for what, st, _ in phone.commit_record([body], SHA)}
                self.assertEqual(kinds['Scripted journeys'], status)
                self.assertEqual(kinds['App tests'], 'not run')      # this report says nothing about app tests

    def test_a_failing_journeys_report_names_every_merge_since_the_last_pass_and_opens_no_revert(self):
        body = self.journeys_text({'J1Tests/testOpen': 'failed'}, verdict='FAIL', gating_failed=['J1Tests/testOpen'],
                                  suspects=['#1170 Add a thing', '#1169 Fix a thing'])
        self.assertIn(f'merges since the last scripted-journeys PASS ({OLD[:7]}): #1170 Add a thing, #1169 Fix a thing',
                      body)
        self.assertIn('Any of them can be the cause; no revert is opened for a journey.', body)
        self.assertIn('failing: J1Tests/testOpen', body)
        self.assertIn('minutes: scripted journeys 41', body)
        phone = load_phone_build()
        plan = '\n'.join(phone.outcome_lines([body], SHA))
        self.assertIn('Scripted journeys: **fail**', plan)
        self.assertIn('merges since the last scripted-journeys PASS', plan)   # the plan carries the whole range

    def test_the_phone_plan_carries_new_red_and_must_end_only_when_there_is_some(self):
        phone = load_phone_build()
        body = self.journeys_text({'J1Tests/testOpen': 'passed'}).replace(
            f'\ncommit {SHA[:8]}',
            f'\nnew red since the last cut ({OLD[:7]}): J9Tests\nmust end (probation scripts red at 2 or more cuts running): none'
            f'\ncommit {SHA[:8]}', 1)
        plan = '\n'.join(phone.outcome_lines([body], SHA))
        self.assertIn(f'new red since the last cut ({OLD[:7]}): J9Tests', plan)
        self.assertNotIn('must end', plan)   # "none" is quiet, like "failing: none"

    def test_an_inconclusive_journeys_report_is_not_a_pass_or_a_fail(self):
        body = self.journeys_text({}, verdict='INCONCLUSIVE')
        self.assertIn('why inconclusive: why not', body)
        phone = load_phone_build()
        kinds = {what: st for what, st, _ in phone.commit_record([body], SHA)}
        self.assertEqual(kinds['Scripted journeys'], 'not run')

    def test_fail_report_lists_failures_flakes_and_suspect_merges(self):
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        reruns = [run.summarize(manifest({TEST: 'passed', OTHER: 'failed'}))] * 2
        result = dict(run.settle(first, reruns), reruns=2)
        body = self.text(result, ['#1170 Add a thing', '#1169 Fix a thing'])
        self.assertTrue(body.startswith(f'```text\nLane report integration-{SHA[:7]} — FAIL\n'))
        for words in ('re-run 2 times', f'failing: {OTHER}', f'passed on retry: {TEST}',
                      'merges since the last PASS: #1170 Add a thing, #1169 Fix a thing'):
            self.assertIn(words, body)
        self.assertNotIn('phone candidate', body)

    def test_inconclusive_report_says_why(self):
        result = dict(run.summarize({'error': 'git worktree add failed: disk full'}), flaky=[])
        body = self.text(result)
        self.assertIn('— INCONCLUSIVE', body)
        self.assertIn('why inconclusive: git worktree add failed: disk full', body)


class OutcomeWordingTests(unittest.TestCase):
    """Every sentence the report says about how a run ended comes from describe(outcome(...)), so these tables run
    every combination of the record's parts through it (#2590, third audit round: the earlier rounds each fixed
    one branch and the next audit found another)."""
    A, B, R, G, P = 'App/a', 'App/b', 'App/r', 'Journey/g', 'Journey/p'
    VERDICT_SENTENCES = ('outcome', 'failing', 'culprit_why', 'candidate')

    def rows(self):
        def subsets(items):
            return [tuple(x for i, x in enumerate(items) if mask >> i & 1) for mask in range(1 << len(items))]
        for verdict in ('PASS', 'FAIL', 'INCONCLUSIVE'):
            for first in subsets((self.A, self.B)):
                for confirmed in subsets((self.A, self.B)):
                    for retried in subsets((self.A, self.R)):
                        for gating in subsets((self.G,)):
                            for probation in subsets((self.P,)):
                                for trunk in (True, False):
                                    yield dict(verdict=verdict, first_failures=first, confirmed=confirmed,
                                               retry_passes=retried, gating_failed=gating, probation_failed=probation,
                                               trunk=trunk, reruns=2 if first else 0)

    def check(self, row):
        """The problems with the words for one input row; [] when they never contradict the verdict."""
        o = run.outcome(**row)
        w = run.describe(o, sha7='abcdef0', scripted='scripted journeys passed (1 of 1)')
        said = ' '.join(w[k] for k in self.VERDICT_SENTENCES).lower()
        problems = []
        unresolved = set(o.failing)
        # Cole's 2026-10-24 retry rule: fail then pass is green; fail then fail, or fail and never passed, is red.
        should_fail = row['verdict'] != 'INCONCLUSIVE' and bool(
            set(row['confirmed']) | (set(row['first_failures']) - set(row['retry_passes'])) | set(row['gating_failed']))
        if row['verdict'] != 'INCONCLUSIVE' and (o.verdict == 'FAIL') != should_fail:
            problems.append(f'verdict {o.verdict} but should_fail={should_fail}')
        if row['verdict'] == 'INCONCLUSIVE' and o.verdict != 'INCONCLUSIVE':
            problems.append('an inconclusive run became ' + o.verdict)
        if o.verdict == 'FAIL':
            if 'passed' in said:
                problems.append('a FAIL says passed: ' + said)
            if not w['outcome'].startswith('FAIL'):
                problems.append('FAIL outcome sentence: ' + w['outcome'])
            for name in unresolved:
                if name not in w['failing'] or name not in w['outcome']:
                    problems.append(f'{name} failed but is not named as failing')
            if not unresolved:
                problems.append('a FAIL with nothing failing')
        if o.verdict == 'PASS':
            if w['failing'] or 'FAIL' in w['outcome'] or w['culprit_why'] or unresolved:
                problems.append('a PASS names an unresolved failure: ' + str(w))
            for name in row['first_failures']:  # a cleared failure is named only as a retry-pass
                if name in said:
                    problems.append(f'a PASS names {name} outside the retry line')
                if name not in w['retry']:
                    problems.append(f'{name} failed first and passed later but is not named as passed on retry')
        if o.verdict == 'INCONCLUSIVE' and ('PASS' in w['outcome'] or w['candidate']):
            problems.append('an INCONCLUSIVE run claims a pass: ' + str(w))
        failed_for_good = set(o.confirmed) | set(o.gating_failed)
        listed = {n for n in row['retry_passes'] if n not in failed_for_good}
        for name in listed:
            if name not in w['retry']:
                problems.append(f'retry-pass {name} is not named')
        for name in {self.A, self.B, self.R} - listed:
            if name in w['retry']:
                problems.append(f'{name} is listed as passed on retry but is not a retry-pass')
        if not listed and w['retry'] != 'passed on retry: none':
            problems.append('no retry-pass but the line says: ' + w['retry'])
        for name in row['probation_failed']:
            if name in said or 'not verdict input' not in w['probation'] or name not in w['probation']:
                problems.append(f'probation failure {name} is not named as not verdict input')
        if not row['probation_failed'] and w['probation']:
            problems.append('a probation line with no probation failure')
        if run.outcome(**dict(row, probation_failed=())).verdict != o.verdict:
            problems.append('a probation failure changed the verdict')
        if o.verdict == 'PASS':
            if row['trunk'] and 'is the current phone candidate' not in w['candidate']:
                problems.append('a trunk PASS does not name the candidate')
            if not row['trunk'] and ('no phone candidate' not in w['candidate']
                                     or 'is the current phone candidate' in w['candidate']):
                problems.append('a branch PASS calls itself a candidate')
        elif w['candidate']:
            problems.append('a candidate line on ' + o.verdict)
        if o.verdict == 'FAIL' and not o.confirmed and 'gating scripted journey failed' not in w['culprit_why']:
            problems.append('a journey-only FAIL has no culprit reason')
        if (o.verdict != 'FAIL' or o.confirmed) and w['culprit_why']:
            problems.append('a culprit reason when the app tests are searchable')
        return problems

    def test_the_words_never_contradict_the_verdict_in_any_combination(self):
        bad, count = {}, 0
        for row in self.rows():
            count += 1
            problems = self.check(row)
            if problems:
                bad[str(row)] = problems
        self.assertEqual(count, 3 * 4 * 4 * 4 * 2 * 2 * 2)
        self.assertEqual(len(bad), 0, '\n'.join(f'{k}: {v}' for k, v in list(bad.items())[:5]))

    def test_the_audits_case_a_gating_journey_fails_while_the_app_plan_passes(self):
        # 327a481: confirmed=[], verdict FAIL, failed=[journey] was reported as "passed on a re-run".
        row = dict(verdict='FAIL', first_failures=(), confirmed=(), retry_passes=(), gating_failed=(self.G,),
                   probation_failed=(), trunk=True, reruns=0)
        self.assertEqual(self.check(row), [])
        words = run.describe(run.outcome(**row))
        self.assertEqual(words['failing'], f'failing: {self.G}')
        self.assertIn('gating scripted journey failed', words['culprit_why'])
        self.assertNotIn('passed', words['culprit_why'])

    def test_the_check_itself_catches_the_old_wording(self):
        row = dict(verdict='FAIL', first_failures=(), confirmed=(), retry_passes=(), gating_failed=(self.G,),
                   probation_failed=(), trunk=True, reruns=0)
        real = run.describe
        old = 'each failing test passed on a re-run, so there is no stable failure to bisect'
        with patch.object(run, 'describe', lambda o, **kw: dict(real(o, **kw), culprit_why=old)):
            self.assertTrue(any('passed' in p for p in self.check(row)))

    def test_a_first_failure_nothing_passed_is_red_and_a_retry_pass_is_named(self):
        red = run.outcome('PASS', first_failures=(self.A,), reruns=2)   # failed, and no re-run cleared it
        self.assertEqual((red.verdict, red.confirmed), ('FAIL', (self.A,)))
        green = run.outcome('FAIL', first_failures=(self.A,), retry_passes=(self.A,), reruns=2)
        self.assertEqual((green.verdict, green.retry_passes), ('PASS', (self.A,)))
        self.assertIn(self.A, run.describe(green)['retry'])
        self.assertEqual(run.describe(green)['failing'], '')

    def test_a_proof_run_of_another_branch_is_never_a_phone_candidate(self):
        words = run.describe(run.outcome('PASS', trunk=False), sha7='abcdef0')
        self.assertIn('no phone candidate', words['candidate'])
        self.assertNotIn('is the current phone candidate', words['candidate'])


class DiagnosisTests(unittest.TestCase):
    def test_claude_is_headless_read_only_and_cannot_ask(self):
        cmd = run.claude_command(Path('/mac/evidence'))
        self.assertEqual(cmd[cmd.index('--permission-mode') + 1], 'dontAsk')
        self.assertEqual(cmd[cmd.index('--tools') + 1], 'Read,Grep,Glob')
        self.assertEqual(cmd[cmd.index('--add-dir') + 1], '/mac/evidence')
        self.assertEqual(json.loads(cmd[cmd.index('--json-schema') + 1]), run.DIAGNOSIS_SCHEMA)
        for flag in ('-p', '--strict-mcp-config', '--no-session-persistence', '--max-budget-usd'):
            self.assertIn(flag, cmd)
        self.assertFalse(any('Bash' in part or 'Edit' in part or 'Write' in part for part in cmd))
        # Variadic flags must be followed by another flag, or the CLI swallows the next argument.
        for flag in ('--tools', '--add-dir'):
            self.assertTrue(cmd[cmd.index(flag) + 2].startswith('--'))

    def group(self, tests, **over):
        return dict({'tests': tests, 'title': 'Resume plays the wrong item', 'steps': 's', 'expected': 'e',
                     'actual': 'a', 'root_cause': 'r', 'suspect': '#1170: moved the cursor'}, **over)

    def test_only_a_complete_partition_is_accepted(self):
        good = {'groups': [self.group([TEST, OTHER])]}
        self.assertEqual(run.diagnoses(good, [OTHER, TEST]), good['groups'])
        for bad in ({'groups': [self.group([TEST])]}, {'groups': [self.group([TEST, OTHER, TEST])]},
                    {'groups': [self.group([TEST, OTHER], suspect=' ')]}, {'groups': 'nope'}, None, {}):
            with self.subTest(bad=bad):
                fallback = run.diagnoses(bad, [TEST, OTHER])
                self.assertEqual([g['tests'] for g in fallback], [[TEST], [OTHER]])
                self.assertIn('Unconfirmed', fallback[0]['root_cause'])

    def ops(self, tmp, replies):
        calls = []
        def fake_run(cmd, cwd=None, timeout=None, stdin=None, env=None):
            calls.append({'cmd': [str(c) for c in cmd], 'stdin': stdin, 'env': env})
            return replies.pop(0)
        return run.Ops(home=Path(tmp) / 'home', repo_root=Path(tmp), run=fake_run, echo=False), calls

    def test_no_token_means_no_claude_call_and_fallback_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops, calls = self.ops(tmp, [run.Result(44, '', 'item not found')])
            groups, cost = ops.diagnose(Path(tmp), Path(tmp), SHA, [TEST], [])
        self.assertEqual(len(calls), 1)  # the Keychain read only
        self.assertIsNone(cost)
        self.assertIn('Unconfirmed', groups[0]['root_cause'])

    def test_structured_answer_becomes_groups_with_cost_and_token_only_in_env(self):
        answer = {'is_error': False, 'total_cost_usd': 0.42,
                  'structured_output': {'groups': [self.group([TEST])]}}
        with tempfile.TemporaryDirectory() as tmp, patch.object(run, 'CLAUDE', Path(tmp) / 'claude'):
            (Path(tmp) / 'claude').write_text('')
            ops, calls = self.ops(tmp, [run.Result(0, 'tok-123\n'), run.Result(0, json.dumps(answer))])
            groups, cost = ops.diagnose(Path(tmp), Path(tmp), SHA, [TEST], ['#1170 Add a thing'])
            saved = (Path(tmp) / 'diagnosis.json').read_text()
        self.assertEqual((groups[0]['title'], cost), ('Resume plays the wrong item', 0.42))
        claude = calls[1]
        self.assertEqual(claude['env']['CLAUDE_CODE_OAUTH_TOKEN'], 'tok-123')
        self.assertNotIn('tok-123', ' '.join(claude['cmd']) + claude['stdin'] + saved)
        self.assertIn(TEST, claude['stdin'])
        self.assertIn('#1170 Add a thing', claude['stdin'])

    def test_claude_error_or_garbage_falls_back(self):
        for reply in (run.Result(1, 'not json'), run.Result(0, json.dumps({'is_error': True, 'subtype': 'error_max_budget_usd'}))):
            with self.subTest(reply=reply.stdout), tempfile.TemporaryDirectory() as tmp, \
                    patch.object(run, 'CLAUDE', Path(tmp) / 'claude'):
                (Path(tmp) / 'claude').write_text('')
                ops, _ = self.ops(tmp, [run.Result(0, 'tok'), reply])
                groups, _ = ops.diagnose(Path(tmp), Path(tmp), SHA, [TEST], [])
                self.assertIn('Unconfirmed', groups[0]['root_cause'])


class FindDuplicateTests(unittest.TestCase):
    """#1871: a diagnosis went onto a design issue that only cited the failing test as an example."""
    TEST = 'SpokenMarginsAppTests/RealPlaybackMarginCaptureTests/testStreamedMarginStoresPreAndPostEvidence'

    def setUp(self):
        self.texts = {}

    def issue(self, number, body='', labels=(), title='', comments=()):
        # A REST issue object (author_association, user.login, a comment count); the comments' text comes from
        # the trusted comment reader, which `duplicate` stands in for.
        self.texts[number] = list(comments)
        return {'number': number, 'title': title, 'body': body, 'labels': [{'name': name} for name in labels],
                'comments': len(comments), 'author_association': 'OWNER', 'user': {'login': 'uncomposed'}}

    def duplicate(self, *issues, tests=None):
        return run.find_duplicate(list(issues), tests or [self.TEST], lambda n: '\n'.join(self.texts.get(n, [])))

    def test_a_design_issue_that_cites_the_test_is_not_a_duplicate(self):
        design = self.issue(864, f'Batching idea. Example: `{self.TEST}` runs long.', labels=['enhancement', 'deferred'])
        self.assertIsNone(self.duplicate(design))
        # Naming it as the example of a bug does not make a report either, without the regression label.
        self.assertIsNone(self.duplicate(self.issue(865, 'testStreamedMarginStoresPreAndPostEvidence is slow', labels=['bug'])))

    def test_table_of_neighbouring_issues(self):
        name = 'testStreamedMarginStoresPreAndPostEvidence'
        for label, issue, expected in [
            ('regression issue naming the test', self.issue(1872, f'It fails: {name}', labels=['bug', 'regression']), 1872),
            ('run-filed issue with a Failing tests line', self.issue(1873, f'Failing tests: `{self.TEST}`\n\n## Steps'), 1873),
            ('earlier run comment with a Failing tests line',
             self.issue(900, 'Open bug about playback', comments=[f'Failing tests: `{self.TEST}`\n## Steps']), 900),
            ('regression label but no mention of the test', self.issue(901, 'Another test fails', labels=['regression']), None),
            ('the test only inside a Steps line', self.issue(902, f'## Steps\nRun {name}\nFailing tests: `Other/testOther`'), None),
            ('lookalike test name with a regression label',
             self.issue(903, f'{name}2 fails', labels=['regression']), None),
            ('lookalike test name on a Failing tests line',
             self.issue(904, f'Failing tests: `X/Y/pre_{name}`'), None),
            ('report issue #184', self.issue(run.REPORT_ISSUE, f'Failing tests: `{self.TEST}`', labels=['regression']), None),
        ]:
            with self.subTest(label):
                self.assertEqual(self.duplicate(issue), expected)

    def test_the_search_asks_for_open_issues_over_rest(self):
        # The search is an issues search for open issues, over REST: the objects carry the labels and the author's
        # association, which `gh issue list --json` doesn't offer.
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [])
            asked = []
            ops.must = lambda cmd, *a, **k: asked.append(cmd) or run.Result(0, '')
            self.assertEqual(run.Ops.open_issues_matching(ops, self.TEST), [])
        self.assertIn('search/issues', asked[0])
        query = next(arg for arg in asked[0] if arg.startswith('q='))
        self.assertIn('is:issue is:open', query)

    def test_the_first_real_duplicate_wins_over_a_citing_design_issue(self):
        design = self.issue(864, f'Example: {self.TEST}')
        real = self.issue(1872, f'Failing tests: `{self.TEST}`', labels=['bug', 'regression'])
        self.assertEqual(self.duplicate(design, real), 1872)

    def test_a_failure_report_hidden_in_a_long_comment_thread_is_found(self):
        long_thread = self.issue(950, 'Open bug', comments=['x'] * 101)
        found = run.find_duplicate([long_thread], [self.TEST],
                                   lambda number: f'chatter\nFailing tests: `{self.TEST}`\n')
        self.assertEqual(found, 950)
        self.assertIsNone(run.find_duplicate([long_thread], [self.TEST], lambda number: f'only mentions {self.TEST}'))


class FakeOps(run.Ops):
    """Real tick, fake boundaries: git, GitHub, the simulator and Claude."""

    def __init__(self, tmp, plans, bodies=(), waiting=(), listing=None):
        super().__init__(home=Path(tmp) / 'home', repo_root=Path(tmp) / 'repo', run=self.fake_run, echo=False)
        (Path(tmp) / 'repo').mkdir()
        self.sha, self.listing = SHA, listing or {'gating': [], 'probation': []}
        self.waiting = list(waiting)
        self.plans, self.bodies, self.calls, self.posted, self.filed, self.diagnosed = list(plans), list(bodies), [], [], [], []

    def fake_run(self, cmd, cwd=None, timeout=None, stdin=None, env=None):
        cmd = [str(c) for c in cmd]
        self.calls.append(cmd)
        if cmd[:2] == ['git', 'rev-parse']:
            return run.Result(0, self.sha + '\n')
        if cmd[:3] == ['git', 'worktree', 'add']:
            wt = Path(cmd[-2])
            (wt / 'TestPlans').mkdir(parents=True, exist_ok=True)
            (wt / 'TestPlans' / 'scripted-journeys.json').write_text(json.dumps(self.listing))
        if cmd[:2] == ['git', 'log']:
            return run.Result(0, 'Merge pull request #1170 from uncomposed/ws/1170-x\n')
        return run.Result(0, '')

    def report_comments(self):
        return [{'created_at': '2026-10-09T02:49:42Z', 'body': b} for b in self.bodies]

    def lane_waiting(self):
        return self.waiting

    def free_bytes(self):
        return 50 * GB

    def simctl_problem(self):
        return None

    def test_plan(self, wt, output, plan, fds, only=()):
        self.calls.append(['test_plan', output.name, *only])
        return self.plans.pop(0)

    def post_report(self, body, evidence):
        self.posted.append(body)
        return 'https://github.com/report/1'

    def diagnose(self, wt, evidence, sha, failed, suspects, journeys=()):
        self.diagnosed.append((failed, suspects))
        self.diagnosed_journeys = tuple(journeys)
        return run.fallback_groups(failed, journeys), None

    def file_failures(self, groups, sha, report, evidence, cost, labels=run.FAIL_LABELS):
        self.filed.append([g['tests'] for g in groups])
        self.filed_labels = getattr(self, 'filed_labels', []) + [labels]
        return [1200]


@contextlib.contextmanager
def mac_with_room():
    @contextlib.contextmanager
    def slot():
        yield (7, 8)
    with patch.object(run.lane_slots, 'memory_pressure_level', return_value=1), \
            patch.object(run.lane_slots, 'simulator_job_running', return_value=False), \
            patch.object(run, 'exclusive_slot', slot):
        yield


class TickTests(unittest.TestCase):
    def test_simctl_waiting_on_first_launch_holds_with_the_cause(self):
        # #2591: after an Xcode update without its components, every simctl call waited on a password prompt.
        why = 'CoreSimulator is older than Xcode expects (1171.7, Xcode wants 1174.9.2)'
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [], bodies=[report_comment(OLD[:7], 'PASS')])
            with patch.object(ops, 'simctl_problem', return_value=why), patch.object(ops, 'log') as log:
                self.assertEqual(run.tick(ops), 'held')
        self.assertIn(why, ' '.join(str(c) for c in log.call_args_list))
        self.assertFalse(any(c[:3] == ['git', 'worktree', 'add'] for c in ops.calls))
        self.assertEqual(ops.posted, [])

    def test_a_tip_someone_already_reported_starts_nothing(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [], bodies=[report_comment(SHA[:7], 'PASS', by='Test Desk')])
            self.assertEqual(run.tick(ops), 'held')
        self.assertFalse(any(c[:3] == ['git', 'worktree', 'add'] for c in ops.calls))
        self.assertEqual(ops.posted, [])

    def test_waiting_lane_app_tests_hold_a_new_tip(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room(), patch.object(run.time, 'time', return_value=REPORTED_AT + 600):
            ops = FakeOps(tmp, [], bodies=[report_comment(OLD[:7], 'PASS')], waiting=[1179])
            self.assertEqual(run.tick(ops), 'held')
        self.assertEqual(ops.posted, [])

    def test_a_scratch_folder_git_no_longer_knows_is_cleared_not_reported_inconclusive(self):
        # #2397: `git worktree remove` said "<home>/worktree is not a working tree" for a folder left by an
        # interrupted tick, the tick stopped there, and every tip was reported INCONCLUSIVE with 0 tests run.
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [manifest({TEST: 'passed'})], bodies=[report_comment(OLD[:7], 'PASS')])
            leftover = ops.home / 'worktree'
            (leftover / 'junk').mkdir(parents=True)
            first_remove = []

            def refusing(cmd, cwd=None, timeout=None, stdin=None, env=None, base=ops.fake_run):
                if [str(c) for c in cmd[:3]] == ['git', 'worktree', 'remove'] and not first_remove:
                    first_remove.append(cmd)
                    ops.calls.append([str(c) for c in cmd])
                    return run.Result(128, '', f"fatal: '{leftover}' is not a working tree")
                return base(cmd, cwd=cwd, timeout=timeout, stdin=stdin, env=env)

            ops.run = refusing
            self.assertEqual(run.tick(ops), 'PASS')
            self.assertEqual(len(ops.posted), 1)
            self.assertNotIn('INCONCLUSIVE', ops.posted[0])
        self.assertTrue(first_remove, 'the stale folder was never offered to git')
        order = [c[:3] for c in ops.calls if c[:2] == ['git', 'worktree']]
        self.assertIn(['git', 'worktree', 'prune'], [c[:3] for c in order])
        self.assertLess(order.index(['git', 'worktree', 'prune']), order.index(['git', 'worktree', 'add']))

    def test_a_scratch_folder_outside_the_job_home_is_never_deleted_by_hand(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [])
            elsewhere = Path(tmp) / 'precious'
            elsewhere.mkdir()
            ops.run = lambda cmd, **kw: run.Result(128, '', 'not a working tree') if cmd[2:3] == ['remove'] else run.Result(0, '')
            ops.clear_scratch_worktree(elsewhere)
            self.assertTrue(elsewhere.exists())

    def test_pass_posts_one_report_and_records_the_tip(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [manifest({TEST: 'passed'})], bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'PASS')
            state = json.loads((ops.home / 'state.json').read_text())
            self.assertEqual(run.tick(ops), 'held')  # same tip next tick
        self.assertEqual(len(ops.posted), 1)
        self.assertIn(f'{run.BASE_BRANCH} moved from {OLD[:7]}', ops.posted[0])
        self.assertEqual(state['results'][SHA]['verdict'], 'PASS')
        self.assertNotIn('in_progress', state['results'][SHA])
        self.assertEqual(ops.diagnosed, [])
        self.assertTrue(any(c[:3] == ['git', 'worktree', 'remove'] for c in ops.calls))

    def test_two_passing_journeys_runs_name_the_probation_script_that_earned_gating(self):
        # #1901: nothing counted a script's passes, so nothing was ever promoted. #3669: the passes now come from the
        # journeys runs at a phone build, not from every tip.
        listing = {'gating': [], 'probation': [{'test': JOURNEY, 'journey': 'J1'}]}
        passing = manifest({}, probation={f'{JOURNEY}/testOpen': 'passed'})
        passing['status'] = 'verified'
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [passing, passing], bodies=[report_comment(OLD[:7], 'PASS')], listing=listing)
            self.assertEqual(run.journeys_run(ops, SHA, 'a phone build was cut'), 'PASS')
            self.assertEqual(json.loads((ops.home / 'state.json').read_text())['journeys'][JOURNEY],
                             {'passes': 1, 'bad': 0})
            self.assertEqual(run.journeys_run(ops, 'c' * 40, 'a phone build was cut'), 'PASS')
            streaks = json.loads((ops.home / 'state.json').read_text())['journeys']
        self.assertEqual(streaks[JOURNEY], {'passes': 2, 'bad': 0})
        self.assertNotIn('journeys due to move', ops.posted[0])
        self.assertIn('journeys due to move: J1ListenToAnArticleJourneyUITests passed twice running, move to gating',
                      ops.posted[1])

    def test_a_tip_tick_runs_the_app_plan_and_never_the_journeys_plan(self):
        listing = {'gating': [{'test': JOURNEY, 'journey': 'J1'}], 'probation': []}
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [manifest({TEST: 'passed'}), tour_manifest()],
                          bodies=[report_comment(OLD[:7], 'PASS')], listing=listing)
            self.assertEqual(run.tick(ops), 'PASS')
        self.assertEqual([c[1] for c in ops.calls if c[0] == 'test_plan'], ['app', 'tour'])
        self.assertIn(run.JOURNEYS_NOT_ON_TIP, ops.posted[0])

    def test_flaky_failure_is_rerun_twice_and_reported_as_pass_without_claude(self):
        plans = [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), manifest({TEST: 'passed'})]
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'PASS')
        self.assertIn(['test_plan', 'rerun-1', TEST], ops.calls)
        self.assertIn(['test_plan', 'rerun-2', TEST], ops.calls)
        self.assertIn(f'passed on retry: {TEST}', ops.posted[0])
        self.assertEqual((ops.diagnosed, ops.filed), ([], []))

    def test_confirmed_failure_reports_then_diagnoses_and_files(self):
        plans = [manifest({TEST: 'failed'}), manifest({TEST: 'failed'}), manifest({TEST: 'failed'})]
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'FAIL')
            state = json.loads((ops.home / 'state.json').read_text())
        self.assertIn('merges since the last PASS: #1170', ops.posted[0])
        self.assertEqual(ops.diagnosed, [([TEST], ['#1170'])])
        self.assertEqual(ops.filed, [[[TEST]]])
        self.assertEqual(state['results'][SHA]['issues'], [1200])
        log = next(c for c in ops.calls if c[:2] == ['git', 'log'])
        self.assertEqual(log[-1], f'{OLD[:7]}..{SHA}')

    def test_setup_failure_is_reported_inconclusive_and_not_retried(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [])
            original = ops.fake_run
            def broken(cmd, **kw):
                if str(cmd[0]) == 'scripts/setup-worktree.sh':
                    return run.Result(1, '', 'no .venv')
                return original(cmd, **kw)
            ops.run = broken
            self.assertEqual(run.tick(ops), 'INCONCLUSIVE')
            self.assertEqual(run.tick(ops), 'held')
        self.assertIn('why inconclusive: scripts/setup-worktree.sh failed: no .venv', ops.posted[0])
        self.assertEqual(len(ops.posted), 1)

    def test_a_run_cut_off_part_way_is_closed_not_repeated(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [])
            ops.home.mkdir()
            (ops.home / 'state.json').write_text(json.dumps(
                {'last_started': 0, 'results': {SHA: {'started': 0, 'in_progress': True}}}))
            self.assertEqual(run.tick(ops), 'held')
        self.assertEqual(ops.posted, [])


APP_PATH = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift'


def merge(n):
    return {'sha': f'{n:040x}', 'parents': [f'{n - 1:040x}', f'{n + 100:040x}'],
            'subject': f'Merge pull request #{n} from uncomposed/ws/{n}-x', 'body': f'Change {n}'}


class CulpritOps(FakeOps):
    """FakeOps plus the culprit search and the revert: merges #11..#14 since the last PASS; #13 broke TEST."""

    def __init__(self, tmp, plans, paths=(APP_PATH,), open_reverts=(), **kw):
        super().__init__(tmp, plans, **kw)
        self.events, self.paths, self.open_reverts, self.comments, self.reverts = [], list(paths), list(open_reverts), [], []

    def commits_since(self, green, sha):
        self.events.append(('commits_since', green))
        return [merge(n) for n in (11, 12, 13, 14)]

    def check_commit(self, wt, evidence, commit, failed, fds):
        self.events.append(('check', int(commit['sha'], 16)))
        return 'fail' if int(commit['sha'], 16) >= 13 else 'pass'

    def changed_paths(self, commit):
        return self.paths

    def open_revert_prs(self):
        return self.open_reverts

    def reverted_on_base(self, merge_sha):
        return None

    def comment(self, number, text, evidence, name):
        self.comments.append((number, text))

    def open_revert(self, wt, evidence, commit, sha, report, failed, checks, prose):
        self.reverts.append((int(commit['sha'], 16), failed, checks, len(prose)))
        return 'https://github.com/x/y/pull/9001', ''


@contextlib.contextmanager
def recording_slot(events):
    @contextlib.contextmanager
    def slot():
        events.append(('slot', 'held'))
        try:
            yield (7, 8)
        finally:
            events.append(('slot', 'released'))
    with patch.object(run.lane_slots, 'memory_pressure_level', return_value=1), \
            patch.object(run.lane_slots, 'simulator_job_running', return_value=False), \
            patch.object(run, 'exclusive_slot', slot):
        yield


def real_scope():
    """test-scope.py from this checkout, reading the checkout's files whatever root the fake ops has."""
    scope = run.revert.load_test_scope(run.REPO_ROOT)
    return types.SimpleNamespace(
        is_lane_path=scope.is_lane_path, build_scripts=lambda root: scope.build_scripts(run.REPO_ROOT),
        classify_path=lambda root, path, diff='', build=frozenset(): scope.classify_path(run.REPO_ROOT, path, diff, build))


FAILING = [manifest({TEST: 'failed'}), manifest({TEST: 'failed'}), manifest({TEST: 'failed'})]


class CulpritTests(unittest.TestCase):
    def tick(self, tmp, **kw):
        ops = CulpritOps(tmp, FAILING, bodies=[report_comment(OLD[:7], 'PASS')], **kw)
        with recording_slot(ops.events), patch.object(run.revert, 'load_test_scope', return_value=real_scope()):
            verdict = run.tick(ops)
        return ops, verdict, json.loads((ops.home / 'state.json').read_text())

    def test_a_confirmed_fail_finds_the_culprit_while_the_slot_is_held_and_opens_the_revert(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict, state = self.tick(tmp)
        self.assertEqual(verdict, 'FAIL')
        self.assertEqual([e for e in ops.events if e[0] == 'check'], [('check', 12), ('check', 13)])
        self.assertLess(ops.events.index(('check', 13)), ops.events.index(('slot', 'released')))
        self.assertEqual(ops.reverts, [(13, [TEST], [('0000000', 'pass'), ('0000000', 'fail')], 1)])
        self.assertEqual(state['results'][SHA]['revert'], 'https://github.com/x/y/pull/9001')
        self.assertEqual((ops.filed, ops.comments), ([], []))   # the re-land issue replaces the failure issue
        self.assertEqual(state['results'][SHA]['issues'], [])

    def test_each_reason_not_to_revert_tells_the_owner_and_files_the_failure_issue(self):
        cases = [
            ('persistence', dict(paths=['Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift']), 'persistence'),
            ('packet', dict(paths=['Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift']), 'packet'),
            ('lane', dict(paths=['scripts/lane-runner.py']), 'the lane'),
            ('another revert', dict(open_reverts=['#1234']), '#1234'),
            ('ops only (#1417)', dict(paths=['ops/ledger/ledger.py', 'ops/README.md']), 'outside the app build'),
        ]
        for name, kw, words in cases:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                ops, verdict, state = self.tick(tmp, **kw)
                self.assertEqual((verdict, ops.reverts), ('FAIL', []))
                self.assertEqual([n for n, _ in ops.comments], [run.REPORT_ISSUE])
                self.assertIn(words, ops.comments[0][1])
                self.assertIn('#13', ops.comments[0][1])
                self.assertEqual(ops.filed, [[[TEST]]])
                self.assertNotIn('revert', state['results'][SHA])

    def test_a_failed_revert_is_reported_not_swallowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = CulpritOps(tmp, FAILING, bodies=[report_comment(OLD[:7], 'PASS')])
            ops.open_revert = lambda *a: (None, 'git revert -m 1 does not apply cleanly on the newest next (x.swift)')
            with recording_slot(ops.events), patch.object(run.revert, 'load_test_scope', return_value=real_scope()):
                run.tick(ops)
        self.assertIn('does not apply cleanly', ops.comments[0][1])
        self.assertEqual(ops.filed, [[[TEST]]])

    def test_no_single_culprit_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = CulpritOps(tmp, FAILING, bodies=[report_comment(OLD[:7], 'PASS')])
            ops.check_commit = lambda *a: 'unknown'
            with recording_slot(ops.events), patch.object(run.revert, 'load_test_scope', return_value=real_scope()):
                run.tick(ops)
        self.assertEqual(ops.reverts, [])
        self.assertIn('no single culprit merge', ops.comments[0][1])

    def test_without_an_earlier_pass_nothing_is_searched(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = CulpritOps(tmp, FAILING, bodies=[])
            with recording_slot(ops.events), patch.object(run.revert, 'load_test_scope', return_value=real_scope()):
                run.tick(ops)
        self.assertFalse(any(e[0] in ('commits_since', 'check') for e in ops.events))
        self.assertIn('no earlier integration PASS', ops.comments[0][1])

    def test_a_retry_pass_never_searches_or_reverts(self):
        for plans in ([manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), manifest({TEST: 'passed'})],
                      [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), {'status': 'failed_or_incomplete', 'steps': []}]):
            with tempfile.TemporaryDirectory() as tmp:
                ops = CulpritOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
                with recording_slot(ops.events):
                    self.assertEqual(run.tick(ops), 'PASS')
            self.assertEqual((ops.reverts, ops.comments), ([], []))
            self.assertFalse(any(e[0] in ('commits_since', 'check') for e in ops.events))


class ScriptedJourneyOutcomeTests(unittest.TestCase):
    """The journeys run at a phone build, end to end (#3669; #2590, audit on 327a481 for the verdict rules)."""
    GATING = JOURNEY + '/testOpen'
    LISTING = {'gating': [{'test': JOURNEY, 'journey': 'J1'}], 'probation': [{'test': JOURNEY + '2', 'journey': 'J2'}]}

    def journeys(self, gating, probation):
        step = {'name': 'xcode-tests', 'errors': [], 'exit_code': 0, 'passed_on_retry': [],
                'tests': {self.GATING: {'status': gating}, JOURNEY + '2/testOpen': {'status': probation}},
                'gating': {self.GATING: gating}, 'probation': {JOURNEY + '2/testOpen': probation}}
        return {'status': 'verified', 'steps': [step]}

    def journeys_run(self, plans, bodies=(report_comment(OLD[:7], 'PASS'),), **kw):
        with tempfile.TemporaryDirectory() as tmp:
            ops = CulpritOps(tmp, plans, bodies=list(bodies), listing=self.LISTING)
            with recording_slot(ops.events), patch.object(run.revert, 'load_test_scope', return_value=real_scope()):
                verdict = run.journeys_run(ops, SHA, 'a phone build was cut from this commit', **kw)
        return ops, verdict

    NAME = 'J1ListenToAnArticleJourneyUITests'

    def cut(self, sha7, probation, gating='passed', verdict='PASS'):
        """An earlier scripted-journeys report on #184, as the journeys line prints it."""
        return (f'```text\nLane report scripted-journeys-{sha7} \u2014 {verdict}\n'
                f'  scripted journeys (only those on gating are verdict input): '
                f'{self.NAME} {gating}, {self.NAME}2 {probation}\n```\n')

    def test_a_probation_script_red_at_a_second_cut_must_end_and_the_report_leads_with_it(self):
        # #3881: four scripts sat red for days under a bare PASS. The owner's rule (2026-11-09): two cuts at most.
        ops, verdict = self.journeys_run([self.journeys('passed', 'failed')],
                                         bodies=[self.cut('1111111', 'failed'), self.cut('2222222', 'failed')])
        self.assertEqual(verdict, 'PASS')
        lines = ops.posted[0].splitlines()
        self.assertTrue(lines[1].startswith('Lane report scripted-journeys-'))
        self.assertEqual(lines[2], 'new red since the last cut (2222222): none')
        self.assertTrue(lines[3].startswith('must end (probation scripts red at 2 or more cuts running'), lines[3])
        self.assertTrue(lines[3].endswith(f': {self.NAME}2 (3 cuts)'), lines[3])
        self.assertTrue(lines[4].startswith('commit '))

    def test_a_script_that_turns_red_at_this_cut_is_new_red_with_the_merges_since_the_last_cut(self):
        ops, _ = self.journeys_run([self.journeys('passed', 'failed')], bodies=[self.cut('2222222', 'passed')])
        report = ops.posted[0]
        self.assertIn(f'new red since the last cut (2222222; merges since #1170): {self.NAME}2', report)
        self.assertIn('fix the script, or delete the test): none', report)

    def test_the_first_cut_on_record_has_no_range_and_a_green_cut_says_none(self):
        ops, _ = self.journeys_run([self.journeys('passed', 'failed')], bodies=[])
        self.assertIn(f'new red since the last cut (no earlier cut on #184): {self.NAME}2', ops.posted[0])
        ops, _ = self.journeys_run([self.journeys('passed', 'passed')], bodies=[self.cut('2222222', 'failed')])
        self.assertIn('new red since the last cut (2222222): none', ops.posted[0])
        self.assertIn('delete the test): none', ops.posted[0])

    def test_a_rerun_of_the_same_commit_is_not_a_second_cut(self):
        # The earlier report for SHA must not count as a cut again, or one more red run would end a script a cut early.
        ops, _ = self.journeys_run([self.journeys('passed', 'failed')],
                                   bodies=[self.cut('2222222', 'failed'), self.cut(SHA[:7], 'failed')], again=True)
        self.assertIn(f'{self.NAME}2 (2 cuts)', ops.posted[0])

    def test_a_gating_journey_that_fails_is_a_fail_with_one_issue_and_no_revert(self):
        previous = report_comment(OLD[:7], 'PASS').replace('integration-', 'scripted-journeys-')
        ops, verdict = self.journeys_run([self.journeys('failed', 'passed')], bodies=[previous])
        self.assertEqual(verdict, 'FAIL')
        self.assertFalse(any(e[0] in ('commits_since', 'check') for e in ops.events))   # nothing searchable
        self.assertEqual((ops.reverts, ops.comments, ops.diagnosed), ([], [], []))
        report = ops.posted[0]
        self.assertTrue(report.startswith(f'```text\nLane report scripted-journeys-{SHA[:7]} — FAIL'))
        self.assertIn(f'failing: {JOURNEY}', report)
        self.assertIn(f'merges since the last scripted-journeys PASS ({OLD[:7]}): #1170', report)
        self.assertIn('why it ran: a phone build was cut from this commit', report)
        self.assertEqual(ops.filed, [[[JOURNEY]]])
        self.assertEqual(run.reported(ops.posted), [])   # a journeys report is not an integration report

    def test_the_issue_a_failing_journey_files_names_the_whole_range_to_search(self):
        groups = run.journey_fail_groups([JOURNEY], ['#1170 Add a thing', '#1169 Fix a thing'], OLD[:7])
        self.assertEqual(len(groups), 1)
        self.assertIn('#1170 Add a thing, #1169 Fix a thing', groups[0]['suspect'])
        self.assertIn(OLD[:7], groups[0]['suspect'])
        self.assertIn(f'--plan journeys --only-testing {JOURNEY}', groups[0]['steps'])
        text = run.issue_text(groups[0], SHA, 'https://x/report', Path('/e'), None)
        self.assertIn(f'Failing tests: `{JOURNEY}`', text)   # the line find_duplicate reads, so a repeat comments

    def boot_failed(self):
        """What verify-tests.py writes when the simulator boot stops on a crash report: no journey ran (#3519)."""
        boot = {'name': 'simulator-boot', 'exit_code': 1, 'errors': ['assetsd-x.ips while booting']}
        return {'status': 'failed_or_incomplete', 'steps': [boot], 'error': 'simulator-boot: assetsd-x.ips while booting'}

    def test_journeys_that_never_booted_are_inconclusive_not_a_fail(self):
        ops, verdict = self.journeys_run([self.boot_failed(), self.boot_failed()])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual([c[1] for c in ops.calls if c[0] == 'test_plan'], ['journeys', 'journeys-retry'])
        report = ops.posted[0]
        self.assertIn('— INCONCLUSIVE', report)
        self.assertIn('journeys not run: simulator boot failed', report)
        self.assertNotIn('failing:', report)
        self.assertEqual((ops.comments, ops.diagnosed, ops.filed), ([], [], []))

    def test_a_plan_that_ran_no_journey_is_inconclusive_even_without_a_boot_fault(self):
        # No manifest at all (a build failure, a runner exit): nothing was verified, so the gating journey is not "failed".
        broken = {'status': 'failed_or_incomplete', 'steps': [], 'error': 'journeys: runner exit 1, no manifest'}
        ops, verdict = self.journeys_run([broken])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertIn('no scripted journey ran, so nothing was verified', ops.posted[0])
        self.assertEqual(ops.filed, [])

    def stopped(self, gating, probation='not_run', **records):
        """What verify-tests.py wrote at f4e7222 (#3963): three app crashes at launch in a minute stopped the step
        (exit 124, interrupted), and the journey it was on has no record."""
        step = {'name': 'xcode-tests', 'errors': ['Process exit 124'], 'exit_code': 124, 'interrupted': True,
                'simulator_crash_report': '/r/SpokenMarginsApp-2026-11-09-220741.ips', 'passed_on_retry': [],
                'tests': records, 'gating': {self.GATING: gating}, 'probation': {JOURNEY + '2/testOpen': probation}}
        return {'status': 'failed_or_incomplete', 'steps': [step], 'error': 'Process exit 124; No completed tests recorded'}

    def test_a_journey_a_crash_flood_stopped_is_inconclusive_not_a_fail(self):
        ops, verdict = self.journeys_run([self.stopped('missing')])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        report = ops.posted[0]
        self.assertIn('— INCONCLUSIVE', report)
        self.assertNotIn('failing:', report)
        self.assertIn('stopped before these gating journeys finished', report)
        self.assertNotIn('no scripted journey ran', report)   # one reason, not two
        self.assertRegex(report, r'new red since the last cut \([^)]*\): none')   # nor a bad run in the streaks
        self.assertEqual((ops.comments, ops.diagnosed, ops.filed), ([], [], []))

    def test_a_stop_after_a_journey_failed_still_fails_that_one(self):
        # The probation journey had passed; the gating one ran and failed before the stop: a seen failure is red.
        ops, verdict = self.journeys_run([self.stopped('failed', 'passed',
                                                       **{self.GATING: {'status': 'failed'}})])
        self.assertEqual(verdict, 'FAIL')
        self.assertIn(f'failing: {JOURNEY}', ops.posted[0])

    def test_a_stop_that_cut_a_gating_journey_short_is_not_a_pass(self):
        ops, verdict = self.journeys_run([self.stopped('missing', 'passed',
                                                       **{JOURNEY + '2/testOpen': {'status': 'passed'}})])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertIn(f'stopped before these gating journeys finished, so they were not verified: {JOURNEY}',
                      ops.posted[0])
        self.assertEqual(ops.filed, [])

    def test_a_probation_journey_a_stop_cut_short_is_not_named_failed(self):
        ops, verdict = self.journeys_run([self.stopped('failed', 'missing', **{self.GATING: {'status': 'failed'}})])
        self.assertEqual(verdict, 'FAIL')
        self.assertNotIn('probation scripted journeys that failed', ops.posted[0])
        self.assertNotRegex(ops.posted[0], rf'new red since the last cut \([^)]*\): [^\n]*{self.NAME}2')

    def test_a_listed_journey_missing_from_a_run_that_finished_is_still_a_fail(self):
        # Not stopped: a gating script that xcodebuild never ran (a renamed test) is red, so the listing gets fixed.
        ops, verdict = self.journeys_run([self.journeys('missing', 'passed')])
        self.assertEqual(verdict, 'FAIL')
        self.assertIn(f'failing: {JOURNEY}', ops.posted[0])

    def test_a_journeys_boot_fault_that_clears_on_the_retry_is_judged_by_the_journeys(self):
        ops, verdict = self.journeys_run([self.boot_failed(), self.journeys('passed', 'passed')])
        self.assertEqual(verdict, 'PASS')
        self.assertIn('— PASS', ops.posted[0])
        ops, verdict = self.journeys_run([self.boot_failed(), self.journeys('failed', 'passed')])
        self.assertEqual(verdict, 'FAIL')
        self.assertIn(f'failing: {JOURNEY}', ops.posted[0])

    def test_a_probation_journey_that_fails_is_named_and_not_verdict_input(self):
        ops, verdict = self.journeys_run([self.journeys('passed', 'failed')])
        self.assertEqual(verdict, 'PASS')
        self.assertIn(f'probation scripted journeys that failed (not verdict input): {JOURNEY}2', ops.posted[0])
        self.assertNotIn('failing:', ops.posted[0])
        self.assertEqual((ops.comments, ops.diagnosed, ops.filed), ([], [], []))

    def test_the_report_carries_the_plans_minutes(self):
        plans = Path(tempfile.mkdtemp())
        for folder, seconds in (('journeys', [120, 30.4]), ('app', [600]), ('rerun-1', [60]), ('tour', [300])):
            (plans / folder).mkdir()
            (plans / folder / 'manifest.json').write_text(json.dumps({'steps': [{'seconds': x} for x in seconds]}))
        (plans / 'rerun-2').mkdir()
        (plans / 'rerun-2' / 'manifest.json').write_text('not json')
        self.assertEqual(run.plan_minutes(plans), {'app': 11, 'screen tour': 5, 'scripted journeys': 3})
        self.assertEqual(run.plan_minutes(plans / 'nowhere'), {})
        self.assertEqual(run.minutes_line({'app': 11, 'scripted journeys': 3}), 'minutes: app 11, scripted journeys 3')
        self.assertEqual(run.minutes_line({}), '')
        shutil.rmtree(plans)

    def test_a_commit_with_a_pass_or_fail_report_is_not_run_again_and_an_inconclusive_one_is(self):
        def reported(verdict):
            return [f'```text\nLane report scripted-journeys-{SHA[:7]} — {verdict}\n```\n']
        for verdict, plans, expected in (('PASS', [], 'held'), ('FAIL', [], 'held'),
                                         ('INCONCLUSIVE', [self.journeys('passed', 'passed')], 'PASS')):
            with self.subTest(verdict=verdict):
                ops, got = self.journeys_run(plans, bodies=reported(verdict))
                self.assertEqual(got, expected)
                self.assertEqual(len(ops.posted), 0 if expected == 'held' else 1)


class PhoneBuildAsksForJourneysTests(unittest.TestCase):
    """scripts/phone-build is the other half of #3669: every build it delivers asks for the journeys on its commit."""

    def test_deliver_asks_for_the_journeys_after_the_plan_is_written(self):
        import inspect
        phone = load_phone_build()
        source = inspect.getsource(phone.deliver)
        self.assertLess(source.index('share_files(folder, sha)'), source.index('request_journeys(sha)'))
        self.assertLess(source.index('request_journeys(sha)'), source.index('notify_ready(sha, plan)'))

    def test_the_request_names_the_commit_and_never_fails_the_build(self):
        phone = load_phone_build()
        for outcome in (types.SimpleNamespace(returncode=0, stdout='', stderr=''),
                        types.SimpleNamespace(returncode=1, stdout='', stderr='no such commit'), OSError('no python')):
            with self.subTest(outcome=str(outcome)[:30]):
                calls = []

                def fake(cmd, **kw):
                    calls.append(cmd)
                    if isinstance(outcome, Exception):
                        raise outcome
                    return outcome
                with patch.object(phone.subprocess, 'run', fake), patch.object(phone, 'say'):
                    phone.request_journeys(SHA)    # must not raise
                self.assertEqual(calls[0][1:4], [str(run.REPO_ROOT / 'ops' / 'testdesk' / 'sm_integration_run.py'),
                                                 '--journeys-request', SHA])


class JourneysRequestTests(unittest.TestCase):
    """scripts/phone-build asks for the journeys; the launchd tick runs them first (#3669)."""

    def request(self, home, sha=SHA, why='a phone build was cut', at=1_000_000.0):
        return run.write_journeys_request(Path(home), sha, why, at)

    def test_a_request_is_kept_once_and_listed_oldest_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.request(tmp, SHA, 'first', 100.0)
            self.request(tmp, SHA, 'second', 200.0)       # asking twice for one commit keeps the first
            self.request(tmp, OLD, 'older commit, later ask', 150.0)
            found = run.pending_journeys_requests(Path(tmp), 300.0)
        self.assertEqual([(r['sha'], r['why']) for r in found], [(SHA, 'first'), (OLD, 'older commit, later ask')])

    def test_stale_and_unreadable_requests_are_dropped(self):
        with tempfile.TemporaryDirectory() as tmp:
            stale = self.request(tmp, SHA, at=0.0)
            (run.request_dir(Path(tmp)) / ('c' * 40 + '.json')).write_text('{not json')
            (run.request_dir(Path(tmp)) / ('d' * 40 + '.json')).write_text(json.dumps(
                {'sha': 'e' * 40, 'why': 'name does not match the commit', 'requested': 1.0}))
            fresh = self.request(tmp, OLD, at=run.REQUEST_MAX_AGE_SECONDS)
            found = run.pending_journeys_requests(Path(tmp), run.REQUEST_MAX_AGE_SECONDS + 1)
            self.assertEqual([r['sha'] for r in found], [OLD])
            self.assertFalse(stale.exists())
            self.assertTrue(fresh.exists())
            self.assertEqual(sorted(p.name for p in run.request_dir(Path(tmp)).iterdir()), [OLD + '.json'])

    def tick_with(self, tmp, plans, bodies=(), **kw):
        ops = FakeOps(tmp, plans, bodies=list(bodies), listing=ScriptedJourneyOutcomeTests.LISTING)
        self.request(ops.home, ops.sha, 'a phone build was cut from this commit', at=ops.now())
        with mac_with_room():
            return ops, run.tick(ops)

    def test_the_tick_runs_a_requested_commit_first_and_clears_the_request(self):
        passing = ScriptedJourneyOutcomeTests.journeys(ScriptedJourneyOutcomeTests(), 'passed', 'passed')
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict = self.tick_with(tmp, [passing], bodies=[report_comment(OLD[:7], 'PASS')])
            left = list(run.request_dir(ops.home).glob('*.json'))
        self.assertEqual(verdict, 'journeys')
        self.assertEqual([c[1] for c in ops.calls if c[0] == 'test_plan'], ['journeys'])   # not the tip's app plan
        self.assertEqual(run.journey_reported(ops.posted), [(SHA[:7], 'PASS')])
        self.assertEqual(left, [])

    def test_a_request_waits_while_the_mac_has_no_room_and_the_tip_is_not_tested_instead(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [], bodies=[report_comment(OLD[:7], 'PASS')])
            self.request(ops.home, ops.sha, at=ops.now())
            with patch.object(run.lane_slots, 'memory_pressure_level', return_value=2), \
                    patch.object(run.lane_slots, 'simulator_job_running', return_value=False):
                self.assertEqual(run.tick(ops), 'held')
            self.assertEqual(len(list(run.request_dir(ops.home).glob('*.json'))), 1)
        self.assertEqual(ops.posted, [])

    def test_a_request_whose_commit_already_has_a_report_is_cleared_and_the_tick_goes_on(self):
        done = f'```text\nLane report scripted-journeys-{SHA[:7]} — PASS\n```\n'
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict = self.tick_with(tmp, [manifest({TEST: 'passed'}), tour_manifest()],
                                          bodies=[report_comment(OLD[:7], 'PASS'), done])
            left = list(run.request_dir(ops.home).glob('*.json'))
        self.assertEqual(verdict, 'PASS')   # the tip's own run
        self.assertEqual(left, [])

    def test_an_inconclusive_run_is_tried_once_more_and_then_dropped(self):
        broken = {'status': 'failed_or_incomplete', 'steps': [], 'error': 'journeys: runner exit 1, no manifest'}
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [broken, broken], listing=ScriptedJourneyOutcomeTests.LISTING)
            seconds = [run.time.time()]
            def now():  # every look at the clock is a minute later, so two runs never share an evidence folder
                seconds[0] += 60
                return seconds[0]
            ops.now = now
            path = self.request(ops.home, ops.sha, at=ops.now())
            with mac_with_room():
                self.assertEqual(run.tick(ops), 'journeys')
                self.assertTrue(path.exists())      # first attempt: kept
                self.assertEqual(run.tick(ops), 'journeys')
            self.assertFalse(path.exists())         # second attempt: dropped
        self.assertEqual(len(ops.posted), 2)

    def test_a_run_that_raises_is_counted_and_never_stops_the_tips_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [manifest({TEST: 'passed'}), tour_manifest()], bodies=[report_comment(OLD[:7], 'PASS')],
                          listing=ScriptedJourneyOutcomeTests.LISTING)
            clock = [run.time.time()]
            ops.now = lambda: clock.__setitem__(0, clock[0] + 60) or clock[0]
            path = self.request(ops.home, ops.sha, at=ops.now())
            with mac_with_room(), patch.object(run, 'journeys_run', side_effect=RuntimeError('post failed')):
                self.assertEqual(run.take_journeys_request(ops, ops.now(), ops.report_comments()), 'INCONCLUSIVE')
                self.assertTrue(path.exists())                       # first attempt: kept
                self.assertEqual(run.take_journeys_request(ops, ops.now(), ops.report_comments()), 'INCONCLUSIVE')
                self.assertFalse(path.exists())                      # second: dropped, not retried for three days
            with mac_with_room(), patch.object(run, 'journeys_run', side_effect=RuntimeError('post failed')):
                self.request(ops.home, ops.sha, at=ops.now())
                self.assertEqual(run.tick(ops), 'journeys')          # logged, not raised: no 'tick error', the tip waits one tick

    def test_a_busy_simulator_uses_no_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [], listing=ScriptedJourneyOutcomeTests.LISTING)
            path = self.request(ops.home, ops.sha, at=ops.now())
            @contextlib.contextmanager
            def busy():
                raise TimeoutError('Mac-wide simulator slot is busy')
                yield
            with mac_with_room(), patch.object(run, 'exclusive_slot', busy):
                for _ in range(3):
                    self.assertEqual(run.tick(ops), 'held')
            self.assertEqual(json.loads(path.read_text())['attempts'], 0)
        self.assertEqual(ops.posted, [])

    def test_a_request_yields_to_waiting_lane_tests_for_three_hours_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [], waiting=[7], listing=ScriptedJourneyOutcomeTests.LISTING)
            self.request(ops.home, ops.sha, at=ops.now())
            with mac_with_room():
                self.assertEqual(run.tick(ops), 'held')
            self.assertEqual(ops.posted, [])
            passing = ScriptedJourneyOutcomeTests.journeys(ScriptedJourneyOutcomeTests(), 'passed', 'passed')
            ops.plans = [passing]
            (run.request_dir(ops.home) / f'{ops.sha}.json').write_text(json.dumps(
                {'sha': ops.sha, 'why': 'w', 'requested': ops.now() - run.LANE_YIELD_SECONDS - 1, 'attempts': 0}))
            with mac_with_room():
                self.assertEqual(run.tick(ops), 'journeys')

    def test_a_confirmed_hosted_fail_is_handled_before_a_waiting_request(self):
        hosted = hosted_report(OLD[:7], 'FAIL', [TEST])
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [], bodies=[hosted], listing=ScriptedJourneyOutcomeTests.LISTING)
            self.request(ops.home, ops.sha, at=ops.now())
            with patch.object(run, 'journeys_run', side_effect=AssertionError('revert first')), \
                    recording_slot(ops.events):
                run.tick(ops)   # goes on to the hosted FAIL (its own tests cover what it does there)
            self.assertEqual(len(list(run.request_dir(ops.home).glob('*.json'))), 1)

    def test_again_runs_a_commit_that_already_has_a_report(self):
        done = f'```text\nLane report scripted-journeys-{SHA[:7]} — FAIL\n```\n'
        passing = ScriptedJourneyOutcomeTests.journeys(ScriptedJourneyOutcomeTests(), 'passed', 'passed')
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [passing], bodies=[done], listing=ScriptedJourneyOutcomeTests.LISTING)
            self.assertEqual(run.journeys_run(ops, SHA, 'a flake?'), 'held')
            self.assertEqual(run.journeys_run(ops, SHA, 'a flake?', again=True), 'PASS')

    def test_the_command_line_exit_codes_for_an_upload(self):
        cases = (('PASS', 0), ('FAIL', 1), ('INCONCLUSIVE', 1), ('held', 75))
        for verdict, code in cases:
            with self.subTest(verdict=verdict), tempfile.TemporaryDirectory() as tmp:
                ops = FakeOps(tmp, [])
                with patch.object(run, 'Ops', return_value=ops), patch.object(run, 'journeys_run', return_value=verdict), \
                        patch('builtins.print'):
                    self.assertEqual(run.main(['--journeys', '--sha', SHA]), code)
        with tempfile.TemporaryDirectory() as tmp:   # held because an earlier report stands: that report's verdict
            ops = FakeOps(tmp, [], bodies=[f'```text\nLane report scripted-journeys-{SHA[:7]} — FAIL\n```\n'])
            with patch.object(run, 'Ops', return_value=ops), patch.object(run, 'journeys_run', return_value='held'), \
                    patch('builtins.print'):
                self.assertEqual(run.main(['--journeys', '--sha', SHA]), 1)

    def test_dry_run_never_writes_a_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [])
            with patch.object(run, 'Ops', return_value=ops), patch('builtins.print'):
                self.assertEqual(run.main(['--dry-run', '--journeys-request', 'HEAD']), 0)
            self.assertEqual(run.pending_journeys_requests(ops.home, ops.now()), [])

    def test_the_owners_plan_is_rewritten_only_for_the_build_waiting_for_him(self):
        with tempfile.TemporaryDirectory() as tmp:
            phone = Path(tmp) / 'phone'
            (phone / 'latest').mkdir(parents=True)
            ops = FakeOps(tmp, [])
            for sha, rewrites in ((SHA, 1), (OLD, 0)):
                (phone / 'latest' / 'build.json').write_text(json.dumps({'sha': sha}))
                before = len(ops.calls)
                with patch.dict(os.environ, {'SM_PHONE_DIR': str(phone)}):
                    run.refresh_phone_plan(ops, SHA)
                self.assertEqual(sum(1 for c in ops.calls[before:] if c[-1:] == ['--plan-only']), rewrites)
            with patch.dict(os.environ, {'SM_PHONE_DIR': str(phone / 'none')}):
                run.refresh_phone_plan(ops, SHA)   # no phone build at all: nothing to do, nothing raised

    def test_journeys_reports_do_not_count_as_integration_reports(self):
        body = f'```text\nLane report scripted-journeys-{SHA[:7]} — PASS\n```\n'
        self.assertEqual(run.reported([body]), [])
        self.assertEqual(run.last_green(run.reported([body])), None)
        self.assertEqual(run.journey_reported([body, report_comment(OLD[:7], 'PASS')]), [(SHA[:7], 'PASS')])

    def test_the_command_line_asks_without_running_anything(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [])
            with patch.object(run, 'Ops', return_value=ops), patch('builtins.print'):
                self.assertEqual(run.main(['--journeys-request', 'HEAD', '--why', 'a phone build was cut']), 0)
            asked = run.pending_journeys_requests(ops.home, ops.now())
        self.assertEqual([(r['sha'], r['why']) for r in asked], [(SHA, 'a phone build was cut')])
        self.assertFalse(any(c[:3] == ['git', 'worktree', 'add'] for c in ops.calls))


class FlakeTallyTests(unittest.TestCase):
    NOW = run.dt.datetime(2026, 10, 24, 12, 0, tzinfo=run.dt.timezone.utc)

    def comment(self, test, run_id, days_ago=1, login='github-actions[bot]'):
        when = self.NOW - run.dt.timedelta(days=days_ago)
        return {'body': run.tally_line(test, SHA, run_id, when) + '\n\nnote', 'user': {'login': login}}

    def test_counts_keep_the_last_7_days_bot_comments_and_one_per_run(self):
        comments = [self.comment(TEST, '1'), self.comment(TEST, '2'), self.comment(TEST, '2'),
                    self.comment(TEST, '3', days_ago=8), self.comment(OTHER, '4'),
                    self.comment(TEST, '5', login='mallory'), self.comment(TEST, '6', login='github-actions'),
                    {'body': 'flake-tally: nonsense', 'user': {'login': 'github-actions[bot]'}}]
        self.assertEqual(run.tally_counts(comments, self.NOW), {TEST: ['1', '2'], OTHER: ['4']})

    def test_an_issue_is_due_at_three_and_not_when_one_is_open(self):
        counts = {TEST: ['1', '2', '3'], OTHER: ['4', '5']}
        self.assertEqual(run.tests_due_an_issue(counts, set()), [TEST])
        self.assertEqual(run.tests_due_an_issue(counts, {TEST}), [])

    def issue_for(self, test, login='github-actions[bot]', association='NONE'):
        title, body = run.flake_issue_text(test, ['1', '2', '3'])
        return {'title': title, 'body': body, 'author_association': association, 'user': {'login': login}}

    def test_a_long_test_name_does_not_open_a_duplicate(self):
        long_test = 'SpokenMarginsAppTests/Gate1AppModelPlaybackTests/' + 'testResumeAfterTheRouteChangesWhileTheSourceIsBuffering' * 3
        title, _ = run.flake_issue_text(long_test, ['1', '2', '3'])
        self.assertLessEqual(len(title), run.FLAKE_TITLE_MAX)
        self.assertTrue(title.endswith('…'))  # cut to fit, so a match on the title could never succeed
        markers = run.flake_markers([self.issue_for(long_test)])
        self.assertEqual(run.tests_due_an_issue({long_test: ['1', '2', '3']}, markers), [])

    def test_a_name_that_is_a_prefix_of_an_open_issues_name_is_still_due(self):
        longer = TEST + 'AfterARouteChange'
        markers = run.flake_markers([self.issue_for(longer)])
        self.assertEqual(run.tests_due_an_issue({TEST: ['1', '2', '3']}, markers), [TEST])
        self.assertEqual(run.tests_due_an_issue({longer: ['1', '2', '3']}, markers), [])

    def test_a_short_name_still_dedupes_through_its_marker(self):
        markers = run.flake_markers([self.issue_for(TEST)])
        self.assertEqual(markers, {TEST})
        self.assertEqual(run.tests_due_an_issue({TEST: ['1', '2', '3']}, markers), [])

    def test_a_strangers_marker_does_not_hide_a_flake(self):
        stranger = self.issue_for(TEST, login='mallory')
        self.assertEqual(run.flake_markers([stranger]), set())
        self.assertEqual(run.flake_markers([self.issue_for(TEST, login='mallory', association='COLLABORATOR')]), {TEST})

    def test_a_hosted_trunk_run_tallies_and_opens_the_issue_once(self):
        class Tally(run.Ops):
            def __init__(self):
                self.posted, self.opened, self.issues = [], [], []
                self.old = [self_comment.comment(TEST, '1'), self_comment.comment(TEST, '2')]
                self.logs = []
            def log(self, text): self.logs.append(text)
            def post_tally(self, body): self.posted.append(body); self.old.append({'body': body, 'user': {'login': 'github-actions[bot]'}})
            def tally_comments(self): return self.old
            def open_flake_markers(self): return run.flake_markers(self.issues)
            def closed_flake_markers(self): return {}
            def open_flake_issue(self, title, body): self.opened.append((title, body)); return 'url'
        self_comment = self
        ops = Tally()
        with patch.object(run.dt, 'datetime', wraps=run.dt.datetime) as clock:
            clock.now.return_value = self.NOW
            opened = run.record_flakes(ops, [TEST], SHA, '9')
        self.assertTrue(ops.posted[0].startswith(f'flake-tally: {TEST} {SHA[:7]} 9 '))
        self.assertEqual((opened, len(ops.opened)), (['url'], 1))
        self.assertIn(TEST.rsplit('/', 1)[-1], ops.opened[0][0])
        ops.issues = [{'body': ops.opened[0][1], 'user': {'login': 'github-actions[bot]'}}]
        self.assertEqual(run.record_flakes(ops, [TEST], SHA, '10'), [])

    def test_one_new_pass_after_a_fixed_flake_does_not_reopen_it(self):
        # Audit on 4ef3196: passes from before a flake issue was closed counted toward a second issue.
        class Tally(run.Ops):
            def __init__(self, old, closed):
                self.posted, self.opened, self.old, self.closed = [], [], old, closed
            def log(self, text): raise AssertionError(text)
            def post_tally(self, body): self.posted.append(body); self.old.append({'body': body, 'user': {'login': 'github-actions[bot]'}})
            def tally_comments(self): return self.old
            def open_flake_markers(self): return set()
            def closed_flake_markers(self): return run.flake_tally.closed_flake_markers(self.closed)
            def open_flake_issue(self, title, body): self.opened.append((title, body)); return 'url'
        closed_at = (self.NOW - run.dt.timedelta(days=3)).strftime('%Y-%m-%dT%H:%M:%SZ')
        fixed = dict(self.issue_for(TEST), state='closed', closed_at=closed_at)
        with patch.object(run.dt, 'datetime', wraps=run.dt.datetime) as clock:
            clock.now.return_value = self.NOW
            ops = Tally([self.comment(TEST, str(i), days_ago=5 - i * 0.5) for i in range(3)], [fixed])
            self.assertEqual(run.record_flakes(ops, [TEST], SHA, '9'), [])
            again = Tally([self.comment(TEST, str(i), days_ago=2 - i * 0.5) for i in range(2)], [fixed])
            self.assertEqual(run.record_flakes(again, [TEST], SHA, '9'), ['url'])

    def test_a_branch_proof_run_tallies_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), manifest({TEST: 'passed'})],
                            bodies=[report_comment(SHA[:7], 'PASS')])
            with recording_slot(ops.events), patch.object(run, 'record_flakes', side_effect=AssertionError('no tally')), \
                    patch.dict(os.environ, {'GITHUB_RUN_ID': '42'}):
                self.assertEqual(run.hosted_run(ops, SHA, post=False), 'PASS')


class StrangerTests(unittest.TestCase):
    """#1822: once the repo is public, a stranger can file an issue naming a failing test, or post a /lane T3 request
    or a fake desk report. None of it may steer the desk or take over a failure report."""
    OWNER = {'author_association': 'OWNER', 'user': {'login': 'uncomposed'}}
    STRANGER = {'author_association': 'NONE', 'user': {'login': 'mallory'}}

    def issue(self, number, who, comments=0, title='Flaky', body=f'{TEST} fails'):
        return dict(who, number=number, title=title, body=body, comments=comments, labels=[{'name': 'regression'}])

    def test_a_strangers_issue_naming_the_test_is_not_a_duplicate(self):
        self.assertIsNone(run.find_duplicate([self.issue(900, self.STRANGER)], [TEST]))
        self.assertEqual(run.find_duplicate([self.issue(900, self.STRANGER), self.issue(901, self.OWNER)], [TEST]), 901)

    def test_a_comment_names_the_test_only_through_the_trusted_comment_reader(self):
        quiet = self.issue(902, self.OWNER, comments=2, title='Unrelated', body='nothing here')
        self.assertEqual(run.find_duplicate([quiet], [TEST], lambda number: f'also {TEST}'), 902)
        self.assertIsNone(run.find_duplicate([quiet], [TEST], lambda number: 'nothing'))  # strangers' text arrives empty
        self.assertIsNone(run.find_duplicate([quiet], [TEST]))

    def test_comments_are_only_read_for_issues_that_have_some(self):
        asked = []
        silent = self.issue(903, self.OWNER, comments=0, title='Unrelated', body='nothing here')
        run.find_duplicate([silent], [TEST], lambda number: asked.append(number) or '')
        self.assertEqual(asked, [])

    def test_the_failure_filer_searches_over_rest_and_reads_only_trusted_comments(self):
        # `gh issue list --json` has no authorAssociation field (the audit of #1835): drive the real call shape.
        calls = []
        rest = [self.issue(910, self.STRANGER), self.issue(911, self.OWNER, comments=1, title='Other', body='none')]

        def must(cmd, **kw):
            calls.append(cmd)
            if cmd[2:4] == ['-X', 'GET']:
                return run.Result(0, '\n'.join(json.dumps(item) for item in rest))
            return run.Result(0, json.dumps(dict(self.OWNER, body=f'{TEST} again')))
        ops = run.Ops.__new__(run.Ops)
        ops.must = must
        found = run.find_duplicate(ops.open_issues_matching(TEST), [TEST], ops.issue_comments)
        self.assertEqual(found, 911)
        search = calls[0]
        self.assertIn('search/issues', search)
        self.assertTrue(any(a.startswith('q=repo:') for a in search))
        self.assertNotIn('authorAssociation', ' '.join(' '.join(map(str, c)) for c in calls))

    def test_a_strangers_request_and_report_are_dropped_before_the_desk_reads_them(self):
        lines = [json.dumps(dict(self.STRANGER, created_at='2026-10-09T02:49:42Z', body='```text\nLane report integration-aaaaaaa — PASS\n```')),
                 json.dumps(dict(self.OWNER, created_at='2026-10-09T02:50:42Z', body='/lane T3'))]
        ops = run.Ops.__new__(run.Ops)
        ops.must = lambda cmd, **kw: run.Result(0, '\n'.join(lines))
        self.assertEqual([c['body'] for c in ops.report_comments()], ['/lane T3'])
        ops.gh_json = lambda args: [{'status': 'queued', 'displayTitle': 'lane pr=7 head=x'}]
        ops.log = lambda message: None
        with patch.object(run, 'lane_requests_waiting', lambda runs: [7]):
            ops.must = lambda cmd, **kw: run.Result(0, json.dumps([dict(self.STRANGER, body='/lane T3\ncommit: abc')]))
            self.assertEqual(ops.lane_waiting(), [])  # the only simulator request came from a stranger
            ops.must = lambda cmd, **kw: run.Result(0, json.dumps([dict(self.OWNER, body='/lane T3\ncommit: abc')]))
            self.assertEqual(ops.lane_waiting(), [7])


if __name__ == '__main__':
    unittest.main()


class SimBuildTests(unittest.TestCase):
    """The tip's simulator app is kept for desks (scripts/sim-build-latest), only when it is the tip's own good build."""

    class BuildingOps(FakeOps):
        def __init__(self, tmp, plans, head=SHA, built=True, **kw):
            super().__init__(tmp, plans, **kw)
            self.head, self.built = head, built

        def test_plan(self, wt, output, plan, fds, only=()):
            result = super().test_plan(wt, output, plan, fds, only)
            app = (wt / '.build/verification/SpokenMarginsAppBehavior/Build/Products/Debug-iphonesimulator'
                   / 'SpokenMarginsApp.app')
            app.mkdir(parents=True, exist_ok=True)
            (app / 'Info.plist').write_text('<plist/>')
            steps = [{'name': 'build-for-testing', 'exit_code': 0 if self.built else 65}]
            if self.built:
                steps.append({'name': 'bundle-contracts', 'exit_code': 0})
            output.mkdir(parents=True, exist_ok=True)
            (output / 'manifest.json').write_text(json.dumps(dict(result, head=self.head,
                                                                  steps=steps + result['steps'])))
            return result

    def setUp(self):
        self.root = Path(os.environ['SM_SIM_BUILDS'])
        run.shutil.rmtree(self.root, ignore_errors=True)

    @needs_ditto
    def test_a_tested_tip_leaves_its_app_and_latest_points_at_it(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = self.BuildingOps(tmp, [manifest({TEST: 'passed'})], bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'PASS')
            log = (ops.home / 'log.txt').read_text()
        self.assertEqual(run.sim_builds.latest(self.root)['sha'], SHA)
        self.assertIn('simulator build kept', log)

    @needs_ditto
    def test_a_failing_tip_is_still_kept_for_desks(self):
        plans = [manifest({TEST: 'failed'})] * 3
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = self.BuildingOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'FAIL')
        self.assertEqual(run.sim_builds.latest(self.root)['sha'], SHA)

    def test_a_broken_build_or_another_commit_s_build_is_not_kept(self):
        for head, built, why in ((SHA, False, 'no good simulator build'), (OLD, True, 'not ' + SHA[:7])):
            with self.subTest(why=why), tempfile.TemporaryDirectory() as tmp, mac_with_room():
                ops = self.BuildingOps(tmp, [manifest({TEST: 'passed'})], head=head, built=built,
                                       bodies=[report_comment(OLD[:7], 'PASS')])
                run.tick(ops)
                self.assertIn(why, (ops.home / 'log.txt').read_text())
                self.assertIsNone(run.sim_builds.latest(self.root))

    def test_no_copy_when_the_build_left_the_mac_under_ten_gigabytes(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = self.BuildingOps(tmp, [manifest({TEST: 'passed'})], bodies=[report_comment(OLD[:7], 'PASS')])
            room = iter([50 * GB, 9 * 1024 ** 3])  # room to start; the build itself ate the rest
            with patch.object(ops, 'free_bytes', side_effect=lambda: next(room)):
                self.assertEqual(run.tick(ops), 'PASS')
            self.assertIn('under the 10 GB floor', (ops.home / 'log.txt').read_text())
        self.assertIsNone(run.sim_builds.latest(self.root))


def hosted_report(sha7, verdict, failing=()):
    """A report as hosted_run posts it: the bot's comment, `run by: hosted integration`, its failing line."""
    lines = [f'Lane report integration-{sha7} — {verdict}', f'commit {sha7}', f'run by: {run.HOSTED_RUN_BY}']
    if failing:
        lines.append('failing: ' + ', '.join(failing))
    return '```text\n' + '\n'.join(lines) + '\n```\n'


class HostedOps(CulpritOps):
    """CulpritOps with the hosted switch, the checkout's HEAD and a record of every way to the Keychain or Claude."""

    def __init__(self, tmp, plans, hosted=True, runs=({'status': 'in_progress', 'conclusion': None},),
                 tip_age=3600, **kw):
        super().__init__(tmp, plans, **kw)
        self.hosted, self.runs, self.tip_age = hosted, runs if runs is None else list(runs), tip_age

    def hosted_on(self):
        return self.hosted

    def hosted_runs(self, sha):
        self.calls.append(['hosted_runs', sha])
        return self.runs

    def commit_time(self, sha):
        return run.time.time() - self.tip_age

    def test_plan(self, wt, output, plan, fds, only=()):
        output.mkdir(parents=True, exist_ok=True)
        (output / 'tests.xcresult').mkdir()  # bundles must not reach the hosted run's artifact
        return super().test_plan(wt, output, plan, fds, only)


class HostedSwitchTests(unittest.TestCase):
    def test_the_switch_reads_on_only_from_the_variable_and_any_trouble_is_off(self):
        cases = [(run.Result(0, 'on\n'), True), (run.Result(0, 'off\n'), False), (run.Result(0, ''), False),
                 (run.Result(1, '', 'HTTP 404: Not Found'), False), (run.Result(0, 'On\n'), False)]
        for result, expected in cases:
            with self.subTest(result=result.stdout or result.stderr), tempfile.TemporaryDirectory() as tmp:
                calls = []
                ops = run.Ops(home=Path(tmp), repo_root=Path(tmp), echo=False,
                              run=lambda cmd, **kw: calls.append(cmd) or result)
                self.assertIs(ops.hosted_on(), expected)
                self.assertEqual(calls[0][:3], ['gh', 'api', f'repos/{run.REPO}/actions/variables/LANE_HOSTED_APP'])

    def test_switched_off_the_mac_tests_the_new_tip_as_before_whatever_hosted_reported(self):
        # A hosted FAIL on an older tip is someone else's history: with the switch off the Mac neither chases it
        # nor holds back, and tests the new tip once as today.
        bodies = [report_comment(OLD[:7], 'PASS'), hosted_report('c' * 7, 'FAIL', [TEST])]
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [manifest({TEST: 'passed'})], hosted=False, bodies=bodies)
            with recording_slot(ops.events):
                self.assertEqual(run.tick(ops), 'PASS')
            state = json.loads((ops.home / 'state.json').read_text())
        self.assertEqual(len(ops.posted), 1)
        self.assertIn(f'run by: {run.RUN_BY}', ops.posted[0])
        self.assertNotIn('hosted_handled', state)
        self.assertEqual((ops.reverts, ops.comments), ([], []))


class HostedRunTests(unittest.TestCase):
    def hosted_run(self, tmp, plans, bodies=(report_comment(OLD[:7], 'PASS'),)):
        ops = HostedOps(tmp, plans, bodies=list(bodies))
        with recording_slot(ops.events), \
                patch.object(run, 'keep_sim_build', side_effect=AssertionError('no sim build when hosted')), \
                patch.object(run.lane_ledger, 'record_tip', side_effect=AssertionError('no ledger when hosted')), \
                patch.dict(os.environ, {'GITHUB_RUN_ID': '42', 'GITHUB_REPOSITORY': 'uncomposed/spoken-margins-native'}):
            verdict = run.hosted_run(ops, SHA)
        return ops, verdict

    def test_a_confirmed_fail_is_reported_and_nothing_else(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict = self.hosted_run(tmp, FAILING)
            bundles = list((ops.repo_root / 'artifacts').rglob('*.xcresult'))
            state_written = (ops.home / 'state.json').exists()
        self.assertEqual(verdict, 'FAIL')
        self.assertEqual(len(ops.posted), 1)
        self.assertEqual(run.reported(ops.posted), [(SHA[:7], 'FAIL')])  # the same first line phone-build reads
        self.assertIn(f'run by: {run.HOSTED_RUN_BY}', ops.posted[0])
        self.assertIn(f'failing: {TEST}', ops.posted[0])
        self.assertIn('actions/runs/42', ops.posted[0])
        self.assertIn(['test_plan', 'rerun-1', TEST], ops.calls)
        self.assertIn(['test_plan', 'rerun-2', TEST], ops.calls)
        # No culprit search, revert, issue, Claude or Keychain, and no state or bundles left behind.
        self.assertEqual((ops.diagnosed, ops.filed, ops.reverts, ops.comments), ([], [], [], []))
        self.assertFalse(any(e[0] in ('commits_since', 'check') for e in ops.events))
        self.assertFalse(any('security' in c[0] or 'claude' in c[0] for c in ops.calls))
        self.assertFalse(any(c[:2] in (['gh', 'pr'], ['gh', 'issue']) or c[:3] == ['git', 'worktree', 'add']
                             for c in ops.calls))
        self.assertEqual(bundles, [])
        self.assertFalse(state_written)

    def test_a_hosted_run_tests_the_tip_with_the_app_plan_and_the_tour_and_no_journeys(self):
        # #3669: the journeys cost about an hour of a hosted Mac per tip; they run at the phone build instead.
        listing = {'gating': [{'test': JOURNEY, 'journey': 'J1'}], 'probation': []}
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [manifest({TEST: 'passed'}), tour_manifest()], listing=listing,
                            bodies=[report_comment(OLD[:7], 'PASS')])
            (ops.repo_root / 'TestPlans').mkdir(parents=True)
            (ops.repo_root / 'TestPlans' / 'scripted-journeys.json').write_text(json.dumps(listing))
            with recording_slot(ops.events), patch.dict(os.environ, {'GITHUB_RUN_ID': '42'}):
                self.assertEqual(run.hosted_run(ops, SHA), 'PASS')
        self.assertEqual([c[1] for c in ops.calls if c[0] == 'test_plan'], ['app', 'tour'])
        self.assertIn(run.JOURNEYS_NOT_ON_TIP, ops.posted[0])

    def test_a_hosted_tip_run_files_a_failing_tour_test_and_a_proof_run_does_not(self):
        # #3822: the hosted run tours the tip too, so its failing tour tests are tracked the same way.
        failed = tour_manifest({'SpokenMarginsUISeamsUITests/ScreenTourTests/testTour': 'failed'}, screens=[])
        for post, expected in ((True, [[['SpokenMarginsUISeamsUITests/ScreenTourTests/testTour']]]), (False, [])):
            with tempfile.TemporaryDirectory() as tmp:
                ops = HostedOps(tmp, [manifest({TEST: 'passed'}), failed], bodies=[report_comment(OLD[:7], 'PASS')])
                with recording_slot(ops.events), patch.dict(os.environ, {'GITHUB_RUN_ID': '42'}):
                    self.assertEqual(run.hosted_run(ops, SHA, post=post), 'PASS')
            self.assertEqual(ops.filed, expected, post)

    def test_a_pass_names_the_hosted_runner_and_the_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict = self.hosted_run(tmp, [manifest({TEST: 'passed'})])
        self.assertEqual(verdict, 'PASS')
        self.assertIn('hosted-integration.yml on a GitHub-hosted Mac', ops.posted[0])
        self.assertIn(f'{SHA[:7]} is the current phone candidate', ops.posted[0])

    def test_a_tip_already_reported_is_not_tested_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict = self.hosted_run(tmp, [], bodies=[report_comment(SHA[:7], 'PASS')])
        self.assertEqual((verdict, ops.posted), ('held', []))

    def test_a_checkout_at_another_commit_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [])
            ops.sha = OLD
            with self.assertRaises(ValueError):
                run.hosted_run(ops, SHA)
        self.assertEqual(ops.posted, [])

    def test_trouble_before_the_tests_is_reported_inconclusive(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [], bodies=[report_comment(OLD[:7], 'PASS')])

            @contextlib.contextmanager
            def busy():
                raise TimeoutError('simulator slot decision is busy')
                yield
            with patch.object(run, 'exclusive_slot', busy):
                self.assertEqual(run.hosted_run(ops, SHA), 'INCONCLUSIVE')
        self.assertIn('why inconclusive: simulator slot decision is busy', ops.posted[0])

    def test_a_run_that_executed_no_tests_is_inconclusive_not_a_pass(self):
        """#2590: the hosted run lacked xcodegen, ran nothing and still looked green."""
        empty = manifest({})
        self.assertEqual(empty['status'], 'verified')
        result = run.summarize(empty)
        self.assertEqual(result['verdict'], 'INCONCLUSIVE')
        self.assertIn('ran 0 tests', ' '.join(result['errors']))
        skipped_only = run.summarize(manifest({TEST: 'skipped'}))
        self.assertEqual(skipped_only['verdict'], 'INCONCLUSIVE')
        self.assertEqual(run.summarize(manifest({TEST: 'passed'}))['verdict'], 'PASS')

    def test_the_hosted_job_is_red_unless_the_tip_passed(self):
        self.assertEqual({v: run.hosted_exit_code(v) for v in ('PASS', 'held', 'FAIL', 'INCONCLUSIVE')},
                         {'PASS': 0, 'held': 0, 'FAIL': 1, 'INCONCLUSIVE': 1})

    def test_main_exits_nonzero_for_a_hosted_run_that_tested_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [manifest({})], bodies=[report_comment(OLD[:7], 'PASS')])
            with recording_slot(ops.events), patch.object(run, 'Ops', return_value=ops), \
                    patch.dict(os.environ, {'GITHUB_RUN_ID': '42'}):
                self.assertEqual(run.main(['--hosted', '--sha', SHA]), 1)
        self.assertEqual(run.reported(ops.posted), [(SHA[:7], 'INCONCLUSIVE')])
        self.assertIn('ran 0 tests', ops.posted[0])

    def test_a_proof_run_from_a_branch_posts_no_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [manifest({TEST: 'passed'})], bodies=[report_comment(SHA[:7], 'PASS')])
            with recording_slot(ops.events), patch.object(run, 'pack_sim_build', side_effect=AssertionError(
                    'a branch run must leave no sim-app for desks')), \
                    patch.dict(os.environ, {'GITHUB_RUN_ID': '42', 'GITHUB_REF_NAME': 'ws/2590-x'}):
                verdict = run.hosted_run(ops, SHA, post=False)  # even a tip that has a report is tested
            written = list(ops.repo_root.rglob('report.md'))
            text = written[0].read_text() if written else ''
        self.assertEqual((verdict, ops.posted), ('PASS', []))
        self.assertEqual(len(written), 1)
        self.assertIn("branch ws/2590-x, not main's tip", text)
        self.assertNotIn("(main's tip)", text)
        self.assertNotIn('current phone candidate', text)

    def test_main_needs_a_full_sha(self):
        with open(os.devnull, 'w') as quiet, self.assertRaises(SystemExit), contextlib.redirect_stderr(quiet):
            run.main(['--hosted', '--sha', SHA[:7]])

    class BuildingHostedOps(HostedOps):
        """A hosted run whose app plan leaves a built app, of `head`, that passed bundle-contracts or not."""

        def __init__(self, tmp, plans, head=SHA, built=True, **kw):
            super().__init__(tmp, plans, **kw)
            self.head, self.built = head, built

        def test_plan(self, wt, output, plan, fds, only=()):
            result = super().test_plan(wt, output, plan, fds, only)
            app = (wt / '.build/verification/SpokenMarginsAppBehavior/Build/Products/Debug-iphonesimulator'
                   / 'SpokenMarginsApp.app')
            app.mkdir(parents=True, exist_ok=True)
            (app / 'Info.plist').write_text('<plist/>')
            steps = [{'name': 'bundle-contracts', 'exit_code': 0 if self.built else 1}]
            (output / 'manifest.json').write_text(json.dumps(dict(result, head=self.head,
                                                                  steps=steps + result['steps'])))
            return result

    def test_the_tip_s_own_good_build_is_packed_for_the_sim_app_artifact(self):
        """Desks download it (scripts/sim-build-latest); only exactly this SHA's build that passed bundle-contracts."""
        rows = [(SHA, True, 'packed'), (SHA, False, 'not packed: no good simulator build'),
                (OLD, True, f'not packed: the app plan built {OLD[:7]}')]
        for head, built, said in rows:
            with self.subTest(said=said), tempfile.TemporaryDirectory() as tmp:
                if said == 'packed' and not shutil.which('ditto'):
                    self.skipTest('ditto is macOS-only')
                ops = self.BuildingHostedOps(tmp, [manifest({TEST: 'failed'})] * 3, head=head, built=built,
                                             bodies=[report_comment(OLD[:7], 'PASS')])
                with recording_slot(ops.events), patch.object(run.lane_ledger, 'record_tip'):
                    self.assertEqual(run.hosted_run(ops, SHA), 'FAIL')  # failing tips are packed too
                packed = ops.repo_root / 'artifacts' / 'sim-app'
                self.assertIn('simulator build ' + said, (ops.home / 'log.txt').read_text())
                self.assertEqual(packed.is_dir(), said == 'packed')
                if said == 'packed':
                    self.assertEqual(json.loads((packed / 'build.json').read_text())['sha'], SHA)
                    self.assertTrue((packed / run.sim_builds.PACKED_APP).is_file())
                self.assertIsNone(run.sim_builds.latest(Path(os.environ['SM_SIM_BUILDS'])))  # nothing kept on disk


class MacDefersToHostedTests(unittest.TestCase):
    def tick(self, tmp, plans, bodies, ops=None):
        ops = ops or HostedOps(tmp, plans, bodies=bodies)
        with recording_slot(ops.events), patch.object(run.revert, 'load_test_scope', return_value=real_scope()):
            verdict = run.tick(ops)
        path = ops.home / 'state.json'
        return ops, verdict, json.loads(path.read_text()) if path.exists() else {}

    def test_while_on_the_mac_tests_no_new_tip(self):
        bodies = [report_comment(OLD[:7], 'PASS', by=run.HOSTED_RUN_BY)]
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict, state = self.tick(tmp, [], bodies)
        self.assertEqual(verdict, 'deferred')
        self.assertEqual((ops.posted, ops.comments, ops.reverts), ([], [], []))
        self.assertFalse(any(c[:3] == ['git', 'worktree', 'add'] for c in ops.calls))

    def test_a_tip_with_no_hosted_run_is_tested_here_as_when_off(self):
        # #2127: the lane runner's merges are pushed with the workflow token, which starts no workflows. A tip
        # with no hosted run, or one whose run ended without a report, would otherwise go untested.
        cases = [('no run', []), ('a run that ended without a report', [{'status': 'completed', 'conclusion': 'failure'}]),
                 ('runs unreadable', None)]
        for name, runs in cases:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                ops = HostedOps(tmp, [manifest({TEST: 'passed'})], runs=runs,
                                bodies=[report_comment(OLD[:7], 'PASS', by=run.HOSTED_RUN_BY)])
                ops, verdict, state = self.tick(tmp, [], [], ops=ops)
                self.assertEqual(verdict, 'PASS')
                self.assertEqual(len(ops.posted), 1)
                self.assertIn(f'run by: {run.RUN_BY}', ops.posted[0])
                self.assertIn('the Mac tests it', (ops.home / 'log.txt').read_text())

    def test_a_tip_the_hosted_run_has_or_may_soon_have_is_left_to_it(self):
        cases = [('queued', {'runs': [{'status': 'queued', 'conclusion': None}]}),
                 ('in progress', {'runs': [{'status': 'in_progress', 'conclusion': None}]}),
                 ('just landed, no run listed yet', {'runs': [], 'tip_age': 60})]
        for name, kw in cases:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                ops = HostedOps(tmp, [], bodies=[report_comment(OLD[:7], 'PASS', by=run.HOSTED_RUN_BY)], **kw)
                ops, verdict, _ = self.tick(tmp, [], [], ops=ops)
                self.assertEqual(verdict, 'deferred')
                self.assertEqual(ops.posted, [])
                self.assertFalse(any(c[:3] == ['git', 'worktree', 'add'] for c in ops.calls))
                self.assertIn(['hosted_runs', SHA], ops.calls)

    def test_the_hosted_run_list_asks_github_for_this_commit_and_trouble_is_none(self):
        cases = [(run.Result(0, '[{"status":"queued","conclusion":null}]'), [{'status': 'queued', 'conclusion': None}]),
                 (run.Result(0, '[]'), []), (run.Result(1, '', 'HTTP 502'), None), (run.Result(0, 'not json'), None)]
        for result, expected in cases:
            with self.subTest(result=result.stdout or result.stderr), tempfile.TemporaryDirectory() as tmp:
                calls = []
                ops = run.Ops(home=Path(tmp), repo_root=Path(tmp), echo=False,
                              run=lambda cmd, **kw: calls.append(cmd) or result)
                self.assertEqual(ops.hosted_runs(SHA), expected)
                self.assertEqual(calls[0][:3], ['gh', 'api',
                                 f'repos/{run.REPO}/actions/workflows/hosted-integration.yml/runs?head_sha={SHA}&per_page=20'])

    def test_an_unhandled_hosted_fail_is_confirmed_here_then_searched_and_reverted_once(self):
        bodies = [report_comment(OLD[:7], 'PASS'), hosted_report(SHA[:7], 'FAIL', [TEST])]
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict, state = self.tick(tmp, [manifest({TEST: 'failed'})], bodies)
            again = self.tick(tmp, [], bodies, ops=ops)[1]
        self.assertEqual((verdict, again), ('handled', 'deferred'))
        self.assertIn(['test_plan', 'confirm', TEST], ops.calls)
        self.assertEqual([e for e in ops.events if e[0] == 'check'], [('check', 12), ('check', 13)])
        self.assertLess(ops.events.index(('check', 13)), ops.events.index(('slot', 'released')))
        self.assertEqual(ops.reverts[0][0], 13)
        self.assertEqual(ops.diagnosed, [([TEST], ['#1170'])])
        self.assertEqual(ops.posted, [])  # the hosted report stands; the Mac posts no second one
        record = state['hosted_handled'][SHA[:7]]
        self.assertEqual((record['confirm'], record['revert']), ('fail', 'https://github.com/x/y/pull/9001'))
        log = next(c for c in ops.calls if c[:2] == ['git', 'log'])
        self.assertEqual(log[-1], f'{OLD[:7]}..{SHA}')

    def test_a_hosted_fail_that_passes_here_reverts_and_files_nothing(self):
        # find_culprit takes the tip as failing: without the check here it would blame the newest merge.
        bodies = [report_comment(OLD[:7], 'PASS'), hosted_report(SHA[:7], 'FAIL', [TEST])]
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict, state = self.tick(tmp, [manifest({TEST: 'passed'})], bodies)
        self.assertEqual(verdict, 'handled')
        self.assertEqual((ops.reverts, ops.filed, ops.diagnosed), ([], [], []))
        self.assertFalse(any(e[0] in ('commits_since', 'check') for e in ops.events))
        self.assertEqual([n for n, _ in ops.comments], [run.REPORT_ISSUE])
        self.assertIn('not confirmed on the Mac', ops.comments[0][1])
        self.assertEqual(state['hosted_handled'][SHA[:7]]['confirm'], 'pass')

    def test_a_hosted_fail_with_an_app_test_and_a_journey_confirms_the_app_test_only(self):
        # #2667: the Mac re-runs app tests only, so a journey in the list would end every FAIL as "not reproduced".
        bodies = [report_comment(OLD[:7], 'PASS'), hosted_report(SHA[:7], 'FAIL', [JOURNEY, TEST])]
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict, state = self.tick(tmp, [manifest({TEST: 'failed'})], bodies)
        self.assertEqual(verdict, 'handled')
        self.assertIn(['test_plan', 'confirm', TEST], ops.calls)
        self.assertFalse(any(JOURNEY in str(c) for c in ops.calls))
        self.assertEqual(ops.reverts[0][0], 13)
        self.assertEqual(ops.diagnosed, [([TEST], ['#1170'])])
        self.assertEqual(state['hosted_handled'][SHA[:7]]['confirm'], 'fail')

    def test_an_app_test_that_passes_here_still_names_the_journey_it_did_not_rerun(self):
        bodies = [hosted_report(SHA[:7], 'FAIL', [JOURNEY, TEST])]
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict, _ = self.tick(tmp, [manifest({TEST: 'passed'})], bodies)
        self.assertEqual((verdict, ops.reverts, ops.filed), ('handled', [], []))
        self.assertIn('not confirmed on the Mac', ops.comments[0][1])
        self.assertIn(f'`{JOURNEY}`', ops.comments[0][1])
        self.assertIn('did not re-run it', ops.comments[0][1])

    def test_a_hosted_fail_naming_only_journeys_runs_nothing_and_says_so(self):
        bodies = [hosted_report(SHA[:7], 'FAIL', [JOURNEY])]
        with tempfile.TemporaryDirectory() as tmp:
            ops, verdict, state = self.tick(tmp, [], bodies)
            again = self.tick(tmp, [], bodies, ops=ops)[1]
        self.assertEqual((verdict, again), ('handled', 'deferred'))
        self.assertFalse(any(c[:1] == ['test_plan'] for c in ops.calls))
        self.assertFalse(any(c[:3] == ['git', 'worktree', 'add'] for c in ops.calls))
        self.assertEqual((ops.reverts, ops.filed, ops.diagnosed), ([], [], []))
        self.assertEqual([n for n, _ in ops.comments], [run.REPORT_ISSUE])
        self.assertIn('only scripted journeys failed', ops.comments[0][1])
        self.assertNotIn('not confirmed on the Mac', ops.comments[0][1])
        self.assertEqual(state['hosted_handled'][SHA[:7]]['confirm'], 'journeys only')

    def test_only_the_newest_hosted_report_counts(self):
        cases = [
            ('a newer hosted PASS', [hosted_report(SHA[:7], 'FAIL', [TEST]), hosted_report('c' * 7, 'PASS')]),
            ('already handled', [hosted_report('d' * 7, 'FAIL', [TEST])]),
            ('a FAIL naming no test', [hosted_report(SHA[:7], 'FAIL')]),
            ('an INCONCLUSIVE', [hosted_report(SHA[:7], 'INCONCLUSIVE')]),
            ("the Mac's own FAIL", [report_comment(SHA[:7], 'FAIL') + f'failing: {TEST}\n']),
        ]
        for name, bodies in cases:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                ops = HostedOps(tmp, [], bodies=bodies)
                ops.home.mkdir()
                (ops.home / 'state.json').write_text(json.dumps({'results': {}, 'hosted_handled': {'d' * 7: {}}}))
                ops, verdict, _ = self.tick(tmp, [], bodies, ops=ops)
                self.assertEqual(verdict, 'deferred')
                self.assertFalse(any(c[:1] == ['test_plan'] for c in ops.calls))

    def test_a_handling_run_cut_off_part_way_is_not_repeated(self):
        bodies = [hosted_report(SHA[:7], 'FAIL', [TEST])]
        with tempfile.TemporaryDirectory() as tmp:
            ops = HostedOps(tmp, [], bodies=bodies)
            ops.home.mkdir()
            (ops.home / 'state.json').write_text(json.dumps(
                {'results': {}, 'hosted_handled': {SHA[:7]: {'started': 0, 'in_progress': True}}}))
            ops, verdict, state = self.tick(tmp, [], bodies, ops=ops)
        self.assertEqual(verdict, 'deferred')
        self.assertEqual(state['hosted_handled'][SHA[:7]]['confirm'], 'stopped before completion')


class ScreenTourTests(unittest.TestCase):
    """#381: the integration run tours the screens after a PASS; the tour is never verdict input."""

    def tick(self, plans):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            verdict = run.tick(ops)
        return ops, verdict

    def tour_calls(self, ops):
        return [c for c in ops.calls if c[:2] == ['test_plan', 'tour']]

    def test_a_pass_runs_the_tour_and_the_report_lists_its_screens(self):
        ops, verdict = self.tick([manifest({TEST: 'passed'}), tour_manifest()])
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(len(self.tour_calls(ops)), 1)
        self.assertIn('screen tour (not verdict input): 3 screenshots in tour/screens of the evidence folder: '
                      '01-library-light.png, 01-library-dark.png, 02-item-light.png', ops.posted[0])

    def test_a_failing_tour_is_one_report_line_and_the_verdict_stays_pass(self):
        failed = tour_manifest({'SpokenMarginsUISeamsUITests/ScreenTourTests/testTour': 'failed'}, screens=[])
        ops, verdict = self.tick([manifest({TEST: 'passed'}), failed])
        self.assertEqual(verdict, 'PASS')
        self.assertIn('screen tour (not verdict input): failed: ', ops.posted[0])
        self.assertIn('(failed: SpokenMarginsUISeamsUITests/ScreenTourTests/testTour)', ops.posted[0])

    TOUR_TEST = 'SpokenMarginsUISeamsUITests/ScreenTourTests/testTour'

    def test_a_failing_tour_test_files_one_tracked_issue_and_the_verdict_stays_pass(self):
        # #3822: two tour tests failed in every report for a day as one unread line.
        failed = tour_manifest({self.TOUR_TEST: 'failed'}, screens=[])
        ops, verdict = self.tick([manifest({TEST: 'passed'}), failed])
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(ops.filed, [[[self.TOUR_TEST]]])
        self.assertEqual(ops.filed_labels, [run.TOUR_LABELS])
        self.assertNotIn('priority', run.TOUR_LABELS)   # a tour failure is tracked, never a blocker

    def test_a_tour_that_passed_or_could_not_run_files_nothing(self):
        for plans in ([manifest({TEST: 'passed'}), tour_manifest()],              # captured
                      [manifest({TEST: 'passed'}), tour_manifest(screens=[])],     # inconclusive: no screenshot
                      [manifest({TEST: 'passed'})]):                               # the tour could not start
            ops, _ = self.tick(list(plans))
            self.assertEqual(ops.filed, [])

    def test_a_second_run_comments_on_the_open_tour_issue_and_files_no_second_one(self):
        class GhOps(run.Ops):
            def __init__(self, tmp):
                super().__init__(home=Path(tmp) / 'home', repo_root=Path(tmp) / 'repo', run=self.fake_run, echo=False)
                self.open, self.cmds = [], []

            def fake_run(self, cmd, cwd=None, timeout=None, stdin=None, env=None):
                cmd = [str(c) for c in cmd]
                self.cmds.append(cmd)
                if cmd[:3] == ['gh', 'issue', 'create']:
                    self.open.append({'number': 3900, 'title': cmd[cmd.index('--title') + 1],
                                      'body': Path(cmd[cmd.index('--body-file') + 1]).read_text(), 'labels': [],
                                      'comments': 0, 'author_association': 'OWNER', 'user': {'login': 'uncomposed'}})
                    return run.Result(0, 'https://github.com/Spoken-Margins/spoken-margins-native/issues/3900\n')
                return run.Result(0, '')

            def open_issues_matching(self, test):
                return list(self.open)

            def issue_comments(self, number):
                return ''

        tour = {'status': 'failed', 'detail': 'x', 'screens': [], 'failed': [self.TOUR_TEST]}
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'repo').mkdir()
            ops = GhOps(tmp)
            for n in range(2):
                evidence = Path(tmp) / f'evidence{n}'
                evidence.mkdir()
                self.assertEqual(run.file_tour_failures(ops, SHA, 'https://x/report', evidence, tour), [3900])
        creates = [c for c in ops.cmds if c[:3] == ['gh', 'issue', 'create']]
        comments = [c for c in ops.cmds if c[:3] == ['gh', 'issue', 'comment']]
        self.assertEqual(len(creates), 1)
        self.assertEqual(creates[0][creates[0].index('--label') + 1], run.TOUR_LABELS)
        self.assertIn('testTour fails', creates[0][creates[0].index('--title') + 1])
        self.assertEqual([c[3] for c in comments], ['3900'])

    def test_a_github_fault_while_filing_a_tour_failure_never_stops_the_report(self):
        class Broken(FakeOps):
            def file_failures(self, *a, **k):
                raise RuntimeError('gh is down')
        with tempfile.TemporaryDirectory() as tmp:
            ops = Broken(tmp, [])
            tour = {'status': 'failed', 'detail': 'x', 'screens': [], 'failed': [self.TOUR_TEST]}
            self.assertEqual(run.file_tour_failures(ops, SHA, 'r', Path(tmp), tour), [])

    def test_a_tour_that_passed_but_exported_nothing_is_not_called_captured(self):
        ops, verdict = self.tick([manifest({TEST: 'passed'}), tour_manifest(screens=[])])
        self.assertEqual(verdict, 'PASS')
        self.assertIn('screen tour (not verdict input): inconclusive: no screenshot was exported', ops.posted[0])
        self.assertNotIn('screenshots in tour/screens', ops.posted[0])

    def test_a_tour_that_cannot_start_never_blocks_the_report(self):
        ops, verdict = self.tick([manifest({TEST: 'passed'})])  # FakeOps has no plan left to give the tour
        self.assertEqual(verdict, 'PASS')
        self.assertIn('screen tour (not verdict input): not run: ', ops.posted[0])

    def test_no_tour_after_a_fail_or_an_inconclusive_app_plan(self):
        for plans in ([manifest({TEST: 'failed'})] * 3, [manifest({}, interrupted=True)]):
            with self.subTest(first=plans[0]['steps'][0]['exit_code']):
                ops, _ = self.tick(list(plans))
                self.assertEqual(self.tour_calls(ops), [])
                self.assertNotIn('screen tour', ops.posted[0])

    def test_a_long_tour_names_the_first_screens_and_counts_the_rest(self):
        names = [f'{n:02d}-screen.png' for n in range(30)]
        line = run.tour_line({'status': 'captured', 'detail': '', 'screens': names})
        self.assertIn('30 screenshots', line)
        self.assertIn(names[run.TOUR_NAMES_SHOWN - 1], line)
        self.assertNotIn(names[run.TOUR_NAMES_SHOWN], line)
        self.assertTrue(line.endswith('and 6 more'))
