"""#4573: the scheduled main T3's decisions, its `main-t3` status and its failure issue (scripts/main_t3.py).

#4575's release gate reads the status this writes, so its context, states and description limit are contract.
"""
from __future__ import annotations

import datetime
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import main_t3 as M  # noqa: E402

NOW = datetime.datetime(2026, 11, 18, 12, 0, tzinfo=datetime.timezone.utc)
SHA = 'a' * 40
GREEN = 'b' * 40


def status(state, hours_ago=1.0, context=M.CONTEXT):
    when = NOW - datetime.timedelta(hours=hours_ago)
    return {'context': context, 'state': state, 'created_at': when.strftime('%Y-%m-%dT%H:%M:%SZ')}


def manifest(passed=(), failed=None, retried=()):
    tests = {t: {'status': 'passed'} for t in passed}
    for test, messages in (failed or {}).items():
        tests[test] = {'status': 'failed', 'retry_failures': list(messages)}
    for test in retried:
        tests[test] = {'status': 'passed', 'passed_on_retry': True}
    return {'status': 'verified' if not failed else 'failed', 'steps': [{'name': 'xcode-tests', 'tests': tests}]}


class ShouldRunTests(unittest.TestCase):
    def test_a_commit_with_no_main_t3_status_runs(self):
        self.assertTrue(M.should_run([], NOW)[0])
        self.assertTrue(M.should_run([status('success', context='lane'), status('failure', context='ci')], NOW)[0])

    def test_a_final_status_skips(self):
        for state in ('success', 'failure'):
            with self.subTest(state=state):
                run, why = M.should_run([status(state)], NOW)
                self.assertFalse(run)
                self.assertIn(state, why)

    def test_the_newest_main_t3_status_decides_whatever_the_listing_order(self):
        self.assertFalse(M.should_run([status('error', 3), status('success', 1)], NOW)[0])
        self.assertFalse(M.should_run([status('success', 1), status('error', 3)], NOW)[0])

    def test_a_fresh_pending_skips_and_a_lost_one_runs(self):
        self.assertFalse(M.should_run([status('pending', 1)], NOW)[0])
        self.assertTrue(M.should_run([status('pending', 6)], NOW)[0])

    def test_one_runner_fault_gets_one_retry_and_no_more(self):
        self.assertTrue(M.should_run([status('error', 1), status('pending', 2)], NOW)[0])
        self.assertFalse(M.should_run([status('error', 1), status('pending', 2), status('error', 4),
                                       status('pending', 5)], NOW)[0])

    def test_a_failure_is_never_run_again_on_the_same_commit(self):
        # Owner, 2026-11-18: in-run retries already separate flakes, so a red result gets no second full run, even
        # when an earlier attempt on the commit was a runner fault, or the failure is old.
        for history in ([status('failure', 1)], [status('failure', 1), status('error', 3)],
                        [status('failure', 30)], [status('failure', 1), status('pending', 2)]):
            with self.subTest(history=[s['state'] for s in history]):
                self.assertFalse(M.should_run(history, NOW)[0])

    def test_force_always_runs(self):
        self.assertTrue(M.should_run([status('success')], NOW, force=True)[0])


class ResultsTests(unittest.TestCase):
    def test_a_rerun_replaces_the_first_run_and_a_fresh_clone_counts_only_its_failures(self):
        found = {'verify-app': manifest(passed=['T/A/test1'], failed={'T/A/test2': ['first']}),
                 'verify-app-retry': manifest(passed=['T/A/test1', 'T/A/test2']),
                 'verify-adapters': manifest(passed=['T/B/test1']),
                 'verify-adapters-fresh': manifest(passed=['T/B/test1'], failed={'T/B/test9': ['boom']})}
        results = M.collect_results(M.pick_manifests(found))
        self.assertEqual(results['passed'], 3)
        self.assertEqual(results['failed'], [('T/B/test9', ['boom'])])

    def test_failures_keep_their_messages_once_and_retries_are_named(self):
        found = {'verify-app': manifest(passed=['T/A/ok'], failed={'T/A/bad': ['XCTAssertEqual failed', 'XCTAssertEqual failed']},
                                        retried=['T/A/flaky'])}
        results = M.collect_results(M.pick_manifests(found))
        self.assertEqual(results['passed'], 2)
        self.assertEqual(results['failed'], [('T/A/bad', ['XCTAssertEqual failed'])])
        self.assertEqual(results['retried'], ['T/A/flaky'])

    def test_no_manifest_is_no_result(self):
        self.assertEqual(M.collect_results(M.pick_manifests({})), {'passed': 0, 'failed': [], 'retried': []})


