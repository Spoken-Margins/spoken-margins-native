"""The automerge run takes the hosted fast checks' PASS and runs only --plan fast-mac-rest on the Mac (#1389).

Over the three days to 2026-10-18 the lane spent about 76 Mac-hours on 322 host-only automerge runs (14 minutes
each), most of it on steps a GitHub-hosted runner can run once the repo is public. What these tests guard: the
runner never takes a hosted result for a commit it didn't test (another head, another tree, a next that moved in
ways that matter, a check that didn't pass), and with the switch off nothing changes. The VPS pair in linux-t1.yml
(#2160) was read here until #2442 retired it.
"""
import contextlib
import io
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import lane, verification  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ON = {'LANE_HOSTED_FAST': 'on'}


def notice(plan, tree, base, head, title='lane-hosted-tested', level='notice'):
    return {'title': title, 'annotation_level': level, 'message': f'plan={plan} tree={tree} parents={base} {head}'}


class FakeChecks:
    """The two GitHub API reads hosted_fast_records makes: check runs on a head, and one run's annotations."""

    def __init__(self, runs, annotations):
        self.repo, self.runs, self.annotations, self.calls = 'o/r', runs, annotations, []

    def api(self, path):
        self.calls.append(path)
        if '/annotations' in path:
            return json.dumps(self.annotations[int(path.split('/')[-2])])
        name = next(name for name in lane.HOSTED_FAST_CHECKS
                    if 'check_name=' + lane.urllib.parse.quote(name, safe='') + '&' in path)
        return json.dumps({'check_runs': self.runs.get(name, [])})


def passing(head, base='d' * 40, tree='e' * 40, checks=None, **changes):
    """FakeChecks where both hosted checks (or <checks>) passed on <head>, each with its notice; changes override a run's
    fields."""
    runs, annotations = {}, {}
    for index, (name, plan) in enumerate((checks or lane.HOSTED_FAST_CHECKS).items(), start=1):
        run = {'id': index, 'status': 'completed', 'conclusion': 'success', 'app': {'slug': 'github-actions'},
               'started_at': '2026-10-18T10:00:00Z', 'html_url': f'https://example.test/run/{index}'}
        run.update(changes.get(name, {}))
        runs[name] = [run]
        annotations[index] = [notice(plan, tree, base, head)]
    return FakeChecks(runs, annotations)


class HostedTestedTests(unittest.TestCase):
    def test_reads_the_one_notice_and_ignores_anything_else(self):
        record = lane.hosted_tested([{'title': 'other', 'annotation_level': 'notice', 'message': 'x'},
                                     notice('fast-portable', 'e' * 40, 'd' * 40, 'a' * 40)])
        self.assertEqual(record, {'plan': 'fast-portable', 'tree': 'e' * 40, 'base': 'd' * 40, 'head': 'a' * 40})

    def test_no_record_from_a_warning_two_notices_or_a_malformed_one(self):
        good = notice('fast-portable', 'e' * 40, 'd' * 40, 'a' * 40)
        for name, annotations in (
                ('none', []),
                ('a warning, not a notice', [{**good, 'annotation_level': 'warning'}]),
                ('two notices', [good, good]),
                ('a short sha', [notice('fast-portable', 'e' * 7, 'd' * 40, 'a' * 40)]),
                ('one parent', [{**good, 'message': f'plan=fast-portable tree={"e" * 40} parents={"d" * 40}'}])):
            with self.subTest(name):
                self.assertIsNone(lane.hosted_tested(annotations))


