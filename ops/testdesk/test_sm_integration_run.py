import contextlib
import os
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

    def test_a_test_that_passes_both_reruns_is_flaky_not_failing(self):
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        reruns = [run.summarize(manifest({TEST: 'passed', OTHER: 'failed'})),
                  run.summarize(manifest({TEST: 'passed', OTHER: 'failed'}))]
        settled = run.settle(first, reruns)
        self.assertEqual((settled['verdict'], settled['failed'], settled['flaky']), ('FAIL', [OTHER], [TEST]))
        clean = run.settle(first, [run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))] * 2)
        self.assertEqual((clean['verdict'], clean['failed'], clean['flaky']), ('PASS', [], sorted([TEST, OTHER])))

    def test_a_rerun_cannot_clear_a_test_it_did_not_pass(self):
        first = run.summarize(manifest({TEST: 'failed'}))
        stopped = run.summarize(manifest({TEST: 'passed'}, interrupted=True))
        failed = run.summarize(manifest({TEST: 'failed'}))
        other_only = run.summarize(manifest({OTHER: 'passed'}))  # the failing test never ran
        for reruns in ([stopped, stopped], [failed, failed], [stopped], [other_only, other_only], [failed, stopped], []):
            with self.subTest(reruns=len(reruns)):
                self.assertEqual(run.settle(first, reruns)['verdict'], 'FAIL')

    def test_a_pass_in_any_completed_rerun_clears_the_test_even_when_the_other_rerun_stopped(self):
        # #1417: re-run 1 passed both tests; re-run 2 never ran a test (the simulator would not boot).
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        passed = run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))
        stopped = run.summarize({'status': 'failed_or_incomplete', 'steps': []})
        for reruns in ([passed, stopped], [stopped, passed], [passed]):
            with self.subTest(reruns=[r['verdict'] for r in reruns]):
                settled = run.settle(first, reruns)
                self.assertEqual((settled['verdict'], settled['failed'], settled['flaky']),
                                 ('PASS', [], sorted([TEST, OTHER])))

    def test_a_test_that_passes_once_and_fails_once_is_flaky_but_the_report_says_so(self):
        first = run.summarize(manifest({TEST: 'failed', OTHER: 'failed'}))
        reruns = [run.summarize(manifest({TEST: 'passed', OTHER: 'passed'})),
                  run.summarize(manifest({TEST: 'failed', OTHER: 'passed'}))]
        settled = run.settle(first, reruns)
        self.assertEqual((settled['verdict'], settled['flaky']), ('PASS', sorted([TEST, OTHER])))
        self.assertEqual(list(settled['flaky_notes']), [TEST])
        text = run.report_text('a' * 40, dict(settled, reruns=2, crashes=[], counts={'passed': 0, 'failed': 0, 'skipped': 0}),
                               started=0, finished=1, previous=None, suspects=[], evidence=Path('/e'))
        self.assertIn(f'{TEST} (passed in 1 of 2 re-runs, failed in the rest)', text)

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
        for words in (f'run by: {run.RUN_BY}', f'next moved from {OLD[:7]}', '1 passed, 0 failed',
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

    def issue(self, number, body='', labels=(), title='', comments=()):
        return {'number': number, 'title': title, 'body': body, 'labels': [{'name': name} for name in labels],
                'comments': [{'body': c} for c in comments]}

    def duplicate(self, *issues, tests=None):
        return run.find_duplicate(list(issues), tests or [self.TEST])

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

    def test_the_search_asks_for_open_issues_and_their_labels(self):
        # A closed issue is never listed (`--state open`), and the rule reads labels, so the list must carry them.
        with tempfile.TemporaryDirectory() as tmp:
            ops = FakeOps(tmp, [])
            asked = []
            ops.gh_json = lambda args: asked.append(args) or []
            ops.must = lambda cmd, *a, **k: run.Result(0, 'https://github.com/uncomposed/spoken-margins-native/issues/1900\n')
            group = run.fallback_groups([self.TEST])
            run.Ops.file_failures(ops, group, SHA, 'report', Path(tmp), None)
        self.assertIn('--state', asked[0])
        self.assertIn('open', asked[0])
        self.assertIn('number,title,body,comments,labels', asked[0])

    def test_the_first_real_duplicate_wins_over_a_citing_design_issue(self):
        design = self.issue(864, f'Example: {self.TEST}')
        real = self.issue(1872, f'Failing tests: `{self.TEST}`', labels=['bug', 'regression'])
        self.assertEqual(self.duplicate(design, real), 1872)

    def test_a_failure_report_hidden_in_a_long_comment_thread_is_found(self):
        long_thread = self.issue(950, 'Open bug', comments=['x'] * run.LISTED_COMMENTS)
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

    def test_pass_posts_one_report_and_records_the_tip(self):
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, [manifest({TEST: 'passed'})], bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'PASS')
            state = json.loads((ops.home / 'state.json').read_text())
            self.assertEqual(run.tick(ops), 'held')  # same tip next tick
        self.assertEqual(len(ops.posted), 1)
        self.assertIn(f'next moved from {OLD[:7]}', ops.posted[0])
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

    def test_flaky_failure_is_rerun_twice_and_reported_as_pass_without_claude(self):
        plans = [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), manifest({TEST: 'passed'})]
        with tempfile.TemporaryDirectory() as tmp, mac_with_room():
            ops = FakeOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            self.assertEqual(run.tick(ops), 'PASS')
        self.assertIn(['test_plan', 'rerun-1', TEST], ops.calls)
        self.assertIn(['test_plan', 'rerun-2', TEST], ops.calls)
        self.assertIn(f'flaky: {TEST}', ops.posted[0])
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

    def test_a_flaky_pass_never_searches_or_reverts(self):
        plans = [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), manifest({TEST: 'passed'})]
        with tempfile.TemporaryDirectory() as tmp:
            ops = CulpritOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            with recording_slot(ops.events):
                self.assertEqual(run.tick(ops), 'PASS')
        self.assertEqual((ops.reverts, ops.comments), ([], []))
        self.assertFalse(any(e[0] == 'check' for e in ops.events))

    def test_a_pass_in_one_rerun_with_the_other_unable_to_boot_never_searches_or_reverts(self):
        # #1417: re-run 1 passed, re-run 2 never ran a test.
        plans = [manifest({TEST: 'failed'}), manifest({TEST: 'passed'}), {'status': 'failed_or_incomplete', 'steps': []}]
        with tempfile.TemporaryDirectory() as tmp:
            ops = CulpritOps(tmp, plans, bodies=[report_comment(OLD[:7], 'PASS')])
            with recording_slot(ops.events):
                self.assertEqual(run.tick(ops), 'PASS')
        self.assertEqual((ops.reverts, ops.comments), ([], []))
        self.assertFalse(any(e[0] == 'check' for e in ops.events))



if __name__ == '__main__':
    unittest.main()