class StatusTests(unittest.TestCase):
    def test_states_map_from_the_lane_verdicts(self):
        self.assertEqual(M.VERDICT_STATE, {'PASS': 'success', 'FAIL': 'failure', 'INCONCLUSIVE': 'error'})

    def test_descriptions(self):
        self.assertEqual(M.description('success', {'passed': 1870, 'retried': []}, []), '1870 passed')
        self.assertEqual(M.description('success', {'passed': 5, 'retried': ['x']}, []), '5 passed, 1 on retry')
        failed = [('SpokenMarginsAppTests/Foo/testBar', []), ('SpokenMarginsAppTests/Baz/testQux', [])]
        self.assertEqual(M.description('failure', {'passed': 3, 'failed': failed}, []),
                         '2 failed: Foo/testBar, Baz/testQux')
        self.assertTrue(M.description('error', {}, ['', 'The cloned simulator did not boot']).startswith(
            'runner fault: The cloned simulator did not boot'))
        self.assertIn('no test result', M.description('failure', {'failed': []}, ['Build before simulator boot: x']))

    def test_the_status_line_names_the_fault_not_the_build_time(self):
        # 846e7e5 (2026-11-21): 1899 app tests passed, the adapters plan could not fetch a licence text, and the status
        # said "runner fault: shared build before simulator boot took 7m44s".
        details = ['shared build before simulator boot took 7m44s (reused: False); evidence: /w/verify-build/manifest.json',
                   'boot of the cloned simulator took 2m25s (memory pressure at boot: normal)',
                   'app: passed on retry: none',
                   'adapters: Process exit 2 (see /w/verify-adapters/supertonic-model.log).',
                   'template preparation and simulator clone took 11m02s']
        self.assertEqual(M.description('error', {'passed': 1899, 'failed': []}, details),
                         'runner fault: adapters: Process exit 2 (see /w/verify-adapters/supertonic-model.log).')
        self.assertTrue(M.description('failure', {'failed': []}, details).startswith(
            'failed, no test result: adapters: Process exit 2'))
        for neutral in details[:3] + details[4:]:  # all neutral: the first still shows, as before
            with self.subTest(neutral=neutral[:30]):
                self.assertEqual(M.first_problem([neutral], 'none'), neutral)
        self.assertEqual(M.first_problem(['', ''], 'none'), 'none')
        # Recovered-stall lines (lane-runner.py 2699, 3020, 3023) are also information, found by the review of this change.
        for recovered in ('boot stall on the first clone (A), so it was deleted and one fresh clone (B) booted in 40s',
                          "tolerated one SpringBoard change in the first 30 s of the first boot (owner's rule)",
                          'app: recovered after 1 startup stall (xcode-tests printed no test output) and counts as a PASS'):
            with self.subTest(recovered=recovered[:30]):
                self.assertEqual(M.first_problem([recovered, 'adapters: Process exit 2'], 'none'), 'adapters: Process exit 2')
        self.assertEqual(M.first_problem(['app: passed on retry: Foo/testBar', 'x failed'], 'none'), 'x failed')
        self.assertEqual(M.first_problem(['Build before simulator boot: Process exit 74'], 'none'),
                         'Build before simulator boot: Process exit 74')

    def test_every_description_fits_githubs_limit(self):
        many = [(f'SpokenMarginsAppTests/Class{i}/testSomethingLong{i}', []) for i in range(40)]
        for state, results, details in (('failure', {'failed': many}, []), ('error', {}, ['x ' * 200]),
                                        ('failure', {'failed': []}, ['y' * 500]), ('success', {'passed': 10**9}, [])):
            with self.subTest(state=state):
                text = M.description(state, results, details)
                self.assertLessEqual(len(text), M.DESCRIPTION_LIMIT)
                self.assertLessEqual(len(M.status_payload(state, 'u', text)['description']), M.DESCRIPTION_LIMIT)
        self.assertTrue(M.description('failure', {'failed': many}, []).endswith('...'))

    def test_payload_is_the_contract(self):
        self.assertEqual(M.status_payload('failure', 'https://run', 'd'),
                         {'state': 'failure', 'context': 'main-t3', 'target_url': 'https://run', 'description': 'd'})
        with self.assertRaises(ValueError):
            M.status_payload('cancelled', 'u', 'd')


