"""The main T3 release gate (#4575): only a commit whose newest `main-t3` status is success is built.

The producer (#4573) sets a commit status on the tested commit: context `main-t3`, state success, failure or
error, target_url the run. These tests pin the consumer's rule, its messages, the owner's recorded override,
and its two callers: scripts/phone-build and the `archive` step of scripts/xcodebuild-lane.
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS / 'tests'))
import main_t3_gate as gate  # noqa: E402
import test_phone_build as tpb  # noqa: E402  (a module import, so its classes aren't collected twice)

SHA = 'a1' * 20
RUN = 'https://github.com/Spoken-Margins/spoken-margins-native/actions/runs/9'


def status(state, created, context='main-t3', id_=1, url=RUN):
    return {'context': context, 'state': state, 'target_url': url, 'created_at': created, 'id': id_}


def fake_gh(answer, why=''):
    calls = []

    def run(*args):
        calls.append(args)
        return answer, why
    run.calls = calls
    return run


class DecideTests(unittest.TestCase):
    def test_success_allows(self):
        verdict = gate.decide(SHA, [status('success', '2026-11-18T03:00:00Z')])
        self.assertTrue(verdict.allowed)
        self.assertFalse(verdict.overridden)
        self.assertIn('allowed', verdict.lines()[0])

    def test_failure_error_and_pending_refuse_naming_the_state_the_run_and_the_way_out(self):
        for state in ('failure', 'error', 'pending'):
            with self.subTest(state=state):
                verdict = gate.decide(SHA, [status(state, '2026-11-18T03:00:00Z')])
                self.assertFalse(verdict.allowed)
                text = '\n'.join(verdict.lines())
                self.assertIn('REFUSED', text)
                self.assertIn(SHA, text)
                self.assertIn(f'main-t3: {state}', text)
                self.assertIn(RUN, text)
                self.assertIn(f'gh workflow run main-t3.yml --ref main -f sha={SHA}', text)
                self.assertIn("Test Desk's local T3", text)
                self.assertIn('--allow-without-main-t3 "<reason>"', text)

    def test_missing_refuses_with_no_run_link(self):
        for statuses in ([], [status('success', '2026-11-18T03:00:00Z', context='ci/hosted-fast')]):
            with self.subTest(statuses=statuses):
                verdict = gate.decide(SHA, statuses)
                self.assertFalse(verdict.allowed)
                self.assertEqual(verdict.state, 'missing')
                self.assertNotIn('run:', '\n'.join(verdict.lines()))

    def test_github_unreachable_refuses_and_says_why(self):
        verdict = gate.decide(SHA, None, detail='gh exited 4: Bad credentials')
        self.assertFalse(verdict.allowed)
        self.assertIn('GitHub could not be read', verdict.lines()[0])
        self.assertIn('Bad credentials', verdict.lines()[0])

    def test_the_newest_status_wins_whatever_order_github_lists_them_in(self):
        older_green = [status('success', '2026-11-18T01:00:00Z', id_=1), status('failure', '2026-11-18T04:00:00Z', id_=2)]
        older_red = [status('failure', '2026-11-18T01:00:00Z', id_=1), status('success', '2026-11-18T04:00:00Z', id_=2)]
        for statuses, allowed in ((older_green, False), (older_red, True)):
            for ordered in (statuses, list(reversed(statuses))):
                with self.subTest(states=[s['state'] for s in ordered]):
                    self.assertEqual(gate.decide(SHA, ordered).allowed, allowed)

    def test_a_same_second_tie_goes_to_the_later_id(self):
        statuses = [status('success', '2026-11-18T01:00:00Z', id_=5), status('error', '2026-11-18T01:00:00Z', id_=6)]
        self.assertEqual(gate.decide(SHA, statuses).state, 'error')

    def test_an_override_needs_a_reason(self):
        for reason in ('', '   ', '\n'):
            with self.subTest(reason=reason), self.assertRaises(ValueError):
                gate.decide(SHA, [], reason)

    def test_an_override_allows_a_red_commit_and_says_so_with_its_reason(self):
        verdict = gate.decide(SHA, [status('failure', '2026-11-18T03:00:00Z')], '  hotfix for  a crash ')
        self.assertTrue(verdict.allowed)
        self.assertTrue(verdict.overridden)
        self.assertEqual(verdict.reason, 'hotfix for a crash')
        text = '\n'.join(verdict.lines())
        self.assertIn('OVERRIDDEN', text)
        self.assertIn('main-t3: failure', text)
        self.assertIn('reason: hotfix for a crash', text)

    def test_an_override_on_a_green_commit_is_not_an_override(self):
        verdict = gate.decide(SHA, [status('success', '2026-11-18T03:00:00Z')], 'just in case')
        self.assertTrue(verdict.allowed)
        self.assertFalse(verdict.overridden)


class FetchTests(unittest.TestCase):
    def test_reads_one_status_per_line_from_one_paginated_call(self):
        lines = '\n'.join(json.dumps(s) for s in (status('failure', '2026-11-18T01:00:00Z'),
                                                  status('success', '2026-11-18T02:00:00Z')))
        gh = fake_gh(lines + '\nnot json\n')
        statuses, why = gate.fetch_statuses(SHA, gh)
        self.assertEqual([s['state'] for s in statuses], ['failure', 'success'])
        self.assertEqual(why, '')
        self.assertEqual(len(gh.calls), 1)
        self.assertIn(f'repos/{gate.REPO}/commits/{SHA}/statuses', gh.calls[0])
        self.assertIn('--paginate', gh.calls[0])

    def test_a_failed_call_is_none_with_the_reason(self):
        self.assertEqual(gate.fetch_statuses(SHA, fake_gh(None, 'gh exited 1')), (None, 'gh exited 1'))

    def test_check_wants_a_full_commit(self):
        with self.assertRaises(ValueError):
            gate.check(SHA[:7], None, 'test', gh=fake_gh(''))


class NewestGreenTests(unittest.TestCase):
    def answer(self, nodes):
        return json.dumps({'data': {'repository': {'ref': {'target': {'history': {'nodes': nodes}}}}}})

    def test_takes_the_first_commit_whose_main_t3_is_success(self):
        nodes = [{'oid': 'c3' * 20, 'status': None},
                 {'oid': 'c2' * 20, 'status': {'context': {'state': 'FAILURE', 'targetUrl': RUN}}},
                 {'oid': 'c1' * 20, 'status': {'context': {'state': 'SUCCESS', 'targetUrl': RUN}}},
                 {'oid': 'c0' * 20, 'status': {'context': {'state': 'SUCCESS', 'targetUrl': RUN}}}]
        gh = fake_gh(self.answer(nodes))
        self.assertEqual(gate.newest_green('main', gh), ('c1' * 20, ''))
        self.assertIn('ref=refs/heads/main', gh.calls[0])

    def test_none_green_or_an_unreadable_answer_says_why(self):
        green, why = gate.newest_green('main', fake_gh(self.answer([{'oid': 'c3' * 20, 'status': None}])))
        self.assertIsNone(green)
        self.assertIn('has a green main-t3 status yet', why)
        self.assertIsNone(gate.newest_green('main', fake_gh('{}'))[0])
        green, why = gate.newest_green('main', fake_gh(None, 'gh exited 4'))
        self.assertIsNone(green)
        self.assertIn('gh exited 4', why)


class OverrideRecordTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.log = self.tmp / 'logs' / 'overrides.jsonl'
        patcher = unittest.mock.patch.dict(os.environ, {'SM_MAIN_T3_OVERRIDE_LOG': str(self.log)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_an_override_is_appended_with_the_commit_state_and_reason(self):
        answer = json.dumps(status('error', '2026-11-18T03:00:00Z'))
        verdict = gate.check(SHA, 'runner outage', 'xcodebuild-lane', gh=fake_gh(answer))
        self.assertTrue(verdict.allowed)
        self.assertEqual(verdict.logged_to, self.log)
        entry = json.loads(self.log.read_text().splitlines()[-1])
        self.assertEqual((entry['sha'], entry['found'], entry['reason'], entry['tool'], entry['run']),
                         (SHA, 'error', 'runner outage', 'xcodebuild-lane', RUN))

    def test_a_green_commit_or_a_refusal_writes_nothing(self):
        gate.check(SHA, None, 'test', gh=fake_gh(json.dumps(status('failure', '2026-11-18T03:00:00Z'))))
        gate.check(SHA, 'unneeded', 'test', gh=fake_gh(json.dumps(status('success', '2026-11-18T03:00:00Z'))))
        self.assertFalse(self.log.exists())

    def test_the_cli_refuses_then_allows_with_a_reason(self):
        out = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=str(SCRIPTS), capture_output=True, text=True)
        head = out.stdout.strip()
        with unittest.mock.patch.object(gate, '_gh', fake_gh(json.dumps(status('failure', '2026-11-18T03:00:00Z')))):
            with unittest.mock.patch('sys.stderr'), unittest.mock.patch('sys.stdout'):
                self.assertEqual(gate.main([head]), 1)
                self.assertEqual(gate.main([head, '--allow-without-main-t3', ' ']), 2)
                self.assertEqual(gate.main([head, '--allow-without-main-t3', 'owner: hotfix']), 0)
        self.assertIn('owner: hotfix', self.log.read_text())

    def test_split_override_takes_the_flag_out_of_a_wrappers_arguments(self):
        self.assertEqual(gate.split_override(['-scheme', 'X', '--allow-without-main-t3', 'why', 'archive']),
                         (['-scheme', 'X', 'archive'], 'why'))
        self.assertEqual(gate.split_override(['archive', '--allow-without-main-t3=why']), (['archive'], 'why'))
        self.assertEqual(gate.split_override(['build']), (['build'], None))
        with self.assertRaises(ValueError):
            gate.split_override(['archive', '--allow-without-main-t3'])


class PhoneBuildGateTests(unittest.TestCase):
    """scripts/phone-build with the same fakes as test_phone_build.py; FAKE_MAIN_T3 sets the tip's status."""
    setUp_base = tpb.PhoneBuildTests.setUp
    git = tpb.PhoneBuildTests.git
    run_build = tpb.PhoneBuildTests.run_build

    def setUp(self):
        self.setUp_base()
        self.overrides = self.tmp / 'overrides.jsonl'
        self.env['SM_MAIN_T3_OVERRIDE_LOG'] = str(self.overrides)

    def xcodebuild_ran(self):
        return self.log.exists() and '-derivedDataPath' in self.log.read_text()  # the fake xcodebuild logs its arguments

    def test_a_named_commit_without_a_green_main_t3_is_refused_before_any_build(self):
        for state, found in (('failure', 'main-t3: failure'), ('none', 'main-t3: missing')):
            with self.subTest(state=state):
                done = self.run_build(FAKE_MAIN_T3=state)
                self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
                self.assertIn('REFUSED', done.stdout)
                self.assertIn(self.tip, done.stdout)
                self.assertIn(found, done.stdout)
                self.assertFalse(self.xcodebuild_ran())
                self.assertFalse((self.phone / 'latest').exists())

    def test_a_green_commit_builds(self):
        done = self.run_build(FAKE_MAIN_T3='success')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue((self.phone / 'latest').exists())
        self.assertNotIn('main T3 gate', done.stdout)

    def test_the_owners_override_builds_and_is_recorded(self):
        done = self.run_build('--allow-without-main-t3', 'checking a layout fix tonight', FAKE_MAIN_T3='failure')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('OVERRIDDEN', done.stdout)
        entry = json.loads(self.overrides.read_text())
        self.assertEqual((entry['sha'], entry['tool'], entry['reason']),
                         (self.tip, 'phone-build', 'checking a layout fix tonight'))

    def test_an_override_without_a_reason_is_a_usage_error(self):
        done = self.run_build('--allow-without-main-t3', '  ', FAKE_MAIN_T3='failure')
        self.assertEqual(done.returncode, 2)
        self.assertFalse(self.xcodebuild_ran())

    def test_the_job_builds_the_newest_green_commit_and_waits_when_there_is_none(self):
        def job(**extra):
            env = {**os.environ, **self.env, **extra}
            return subprocess.run(['/usr/bin/python3', str(SCRIPTS / 'phone-build'), '--if-changed'], env=env,
                                  capture_output=True, text=True, timeout=120)
        self.git('update-ref', 'refs/remotes/origin/main', self.tip)
        self.git('update-ref', 'refs/remotes/origin/next', self.tip)
        done = job(FAKE_MAIN_T3='none')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('no phone build', done.stdout)
        self.assertFalse(self.xcodebuild_ran())
        done = job(FAKE_MAIN_T3='success')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue((self.phone / 'latest').resolve().name.endswith(self.tip[:7]))


