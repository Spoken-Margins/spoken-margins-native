"""#2596: the hosted Mac checks run, and the runner waits for them, only when the diff reaches a Swift input.

Before: every PR ran SessionKit core and Mac rest on a hosted Mac, and the runner required both. 22 of 62 PRs in one day
touched no Swift input and spent 23% of the Mac minutes, with a queue p90 of about 52 minutes; a skipped job would have
sent the runner to the build Mac after its 5-minute grace.
"""
import ast
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner as runner_tests
import test_test_scope as scope_tests
import test_lane_hosted_fast as fast_tests
import test_fast_portable as portable_tests

lane = runner_tests.lane
scope = scope_tests.scope
verification = portable_tests.verification
ROOT = Path(__file__).resolve().parents[2]
HEAD, MERGE = 'a' * 40, 'b' * 40


class MacChecksRequiredTests(unittest.TestCase):
    def required(self, *paths):
        return scope.mac_checks_required(paths)

    def test_an_ops_docs_or_workflow_free_diff_needs_no_mac_check(self):
        for paths in (('docs/areas.md',), ('ops/claude/sm_claude_worker.py',), ('AGENTS.md', 'docs/x.md'),
                      ('Design/brief.md',), ('scripts/sm_project_sync.py',), ('scripts/tests/test_sm_project_sync.py',),
                      ('.claude/skills/x/SKILL.md',), ('Site/index.html',)):
            with self.subTest(paths=paths):
                needed, why = self.required(*paths)
                self.assertFalse(needed)
                self.assertEqual(why, 'Mac checks not required: no Swift inputs')

    def test_a_swift_input_still_needs_them(self):
        for path in ('Packages/SessionKit/Sources/SessionKit/X.swift', 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/A.swift',
                     'project.yml', 'Package.resolved', 'TestPlans/fast.json', 'Contracts/schemas/x.json',
                     'Elsewhere/Thing.swift', 'SpokenMarginsNative.xcodeproj/project.pbxproj'):
            with self.subTest(path=path):
                self.assertTrue(self.required(path)[0])

    def test_a_workflow_or_script_that_drives_the_mac_jobs_needs_them(self):
        for path in ('.github/workflows/hosted-portable.yml', '.github/workflows/lane.yml', '.github/actions/x/action.yml',
                     'scripts/verify-tests.py', 'scripts/lane-runner.py', 'scripts/test-scope.py',
                     'scripts/sessionkit_pass.py', 'scripts/tests/test_lane_runner.py', 'scripts/xcodebuild-lane'):
            with self.subTest(path=path):
                self.assertTrue(self.required(path)[0])

    def test_one_swift_path_among_ops_paths_needs_them(self):
        needed, why = self.required('docs/a.md', 'ops/b.py', 'Packages/SessionKit/Sources/SessionKit/X.swift')
        self.assertTrue(needed)
        self.assertIn('X.swift', why)

    def test_nothing_known_or_an_unlisted_path_needs_them(self):
        self.assertTrue(self.required()[0])
        self.assertTrue(self.required('SomeNewTopLevelFolder/file.dat')[0])

    def test_everything_the_sessionkit_tests_read_by_path_needs_them(self):
        import sessionkit_pass
        for read in sessionkit_pass.READS:
            path = read + 'x' if read.endswith('/') else read
            with self.subTest(read=read):
                self.assertTrue(self.required(path)[0])

    def test_the_cli_prints_what_the_workflow_writes_to_its_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            listing = Path(temporary) / 'files.txt'
            for lines, expected in (('docs/a.md\nops/b.py\n', 'mac=false'), ('docs/a.md\nproject.yml\n', 'mac=true')):
                listing.write_text(lines)
                out = subprocess.run([sys.executable, str(ROOT / 'scripts/test-scope.py'), '--mac-required',
                                      str(listing)], capture_output=True, text=True, check=True).stdout.splitlines()
                self.assertEqual(out[0], expected)
                self.assertTrue(out[1].startswith('reason='))
            missing = subprocess.run([sys.executable, str(ROOT / 'scripts/test-scope.py'), '--mac-required',
                                      str(Path(temporary) / 'absent.txt')], capture_output=True, text=True).stdout
            self.assertTrue(missing.startswith('mac=true'))