class IssueTests(unittest.TestCase):
    results = {'passed': 10, 'failed': [('SpokenMarginsAppTests/Foo/testBar', ['XCTAssertTrue failed - nope'])],
               'retried': []}

    def test_last_green_is_the_newest_success_other_than_the_tested_commit(self):
        nodes = [{'oid': SHA, 'status': {'context': {'state': 'SUCCESS'}}}, {'oid': 'c' * 40, 'status': None},
                 {'oid': 'd' * 40, 'status': {'context': {'state': 'FAILURE'}}},
                 {'oid': GREEN, 'status': {'context': {'state': 'SUCCESS'}}}]
        self.assertEqual(M.last_green(nodes, exclude=SHA), GREEN)
        self.assertIsNone(M.last_green(nodes[1:3]))

    def test_body_names_tests_messages_green_and_merges_and_round_trips_its_state(self):
        body = M.issue_body(SHA, 'https://run', self.results, [], GREEN, ['abc1234 Merge pull request #1'])
        self.assertTrue(body.startswith(M.MARKER))
        self.assertIn('`Foo/testBar`: XCTAssertTrue failed - nope', body)
        self.assertIn(f'Last green `main-t3`: `{GREEN}`', body)
        self.assertIn('abc1234 Merge pull request #1', body)
        state = M.issue_state({'body': body})
        self.assertEqual(state['first_failed'], SHA)
        self.assertEqual(state['failed'], ['SpokenMarginsAppTests/Foo/testBar'])
        self.assertEqual(M.issue_title(SHA), 'Main T3 failed on aaaaaaa')

    def test_an_update_keeps_the_first_failing_commit(self):
        body = M.issue_body('e' * 40, 'u', self.results, [], None, [], first_failed=SHA)
        self.assertEqual(M.issue_state({'body': body})['first_failed'], SHA)
        self.assertIn('none in the last 300 commits', body)

    def test_a_build_failure_lists_what_the_run_said(self):
        body = M.issue_body(SHA, 'u', {'passed': 0, 'failed': []}, ['Build before simulator boot: error'], None, [])
        self.assertIn('- Build before simulator boot: error', body)

    def test_the_body_fits_githubs_limit(self):
        many = {'passed': 0, 'failed': [(f'T/C/test{i}', ['m' * 400]) for i in range(500)]}
        self.assertLessEqual(len(M.issue_body(SHA, 'u', many, ['d'] * 100, GREEN, ['x' * 200] * 500)), M.BODY_LIMIT)

    def test_dedupe_finds_only_the_trusted_marked_open_issue(self):
        ours = {'number': 7, 'body': M.issue_body(SHA, 'u', self.results, [], None, []),
                'user': {'login': 'github-actions[bot]'}, 'author_association': 'NONE'}
        stranger = dict(ours, number=3, user={'login': 'someone'}, author_association='NONE')
        unmarked = dict(ours, number=2, body='Main T3 failed on aaaaaaa')
        pull = dict(ours, number=1, pull_request={})
        self.assertEqual(M.find_open_issue([stranger, unmarked, pull, ours])['number'], 7)
        self.assertIsNone(M.find_open_issue([stranger, unmarked, pull]))
        collaborator = dict(stranger, number=5, author_association='MEMBER')
        self.assertEqual(M.find_open_issue([ours, collaborator])['number'], 5)

    def test_a_tampered_state_marker_reads_as_none(self):
        self.assertEqual(M.issue_state({'body': '<!-- main-t3-state: {not json} -->'}), {})
        self.assertEqual(M.issue_state(None), {})

    def test_still_failing_note_names_new_and_fixed_tests(self):
        note = M.still_failing_note('e' * 40, 'u', self.results, ['SpokenMarginsAppTests/Old/testGone'])
        self.assertIn('Newly failing: Foo/testBar.', note)
        self.assertIn('Now passing: Old/testGone.', note)


class LaneRunnerCouplingTests(unittest.TestCase):
    """main_t3.py drives lane_t3.py's T3 machinery; a rename there must fail here, not on the hosted Mac."""

    def test_the_lane_runner_still_has_what_the_main_run_calls(self):
        lane = M.load_lane_t3()
        for name in ('_run_t3_grouped', 'log_retry_passes', 'RepoTally', 'T3_TIMEOUT'):
            with self.subTest(name=name):
                self.assertTrue(hasattr(lane, name))
        self.assertEqual(sorted(lane.PLANS), sorted(M.PLANS))

    def test_an_empty_selector_list_runs_the_whole_plan(self):
        lane = M.load_lane_t3()
        _, _, ran, _ = lane.run_plans({'app': []}, lambda plan, selectors, output: manifest(passed=['T/A/test1']),
                                      Path('/nonexistent'))
        self.assertEqual(len(ran), 1)
        self.assertIn('1 passed', ran[0])