class HostedRecordsTests(unittest.TestCase):
    HEAD = 'a' * 40

    def test_both_checks_passed_and_said_what_they_tested(self):
        found, why = lane.hosted_fast_records(passing(self.HEAD), self.HEAD)
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))
        self.assertEqual({record['plan'] for record in found.values()}, set(lane.HOSTED_FAST_CHECKS.values()))

    def test_any_missing_unfinished_failed_or_foreign_check_means_no(self):
        portable = 'hosted fast: portable'
        for name, changes, expected in (
                ('not finished', {'status': 'in_progress', 'conclusion': None}, 'had not finished'),
                ('failed', {'conclusion': 'failure'}, 'ended failure'),
                ('skipped (switch off on GitHub)', {'conclusion': 'skipped'}, 'ended skipped'),
                ('another app', {'app': {'slug': 'someone-else'}}, 'no "hosted fast: portable" check')):
            with self.subTest(name):
                found, why = lane.hosted_fast_records(passing(self.HEAD, **{portable: changes}), self.HEAD)
                self.assertIsNone(found)
                self.assertIn(expected, why)

    def test_the_newest_run_decides(self):
        checks = passing(self.HEAD)
        name = 'hosted fast: portable'
        checks.runs[name].append({**checks.runs[name][0], 'id': 9, 'conclusion': 'failure',
                                  'started_at': '2026-10-18T11:00:00Z'})
        checks.annotations[9] = []
        found, why = lane.hosted_fast_records(checks, self.HEAD)
        self.assertIsNone(found)
        self.assertIn('ended failure', why)

    def test_a_record_for_another_plan_or_head_is_not_this_run(self):
        for name, annotation in (('another plan', notice('fast', 'e' * 40, 'd' * 40, self.HEAD)),
                                 ('another head', notice('fast-portable', 'e' * 40, 'd' * 40, 'f' * 40))):
            with self.subTest(name):
                checks = passing(self.HEAD)
                checks.annotations[1] = [annotation]
                found, why = lane.hosted_fast_records(checks, self.HEAD)
                self.assertIsNone(found)
                self.assertIn('did not record', why)


