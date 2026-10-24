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


def manifest(tests: dict, interrupted=False, probation=None):
    step = {'name': 'xcode-tests', 'tests': {t: {'status': s} for t, s in tests.items()},
            'probation': probation or {}, 'errors': [], 'exit_code': 0}
    if interrupted:
        step.update(interrupted=True, exit_code=124, simulator_crash_report='SpringBoard.ips')
    failed = any(s == 'failed' and t not in (probation or {}) for t, s in tests.items())
    return {'status': 'failed_or_incomplete' if failed or interrupted else 'verified', 'steps': [step]}


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

    def test_a_test_that_failed_first_is_a_failure_even_when_both_reruns_pass_it(self):
        # #2590, owner 2026-10-21: a recovered failure is evidence of flakiness, never a green verdict.
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        reruns = [run.summarize(manifest({TEST: 'passed', OTHER: 'failed'}))] * 2
        settled = run.settle(first, reruns)
        self.assertEqual((settled['verdict'], settled['failed'], settled['flaky'], settled['confirmed']),
                         ('FAIL', sorted([TEST, OTHER]), [TEST], [OTHER]))
        clean = run.settle(first, [run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))] * 2)
        self.assertEqual((clean['verdict'], clean['failed'], clean['confirmed']), ('FAIL', sorted([TEST, OTHER]), []))
        self.assertEqual(clean['flaky'], sorted([TEST, OTHER]))

    def test_a_rerun_cannot_clear_a_test_it_did_not_pass(self):
        first = run.summarize(manifest({TEST: 'failed'}))
        stopped = run.summarize(manifest({TEST: 'passed'}, interrupted=True))
        failed = run.summarize(manifest({TEST: 'failed'}))
        other_only = run.summarize(manifest({OTHER: 'passed'}))  # the failing test never ran
        for reruns in ([stopped, stopped], [failed, failed], [stopped], [other_only, other_only], [failed, stopped], []):
            with self.subTest(reruns=len(reruns)):
                self.assertEqual(run.settle(first, reruns)['verdict'], 'FAIL')

    def test_a_rerun_that_stopped_changes_nothing_about_the_verdict(self):
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        passed = run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))
        stopped = run.summarize({'status': 'failed_or_incomplete', 'steps': []})
        for reruns in ([passed, stopped], [stopped, passed], [passed]):
            with self.subTest(reruns=[r['verdict'] for r in reruns]):
                settled = run.settle(first, reruns)
                self.assertEqual((settled['verdict'], settled['flaky']), ('FAIL', sorted([TEST, OTHER])))

    def test_the_report_says_how_often_a_flaky_failure_failed(self):
        first = run.summarize(manifest({TEST: 'failed'}))
        reruns = [run.summarize(manifest({TEST: 'passed'})), run.summarize(manifest({TEST: 'failed'}))]
        settled = run.settle(first, reruns)
        text = run.report_text('a' * 40, dict(settled, reruns=2, crashes=[], counts={'passed': 0, 'failed': 1, 'skipped': 0}),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn('— FAIL', text)
        self.assertIn(f'{TEST} (failed 2 of 3 runs', text)

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
                      'flaky: none this run', run.NOT_RUN, run.NOT_VERIFIED, '/mac/evidence',
                      f'{SHA[:7]} is the current phone candidate: app tests passed; scripted journeys not run; '
                      'attended journeys not run.'):
            self.assertIn(words, body)

    def test_the_candidate_line_says_what_a_pass_covers(self):
        """#1465: an app-test PASS must not read as a full candidate when journeys failed or didn't run."""
        base = dict(run.settle(run.summarize(manifest({TEST: 'passed'})), []), reruns=0)
        for journeys, words in (({'J1Tests/testOpen': 'passed'}, 'scripted journeys passed (1 of 1)'),
                                ({'J1Tests/testOpen': 'failed', 'J4Tests/testPlay': 'passed'},
                                 'scripted journeys 1 passed, 1 failed, 0 skipped, 0 not run (failed: testOpen)'),
                                ({'J1Tests/testOpen': 'not_run'}, 'scripted journeys not run'),
                                ({}, 'scripted journeys not run')):
            with self.subTest(journeys=journeys):
                body = self.text(dict(base, journeys=journeys))
                self.assertIn(f'is the current phone candidate: app tests passed; {words}; attended journeys not run.', body)
                phone = load_phone_build()
                plan_lines = phone.commit_record([body], SHA)
                kinds = {what: status for what, status, _ in plan_lines}
                self.assertEqual(kinds['App tests'], 'pass')
                self.assertEqual(kinds['Scripted journeys'], 'fail' if 'failed' in words else
                                 'pass' if 'passed' in words else 'not run')
                self.assertEqual(kinds['Attended journeys'], 'not run')

    def test_the_candidate_line_never_calls_journeys_passed_when_some_did_not_run(self):
        """#1901: one passing script among skipped and unrun ones used to read "scripted journeys passed"."""
        base = dict(run.settle(run.summarize(manifest({TEST: 'passed'})), []), reruns=0)
        mixed = {'J1Tests/a': 'passed', 'J2Tests/b': 'skipped', 'J3Tests/c': 'not_run', 'J7Tests/d': 'passed'}
        body = self.text(dict(base, journeys=mixed))
        self.assertIn('app tests passed; scripted journeys 2 passed, 0 failed, 1 skipped, 1 not run; attended', body)
        self.assertNotIn('scripted journeys passed', body)
        for journeys in ({'a/b': 'passed', 'c/d': 'skipped'}, {'a/b': 'passed', 'c/d': 'not_run'},
                         {'a/b': 'passed', 'c/d': 'missing'}):
            with self.subTest(journeys=journeys):
                self.assertNotIn('scripted journeys passed', self.text(dict(base, journeys=journeys)))
        self.assertIn('scripted journeys passed (2 of 2)', self.text(dict(base, journeys={'a/b': 'passed', 'c/d': 'passed'})))

    def test_fail_report_lists_failures_flakes_and_suspect_merges(self):
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        reruns = [run.summarize(manifest({TEST: 'passed', OTHER: 'failed'}))] * 2
        result = dict(run.settle(first, reruns), reruns=2)
        body = self.text(result, ['#1170 Add a thing', '#1169 Fix a thing'])
        self.assertTrue(body.startswith(f'```text\nLane report integration-{SHA[:7]} — FAIL\n'))
        for words in ('re-run 2 times', f'failing: {OTHER}', f'flaky: {TEST}',
                      'merges since the last PASS: #1170 Add a thing, #1169 Fix a thing'):
            self.assertIn(words, body)
        self.assertNotIn('phone candidate', body)

    def test_inconclusive_report_says_why(self):
        result = dict(run.summarize({'error': 'git worktree add failed: disk full'}), flaky=[])
        body = self.text(result)
        self.assertIn('— INCONCLUSIVE', body)
        self.assertIn('why inconclusive: git worktree add failed: disk full', body)


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

    def diagnose(self, wt, evidence, sha, failed, suspects):
        self.diagnosed.append((failed, suspects))
        return run.fallback_groups(failed), None

    def file_failures(self, groups, sha, report, evidence, cost):
        self.filed.append([g['tests'] for g in groups])
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

    def test_two_passing_tips_name_the_probation_script_that_earned_gating(self):
        # #1901: nothing counted a script's passes, so nothing was ever promoted.
        listing = {'gating': [], 'probation': [{'test': JOURNEY, 'journey': 'J1'}]}
        passing = manifest({}, probation={f'{JOURNEY}/testOpen': 'passed'})
        passing['status'] = 'verified'
        plans = [manifest({TEST: 'passed'}), passing, manifest({TEST: 'passed'}), passing]
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')], listing=listing)
            self.assertEqual(run.tick(ops), 'PASS')
            self.assertEqual(json.loads((ops.home / 'state.json').read_text())['journeys'][JOURNEY],
                             {'passes': 1, 'bad': 0})
            ops.sha = 'c' * 40
            self.assertEqual(run.tick(ops), 'PASS')
            streaks = json.loads((ops.home / 'state.json').read_text())['journeys']
        self.assertEqual(streaks[JOURNEY], {'passes': 2, 'bad': 0})
        self.assertNotIn('journeys due to move', ops.posted[0])
        self.assertIn('journeys due to move: J1ListenToAnArticleJourneyUITests passed twice running, move to gating',
                      ops.posted[1])

    def test_flaky_failure_is_rerun_twice_and_reported_as_fail(self):
        plans = [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), manifest({TEST: 'passed'})]
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'FAIL')
        self.assertIn(['test_plan', 'rerun-1', TEST], ops.calls)
        self.assertIn(['test_plan', 'rerun-2', TEST], ops.calls)
        self.assertIn('— FAIL', ops.posted[0])
        self.assertIn(f'flaky: {TEST}', ops.posted[0])

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

    def test_a_flaky_failure_never_searches_or_reverts(self):
        # Failing once and passing on a re-run names no merge: nothing to bisect, and never a revert.
        for plans in ([manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), manifest({TEST: 'passed'})],
                      [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), {'status': 'failed_or_incomplete', 'steps': []}]):
            with tempfile.TemporaryDirectory() as tmp:
                ops = CulpritOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
                with recording_slot(ops.events):
                    self.assertEqual(run.tick(ops), 'FAIL')
            self.assertEqual(ops.reverts, [])
            self.assertFalse(any(e[0] in ('commits_since', 'check') for e in ops.events))


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
            with recording_slot(ops.events), patch.dict(os.environ, {'GITHUB_RUN_ID': '42'}):
                verdict = run.hosted_run(ops, SHA, post=False)  # even a tip that has a report is tested
            written = list(ops.repo_root.rglob('report.md'))
        self.assertEqual((verdict, ops.posted), ('PASS', []))
        self.assertEqual(len(written), 1)

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