def mac_only_reach():
    """{scripts/ path: what reaches it} for the code only the Mac jobs run (audit on 07cedaa).

    The seeds are the runner tests PORTABLE_RUNNER_TESTS_LEFT_OUT names, the ops folders the portable plan leaves out
    or that skip on Linux, and the scripts the Mac-only steps run. A seed reaches every scripts/ file it names (it
    loads or runs it); from there, Python imports are followed all the way down. Names inside the files a seed runs
    are not followed: lane-runner.py and verify-tests.py name nearly every script, and the tests stub what they run.
    """
    files = [p.relative_to(ROOT) for p in (ROOT / 'scripts').rglob('*')
             if p.is_file() and '__pycache__' not in p.parts and p.suffix != '.md']
    modules = {p.stem: p for p in files if p.suffix == '.py'}
    seeds = {Path('scripts/tests') / (prefix.split('.')[0] + '.py') for prefix in verification.PORTABLE_RUNNER_TESTS_LEFT_OUT}
    for folder in (*verification.PORTABLE_OPS_LEFT_OUT, *scope.MAC_ONLY_OPS):
        seeds |= {p.relative_to(ROOT) for p in (ROOT / folder).rglob('*')
                  if p.is_file() and '__pycache__' not in p.parts and p.suffix != '.md'}
    commands = ' '.join([*verification.PACKAGE_RUNNER, verification.SHIPPED_COMPAT_COMMAND])
    seeds |= {Path(name) for name in re.findall(r'scripts/[\w.-]+', commands)}

    def imports(path, text):
        try:
            tree = ast.parse(text)
        except (SyntaxError, ValueError):
            return set()
        names = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                names |= {alias.name.split('.')[0] for alias in node.names}
            elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
                names.add(node.module.split('.')[0])
        return {modules[name] for name in names if name in modules}

    def named(text):
        return {p for p in files if re.search(r'(?<![\w.-])' + re.escape(p.name) + r'(?![\w-])', text)}

    reached, todo = {}, [(seed, 'a Mac-only seed') for seed in sorted(seeds)]
    while todo:
        path, by = todo.pop()
        if path in reached:
            continue
        reached[path] = by
        try:
            text = (ROOT / path).read_text(errors='ignore')
        except OSError:
            continue
        nxt = imports(path, text) | (named(text) if path in seeds else set())
        todo += [(p, str(path)) for p in sorted(nxt) if p not in reached]
    return {str(p): by for p, by in reached.items() if str(p).startswith('scripts/')}