class HostedChecksStandTests(unittest.TestCase):
    """hosted_fast_checks with real git: the tree must match, and next's moves since must not matter."""
    setUp = test_lane_runner.PushTests.setUp
    commit = test_lane_runner.PushTests.commit
    rev = test_lane_runner.PushTests.rev

    def move_next(self, name, text='someone else merged\n'):
        path = self.other / name
        path.parent.mkdir(parents=True, exist_ok=True)
        self.commit(self.other, name, text)
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)
        return lane.fetch_base(self.tree, 'main')

    def pr(self):
        self.commit(self.tree, 'pr.txt', 'pr\n')
        head = self.rev(self.tree, 'HEAD')
        tested = lane.fetch_base(self.tree, 'main')
        return head, tested, lane.merged_tree(self.tree, tested, head)

    def stands(self, head, base_sha, records, env=ON):
        return lane.hosted_fast_checks(None, self.tree, 'main', head, base_sha, env=env, records=records)

    def records(self, head, base, tree, only=None):
        """A records reader whose checks all passed and recorded <tree>; with <only>, just that set of checks."""
        def read(github, h, checks):
            if only is not None and checks is not only:
                return None, f'no "{next(iter(checks))}" check ran on {h[:7]}'
            return {name: {'plan': plan, 'tree': tree, 'base': base, 'head': head, 'url': 'u'}
                    for name, plan in checks.items()}, ''
        return read

    def test_it_waits_for_checks_still_running_then_takes_them(self):
        # The first lane runs after the switch went on found the hosted checks still running and ran the whole
        # --plan fast on the Mac (#1389). Inside a lane job the runner now waits for them.
        head, tested, tree = self.pr()
        passed = self.records(head, tested, tree)
        reads, slept, now = [], [], [0.0]

        def running_twice(github, h, checks):
            reads.append(checks)
            if len(reads) <= 2:  # two polls
                return None, f'"{next(iter(checks))}" had not finished on {h[:7]}'
            return passed(github, h, checks)

        def sleep(seconds):
            slept.append(seconds)
            now[0] += seconds
        found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env={**ON, 'GITHUB_ACTIONS': 'true'},
                                             records=running_twice, clock=lambda: now[0], sleep=sleep,
                                             out=io.StringIO())
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))
        self.assertEqual(slept, [lane.HOSTED_FAST_POLL] * 2)

    def test_the_wait_is_bounded_and_skipped_outside_a_lane_job(self):
        head, tested, _ = self.pr()

        def running(github, h, checks):
            return None, f'"{next(iter(checks))}" had not finished on {h[:7]}'
        for env, polls in (({**ON, 'GITHUB_ACTIONS': 'true'}, lane.HOSTED_FAST_WAIT // lane.HOSTED_FAST_POLL), (ON, 0)):
            with self.subTest(env):
                slept, now = [], [0.0]

                def sleep(seconds):
                    slept.append(seconds)
                    now[0] += seconds
                found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env=env, records=running,
                                                     clock=lambda: now[0], sleep=sleep, out=io.StringIO())
                self.assertIsNone(found)
                self.assertIn('had not finished', why)
                self.assertEqual(len(slept), polls)

    def test_a_failed_or_missing_check_is_not_waited_for(self):
        head, tested, _ = self.pr()
        slept = []
        for why in ('"hosted fast: portable" ended failure on abc1234', 'no "hosted fast: portable" check ran'):
            found, said = lane.hosted_fast_checks(None, self.tree, 'main', head, tested,
                                                  env={**ON, 'GITHUB_ACTIONS': 'true'},
                                                  records=lambda github, h, checks, why=why: (None, why),
                                                  sleep=slept.append, out=io.StringIO())
            self.assertIsNone(found)
        self.assertEqual(slept, [])

    def test_off_reads_no_checks(self):
        # The Mac runs the whole --plan fast, and nothing off the Mac is read: no VPS pair since #2442.
        head, tested, tree = self.pr()
        for env in ({}, {'LANE_HOSTED_FAST': ''}, {'LANE_HOSTED_FAST': 'off'}, {'LANE_HOSTED_FAST': 'yes'}):
            with self.subTest(env):
                reads = []

                def passed(github, h, checks):
                    reads.append(checks)
                    return self.records(head, tested, tree)(github, h, checks)
                found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env=env, records=passed)
                self.assertIsNone(found)
                self.assertIn('the hosted fast checks are off', why)
                self.assertEqual(reads, [])

    def test_with_the_switch_on_the_hosted_pair_stands_and_says_so(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, tree))
        self.assertEqual(why, '')
        self.assertEqual({record['runner'] for record in found.values()}, {'GitHub-hosted'})
        self.assertIn('GitHub-hosted: --plan fast-portable and SessionKitCoreTests', lane.hosted_fast_ran(found))
        self.assertTrue(all(line.startswith('GitHub-hosted check "') for line in lane.hosted_fast_lines(found)))

    def test_another_tree_does_not_stand(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, '0' * 40))
        self.assertIsNone(found)
        self.assertIn('"hosted fast: portable" tested a tree that is not', why)

    def test_the_same_merge_stands(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, tree))
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))
        # The tree the runner's own merge commit holds is the one the hosted job reported.
        sha, _ = lane.build_merge_commit(self.tree, 'main', head, 5, 'A change')
        self.assertEqual(self.rev(self.tree, sha + '^{tree}'), tree)

    def test_a_tree_that_is_not_this_merge_is_refused(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, tested, '0' * 40))
        self.assertIsNone(found)
        self.assertIn('tested a tree that is not', why)

    def test_next_moving_elsewhere_lets_it_stand_and_says_so(self):
        head, tested, tree = self.pr()
        newest = self.move_next('docs/notes.md')
        found, why = self.stands(head, newest, self.records(head, tested, tree))
        self.assertEqual(why, '')
        self.assertTrue(all(len(record['moved']) == 1 for record in found.values()))
        lines = lane.hosted_fast_lines(found)
        self.assertTrue(all('1 commit since touch none of this PR' in line for line in lines))
        self.assertIn(tested[:7], lane.hosted_fast_ran(found))

    def test_next_touching_the_prs_files_or_a_global_input_means_the_whole_plan(self):
        # #2596 (Default taken 5): only the PR's own files and what every PR is built from make a hosted check stale.
        for name, path in (('the PR\'s file', 'pr.txt'), ('project.yml', 'project.yml'),
                           ('Package.swift', 'Packages/SessionKit/Package.swift'),
                           ('Package.resolved', 'Package.resolved'), ('package-lock.json', 'web/package-lock.json'),
                           ('package.json', 'package.json')):
            with self.subTest(name):
                self.setUp()
                head, tested, tree = self.pr()
                newest = self.move_next(path)
                found, why = self.stands(head, newest, self.records(head, tested, tree))
                self.assertIsNone(found)
                self.assertIn(f'tested it on main at {tested[:7]}', why)
                self.assertTrue(lane.HOSTED_STALE.search(why), why)

    def test_next_moving_in_scripts_or_workflows_lets_a_hosted_check_stand(self):
        # 6 of 7 fallbacks on 2026-10-24 were a scripts/ file merged by someone else while the check ran.
        for path in ('scripts/verify-tests.py', 'scripts/lane-runner.py', '.github/workflows/lane.yml',
                     'ops/testdesk/x.py', 'App/SpokenMarginsApp/Sources/Other.swift'):
            with self.subTest(path):
                self.setUp()
                head, tested, tree = self.pr()
                newest = self.move_next(path)
                found, why = self.stands(head, newest, self.records(head, tested, tree))
                self.assertEqual(why, '')
                self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))

    def test_a_base_commit_the_runner_lacks_is_fetched_not_read_as_another_tree(self):
        # The job's checkout can be older than the tip a fresh hosted run merged onto: git merge-tree cannot merge a
        # commit it lacks, and that read as "tested a tree that is not ..." (#2596: 4 of 7 fallbacks).
        head, tested, tree = self.pr()
        lagging = Path(self.temporary.name) / 'lagging'
        subprocess.run(self.git + ['clone', '-q', '-b', 'main', str(self.origin), str(lagging)], check=True,
                       capture_output=True)
        subprocess.run(self.git + ['-C', str(lagging), 'fetch', '-q', str(self.tree), 'HEAD'], check=True)
        newest = self.move_next('docs/notes.md')
        expected = lane.merged_tree(self.tree, newest, head)
        self.assertIsNotNone(expected)
        self.assertIsNone(lane.merged_tree(lagging, newest, head))
        self.assertEqual(lane.merged_tree(lagging, newest, head, fetch='main'), expected)
        found, why = lane.hosted_fast_checks(None, lagging, 'main', head, newest, env=ON,
                                             records=self.records(head, newest, expected))
        self.assertEqual(why, '')
        self.assertEqual(set(found), set(lane.HOSTED_FAST_CHECKS))

    def test_a_record_naming_a_next_the_runner_does_not_have_falls_back(self):
        head, tested, tree = self.pr()
        found, why = self.stands(head, tested, self.records(head, 'f' * 40, tree))
        self.assertIsNone(found)
        self.assertTrue(why)

    def test_a_read_error_falls_back(self):
        head, tested, _ = self.pr()

        def broken(github, h, checks):
            raise subprocess.CalledProcessError(1, ['gh', 'api'])
        found, why = lane.hosted_fast_checks(None, self.tree, 'main', head, tested, env=ON, records=broken)
        self.assertIsNone(found)
        self.assertIn('could not read the fast checks off the Mac', why)


