import contextlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
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
                 (dict(state={'results': {}, 'last_started': 10_000 - 29 * 60}), '30 minutes'),
                 (dict(pressure=2), 'warn'),
                 (dict(pressure=None), 'unreadable'),
                 (dict(free_bytes=9 * GB), 'needs 10 GB'),
                 (dict(free_bytes=17 * GB, builds=2), 'needs 18 GB'),
                 (dict(slot_busy=True), 'simulator slot')]
        for over, words in cases:
            with self.subTest(over=over):
                self.assertIn(words, self.hold(**over))
        self.assertIsNone(self.hold(state={'results': {}, 'last_started': 10_000 - 30 * 60}))
        self.assertIsNone(self.hold(free_bytes=18 * GB, builds=2))

    def test_another_runner_s_report_on_this_tip_counts_once_per_tip(self):
        # The scheduled task and the standing Test Desk post the same heading.
        self.assertIsNone(self.hold(reports=[(OLD[:7], 'PASS')]))
        self.assertIn('already', self.hold(reports=[(OLD[:7], 'PASS'), (SHA[:7], 'FAIL')]))


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
                  run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))]
        settled = run.settle(first, reruns)
        self.assertEqual((settled['verdict'], settled['failed'], settled['flaky']), ('FAIL', [OTHER], [TEST]))
        clean = run.settle(first, [run.summarize(manifest({TEST: 'passed', OTHER: 'passed'}))] * 2)
        self.assertEqual((clean['verdict'], clean['failed'], clean['flaky']), ('PASS', [], sorted([TEST, OTHER])))

    def test_a_rerun_cannot_clear_a_test_it_did_not_pass(self):
        first = run.summarize(manifest({TEST: 'failed'}))
        stopped = run.summarize(manifest({TEST: 'passed'}, interrupted=True))
        passed = run.summarize(manifest({TEST: 'passed'}))
        other_only = run.summarize(manifest({OTHER: 'passed'}))  # the failing test never ran
        for reruns in ([passed, stopped], [passed], [passed, other_only], []):
            with self.subTest(reruns=len(reruns)):
                self.assertEqual(run.settle(first, reruns)['verdict'], 'FAIL')

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
                      f'{SHA[:7]} is the current phone candidate.'):
            self.assertIn(words, body)

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


class FakeOps(run.Ops):
    """Real tick, fake boundaries: git, GitHub, the simulator and Claude."""

    def __init__(self, tmp, plans, bodies=()):
        super().__init__(home=Path(tmp) / 'home', repo_root=Path(tmp) / 'repo', run=self.fake_run, echo=False)
        (Path(tmp) / 'repo').mkdir()
        self.plans, self.bodies, self.calls, self.posted, self.filed, self.diagnosed = list(plans), list(bodies), [], [], [], []

    def fake_run(self, cmd, cwd=None, timeout=None, stdin=None, env=None):
        cmd = [str(c) for c in cmd]
        self.calls.append(cmd)
        if cmd[:2] == ['git', 'rev-parse']:
            return run.Result(0, SHA + '\n')
        if cmd[:3] == ['git', 'worktree', 'add']:
            wt = Path(cmd[-2])
            (wt / 'TestPlans').mkdir(parents=True)
            (wt / 'TestPlans' / 'scripted-journeys.json').write_text(json.dumps({'gating': [], 'probation': []}))
        if cmd[:2] == ['git', 'log']:
            return run.Result(0, 'Merge pull request #1170 from uncomposed/ws/1170-x\n')
        return run.Result(0, '')

    def report_bodies(self):
        return self.bodies

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
        plans = [manifest({TEST: 'failed'}), manifest({TEST: 'failed'}), manifest({TEST: 'passed'})]
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


if __name__ == '__main__':
    unittest.main()