class AppBuildRecordTests(unittest.TestCase):
    """#3539: the app build writes no `lane-hosted-tested` notice, so green on the head is what stands."""
    NAME = next(iter(lane.HOSTED_APP_CHECK))

    def github(self, *more, **run):
        """A fake GitHub: one check run (suite 7, from a pull_request workflow run) plus <more> runs, each with its
        own suite and an `event` saying what started the workflow run that owns it."""
        fake = mock.Mock(repo='o/r')
        runs = [{'id': 1, 'status': 'completed', 'conclusion': 'success', 'started_at': 't', 'html_url': 'u',
                 'app': {'slug': 'github-actions'}, 'check_suite': {'id': 7}, 'event': 'pull_request', **run}, *more]

        def api(path):
            if f'/actions/workflows/{lane.HOSTED_APP_WORKFLOW}/runs?' in path:
                event = re.search(r'event=([a-z_]+)', path).group(1)
                return json.dumps({'workflow_runs': [{'check_suite_id': r['check_suite']['id']} for r in runs
                                                     if r['event'] == event]})
            return json.dumps({'check_runs': runs})
        fake.api = mock.Mock(side_effect=api)
        return fake

    def test_green_on_the_head_stands_with_no_notice_and_no_merge_tree(self):
        github = self.github()
        found, why = lane.hosted_fast_records(github, HEAD, checks=lane.HOSTED_APP_CHECK)
        self.assertEqual((set(found), why), ({self.NAME}, ''))
        self.assertFalse([c for c in github.api.call_args_list if 'annotations' in c.args[0]],
                         'it must not read annotations')
        with mock.patch.object(lane, 'merged_tree') as merged:
            stood, why = lane._fast_checks_stand(github, Path('.'), 'main', HEAD, MERGE,
                                                 lane.hosted_fast_records, lane.HOSTED_APP_CHECK)
        self.assertEqual((set(stood), why), ({self.NAME}, ''))
        merged.assert_not_called()

    def test_a_newer_hand_started_run_does_not_replace_the_prs_own_build(self):
        # Audit on 7812c37: hosted-app-macos.yml gives workflow_dispatch runs the same job name, and one started on
        # the PR's branch sits on the same head. A red one (missing runtime, misspelled test) must not FAIL the PR,
        # and a green one with device_build off must not stand for the PR's build.
        def dispatched(**run):
            return {'id': 2, 'status': 'completed', 'conclusion': 'failure', 'started_at': 'u', 'html_url': 'd',
                    'app': {'slug': 'github-actions'}, 'check_suite': {'id': 8}, 'event': 'workflow_dispatch', **run}
        found, why = lane.hosted_fast_records(self.github(dispatched()), HEAD, checks=lane.HOSTED_APP_CHECK)
        self.assertEqual((found, why), ({self.NAME: {'head': HEAD, 'url': 'u'}}, ''))
        found, why = lane.hosted_fast_records(self.github(dispatched(conclusion='success'), conclusion='failure'),
                                              HEAD, checks=lane.HOSTED_APP_CHECK)
        self.assertIsNone(found)
        self.assertIn('ended failure', why)

    def test_only_a_hand_started_run_on_the_head_is_no_app_build(self):
        found, why = lane.hosted_fast_records(self.github(event='workflow_dispatch'), HEAD, checks=lane.HOSTED_APP_CHECK)
        self.assertIsNone(found)
        self.assertIn(f'no "{self.NAME}" check ran', why)

    def test_red_cancelled_and_unfinished_do_not_stand(self):
        for run, words in (({'conclusion': 'failure'}, 'ended failure'), ({'conclusion': 'cancelled'}, 'ended cancelled'),
                           ({'conclusion': 'skipped'}, 'ended skipped'),
                           ({'status': 'in_progress', 'conclusion': None}, lane.NOT_FINISHED)):
            with self.subTest(run=run):
                found, why = lane.hosted_fast_records(self.github(**run), HEAD, checks=lane.HOSTED_APP_CHECK)
                self.assertIsNone(found)
                self.assertIn(words, why)
        self.assertTrue(lane.HOSTED_FAILED.search(f'"{self.NAME}" ended failure on abc1234'))

    def test_the_report_says_the_app_build_passed_beside_the_merge_records(self):
        tree = 'c' * 40
        found = {'hosted fast: portable': {'plan': 'fast-portable', 'tree': tree, 'base': MERGE, 'head': HEAD, 'url': 'p'},
                 'hosted fast: Mac rest': {'plan': 'x', 'tree': tree, 'base': MERGE, 'head': HEAD, 'url': 'r'},
                 self.NAME: {'head': HEAD, 'url': 'a'}}
        ran = lane.hosted_fast_ran(found)
        self.assertIn('none on the Mac', ran)
        self.assertIn('the app build passed on this head', ran)
        lines = lane.hosted_fast_lines(found)
        self.assertEqual(len(lines), 3)
        self.assertIn(f'check "{self.NAME}": PASS on this head. a', lines[2])


class MacOnlyReachTests(unittest.TestCase):
    def test_every_script_only_the_mac_jobs_exercise_needs_the_mac_checks(self):
        missed = {path: by for path, by in mac_only_reach().items() if not scope.mac_checks_required([path])[0]}
        self.assertEqual(missed, {}, 'add these to test-scope.py MAC_SCRIPT_FILES: path -> what reaches it')

    def test_the_helpers_the_audit_named_need_them(self):
        for path in ('scripts/sm_paths.py', 'scripts/sm_build_cache.py', 'scripts/comment_trust.py'):
            with self.subTest(path=path):
                self.assertTrue(scope.mac_checks_required([path])[0])

    def test_the_walk_finds_the_helpers_it_is_meant_to(self):
        # A walk that found nothing would pass the test above vacuously.
        reach = mac_only_reach()
        for path in ('scripts/phone-build', 'scripts/sm_paths.py', 'scripts/sm_build_cache.py', 'scripts/lane-runner.py'):
            self.assertIn(path, reach)