class RunAutomergeTests(unittest.TestCase):
    SCOPE = {'tier': 'T2', 'why': ['App/x.swift']}
    FOUND = {name: {'plan': plan, 'tree': 'e' * 40, 'base': 'd' * 40, 'head': 'a' * 40}
             for name, plan in lane.HOSTED_FAST_CHECKS.items()}

    def run_it(self, **kwargs):
        calls = []

        def fast(evidence, changed=None):
            calls.append('fast')
            return 'PASS', []

        def mac_rest(evidence, changed=None):
            calls.append('mac-rest')
            return 'PASS', []
        with tempfile.TemporaryDirectory() as temporary:
            result = lane.run_automerge(self.SCOPE, Path(temporary), fast=fast, mac_rest=mac_rest, **kwargs)
        return calls, result

    def test_without_hosted_results_the_whole_fast_plan_runs(self):
        calls, (verdict, where, ran, _) = self.run_it()
        self.assertEqual(calls, ['fast'])
        self.assertEqual((verdict, ran), ('PASS', 'host tests (--plan fast): passed'))

    def test_with_hosted_results_only_the_mac_rest_runs_and_the_report_says_where_each_part_ran(self):
        calls, (verdict, where, ran, details) = self.run_it(hosted_fast=self.FOUND)
        self.assertEqual(calls, ['mac-rest'])
        self.assertEqual(verdict, 'PASS')
        self.assertIn('Mac: --plan fast-mac-rest', ran)
        self.assertIn('next at ddddddd', ran)
        self.assertTrue(any(line.startswith('GitHub-hosted check "hosted fast: portable": PASS') for line in details))

    def test_a_mac_rest_failure_fails_the_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            verdict, _, ran, _ = lane.run_automerge(self.SCOPE, Path(temporary), hosted_fast=self.FOUND,
                                                    mac_rest=lambda evidence, changed=None: ('FAIL', ['x']))
        self.assertEqual(verdict, 'FAIL')
        self.assertTrue(ran.endswith('fast-mac-rest): fail'))

    def test_the_mac_rest_plan_is_what_the_runner_asks_verify_tests_for(self):
        commands = []

        def runner(command, log, timeout):
            commands.append(command)
            return None
        with tempfile.TemporaryDirectory() as temporary:
            verdict, details = lane.run_mac_rest(Path(temporary), runner=runner)
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertIn('--plan fast-mac-rest', details[0])
        self.assertEqual(commands[0][commands[0].index('--plan') + 1], 'fast-mac-rest')