def job(name, conclusion='success', hours_ago=1.0, status='completed'):
    started = NOW - datetime.timedelta(hours=hours_ago)
    return {'name': name, 'status': status, 'conclusion': conclusion, 'started_at': started.strftime('%Y-%m-%dT%H:%M:%SZ')}


def run(run_id, hours_ago, *jobs):
    created = NOW - datetime.timedelta(hours=hours_ago)
    return {'id': run_id, 'created_at': created.strftime('%Y-%m-%dT%H:%M:%SZ'), 'jobs': list(jobs)}


DECIDE = 'decide: has main moved since its last main-t3?'
T3 = 'main-t3: the whole app suite on main'
FLOOR = datetime.timedelta(minutes=M.FLOOR_MINUTES)


class PushFloorTests(unittest.TestCase):
    """#4839: a push to main starts main-t3, but two simulator runs are never closer than the floor. Without the
    floor, a day of merges would start a 100-minute run per merge."""

    def start(self, runs, current=''):
        return M.recent_work_start(runs, NOW, FLOOR, current)

    def test_no_recent_run_means_no_floor(self):
        self.assertIsNone(self.start([]))

    def test_a_simulator_run_inside_the_floor_holds_the_push(self):
        self.assertIsNotNone(self.start([run(1, 2.5, job(DECIDE), job(T3, hours_ago=2.4))]))

    def test_a_run_older_than_the_floor_does_not(self):
        self.assertIsNone(self.start([run(1, 3.5, job(DECIDE), job(T3, hours_ago=3.4))]))

    def test_a_run_whose_simulator_job_was_skipped_did_no_work(self):
        # the decide job said "already tested", so the t3 job never started
        self.assertIsNone(self.start([run(1, 0.5, job(DECIDE), job(T3, conclusion='skipped'))]))

    def test_a_cancelled_simulator_job_did_no_work(self):
        self.assertIsNone(self.start([run(1, 0.5, job(T3, conclusion='cancelled'))]))

    def test_a_run_still_going_counts_even_when_it_began_long_ago_within_the_floor(self):
        running = job(T3, conclusion=None, status='in_progress', hours_ago=1.7)
        self.assertIsNotNone(self.start([run(1, 1.8, job(DECIDE), running)]))

    def test_this_run_does_not_hold_itself(self):
        self.assertIsNone(self.start([run(7, 0.1, job(DECIDE), job(T3, conclusion=None, status='queued'))], current='7'))

    def test_only_the_simulator_job_counts_not_any_job(self):
        self.assertIsNone(self.start([run(1, 0.5, job(DECIDE))]))

    def test_it_returns_the_newest_start(self):
        found = self.start([run(1, 2.5, job(T3, hours_ago=2.4)), run(2, 1.5, job(T3, hours_ago=1.4))])
        self.assertEqual(found, NOW - datetime.timedelta(hours=1.4))

    def test_a_job_with_no_start_time_uses_its_runs_creation(self):
        queued = {'name': T3, 'status': 'queued', 'conclusion': None, 'started_at': None}
        self.assertIsNotNone(self.start([run(1, 0.2, queued)]))


