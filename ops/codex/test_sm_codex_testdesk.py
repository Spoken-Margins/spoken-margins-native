import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_codex_testdesk as desk
import sm_codex_worker as worker

SHA = 'a' * 40
TEST = 'SpokenMarginsAppTests/PlaybackTests/testResume'
JOURNEY = 'SpokenMarginsAppUITests/JourneyTests/testImport'


def manifest(status='passed', probation=False, interrupted=False):
    step = {'name': 'xcode-tests', 'tests': {JOURNEY if probation else TEST: {'status': status}},
            'probation': {JOURNEY: status} if probation else {}, 'errors': [], 'exit_code': 0}
    if status == 'failed':
        step.update(exit_code=65, errors=[] if probation else ['Failed: ' + TEST])
    if interrupted:
        step.update(interrupted=True, exit_code=124, simulator_crash_report='SpringBoard.ips')
    return {'status': 'verified' if status == 'passed' or probation else 'failed_or_incomplete',
            'steps': [step]}


class PureTests(unittest.TestCase):
    def test_hold_rules_use_worker_pacing_and_disk_threshold(self):
        limits = {'used': 10, 'worst': 10, 'window_mins': 100, 'resets_at': 6000}
        dial = {'workers': 1, 'stop': 90}
        for workers, used, disk, busy, word in ((0, 10, 30, False, '0 Codex'),
                (1, 88, 30, False, 'hold line'), (1, 60, 30, False, 'trend'),
                (1, 10, 29, False, 'GiB'), (1, 10, 30, True, 'simulator')):
            self.assertIn(word, desk.hold_reason(3000, {**dial, 'workers': workers},
                {**limits, 'used': used, 'worst': used}, disk * 2**30, busy))
        self.assertIsNone(desk.hold_reason(3000, dial, limits, 30 * 2**30, False))
        self.assertIn('could not be read', desk.hold_reason(3000, dial, None, 30 * 2**30, False))

    def test_hold_uses_the_dial_s_codex_finish_by(self):
        # 2026-10-02: the Dial said Sat 7 AM (trend 72%) but the desk paced to Codex's Tuesday reset (40%).
        with patch.object(worker, 'pacing_hold', return_value=None) as hold:
            desk.hold_reason(3000, {'workers': 1, 'stop': 97, 'finish_by': ('Sat 7 AM',)}, {}, 30 * 2**30, False)
        self.assertEqual(hold.call_args.kwargs.get('finish_by'), ('Sat 7 AM',))

    def test_diagnosis_runs_at_the_worker_s_reasoning_effort(self):
        # Without -c the CLI falls back to ~/.codex/config.toml's effort (low).
        seen = []
        class Proc:
            returncode = 1
            def __init__(self, cmd, **kwargs):
                seen.append(cmd)
            def wait(self, timeout=None):
                return 0
        with tempfile.TemporaryDirectory() as tmp, patch.object(desk.subprocess, 'Popen', Proc):
            ops = desk.Ops(home=Path(tmp) / 'state', repo_root=Path(tmp), run=lambda *a, **k: worker.Result(0),
                           limits=lambda: None, echo=False)
            ops.diagnose(Path(tmp), Path(tmp), [TEST])
        self.assertIn(f'model_reasoning_effort="{worker.EFFORT}"', seen[0])
        self.assertIn('--json', seen[0])

    def test_once_per_sha_and_spacing_even_after_inconclusive(self):
        state = {'last_started': 100, 'results': {SHA: {'verdict': 'INCONCLUSIVE'}}}
        self.assertIn('already', desk.schedule_hold(SHA, state, 10000))
        self.assertIn('2 hours', desk.schedule_hold('b' * 40, state, 7299))
        self.assertIsNone(desk.schedule_hold('b' * 40, state, 7300))

    def test_infrastructure_never_becomes_a_bug(self):
        self.assertEqual(desk.summarize(manifest('failed'))['verdict'], 'FAIL')
        for m in (manifest('failed', interrupted=True), {'status': 'failed_or_incomplete', 'steps': []},
                  {'status': 'failed_or_incomplete', 'steps': [{'name': 'xcode-tests', 'interrupted': True}]}):
            self.assertEqual(desk.summarize(m)['verdict'], 'INCONCLUSIVE')
        self.assertEqual(desk.summarize(manifest('failed', probation=True))['verdict'], 'PASS')
        self.assertEqual(desk.summarize(manifest('passed'))['counts']['passed'], 1)

    def test_report_and_issue_include_reproduction_evidence_and_limits(self):
        result = desk.summarize(manifest('failed'))
        result['probation_ready'] = [JOURNEY]
        text = desk.report_text(SHA, result, Path('/mac/artifacts/testdesk/run'))
        for word in ('Codex Test Desk: aaaaaaa', 'FAIL', '0 passed', '1 failed', TEST,
                     '/mac/artifacts/', JOURNEY, 'passed twice in a row',
                     'not verified: agent-driven journeys, audible content, Lock Screen (owner)'):
            self.assertIn(word, text)
        body = desk.issue_text({'tests': [TEST], 'title': 'Playback resumes the wrong item',
                               'steps': 'Resume the second item.', 'expected': 'Second item plays.',
                               'actual': 'First item plays.', 'root_cause': 'Cursor stays on first item.'},
                              SHA, 'https://github.com/report', Path('/mac/artifacts/run'))
        for word in ('Steps', 'Expected', 'Actual', TEST, SHA, 'https://github.com/report', 'Build'):
            self.assertIn(word, body)

    def test_failed_probation_attachment_links_survive_summary_and_combine(self):
        source = manifest('failed', probation=True)
        attachments = [{'test': JOURNEY, 'manifest': '/mac/j1/manifest.json',
                        'files': ['/mac/j1/recording.mp4', '/mac/j1/hierarchy.txt']}]
        source['steps'][0]['attachments'] = attachments
        result = desk.combine([desk.summarize(manifest()), desk.summarize(source)])
        self.assertEqual(result['verdict'], 'PASS')
        self.assertEqual(result['counts'], {'passed': 1, 'failed': 1, 'skipped': 0})
        self.assertEqual(result['journeys'][JOURNEY], 'failed')
        self.assertEqual(result['attachments'], attachments)
        text = desk.report_text(SHA, result, Path('/mac/run'))
        for path in ('/mac/j1/manifest.json', '/mac/j1/recording.mp4', '/mac/j1/hierarchy.txt'):
            self.assertIn(f'](<{path}>)', text)
        source['steps'][0]['attachments'][0].update(error='export timed out', export_log='/mac/j1/export.log')
        self.assertIn('Export warning: export timed out',
                      desk.report_text(SHA, desk.summarize(source), Path('/mac/run')))
        self.assertEqual(desk.summarize(manifest('failed'))['verdict'], 'FAIL')

    def test_large_attachment_listing_keeps_failed_report_postable(self):
        source = manifest('failed')
        prefix = '/mac/' + 'long-path/' * 25
        files = [prefix + f'debug-{n}.txt' for n in range(999)] + [prefix + 'recording.mp4']
        source['steps'][0]['attachments'] = [{'test': TEST, 'manifest': prefix + 'manifest.json',
                                           'files': files}]
        result = desk.summarize(source)
        text = desk.report_text(SHA, result, Path('/mac/run'))
        self.assertLess(len(text), 65536)
        self.assertIn('FAIL — 0 passed, 1 failed', text)
        self.assertIn('Failing tests: `' + TEST + '`', text)
        self.assertIn('more file links omitted', text)
        self.assertIn('recording.mp4', text)
        self.assertEqual(result['attachments'][0]['files'], files)

    def test_dedupe_search_is_open_issues_and_uses_test_method(self):
        query = desk.dedupe_query(TEST)
        self.assertIn('is:open', query)
        self.assertIn('is:issue', query)
        self.assertIn('"testResume"', query)
        self.assertEqual(desk.find_duplicate([{'number': 5, 'body': TEST},
                                              {'number': 6, 'body': 'testResumeOther'}], [TEST]), 5)
        self.assertIsNone(desk.find_duplicate([{'number': 6, 'title': 'testResumeOther'}], [TEST]))
        self.assertIsNone(desk.find_duplicate([{'number': desk.REPORT_ISSUE,
                                              'comments': [{'body': TEST}]}], [TEST]))
        self.assertEqual(desk.find_duplicate([{'number': 7, 'body': 'Playback stalls',
            'comments': [{'body': TEST}]}], [TEST]), 7)

    def test_probation_needs_two_distinct_consecutive_shas_and_resets(self):
        old = {'results': {SHA: {'started': 1, 'journeys': {JOURNEY: 'passed'}}}}
        self.assertEqual(desk.probation_ready(old, 'b' * 40, {JOURNEY: 'passed'}, [JOURNEY]), [JOURNEY])
        self.assertEqual(desk.probation_ready(old, SHA, {JOURNEY: 'passed'}, [JOURNEY]), [])
        old['results']['c' * 40] = {'started': 2, 'journeys': {JOURNEY: 'missing'}}
        self.assertEqual(desk.probation_ready(old, 'b' * 40, {JOURNEY: 'passed'}, [JOURNEY]), [])


    def test_class_script_is_passed_only_when_all_its_methods_pass(self):
        selector = JOURNEY.rsplit('/', 1)[0]
        listing = {'gating': [], 'probation': [{'test': selector}]}
        self.assertEqual(desk.script_results(listing, {JOURNEY: 'passed'}), {selector: 'passed'})
        self.assertEqual(desk.script_results(listing, {JOURNEY: 'passed', selector + '/testOther': 'missing'}),
                         {selector: 'missing'})
        self.assertEqual(desk.script_results(listing, {}), {selector: 'not_run'})


    def test_diagnosis_groups_tests_without_losing_or_inventing_failures(self):
        group = {'tests': [TEST, JOURNEY], 'title': 'Import loses playback position',
                 'steps': 'Import then resume.', 'expected': 'Resume anchor.',
                 'actual': 'Starts at zero.', 'root_cause': 'Position is discarded.'}
        self.assertEqual(desk.diagnoses(json.dumps([group]), [TEST, JOURNEY]), [group])
        self.assertEqual(len(desk.diagnoses('not json', [TEST, JOURNEY])), 2)


class TickTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.calls = []
        self.app = manifest()
        self.journeys = manifest(probation=True)
        self.ops = desk.Ops(home=self.root / 'state', repo_root=self.root / 'repo', run=self.fake_run,
                            limits=lambda: None, echo=False)
        self.ops.dial_body = lambda: 'dial'
        self.ops.free_bytes = lambda: 100 * 2**30
        self.addCleanup(patch.stopall)
        patch.object(worker, 'read_dial', return_value={'workers': 1, 'stop': 90}).start()
        patch.object(worker, 'parse_rate_limits', return_value={
            'used': 1, 'worst': 1, 'window_mins': 1, 'resets_at': 1}).start()
        patch.object(desk.lane_slots, 'simulator_job_running', return_value=False).start()
        patch.object(desk, 'exclusive_slot', return_value=contextlib.nullcontext((3, 4))).start()

    def fake_run(self, cmd, cwd=None, timeout=None):
        self.calls.append(cmd)
        if cmd[:2] == ['git', 'rev-parse']:
            return worker.Result(0, SHA)
        if cmd[:3] == ['git', 'worktree', 'add']:
            wt = Path(cmd[-2]); (wt / 'TestPlans').mkdir(parents=True)
            (wt / 'TestPlans/scripted-journeys.json').write_text(json.dumps(
                {'version': 1, 'gating': [], 'probation': [{'test': JOURNEY, 'journey': 'J1'}]}))
        if cmd[:3] == ['gh', 'api', '--method']:
            return worker.Result(0, json.dumps({'html_url': 'https://github.com/report'}))
        if cmd[:3] == ['gh', 'issue', 'list']:
            return worker.Result(0, json.dumps([{'number': desk.REPORT_ISSUE, 'body': TEST}]))
        if cmd[:3] == ['gh', 'issue', 'create']:
            return worker.Result(0, 'https://github.com/uncomposed/spoken-margins-native/issues/900')
        return worker.Result(0)

    def fake_plan(self, wt, output, plan, fds):
        output.mkdir(parents=True)
        (output / 'xcode-tests.log').write_text('assertion failed: wrong item')
        return self.app if plan == 'app' else self.journeys

    def tick(self, dry=False):
        with patch.object(self.ops, 'test_plan', side_effect=self.fake_plan):
            return desk.tick(self.ops, dry_run=dry)

    def test_diagnosis_records_usage_and_bug_posts_once(self):
        self.app = manifest('failed')
        groups = desk.diagnoses('', [TEST])
        def diagnose(wt, evidence, failed):
            (evidence / 'codex.jsonl').write_text(
                '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":90,"output_tokens":10}}\n')
            return groups
        with patch.object(self.ops, 'diagnose', side_effect=diagnose):
            self.assertEqual(self.tick(), 'FAIL')
        rows = [json.loads(line) for line in (self.ops.ledger_dir / 'usage.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['job'], 'testdesk-diagnosis')
        self.assertEqual(rows[0]['input_tokens'], 100)
        self.assertEqual(rows[0]['targets'][0]['head_sha'], SHA)
        self.assertEqual(rows[0]['comment_url'], 'https://github.com/report')
        self.assertEqual(rows[0]['posted'][0]['issue'], 900)
        self.assertTrue(rows[0]['posted'][0]['created'])

    def test_dry_run_does_not_fetch_write_worktree_or_launch_tests(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(self.tick(True), 'dry-run')
        self.assertFalse(self.ops.home.exists())
        self.assertEqual(self.calls, [['git', 'rev-parse', 'origin/next']])
        self.assertIn('--plan app', out.getvalue())
        self.assertIn('--plan journeys', out.getvalue())

    def test_pass_report_state_and_cleanup(self):
        self.assertEqual(self.tick(), 'PASS')
        self.assertEqual(self.tick(), 'held')
        state = json.loads((self.ops.home / 'state.json').read_text())
        self.assertEqual(state['results'][SHA]['journeys'], {JOURNEY: 'passed'})
        self.assertEqual(sum(c[:3] == ['git', 'worktree', 'remove'] for c in self.calls), 1)
        self.assertFalse(any(c[:3] == ['gh', 'issue', 'create'] for c in self.calls))

    def test_flood_stops_before_journeys_no_codex_or_issues(self):
        self.app = manifest('failed', interrupted=True)
        with patch.object(self.ops, 'test_plan', side_effect=self.fake_plan) as plans:
            self.assertEqual(desk.tick(self.ops), 'INCONCLUSIVE')
        self.assertEqual(plans.call_count, 1)
        self.assertFalse(any('exec' in c for c in self.calls))
        self.assertTrue(any(c[:3] == ['git', 'worktree', 'remove'] for c in self.calls))

    def test_fail_diagnoses_then_comments_on_existing_issue(self):
        self.app = manifest('failed')
        with patch.object(self.ops, 'diagnose', return_value=desk.diagnoses('', [TEST])) as diagnosis, \
                patch.object(self.ops, 'gh_json', return_value=[{'number': 42, 'body': TEST}]):
            self.assertEqual(self.tick(), 'FAIL')
        diagnosis.assert_called_once()
        self.assertTrue(any(c[:4] == ['gh', 'issue', 'comment', '42'] for c in self.calls))
        self.assertFalse(any(c[:3] == ['gh', 'issue', 'create'] for c in self.calls))

    def test_fail_finds_a_duplicate_named_only_past_the_first_100_comments(self):
        # #694: `gh issue list` returns only an issue's first 100 comments, so a failing test named
        # in comment 150 was missed and a duplicate ready,priority,bug issue was filed.
        self.app = manifest('failed')
        first_100 = [{'body': f'comment {n}'} for n in range(1, 101)]
        later = '\n'.join(f'comment {n}' for n in range(101, 150)) + '\nStill failing: ' + TEST + '\n'
        fake_run = self.fake_run

        def run(cmd, cwd=None, timeout=None):
            if cmd[:3] == ['gh', 'api', '--paginate'] and cmd[3].endswith('/issues/42/comments'):
                self.calls.append(cmd)
                return worker.Result(0, '\n'.join(c['body'] for c in first_100) + '\n' + later)
            return fake_run(cmd, cwd, timeout)
        self.ops.run = run
        with patch.object(self.ops, 'diagnose', return_value=desk.diagnoses('', [TEST])), \
                patch.object(self.ops, 'gh_json', return_value=[{'number': 42, 'title': 'Resume fails',
                                                                 'comments': first_100}]):
            self.assertEqual(self.tick(), 'FAIL')
        self.assertTrue(any(c[:4] == ['gh', 'issue', 'comment', '42'] for c in self.calls))
        self.assertFalse(any(c[:3] == ['gh', 'issue', 'create'] for c in self.calls))

    def test_a_hit_with_fewer_than_100_comments_is_not_paged(self):
        self.app = manifest('failed')
        with patch.object(self.ops, 'diagnose', return_value=desk.diagnoses('', [TEST])), \
                patch.object(self.ops, 'gh_json', return_value=[{'number': 42, 'title': 'Resume fails',
                                                                 'comments': [{'body': 'no match'}]}]):
            self.assertEqual(self.tick(), 'FAIL')
        self.assertFalse(any(c[:3] == ['gh', 'api', '--paginate'] for c in self.calls))
        self.assertTrue(any(c[:3] == ['gh', 'issue', 'create'] for c in self.calls))

    def test_fail_creates_worker_eligible_issue_with_report_and_steps(self):
        self.app = manifest('failed')
        with patch.object(self.ops, 'diagnose', return_value=desk.diagnoses('', [TEST])):
            self.assertEqual(self.tick(), 'FAIL')
        create = next(c for c in self.calls if c[:3] == ['gh', 'issue', 'create'])
        self.assertEqual(create[create.index('--label') + 1], 'ready,priority,bug')
        body = Path(create[create.index('--body-file') + 1]).read_text()
        self.assertIn('https://github.com/report', body)
        self.assertIn(TEST, body)
        self.assertIn('## Steps', body)

    def test_app_fail_is_filed_even_when_the_journeys_plan_is_inconclusive(self):
        # Codex audit on ee5ddbc: a later infrastructure failure suppressed a confirmed app bug.
        self.app = manifest('failed')
        self.journeys = manifest('failed', probation=True, interrupted=True)
        with patch.object(self.ops, 'diagnose', return_value=desk.diagnoses('', [TEST])) as diagnosis:
            self.assertEqual(self.tick(), 'INCONCLUSIVE')
        self.assertEqual(diagnosis.call_args.args[2], [TEST])
        self.assertTrue(any(c[:3] == ['gh', 'issue', 'create'] for c in self.calls))

    def test_the_sha_is_recorded_before_tests_start_and_an_abandoned_run_is_not_rerun(self):
        # Codex audit on ee5ddbc: a Mac restart mid-run left no SHA record, so it ran again.
        seen = {}
        def plan(wt, output, plan, fds):
            seen[plan] = json.loads((self.ops.home / 'state.json').read_text())['results'].get(SHA)
            return self.fake_plan(wt, output, plan, fds)
        with patch.object(self.ops, 'test_plan', side_effect=plan):
            desk.tick(self.ops)
        self.assertTrue(seen['app']['in_progress'])
        state = json.loads((self.ops.home / 'state.json').read_text())
        self.assertNotIn('in_progress', state['results'][SHA])
        self.assertEqual(state['results'][SHA]['verdict'], 'PASS')

        state = {'last_started': 0, 'results': {SHA: {'verdict': 'INCONCLUSIVE', 'in_progress': True,
                                                       'started': 0, 'evidence': 'x'}}}
        (self.ops.home / 'state.json').write_text(json.dumps(state))
        self.calls.clear()
        self.assertEqual(self.tick(), 'held')
        record = json.loads((self.ops.home / 'state.json').read_text())['results'][SHA]
        self.assertNotIn('in_progress', record)
        self.assertIn('stopped before completion', ' '.join(record['errors']))
        self.assertFalse(any(c[:3] == ['git', 'worktree', 'add'] for c in self.calls))

    def test_setup_failure_posts_inconclusive_and_removes_worktree(self):
        run = self.ops.run
        def fail_setup(cmd, **kwargs):
            if cmd == ['scripts/setup-worktree.sh']:
                return worker.Result(1, stderr='missing venv')
            return run(cmd, **kwargs)
        with patch.object(self.ops, 'run', side_effect=fail_setup), \
                patch.object(self.ops, 'post_report', return_value='https://github.com/report') as report:
            with self.assertRaisesRegex(RuntimeError, 'missing venv'):
                self.tick()
        self.assertIn('INCONCLUSIVE', report.call_args.args[0])
        self.assertTrue(any(c[:3] == ['git', 'worktree', 'remove'] for c in self.calls))

    def test_cli_dry_run_dispatches_without_creating_the_job_state(self):
        with patch.object(desk, 'Ops', return_value=self.ops), patch.object(desk, 'tick') as tick:
            self.assertEqual(desk.main(['--dry-run']), 0)
        tick.assert_called_once_with(self.ops, dry_run=True)
        self.assertFalse(self.ops.home.exists())

    def test_post_failure_still_records_sha_and_removes_worktree(self):
        with patch.object(self.ops, 'post_report', side_effect=RuntimeError('offline')):
            with self.assertRaisesRegex(RuntimeError, 'offline'):
                self.tick()
        self.assertIn(SHA, json.loads((self.ops.home / 'state.json').read_text())['results'])
        self.assertTrue(any(c[:3] == ['git', 'worktree', 'remove'] for c in self.calls))


class PlanLaunchTests(unittest.TestCase):
    def test_runner_inherits_locks_outside_sandbox_and_uses_only_existing_plans(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            output = base / 'app'
            ops = desk.Ops(home=base)
            def run(cmd, **kwargs):
                output.mkdir()
                (output / 'manifest.json').write_text(json.dumps(manifest()))
                return worker.Result(0)
            with patch.dict(os.environ, {'CODEX_SANDBOX': 'seatbelt'}), \
                    patch.object(desk.subprocess, 'run', side_effect=run) as launch:
                self.assertEqual(desk.summarize(ops.test_plan(base, output, 'app', (3, 4)))['verdict'], 'PASS')
            args, kwargs = launch.call_args
            self.assertEqual(args[0][:4], ['.venv/bin/python', 'scripts/verify-tests.py', '--plan', 'app'])
            self.assertEqual(args[0][-2:], ['--simulator-slot-fd', '3'])
            self.assertEqual(kwargs['pass_fds'], (3, 4))
            self.assertNotIn('CODEX_SANDBOX', kwargs['env'])


class ReservationTests(unittest.TestCase):
    def test_exclusive_reservation_is_nonblocking_and_child_keeps_it_on_parent_exit(self):
        import fcntl
        import subprocess
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}):
            slots = desk.lane_slots
            with desk.exclusive_slot() as fds:
                self.assertTrue(slots.simulator_job_running())
                with self.assertRaises(TimeoutError):
                    with desk.exclusive_slot():
                        self.fail('second job acquired a reservation')
                # Real descriptor inheritance, without launching any simulator.
                code = ("import fcntl, os, sys; from pathlib import Path; "
                        "[os.fstat(int(n)) for n in sys.argv[1:]]; print('ready', flush=True); sys.stdin.read()")
                child = subprocess.Popen([sys.executable, '-c', code, *map(str, fds)], pass_fds=fds,
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                self.assertEqual(child.stdout.readline().strip(), 'ready')
            try:
                self.assertTrue(slots.simulator_job_running())
                with self.assertRaises(TimeoutError):
                    with desk.exclusive_slot():
                        self.fail('child lost decision lock')
            finally:
                child.communicate(timeout=5)
            self.assertFalse(slots.simulator_job_running())
            with desk.exclusive_slot():
                pass

    def test_any_busy_slot_holds_even_when_second_slot_is_enabled(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}):
            slots = desk.lane_slots
            handle, _, _ = slots.acquire([slots.SIMULATOR_SLOTS[1]], 'slot', 'other job', max_wait=0)
            try:
                with self.assertRaises(TimeoutError):
                    with desk.exclusive_slot():
                        self.fail('joined another simulator job')
            finally:
                slots.release_handle(handle)


if __name__ == '__main__':
    unittest.main()