class HostedCheckSetTests(unittest.TestCase):
    FULL = lane.HOSTED_MERGED_CHECKS

    def check_set(self, paths, policy=scope):
        with mock.patch.object(lane, 'base_policy', return_value=policy), \
                mock.patch.object(lane, 'committed_changes', return_value=(paths, {})):
            return lane.hosted_check_set(Path('.'), 'main')

    def test_an_ops_only_diff_requires_the_portable_check_alone_and_says_why(self):
        checks, why = self.check_set(['ops/claude/x.py', 'docs/y.md'])
        self.assertEqual(checks, lane.HOSTED_PORTABLE_CHECK)
        self.assertEqual(why, 'Mac checks not required: no Swift inputs')

    def test_a_swift_diff_still_requires_all_three(self):
        self.assertEqual(self.check_set(['Packages/SessionKit/Sources/SessionKit/X.swift']), (self.FULL, None))

    def test_a_diff_under_app_also_waits_for_the_app_build(self):
        with_app = {**self.FULL, **lane.HOSTED_APP_CHECK}
        self.assertEqual(self.check_set(['App/SpokenMarginsApp/Sources/SpokenMarginsApp/X.swift']), (with_app, None))
        self.assertEqual(self.check_set(['App/SpokenMarginsAppTests/XTests.swift', 'docs/y.md']), (with_app, None))

    def test_a_diff_outside_app_does_not_wait_for_the_app_build(self):
        self.assertEqual(self.check_set(['project.yml'])[0], self.FULL)
        self.assertEqual(self.check_set(['docs/App/y.md'])[0], lane.HOSTED_PORTABLE_CHECK)

    def test_the_app_build_is_still_required_when_the_mac_checks_are_not(self):
        policy = mock.Mock(mac_checks_required=lambda paths: (False, 'not needed'), app_build_required=scope.app_build_required)
        checks, why = self.check_set(['App/x.swift'], policy=policy)
        self.assertEqual(checks, {**lane.HOSTED_PORTABLE_CHECK, **lane.HOSTED_APP_CHECK})
        self.assertEqual(why, 'not needed')

    def test_a_base_without_the_app_build_rule_keeps_the_checks_it_had(self):
        policy = mock.Mock(spec=['mac_checks_required'], mac_checks_required=scope.mac_checks_required)
        self.assertEqual(self.check_set(['App/x.swift'], policy=policy), (self.FULL, None))

    def test_the_app_build_check_is_the_one_the_workflow_names(self):
        workflow = (ROOT / '.github/workflows/hosted-app-macos.yml').read_text()
        for name in lane.HOSTED_APP_CHECK:
            self.assertIn(f'name: {name}\n', workflow)
        self.assertTrue((ROOT / '.github/workflows' / lane.HOSTED_APP_WORKFLOW).samefile(
            ROOT / '.github/workflows/hosted-app-macos.yml'))
        self.assertIn("      - 'App/**'\n", workflow)

    def test_an_app_diff_on_the_build_mac_fallback_is_not_merged_with_no_compile(self):
        name = next(iter(lane.HOSTED_APP_CHECK))
        for why in (f'"{name}" ended cancelled on abc1234', f'no "{name}" check ran on abc1234',
                    f'"{name}" {lane.NOT_FINISHED} on abc1234 (waited 60m)'):
            with self.subTest(why=why):
                self.assertEqual(lane.hosted_checks_missing(why)[0], 'INCONCLUSIVE')
        self.assertEqual(lane.hosted_checks_missing('"hosted fast: portable" ended cancelled on abc1234')[0], lane.NEEDS_MAC)
        self.assertEqual(lane.hosted_checks_missing(f'"{name}" ended failure on abc1234')[0], 'FAIL')

    def test_with_no_app_build_on_the_head_the_advice_is_to_start_one_not_re_run_it(self):
        name = next(iter(lane.HOSTED_APP_CHECK))
        note = lane.hosted_checks_missing(f'no "{name}" check ran on abc1234')[3][0]
        self.assertNotIn('Re-run', note)
        self.assertIn('close and reopen the PR', note)
        self.assertIn('Re-run the app build', lane.hosted_checks_missing(f'"{name}" ended cancelled on abc1234')[3][0])

    def test_a_workflow_only_diff_to_the_mac_jobs_own_workflow_requires_all_three(self):
        self.assertEqual(self.check_set(['.github/workflows/hosted-portable.yml']), (self.FULL, None))

    def test_a_base_without_the_rule_or_a_failure_requires_all_three(self):
        self.assertEqual(self.check_set(['docs/y.md'], policy=None), (self.FULL, None))
        self.assertEqual(self.check_set(['docs/y.md'], policy=object()), (self.FULL, None))
        with mock.patch.object(lane, 'base_policy', side_effect=RuntimeError('x')):
            self.assertEqual(lane.hosted_check_set(Path('.'), 'main'), (self.FULL, None))

    def test_the_portable_check_is_the_one_the_workflow_names(self):
        self.assertEqual(lane.HOSTED_PORTABLE_CHECK, {'hosted fast: portable': 'fast-portable'})
        self.assertEqual(set(lane.HOSTED_PORTABLE_CHECK), set(lane.HOSTED_FAST_CHECKS) - {'hosted fast: SessionKit core'})

    def test_a_skipped_mac_check_is_never_a_pass_when_the_runner_does_ask_for_it(self):
        # The runner leaves the Mac checks out only by the diff's own paths. If it asks for them, "skipped" fails to stand.
        github = fast_tests.passing(HEAD, checks=lane.HOSTED_FAST_CHECKS)
        github.runs['hosted fast: SessionKit core'][0]['conclusion'] = 'skipped'
        found, why = lane.hosted_fast_records(github, HEAD, checks=lane.HOSTED_FAST_CHECKS)
        self.assertIsNone(found)

    def test_the_portable_check_alone_stands_and_the_report_says_the_mac_ones_were_not_required(self):
        github = fast_tests.passing(HEAD, checks=lane.HOSTED_PORTABLE_CHECK)
        found, why = lane.hosted_fast_records(github, HEAD, checks=lane.HOSTED_PORTABLE_CHECK)
        self.assertEqual(set(found), set(lane.HOSTED_PORTABLE_CHECK))
        ran = lane.hosted_fast_ran(found)
        self.assertIn('not required: no Swift inputs', ran)
        self.assertIn('none on the Mac', ran)
        self.assertNotIn('Mac: --plan fast-mac-rest', ran)


class WorkflowScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import yaml
        cls.jobs = yaml.safe_load((ROOT / '.github/workflows/hosted-portable.yml').read_text())['jobs']

    def test_there_is_a_cheap_linux_scope_job(self):
        scope_job = self.jobs['scope']
        self.assertEqual(scope_job['runs-on'], 'ubuntu-latest')
        self.assertEqual(scope_job['name'], 'hosted fast: scope')
        self.assertIn('mac', scope_job['outputs'])

    def test_both_mac_jobs_wait_for_it_and_skip_when_it_says_no_swift_inputs(self):
        for name in ('sessionkit', 'mac-rest'):
            with self.subTest(job=name):
                job = self.jobs[name]
                self.assertEqual(job['needs'], 'scope')
                self.assertIn("needs.scope.outputs.mac != 'false'", job['if'])
                # Without a status function GitHub adds success(), so a failed scope job would skip the Mac jobs
                # (audit on 07cedaa). They run unless the scope job was cancelled, skipped or said mac=false.
                self.assertTrue(job['if'].startswith("!cancelled() && needs.scope.result != 'skipped' && "), job['if'])
                self.assertIn('xcode', ' '.join(job['runs-on']).lower() + str(job['runs-on']).lower())

    def test_the_portable_job_does_not_wait_for_the_scope_job(self):
        self.assertNotIn('needs', self.jobs['portable'])

    def test_the_scope_job_fails_safe(self):
        text = (ROOT / '.github/workflows/hosted-portable.yml').read_text()
        self.assertIn('echo "mac=true" >> "$GITHUB_OUTPUT"', text)
        self.assertIn('--mac-required', text)


