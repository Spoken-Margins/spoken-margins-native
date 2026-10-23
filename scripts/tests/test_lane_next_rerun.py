"""#1204: a failing host test is re-run on plain next before the lane blames the PR."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_next_rerun as rerun  # noqa: E402

spec = importlib.util.spec_from_file_location('lane_runner_for_rerun', SCRIPTS / 'lane-runner.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)

BROKEN = 'import unittest\nclass DemoTests(unittest.TestCase):\n    def test_a(self):\n        self.fail("broken")\n'
WORKING = 'import unittest\nclass DemoTests(unittest.TestCase):\n    def test_a(self):\n        pass\n'
ID = 'test_demo.DemoTests.test_a'
OWNER = {'user': {'login': 'uncomposed'}, 'author_association': 'OWNER'}
STRANGER = {'user': {'login': 'mallory'}, 'author_association': 'NONE'}


def git(tree, *args):
    return subprocess.run(['git', '-C', str(tree), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                          check=True, capture_output=True, text=True).stdout.strip()


class FakeApi:
    """gh api: the open issues and milestones it returns, and every write it is asked for."""
    def __init__(self, issues=(), milestones=({'number': 7, 'title': 'Open Source: after the flip'},)):
        self.issues, self.milestones, self.writes = list(issues), list(milestones), []

    def __call__(self, *args):
        if args[0] == '--paginate':
            return '\n'.join(json.dumps(issue) for issue in self.issues)
        if args[0].endswith('/milestones?state=open&per_page=100'):
            return json.dumps(self.milestones)
        self.writes.append(args)
        if args[0].endswith('/issues'):
            return json.dumps({'number': 900 + len(self.writes), 'title': dict(
                arg.split('=', 1) for arg in args[1:] if '=' in arg and not arg.startswith('-'))['title']})
        return json.dumps({'html_url': 'https://example.test/comment'})

    def filed(self):
        return [args for args in self.writes if args[0].endswith('/issues')]

    def commented(self):
        return [args for args in self.writes if args[0].endswith('/comments')]


class Repo:
    """A git tree whose 'next' commit has scripts/tests/test_demo.py as given, and a PR merge commit on top."""
    def __init__(self, folder, on_next, in_pr):
        self.tree = Path(folder) / 'tree'
        (self.tree / 'scripts/tests').mkdir(parents=True)
        git(self.tree.parent, 'init', '-q', str(self.tree))
        self.write(on_next)
        self.next = self.commit('next')
        self.write(in_pr)
        self.merge = self.commit('merge')
        self.evidence = Path(folder) / 'pr5-r1'
        (self.evidence / 'fast').mkdir(parents=True)

    def write(self, text):
        test = self.tree / 'scripts/tests/test_demo.py'
        if text is None:
            test.unlink(missing_ok=True)
            (self.tree / 'scripts/tests/keep.txt').write_text('x')
        else:
            test.write_text(text)

    def commit(self, message):
        git(self.tree, 'add', '-A')
        git(self.tree, 'commit', '-q', '--allow-empty', '-m', message)
        return git(self.tree, 'rev-parse', 'HEAD')

    def failed_step(self, name='runner-tests', log=f'FAIL: test_a ({ID})\nRan 1 test in 0.1s\n', **step):
        manifest = {'status': 'failed_or_incomplete',
                    'steps': [{'name': 'contracts', 'errors': []},
                              dict({'name': name, 'errors': ['Process exit 1'],
                                    'command': [sys.executable, '-m', 'unittest']}, **step)]}
        (self.evidence / 'fast/manifest.json').write_text(json.dumps(manifest))
        (self.evidence / f'fast/{name}.log').write_text(log)

    def recheck(self, api, **kw):
        return rerun.recheck(self.tree, self.next, self.evidence, ['host tests (--plan fast) — failed'], api,
                             'o/r', 5, **kw)


class FailureParsingTests(unittest.TestCase):
    def test_unittest_headings_from_every_python_version_name_the_test(self):
        log = ('FAIL: test_a (test_x.Cls.test_a)\n'                 # Python 3.11+
               'ERROR: test_b (test_x.Cls)\n'                       # Python 3.9
               "FAIL: test_c (test_x.Cls.test_c) (path='a')\n"      # a subTest
               "FAIL: test_c (test_x.Cls.test_c) (path='b')\n"      # the same test twice
               'ERROR: setUpClass (test_y.Other)\n'                 # a class fixture
               'Ran 4 tests in 0.1s\n')
        self.assertEqual(rerun.python_failures(log), ['test_x.Cls.test_a', 'test_x.Cls.test_b', 'test_x.Cls.test_c',
                                                      'test_y.Other'])

    def test_only_a_test_step_that_failed_by_its_tests_is_re_run(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            output = repo.evidence / 'fast'
            repo.failed_step()
            self.assertEqual(rerun.failing_tests(output, repo.tree), ('python', 'scripts/tests', [ID]))
            ops = repo.tree / 'ops/dial'
            repo.failed_step('ops-dial', 'FAIL: test_gate (test_dial_gate.GateTests.test_gate)\n',
                             command=[sys.executable, '-m', 'unittest', 'discover', '-s', str(ops), '-t', str(ops)])
            self.assertEqual(rerun.failing_tests(output, repo.tree),
                             ('python', 'ops/dial', ['test_dial_gate.GateTests.test_gate']))
            swift = {'SessionKitTests/RealPlayerXTests/testA': {'status': 'failed'},
                     'SessionKitTests/OtherTests/testB': {'status': 'passed'}}
            repo.failed_step('package', '', errors=['Process exit 1', 'Failed: SessionKitTests/RealPlayerXTests/testA'],
                             tests=swift)
            self.assertEqual(rerun.failing_tests(output, repo.tree),
                             ('swift', 'Packages/SessionKit', ['SessionKitTests/RealPlayerXTests/testA']))
            for why, step in (('a timeout', dict(name='package', interrupted=True, tests=swift)),
                              ('tests that never ran', dict(name='package', tests=swift,
                                                            errors=['Process exit 1', 'Missing: SessionKitTests/A/testB'])),
                              ('a check that is no test suite', dict(name='contracts')),
                              ('no test named in the log', dict(name='runner-tests', log='Segmentation fault\n'))):
                with self.subTest(why=why):
                    name = step.pop('name')
                    repo.failed_step(name, step.pop('log', ''), **step)
                    self.assertIsNone(rerun.failing_tests(output, repo.tree))

    def test_the_swift_filter_matches_exactly_the_failing_tests(self):
        expression = rerun.swift_filter(['SessionKitTests/RealPlayerXTests/testA', 'SessionKitCoreTests/B/testC'])
        import re
        for name, wanted in (('SessionKitTests.RealPlayerXTests/testA', True), ('SessionKitCoreTests.B/testC', True),
                             ('SessionKitTests.RealPlayerXTests/testAB', False), ('SessionKitTestsXRealPlayerXTests/testA', False)):
            self.assertEqual(bool(re.search(expression, name)), wanted, name)


class RecheckTests(unittest.TestCase):
    def test_a_test_that_fails_on_next_too_is_inconclusive_and_gets_its_own_issue(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            repo.failed_step()
            api = FakeApi()
            verdict, details = repo.recheck(api)
            self.assertEqual(verdict, 'INCONCLUSIVE')
            self.assertIn(f'fails on main {repo.next[:7]} too: not this PR', '\n'.join(details))
            self.assertEqual(git(repo.tree, 'rev-parse', 'HEAD'), repo.merge)  # the tree is back on the merge
            (filed,) = api.filed()
            self.assertIn(f'title=Host test fails on main: {ID}', filed)
            for label in ('ready', 'priority', 'bug', 'regression'):
                self.assertIn(f'labels[]={label}', filed)
            self.assertIn('milestone=7', filed)
            self.assertIn(f'  {ID}: filed #901', details)
            # The auto-revert doesn't count it against the newest lane change: the test's issue tracks it.
            self.assertEqual(lane.lane_report_verdict('\n'.join(
                [lane.report('pr5-r1', verdict, 'a' * 40, repo.next, 'auto', 'host only', 1, 'x', details, 'none', '/e',
                             'owner', {'commit': 'a' * 40, 'next': repo.next, 'tier': 'auto', 'tests': []})]))[0], False)

    def test_the_log_shows_the_assertion_that_failed_on_the_trunk(self):
        # #2535: the log held only the result line, so the cause of #2525/#2526 had to be found in another log.
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            repo.failed_step()
            repo.recheck(FakeApi())
            log = (repo.evidence / 'next-rerun.log').read_text()
            self.assertIn('AssertionError: broken', log)
            self.assertIn('LANE-NEXT-RERUN {', log)

    def test_the_wording_names_the_trunk_and_the_old_wording_still_matches_the_runners_marker(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict(os.environ, {'SM_TRUNK': 'trunkx'}):
            repo = Repo(folder, BROKEN, BROKEN)
            repo.failed_step()
            api = FakeApi()
            verdict, details = repo.recheck(api)
            text = '\n'.join(details)
            self.assertIn(f'fails on trunkx {repo.next[:7]} too: not this PR', text)
            self.assertIn(f'title=Host test fails on trunkx: {ID}', api.filed()[0])
        # lane-runner.py reads the marker, not the branch name: the old line and the new one are both no lane fault.
        for line in ('fails on next abc1234 too: not this PR.', 'fails on main abc1234 too: not this PR.',
                     'fails on trunkx abc1234 too: not this PR.'):
            with self.subTest(line=line):
                body = lane.report('pr5-r1', 'INCONCLUSIVE', 'a' * 40, 'b' * 7, 'auto', 'host only', 1, 'x', [line],
                                   'none', '/e', 'owner', {'commit': 'a' * 40, 'next': 'b' * 7, 'tier': 'auto', 'tests': []})
                self.assertEqual(lane.lane_report_verdict(body)[0], False)

    def test_many_tests_failing_at_once_make_one_issue_not_one_each(self):
        api = FakeApi(milestones=[{'number': 9, 'title': rerun.MILESTONE}])
        tests = [f'test_x.T.test_{n}' for n in range(8)]
        lines = rerun.report_broken_on_next(api, 'o/r', tests, 'a' * 40, 5, 'r1', Path('/log'))
        (filed,) = api.filed()
        self.assertIn('title=Host tests fail on main: many at once', filed)
        self.assertIn('milestone=9', filed)
        self.assertEqual(len(lines), 1)
        # An issue filed before #2535 under the old wording is still the one a later run comments on.
        for title in ('Host tests fail on main: many at once', 'Host tests fail on next: many at once'):
            with self.subTest(title=title):
                again = FakeApi(issues=[{'number': 50, 'title': title, **OWNER}])
                rerun.report_broken_on_next(again, 'o/r', tests, 'a' * 40, 6, 'r2', Path('/log'))
                self.assertEqual(again.filed(), [])
                self.assertEqual(again.commented()[0][0], 'repos/o/r/issues/50/comments')

    def test_an_open_issue_naming_the_test_gets_a_comment_instead(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            repo.failed_step()
            for title in (f'Host test fails on main: {ID}', f'Host test fails on next: {ID}',
                          'DemoTests.test_a fails on the lane Mac'):
                with self.subTest(title=title):
                    api = FakeApi(issues=[{'number': 44, 'title': title, **OWNER},
                                          {'number': 45, 'title': title, 'pull_request': {}, **OWNER}])
                    verdict, details = repo.recheck(api)
                    self.assertEqual(verdict, 'INCONCLUSIVE')
                    self.assertEqual(api.filed(), [])
                    (comment,) = api.commented()
                    self.assertEqual(comment[0], 'repos/o/r/issues/44/comments')
                    self.assertIn(repo.next[:7], comment[2])

    def test_a_strangers_issue_naming_the_test_does_not_hide_the_regression(self):
        # #1822: a public issue titled with the failing test's name must not stop the real issue being filed.
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            repo.failed_step()
            api = FakeApi(issues=[{'number': 44, 'title': f'Host test fails on main: {ID}', **STRANGER}])
            verdict, details = repo.recheck(api)
            self.assertEqual(verdict, 'INCONCLUSIVE')
            self.assertEqual(len(api.filed()), 1)
            self.assertEqual(api.commented(), [])

    def test_a_test_that_passes_on_next_keeps_the_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, WORKING, BROKEN)
            repo.failed_step()
            api = FakeApi()
            verdict, details = repo.recheck(api)
            self.assertEqual(verdict, 'FAIL')
            self.assertIn(f'{ID} (passed on main)', '\n'.join(details))
            self.assertEqual(api.writes, [])
            self.assertEqual(git(repo.tree, 'rev-parse', 'HEAD'), repo.merge)

    def test_a_test_the_pr_added_keeps_the_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, None, BROKEN)
            repo.failed_step()
            api = FakeApi()
            verdict, details = repo.recheck(api)
            self.assertEqual(verdict, 'FAIL')
            self.assertIn(f'{ID} (missing on main)', '\n'.join(details))
            self.assertEqual(api.writes, [])

    def test_a_failure_no_test_explains_is_not_re_run(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            repo.failed_step('contracts', 'schema error\n')
            ran = []
            verdict, details = repo.recheck(FakeApi(), runner=lambda *a: ran.append(a))
            self.assertEqual((verdict, details, ran), ('FAIL', ['host tests (--plan fast) — failed'], []))

    def test_a_tree_that_cannot_check_out_next_keeps_the_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, WORKING, BROKEN)
            repo.failed_step()
            (repo.tree / 'scripts/tests/test_demo.py').write_text(BROKEN + '# edited during the run\n')
            verdict, details = repo.recheck(FakeApi())
            self.assertEqual(verdict, 'FAIL')
            self.assertIn('not re-run on main: could not check out main', details[-1])

    def test_a_re_run_that_runs_out_of_time_is_no_proof_against_next(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            repo.failed_step()
            verdict, details = repo.recheck(FakeApi(), runner=lambda command, log, timeout: None)
            self.assertEqual(verdict, 'FAIL')
            self.assertIn(f'{ID} (missing on main)', '\n'.join(details))
            self.assertEqual(git(repo.tree, 'rev-parse', 'HEAD'), repo.merge)

    def swift_run(self, statuses):
        def run(command, log, timeout):
            self.commands.append(command)
            for test, status in statuses.items():
                module, cls, method = test.split('/')
                log.write(f"Test Case '-[{module}.{cls} {method}]' {status} (0.1 seconds).\n")
            log.flush()
            return 1
        self.commands = []
        return run

    def test_swift_tests_run_by_filter_and_real_player_tests_are_not_filed_while_the_mac_has_no_sound(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Repo(folder, BROKEN, BROKEN)
            player, other = 'SessionKitTests/RealPlayerXTests/testA', 'SessionKitTests/OtherTests/testB'
            tests = {player: {'status': 'failed'}, other: {'status': 'failed'}}
            for usable, filed in ((False, [other]), (True, [other, player]), (None, [other, player])):
                with self.subTest(usable=usable):
                    repo.failed_step('package', '', errors=['Process exit 1', f'Failed: {player}'], tests=tests)
                    manifest = json.loads((repo.evidence / 'fast/manifest.json').read_text())
                    if usable is not None:
                        manifest['audio_output'] = {'usable': usable, 'why': 'lid closed'}
                    (repo.evidence / 'fast/manifest.json').write_text(json.dumps(manifest))
                    api = FakeApi()
                    verdict, details = repo.recheck(api, runner=self.swift_run({player: 'failed', other: 'failed'}))
                    self.assertEqual(verdict, 'INCONCLUSIVE')
                    (command,) = self.commands
                    self.assertEqual(command[:4], ['swift', 'test', '--package-path', 'Packages/SessionKit'])
                    self.assertEqual([args[2] for args in api.filed()],
                                     [f'title=Host test fails on main: {test}' for test in filed])
                    self.assertEqual(any('no sound output (#909)' in line for line in details), usable is False)


class LaneRunnerTests(unittest.TestCase):
    def test_only_a_host_test_fail_is_rechecked_and_its_answer_is_the_verdict(self):
        asked = []

        def recheck(evidence, details):
            asked.append(evidence)
            return 'INCONCLUSIVE', details + ['fails on main abc1234 too: not this PR.']

        for fast, wanted, rechecked in ((('FAIL', ['host tests failed']), 'INCONCLUSIVE', True),
                                        (('PASS', []), 'PASS', False), (('INCONCLUSIVE', ['lane fault']), 'INCONCLUSIVE', False)):
            with self.subTest(fast=fast[0]):
                asked.clear()
                verdict, _, _, details = lane.run_automerge({'tier': 'T1', 'why': ['x']}, Path('/e'),
                                                            fast=lambda evidence, changed=None: fast, recheck=recheck)
                self.assertEqual(verdict, wanted)
                self.assertEqual(bool(asked), rechecked)
        verdict, _, _, _ = lane.run_automerge({'tier': 'T1', 'why': ['x']}, Path('/e'),
                                              fast=lambda evidence, changed=None: ('FAIL', ['x']))
        self.assertEqual(verdict, 'FAIL')  # without a recheck, as in any caller that doesn't pass one

    def test_the_automerge_run_rechecks_on_the_next_commit_it_tested(self):
        source = (SCRIPTS / 'lane-runner.py').read_text()
        self.assertIn('recheck=recheck_on_base(github, base_sha)', source)


if __name__ == '__main__':
    unittest.main()