class SplitPlanTests(unittest.TestCase):
    """verify-tests.py: the three plans together run every step of --plan fast, each on the machine it needs."""

    def test_the_three_plans_cover_every_fast_step(self):
        import test_fast_portable
        covered = (set(verification.PORTABLE_STEPS) | set(verification.HOSTED_SESSIONKIT_STEPS)
                   | set(verification.MAC_REST_STEPS))
        self.assertEqual(test_fast_portable.literal_steps() - covered, set())
        # What the portable plan leaves out, the other two run.
        self.assertEqual(set(verification.PORTABLE_LEFT_OUT) - covered, set())
        self.assertIn('package', verification.MAC_REST_STEPS)  # the sound-output step never leaves the Mac
        self.assertNotIn('package', verification.HOSTED_SESSIONKIT_STEPS)

    def run_plan(self, plan, changed):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / 'node_modules').mkdir()
            run = verification.Run(Path(temporary) / 'run', plan, changed)
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    mock.patch.object(run, 'ops_steps', side_effect=lambda **kw: calls.append(('ops', kw))), \
                    mock.patch.object(run, 'package_core', side_effect=lambda core: calls.append(('package-core', core))), \
                    mock.patch.object(run, 'package_steps',
                                      side_effect=lambda expected, **kw: calls.append(('package-steps', kw))), \
                    mock.patch.object(verification, 'ROOT', Path(temporary)), \
                    mock.patch.object(verification, 'swift_tests', return_value={'T/test'}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    mock.patch.object(verification.sessionkit_pass, 'toolchain', return_value=None), \
                    mock.patch.object(verification.sessionkit_pass, 'find', return_value=None), \
                    mock.patch.object(verification, 'host_test_slot',
                                      side_effect=lambda *a, **k: calls.append(('slot', None)) or contextlib.nullcontext({})), \
                    mock.patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']), \
                    contextlib.redirect_stdout(io.StringIO()):
                run.fast()
            skipped = {step['name'] for step in run.manifest['steps'] if 'skipped' in step}
        return calls, skipped

    def test_hosted_sessionkit_builds_and_runs_the_core_tests_without_a_mac_slot(self):
        calls, skipped = self.run_plan('fast-hosted-sessionkit', None)
        self.assertEqual([name for name, _ in calls], ['package-build', 'package-core'])
        self.assertEqual(calls[1][1], {'SessionKitCoreTests/T/test'})
        self.assertEqual(skipped, {'package'})

    def test_mac_rest_for_an_app_diff_runs_only_the_sessionkit_rest(self):
        calls, skipped = self.run_plan('fast-mac-rest', ['App/SpokenMarginsApp/X.swift'])
        self.assertEqual(calls, [('slot', None), ('package-steps', {'core_elsewhere': True})])
        self.assertEqual(skipped, {'hot-file-ratchet', 'runner-tests', 'ops', 'tools', 'shipped-compat'})

    def test_mac_rest_for_a_lane_diff_also_runs_the_apple_tool_tests_and_ops_disk(self):
        calls, _ = self.run_plan('fast-mac-rest', ['scripts/phone-build'])
        by_name = dict(calls)
        self.assertEqual(by_name['runner-tests'][1:3], ['-c', verification.MAC_REST_RUNNER_LOADER])
        self.assertEqual(by_name['runner-tests'][3:], list(verification.PORTABLE_RUNNER_TESTS_LEFT_OUT))
        self.assertEqual(by_name['ops'], {'only': verification.PORTABLE_OPS_LEFT_OUT})

    def test_the_mac_rest_loader_runs_only_the_listed_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            tests = Path(temporary) / 'scripts' / 'tests'
            tests.mkdir(parents=True)
            (tests / 'test_apple.py').write_text(
                'import unittest\nclass A(unittest.TestCase):\n    def test_needs_xcode(self): pass\n')
            (tests / 'test_other.py').write_text(
                'import unittest\nclass B(unittest.TestCase):\n    def test_elsewhere(self): self.fail("ran")\n')
            done = subprocess.run([sys.executable, '-c', verification.MAC_REST_RUNNER_LOADER, 'test_apple.'],
                                  cwd=temporary, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn('Ran 1 test', done.stderr)

    def test_package_steps_with_the_core_elsewhere_runs_only_the_rest(self):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast-mac-rest')
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args, kw))), \
                    mock.patch.object(run, 'package_core', side_effect=lambda core: calls.append(('package-core',))), \
                    mock.patch.object(verification.host_audio, 'audio_output', return_value={'usable': True}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False):
                run.package_steps({'SessionKitTests/A/test'}, core_elsewhere=True)
        self.assertEqual([call[0] for call in calls], ['package-build', 'package'])
        self.assertIn('--rest', calls[1][1])
        self.assertEqual(calls[1][2]['expected'], {'SessionKitTests/A/test'})