class DecideClaimTests(unittest.TestCase):
    """Audit of c75ffb7: push runs and ticks are in separate concurrency groups, so a tick can decide while a push run
    is still in Mac setup. Without a status on the commit it started a second whole-suite run, and the two raced to
    write the result. decide now leaves `pending` the moment it says run."""

    def decide(self, store, calls, run_id, **over):
        import argparse
        import os
        from unittest import mock
        args = argparse.Namespace(**{'sha': SHA, 'force': False, 'floor_minutes': 0,
                                     'run_url': f'https://x/runs/{run_id}', **over})
        outputs = {}

        class FixedNow(datetime.datetime):  # decide reads the clock; the statuses above are dated NOW
            @classmethod
            def now(cls, tz=None):
                return NOW
        clock = type('clock', (), {'datetime': FixedNow, 'timezone': datetime.timezone, 'timedelta': datetime.timedelta})

        def set_status(sha, payload):
            store.insert(0, {'context': payload['context'], 'state': payload['state'],
                             'created_at': NOW.strftime('%Y-%m-%dT%H:%M:%SZ')})
            calls.append(payload)
        with mock.patch.object(M, 'statuses', lambda sha: list(store)), \
                mock.patch.object(M, 'set_status', set_status), \
                mock.patch.object(M, 'recent_runs', lambda now, floor: []), \
                mock.patch.object(M, 'write_outputs', lambda **kw: outputs.update(kw)), \
                mock.patch.object(M, 'write_summary', lambda text: None), \
                mock.patch.object(M, 'datetime', clock), \
                mock.patch.dict(os.environ, {'GITHUB_RUN_ID': str(run_id)}):
            M.command_decide(args)
        return outputs['run']

    def test_a_tick_deciding_beside_a_push_run_still_in_setup_skips(self):
        store, calls = [], []
        self.assertEqual(self.decide(store, calls, 1, floor_minutes=M.FLOOR_MINUTES), 'true')   # the push run
        self.assertEqual(self.decide(store, calls, 2), 'false')                               # the 12:17 tick
        self.assertEqual(len(calls), 1)

    def test_the_claim_is_a_pending_main_t3_status_with_the_run_url(self):
        store, calls = [], []
        self.decide(store, calls, 7)
        self.assertEqual([(c['context'], c['state'], c['target_url']) for c in calls],
                         [(M.CONTEXT, 'pending', 'https://x/runs/7')])

    def test_a_decision_not_to_run_claims_nothing(self):
        store, calls = [status('success')], []
        self.assertEqual(self.decide(store, calls, 3), 'false')
        self.assertEqual(calls, [])

    def test_a_dispatch_with_force_claims_and_runs_beside_anything(self):
        store, calls = [status('pending', 0.1)], []
        self.assertEqual(self.decide(store, calls, 4, force=True), 'true')
        self.assertEqual(len(calls), 1)


class WorkflowTests(unittest.TestCase):
    """main-t3.yml is the trunk's one simulator run (owner, 2026-11-18)."""
    ROOT = Path(__file__).resolve().parents[2]

    def load(self, name):
        import yaml
        data = yaml.safe_load((self.ROOT / '.github/workflows' / name).read_text())
        return data.get('on', data.get(True))  # PyYAML reads a bare `on:` key as True

    def test_it_ticks_every_3_hours_and_before_the_owners_phone_builds(self):
        crons = [c['cron'] for c in self.load('main-t3.yml')['schedule']]
        self.assertEqual(crons, ['17 */3 * * *', '30 13 * * *', '30 22 * * *'])  # 6:30 and 15:30 America/Phoenix

    def test_it_also_starts_on_a_push_to_main_and_only_a_push_waits_for_the_floor(self):
        self.assertEqual(self.load('main-t3.yml')['push'], {'branches': ['main']})
        text = (self.ROOT / '.github/workflows/main-t3.yml').read_text()
        self.assertIn("github.event_name == 'push' && '--floor-minutes %d'" % M.FLOOR_MINUTES, text)
        self.assertIn('actions: read', text)  # the floor reads this workflow's runs

    def test_a_push_run_cannot_replace_a_waiting_tick_or_dispatch(self):
        # A concurrency group keeps one pending run and a newer pending run replaces it. In one shared group, a merge's
        # push run replaced a waiting release-cut dispatch or fixed tick, then skipped on the floor, leaving the head
        # untested (audit of 30f4499). Pushes get a group of their own, and nothing in progress is ever cancelled.
        import yaml
        data = yaml.safe_load((self.ROOT / '.github/workflows/main-t3.yml').read_text())
        group = data['concurrency']['group']
        self.assertIs(data['concurrency']['cancel-in-progress'], False)

        def resolve(event):  # the one expression the group uses, evaluated for an event
            return group.replace("${{ github.event_name == 'push' && 'push' || 'run' }}",
                                 'push' if event == 'push' else 'run')
        self.assertNotIn('${{', resolve('push'))
        self.assertNotEqual(resolve('push'), resolve('schedule'))
        self.assertEqual(resolve('schedule'), resolve('workflow_dispatch'))

    def test_decide_can_claim_the_commit_and_a_settle_job_clears_a_claim_the_mac_never_reported(self):
        import yaml
        jobs = yaml.safe_load((self.ROOT / '.github/workflows/main-t3.yml').read_text())['jobs']
        self.assertEqual(jobs['decide']['permissions']['statuses'], 'write')
        self.assertIn('--run-url', jobs['decide']['steps'][-1]['run'])
        settle = jobs['settle']
        self.assertEqual(sorted(settle['needs']), ['decide', 't3'])
        self.assertIn('always()', settle['if'])
        self.assertIn('needs.decide.outputs.run', settle['if'])
        self.assertIn('main_t3.py lost', settle['steps'][-1]['run'])
        self.assertFalse(jobs['settle']['name'].startswith(M.RUN_JOB_PREFIX))

    def test_the_floor_names_the_simulator_job_the_workflow_has(self):
        import yaml
        jobs = yaml.safe_load((self.ROOT / '.github/workflows/main-t3.yml').read_text())['jobs']
        self.assertTrue(jobs['t3']['name'].startswith(M.RUN_JOB_PREFIX))
        self.assertFalse(jobs['decide']['name'].startswith(M.RUN_JOB_PREFIX))

    def test_hosted_integration_no_longer_runs_on_a_push(self):
        self.assertEqual(list(self.load('hosted-integration.yml')), ['workflow_dispatch'])