class OneMacJobTests(unittest.TestCase):
    """#2596: SessionKit core and Mac rest share one hosted Mac, so a Swift diff pays for one machine start, not two."""

    @classmethod
    def setUpClass(cls):
        import yaml
        cls.text = (ROOT / '.github/workflows/hosted-portable.yml').read_text()
        cls.jobs = yaml.safe_load(cls.text)['jobs']

    def steps(self, job):
        return [step.get('run', '') for step in self.jobs[job]['steps']]

    def test_the_mac_rest_job_runs_the_core_tests_then_the_rest_on_the_same_machine(self):
        runs = self.steps('mac-rest')
        core = next(i for i, run in enumerate(runs) if '--plan fast-hosted-sessionkit' in run)
        rest = next(i for i, run in enumerate(runs) if '--plan fast-mac-rest' in run)
        blackhole = next(i for i, run in enumerate(runs) if 'blackhole-2ch' in run)
        self.assertLess(core, blackhole)  # the core tests ran before BlackHole in the old job too
        self.assertLess(blackhole, rest)  # the audio tests still get the virtual output

    def test_the_check_name_and_the_recorded_plan_stay_what_the_runner_expects(self):
        self.assertEqual(self.jobs['mac-rest']['name'], 'hosted fast: Mac rest')
        self.assertEqual(lane.HOSTED_REST_CHECK, {'hosted fast: Mac rest': 'fast-hosted-sessionkit+fast-mac-rest'})
        self.assertIn('plan=fast-hosted-sessionkit+fast-mac-rest tree=', self.text)
        self.assertEqual(self.text.count('plan=fast-hosted-sessionkit tree='), 1)  # only the sessionkit job records it

    def test_the_separate_sessionkit_job_runs_only_with_the_mac_rest_switch_off(self):
        self.assertIn("vars.LANE_HOSTED_MAC_REST != 'on'", self.jobs['sessionkit']['if'])
        self.assertNotIn("!= 'on'", self.jobs['mac-rest']['if'])

    def test_the_runner_requires_two_checks_for_a_swift_diff_and_the_job_that_writes_each(self):
        self.assertEqual(set(lane.HOSTED_MERGED_CHECKS), {'hosted fast: portable', 'hosted fast: Mac rest'})
        self.assertNotIn('hosted fast: SessionKit core', lane.HOSTED_MERGED_CHECKS)
        for name in lane.HOSTED_MERGED_CHECKS:
            self.assertIn(f"name: '{name}'", self.text)

    def records(self, rest_plan):
        """hosted_fast_records over the merged set, where the portable check passed and Mac rest recorded <rest_plan>."""
        names = list(lane.HOSTED_MERGED_CHECKS)

        class Checks(fast_tests.FakeChecks):
            def api(self, path):
                if '/annotations' in path:
                    return super().api(path)
                name = next(name for name in names if 'check_name=' + lane.urllib.parse.quote(name, safe='') + '&' in path)
                return fast_tests.json.dumps({'check_runs': self.runs.get(name, [])})

        plans = {**lane.HOSTED_MERGED_CHECKS, 'hosted fast: Mac rest': rest_plan}
        fake = fast_tests.passing(HEAD, checks=plans)
        return lane.hosted_fast_records(Checks(fake.runs, fake.annotations), HEAD, lane.HOSTED_MERGED_CHECKS)

    def test_a_mac_rest_record_from_the_old_job_does_not_stand_for_the_core_tests(self):
        # The audit of 47facb5: the old `mac-rest` job ran no SessionKitCoreTests but recorded plan=fast-mac-rest. A PR
        # whose core check failed or never finished would merge on that record once only two checks are required.
        found, why = self.records('fast-mac-rest')
        self.assertIsNone(found)
        self.assertIn('"hosted fast: Mac rest"', why)
        self.assertIn('did not record', why)

    def test_the_plan_the_merged_job_records_is_the_one_the_runner_requires(self):
        recorded = [plan for run in self.steps('mac-rest') for plan in re.findall(r'plan=(\S+) tree=', run)]
        self.assertEqual(recorded, [lane.HOSTED_MERGED_CHECKS['hosted fast: Mac rest']])
        self.assertNotEqual(recorded, ['fast-mac-rest'])
        found, why = self.records(recorded[0])
        self.assertEqual(set(found), set(lane.HOSTED_MERGED_CHECKS), why)
        # each plan the name lists is one the job runs
        for plan in recorded[0].split('+'):
            self.assertTrue(any(f'--plan {plan}' in run for run in self.steps('mac-rest')), plan)

    def test_the_job_has_room_for_both_plans(self):
        self.assertGreaterEqual(self.jobs['mac-rest']['timeout-minutes'],
                                self.jobs['sessionkit']['timeout-minutes'] + 20)


if __name__ == '__main__':
    unittest.main()