class WorkflowTests(unittest.TestCase):
    """The hosted jobs and the lane agree on names, the switch and what is recorded."""

    @classmethod
    def setUpClass(cls):
        cls.hosted = (ROOT / '.github/workflows/hosted-portable.yml').read_text()
        cls.lane_yml = (ROOT / '.github/workflows/lane.yml').read_text()

    def test_each_required_check_is_a_job_name_that_records_its_plan(self):
        for name, plan in {**lane.HOSTED_FAST_CHECKS, **lane.HOSTED_REST_CHECK}.items():
            with self.subTest(name):
                self.assertIn(f"name: '{name}'", self.hosted)
                self.assertIn(f'::notice title={lane.HOSTED_TESTED_TITLE}::plan={plan} tree=', self.hosted)
                for part in plan.split('+'):  # Mac rest records both plans it runs (#2596)
                    self.assertIn(f'--plan {part}', self.hosted)

    def test_both_jobs_run_on_a_pr_only_from_this_repo_and_only_with_the_switch_on(self):
        guard = ("(github.event.pull_request.head.repo.full_name == github.repository && "
                 f"vars.{lane.HOSTED_FAST_SWITCH} == 'on')")
        # The pair, and the Mac-rest check (#2459), which runs on a PR only with LANE_HOSTED_MAC_REST `on` too.
        # plus the `scope` job (#2596), which has the same guard
        self.assertEqual(self.hosted.count(guard), len(lane.HOSTED_FAST_CHECKS) + len(lane.HOSTED_REST_CHECK) + 1)
        self.assertIn(f"vars.{lane.HOSTED_REST_SWITCH} == 'on')", self.hosted)
        self.assertNotIn('pull_request_target:', self.hosted)

    def test_no_workflow_runs_on_the_vps_test_runner_and_only_the_lane_open_pings_on_the_vps(self):
        # #2442: CI left the owner's VPS. linux-t1.yml is gone; the lane-open pings keep sm-vps for their shared state.
        workflows = ROOT / '.github/workflows'
        self.assertFalse((workflows / 'linux-t1.yml').exists())
        on_vps = {}
        for path in sorted(workflows.glob('*.yml')):
            text = path.read_text()
            self.assertNotIn('sm-vps-t1]', text, path.name)
            jobs = text.split('\njobs:\n', 1)[-1]
            for job, body in re.findall(r'(?ms)^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', jobs):
                if any('sm-vps' in runs_on for runs_on in re.findall(r'(?m)^    runs-on: (.*)$', body)):
                    on_vps.setdefault(path.name, []).append(job)
        self.assertEqual(on_vps, {'lane.yml': ['lane-open-lane', 'lane-open-automerge']})

    def test_the_lane_hands_the_switch_to_the_automerge_and_release_runs_and_may_read_checks(self):
        # The route job (hosted_merge_routing), the lane job (a T3 PASS merging on the hosted checks), the automerge
        # job, its automerge-mac fallback and the release job (#2459).
        for switch in (lane.HOSTED_FAST_SWITCH, lane.HOSTED_REST_SWITCH):
            self.assertEqual(self.lane_yml.count(f'{switch}: ${{{{ vars.{switch} }}}}'), 5, switch)
        self.assertIn('  checks: read\n', self.lane_yml)


if __name__ == '__main__':
    unittest.main()