CERT_LOG = '''Resolve Package Graph
failed downloading 'https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip' which is required by binary target 'onnxruntime': downloadError("The certificate for this server is invalid.")
xcodebuild: error: Could not resolve package dependencies:
  failed downloading 'https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip' which is required by binary target 'onnxruntime': downloadError("The certificate for this server is invalid.")
'''


class PackageFetchFaultTests(unittest.TestCase):
    """#4664: run 44855924738 on 915828e failed in 67 s on a TLS certificate error from download.onnxruntime.ai and
    stayed red until main moved. A network fault while resolving packages is a runner fault (`error`, one retry)."""
    NONE = {'passed': 0, 'failed': [], 'retried': []}

    def test_a_download_or_certificate_error_while_resolving_is_a_fetch_fault(self):
        self.assertTrue(M.package_fetch_fault(CERT_LOG))
        for cause in ('Could not resolve host: github.com', 'The network connection was lost.', 'Failed to clone',
                      'fatal: unable to access https://github.com/x/y.git', 'The operation timed out.',
                      'Connection reset by peer'):
            with self.subTest(cause=cause):
                self.assertTrue(M.package_fetch_fault(f'xcodebuild: error: Could not resolve package dependencies:\n  {cause}'))

    def test_a_resolution_error_with_no_network_cause_is_main_s_own(self):
        for text in ('xcodebuild: error: Could not resolve package dependencies:\n  Dependencies could not be resolved '
                     'because no versions of x match the requirement 9.9.9',
                     'xcodebuild: error: Could not resolve package dependencies:',
                     '',
                     'error: failed downloading a model file',  # not a package resolution error
                     'FollowListsScreen.swift:33:37: error: function declares an opaque return type'):
            with self.subTest(text=text[:40]):
                self.assertFalse(M.package_fetch_fault(text))

    def test_only_a_run_that_ran_no_test_becomes_a_runner_fault(self):
        self.assertEqual(M.state_after_build_fault('failure', self.NONE, True), 'error')
        self.assertEqual(M.state_after_build_fault('failure', self.NONE, False), 'failure')
        self.assertEqual(M.state_after_build_fault('failure', {'passed': 5, 'failed': [], 'retried': []}, True), 'failure')
        self.assertEqual(M.state_after_build_fault('failure', {'passed': 0, 'failed': ['A/testB'], 'retried': []}, True), 'failure')
        self.assertEqual(M.state_after_build_fault('success', {'passed': 5, 'failed': [], 'retried': []}, True), 'success')
        self.assertEqual(M.state_after_build_fault('error', self.NONE, True), 'error')

    def test_it_reads_the_build_log_in_the_evidence_folder(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder)
            self.assertFalse(M.fetch_fault_in_builds(evidence))
            (evidence / 'verify-build').mkdir()
            (evidence / 'verify-build' / 'build-for-testing.log').write_text('error: type mismatch')
            self.assertFalse(M.fetch_fault_in_builds(evidence))
            (evidence / 'verify-build' / 'build-for-testing.log').write_text(CERT_LOG)
            self.assertTrue(M.fetch_fault_in_builds(evidence))

    def test_the_faulted_commit_runs_again_once_then_waits(self):
        self.assertTrue(M.should_run([status('error')], NOW)[0])
        self.assertFalse(M.should_run([status('error'), status('error', hours_ago=3)], NOW)[0])


class CommandLineTests(unittest.TestCase):
    def test_a_short_sha_is_refused(self):
        with self.assertRaises(SystemExit):
            M.main(['decide', '--sha', 'abc1234'])


if __name__ == '__main__':
    unittest.main()