@unittest.skipUnless(shutil.which('ditto') and shutil.which('codesign'), 'needs the Mac\'s ditto and codesign')
class HostedPhoneBuildGateTests(unittest.TestCase):
    setUp = tpb.HostedPhoneBuildTests.setUp
    setUp_base = tpb.PhoneBuildTests.setUp
    make_zip = tpb.HostedPhoneBuildTests.make_zip
    git = tpb.PhoneBuildTests.git
    run_build = tpb.PhoneBuildTests.run_build

    def test_the_hosted_build_of_a_red_commit_is_not_taken(self):
        done = self.run_build(FAKE_MAIN_T3='error')
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn('main-t3: error', done.stdout)
        self.assertNotIn('gh run download', self.log.read_text())
        self.assertFalse((self.phone / 'latest').exists())


class XcodebuildLaneGateTests(unittest.TestCase):
    """An `archive` through scripts/xcodebuild-lane is the upload's first step, so it is gated on HEAD."""

    def setUp(self):
        loader = importlib.machinery.SourceFileLoader('xcodebuild_lane', str(SCRIPTS / 'xcodebuild-lane'))
        spec = importlib.util.spec_from_loader('xcodebuild_lane', loader)
        self.lane = importlib.util.module_from_spec(spec)
        loader.exec_module(self.lane)

    def test_only_an_archive_is_gated(self):
        self.assertTrue(self.lane.archives(['-scheme', 'X', '-archivePath', 'a.xcarchive', 'archive']))
        for argv in (['build'], ['-scheme', 'X', 'build-for-testing'], ['-exportArchive', '-archivePath', 'a']):
            with self.subTest(argv=argv):
                self.assertFalse(self.lane.archives(argv))

    def test_a_refused_archive_runs_no_xcodebuild(self):
        refused = gate.decide(SHA, [status('failure', '2026-11-18T03:00:00Z')])
        with unittest.mock.patch.object(self.lane, 'archive_commit', return_value=(SHA, '')), \
                unittest.mock.patch.object(self.lane.main_t3_gate, 'check', return_value=refused) as check, \
                unittest.mock.patch.object(self.lane.subprocess, 'Popen') as popen, \
                unittest.mock.patch('sys.stderr'):
            self.assertEqual(self.lane.main(['-scheme', 'X', 'archive']), 1)
        check.assert_called_once()
        popen.assert_not_called()

    def test_a_dirty_tree_is_not_the_commit_so_it_is_refused(self):
        with unittest.mock.patch.object(self.lane, 'archive_commit', return_value=(None, 'uncommitted changes')), \
                unittest.mock.patch.object(self.lane.subprocess, 'Popen') as popen, \
                unittest.mock.patch('sys.stderr'):
            self.assertEqual(self.lane.main(['archive']), 1)
        popen.assert_not_called()

    def test_the_override_is_taken_out_before_xcodebuild_sees_the_arguments(self):
        allowed = gate.decide(SHA, [], 'owner hotfix')
        process = unittest.mock.Mock()
        process.wait.return_value = 0
        with unittest.mock.patch.object(self.lane, 'archive_commit', return_value=(SHA, '')), \
                unittest.mock.patch.object(self.lane.main_t3_gate, 'check', return_value=allowed) as check, \
                unittest.mock.patch.object(self.lane, 'build_slot'), \
                unittest.mock.patch.object(self.lane, 'link_local_config'), \
                unittest.mock.patch.object(self.lane, 'worktree_root', return_value=Path('/nonexistent')), \
                unittest.mock.patch.object(self.lane.sm_build_cache, 'ensure_links'), \
                unittest.mock.patch.object(self.lane.subprocess, 'Popen', return_value=process) as popen, \
                unittest.mock.patch('sys.stderr'):
            code = self.lane.main(['-scheme', 'X', '--allow-without-main-t3', 'owner hotfix', 'archive'])
        self.assertEqual(code, 0)
        self.assertEqual(check.call_args[0][1], 'owner hotfix')
        self.assertNotIn('--allow-without-main-t3', popen.call_args[0][0])
        self.assertNotIn('owner hotfix', popen.call_args[0][0])


if __name__ == '__main__':
    unittest.main()
