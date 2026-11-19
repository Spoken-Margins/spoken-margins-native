"""#2596: the hosted Mac checks run, and the runner waits for them, only when the diff reaches a Swift input.

Before: every PR ran SessionKit core and Mac rest on a hosted Mac, and the runner required both. 22 of 62 PRs in one day
touched no Swift input and spent 23% of the Mac minutes, with a queue p90 of about 52 minutes; a skipped job would have
sent the runner to the build Mac after its 5-minute grace.
"""
import ast
import io
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


class MacOnlyAppReadsTests(unittest.TestCase):
    """#3538: a test that runs only on a Mac may read an App/ path only if MAC_APP_READS names it. A diff elsewhere under
    App/ can then be checked off the Mac, so a new read that needs no Apple framework goes to SessionKitCoreTests."""
    TESTS = ROOT / 'Packages/SessionKit/Tests'
    HELPER = TESTS / 'TestInputs/TestInputs.swift'
    # What keeps a whole core test file off Linux, or part of it. Finding one treats the file's reads as Mac reads.
    COMPILED_OUT = re.compile(r'^\s*#(?:if|elseif)\b.*\b(?:canImport|os)\(', re.M)

    def app_inputs(self):
        return {case: path for case, path in re.findall(r'case (\w+) = "([^"]+)"', self.HELPER.read_text())
                if path.startswith('App/')}

    def mac_only_files(self):
        """Every test file in a target other than SessionKitCoreTests, so a new Mac-only target is covered, and every
        core test file with a part Linux may not compile."""
        for path in sorted(self.TESTS.rglob('*.swift')):
            if '.build' in path.parts or path == self.HELPER:
                continue
            if self.TESTS / 'SessionKitCoreTests' not in path.parents or self.COMPILED_OUT.search(path.read_text()):
                yield path

    def reads(self, text):
        inputs = self.app_inputs()
        return {inputs[case] for case in re.findall(r'\.(\w+)\b', text) if case in inputs}

    def listed(self, read):
        return any((read + '/').startswith(path) for path in scope.MAC_APP_READS)

    def test_mac_only_tests_read_only_the_app_paths_on_the_list(self):
        unlisted = {}
        for path in self.mac_only_files():
            found = sorted(read for read in self.reads(path.read_text()) if not self.listed(read))
            if found:
                unlisted[str(path.relative_to(self.TESTS))] = found
        self.assertEqual(unlisted, {}, 'these tests run only on a Mac and read App/ paths MAC_APP_READS does not name. If '
                                       'the read needs no Apple framework, move it to SessionKitCoreTests; if it does, '
                                       'add the path and say why')

    def test_every_listed_path_is_still_read_on_the_mac_and_is_a_pass_input(self):
        import sessionkit_pass
        read = set()
        for path in self.mac_only_files():
            read |= self.reads(path.read_text())
        for listed in scope.MAC_APP_READS:
            with self.subTest(listed=listed):
                self.assertIn(listed.rstrip('/'), read, 'nothing on the Mac reads this any more: take it off the list')
                self.assertTrue(listed.startswith(sessionkit_pass.READS))

    def test_the_guard_sees_a_mac_only_read_and_a_core_file_linux_leaves_out(self):
        self.assertEqual(self.reads('let a = try TestInputs.text(.appSources, "x.swift")'),
                         {'App/SpokenMarginsApp/Sources/SpokenMarginsApp'})
        self.assertFalse(self.listed('App/SpokenMarginsApp/Sources/SpokenMarginsApp'))
        self.assertTrue(self.listed('App/SpokenMarginsApp/Resources/Kitten'))
        names = {path.name for path in self.mac_only_files()}
        self.assertIn('KittenRendererTests.swift', names)
        self.assertIn('VoiceCatalogCoordinatorTests.swift', names)
        self.assertNotIn('HiddenSendersCallSiteGuardTests.swift', names)


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
        for path in ('Packages/SessionKit/Sources/SessionKit/X.swift', 'App/TestFixtures/a.spokenmargins',
                     'project.yml', 'Package.resolved', 'TestPlans/fast.json', 'Contracts/schemas/x.json',
                     'Elsewhere/Thing.swift', 'SpokenMarginsNative.xcodeproj/project.pbxproj'):
            with self.subTest(path=path):
                self.assertTrue(self.required(path)[0])

    def test_an_app_only_diff_needs_no_mac_check_unless_a_mac_only_test_reads_a_path(self):
        # #3540: the Linux portable job runs the core tests that read App/ (and no app build is waited for, #4572).
        for paths in (('App/SpokenMarginsApp/Sources/SpokenMarginsApp/A.swift',),
                      ('App/SpokenMarginsAppTests/XTests.swift', 'docs/y.md'),
                      ('App/SpokenMarginsApp/Info.plist', 'App/SpokenMarginsApp/Resources/Assets.xcassets/x.json'),
                      ('App/SharedSources/B.swift', 'App/SpokenMarginsWatch/C.swift', 'App/Foo.xcodeproj'),
                      ('App/SpokenMarginsApp/Resources/Kitten2/x.onnx',), ('App/SpokenMarginsApp/Resources/Kitt/x',),
                      ('App/TestFixtures2/a.json',)):
            with self.subTest(paths=paths):
                self.assertEqual(self.required(*paths), (False, 'Mac checks not required: no Swift inputs'))
        for path in ('App/TestFixtures/a.spokenmargins', 'App/SpokenMarginsApp/Resources/Kitten/model.onnx',
                     'App/SpokenMarginsApp/Resources/Supertonic/asset-manifest.json',
                     'App/SpokenMarginsApp/Resources/VoiceCatalog/catalog.json'):
            with self.subTest(path=path):
                self.assertTrue(self.required('App/SpokenMarginsApp/Sources/SpokenMarginsApp/A.swift', path)[0])

    def test_app_lookalikes_outside_the_folder_are_not_exempt(self):
        # The exemption is the folder prefix alone: a Swift file or an unlisted path elsewhere still needs the Mac.
        for path in ('app/A.swift', 'Apps/A.swift', 'Web/ios/App/AppDelegate.swift', 'docs/App/A.swift', 'App', 'A.swift'):
            with self.subTest(path=path):
                self.assertTrue(self.required(path)[0])

    def test_a_workflow_or_script_that_drives_the_mac_jobs_needs_them(self):
        for path in ('.github/workflows/hosted-portable.yml', '.github/workflows/lane.yml', '.github/actions/x/action.yml',
                     'scripts/verify-tests.py', 'scripts/lane-runner.py', 'scripts/test-scope.py',
                     'scripts/sessionkit_pass.py', 'scripts/tests/test_lane_runner.py', 'scripts/xcodebuild-lane'):
            with self.subTest(path=path):
                self.assertTrue(self.required(path)[0])

    def test_a_workflow_with_only_linux_jobs_needs_no_mac(self):
        # #4724 held a hosted Mac for ~30 minutes for a workflow whose one job runs on ubuntu-latest.
        for path in ('.github/workflows/merge-policy.yml', '.github/workflows/merge-queue-dequeued.yml',
                     '.github/workflows/signoff-check.yml'):
            with self.subTest(path=path):
                self.assertEqual(self.required(path), (False, 'Mac checks not required: no Swift inputs'))

    def test_every_workflow_with_a_job_off_ubuntu_is_a_mac_workflow(self):
        # Any runner but ubuntu-latest (xcode-27, self-hosted, an expression) counts as a Mac, so a new Mac workflow,
        # or a Linux one that gains a Mac job, fails here until it is listed in MAC_WORKFLOWS.
        import re
        off_ubuntu = set()
        for path in sorted((ROOT / '.github/workflows').glob('*.yml')):
            runners = re.findall(r'(?m)^\s+runs-on:\s*(.+?)\s*$', path.read_text())
            if any(runner != 'ubuntu-latest' for runner in runners):
                off_ubuntu.add(f'.github/workflows/{path.name}')
        self.assertEqual(off_ubuntu, set(scope.MAC_WORKFLOWS))

    def test_one_swift_path_among_ops_paths_needs_them(self):
        needed, why = self.required('docs/a.md', 'ops/b.py', 'Packages/SessionKit/Sources/SessionKit/X.swift')
        self.assertTrue(needed)
        self.assertIn('X.swift', why)

    def test_nothing_known_or_an_unlisted_path_needs_them(self):
        self.assertTrue(self.required()[0])
        self.assertTrue(self.required('SomeNewTopLevelFolder/file.dat')[0])

    def test_everything_the_sessionkit_tests_read_by_path_needs_them_but_the_app_reads_a_mac_does_not(self):
        # sessionkit_pass.READS stays whole, since the pass key covers the core tests too (#3540); only App/ reads leave
        # the Mac checks, and only the ones no Mac-only test reads (MAC_APP_READS, kept honest by the guard above).
        import sessionkit_pass
        for read in sessionkit_pass.READS:
            path = read + 'x' if read.endswith('/') else read
            with self.subTest(read=read):
                self.assertEqual(self.required(path)[0], not read.startswith('App/') or read.startswith(scope.MAC_APP_READS))

    def test_a_web_diff_needs_no_mac_check(self):
        # #3389's own paths, and the rest of what lives in the folder.
        for paths in (('Web/e2e/playwright.config.ts', 'Web/e2e/silence/silence-script.js', 'Web/vite.config.ts'),
                      ('Web/src/app/screens/NowPlaying.tsx',), ('Web/package.json', 'Web/package-lock.json'),
                      ('Web/android/app/build.gradle',), ('Web/README.md',), ('Web/public/icon.png',),
                      ('Web/src/a.ts', 'docs/a.md', 'scripts/sm_project_sync.py'), ('Web/App.Swift/index.ts',)):
            with self.subTest(paths=paths):
                self.assertEqual(self.required(*paths), (False, 'Mac checks not required: no Swift inputs'))

    def test_a_swift_input_or_a_lookalike_of_web_still_needs_them(self):
        for paths in (('Web/ios/App/AppDelegate.swift',), ('Web/a.swift',), ('Web/ios/App.xcodeproj',),
                      ('Web/src/a.ts', 'Web/ios/App/AppDelegate.swift'), ('Web/src/a.ts', 'project.yml'),
                      ('Web/src/a.ts', 'Packages/SessionKit/Sources/SessionKit/A.tsx'),
                      ('Web/src/a.ts', 'Contracts/fixtures/web-packets/a.spokenmargins'),
                      ('web/src/a.ts',), ('WEB/src/a.ts',), ('Web',), ('Webby/a.ts',), ('WebKit/a.ts',), (' Web/a.ts',)):
            with self.subTest(paths=paths):
                self.assertTrue(self.required(*paths)[0])

    def test_no_mac_test_reads_web_by_path(self):
        # Why Web/ can leave the Mac checks. The Swift tests may name it in a comment, as WebPacketImportTests does.
        import sessionkit_pass
        self.assertEqual([read for read in sessionkit_pass.READS if read.lower().startswith('web')], [])
        code = re.compile(r'"Web["/]')
        found = [str(path.relative_to(ROOT)) for folder in ('Packages/SessionKit/Tests', 'App/SpokenMarginsAppTests')
                 for path in (ROOT / folder).rglob('*.swift')
                 if any(code.search(line.partition('//')[0]) for line in path.read_text(errors='ignore').splitlines())]
        self.assertEqual(found, [])

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

    def test_a_diff_under_app_merges_on_the_portable_check_with_no_app_build(self):
        # #3540: the portable job (core tests on Linux) stands in for the Mac checks. Owner, 2026-11-18: no per-PR app
        # build either; before, an App/ diff also waited for "app build (T2, tests only when asked)" (#3539).
        for paths in (['App/SpokenMarginsApp/Sources/SpokenMarginsApp/X.swift'],
                      ['App/SpokenMarginsAppTests/XTests.swift', 'docs/y.md']):
            with self.subTest(paths=paths):
                self.assertEqual(self.check_set(paths),
                                 (lane.HOSTED_PORTABLE_CHECK, 'Mac checks not required: no Swift inputs'))
        self.assertFalse(hasattr(scope, 'app_build_required'))
        self.assertFalse(hasattr(lane, 'HOSTED_APP_CHECK'))

    def test_a_diff_under_app_that_a_mac_only_test_reads_waits_for_the_mac_checks_only(self):
        self.assertEqual(self.check_set(['App/SpokenMarginsApp/Resources/Kitten/x.bin', 'App/A.swift']), (self.FULL, None))
        self.assertEqual(self.check_set(['App/TestFixtures/a.spokenmargins']), (self.FULL, None))

    def test_an_older_base_that_still_names_the_app_build_rule_adds_nothing(self):
        # A PR whose base still has test-scope.py's app_build_required (before #4572) must not bring the wait back.
        policy = mock.Mock(mac_checks_required=lambda paths: (False, 'not needed'), app_build_required=lambda paths: True)
        self.assertEqual(self.check_set(['App/x.swift'], policy=policy), (lane.HOSTED_PORTABLE_CHECK, 'not needed'))

    def test_a_diff_outside_app_keeps_its_checks(self):
        self.assertEqual(self.check_set(['project.yml'])[0], self.FULL)
        self.assertEqual(self.check_set(['docs/App/y.md'])[0], lane.HOSTED_PORTABLE_CHECK)

    def test_a_base_without_the_app_build_rule_keeps_the_checks_it_had(self):
        policy = mock.Mock(spec=['mac_checks_required'], mac_checks_required=scope.mac_checks_required)
        self.assertEqual(self.check_set(['Packages/SessionKit/x.swift'], policy=policy), (self.FULL, None))

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


class HostedWebCheckTests(unittest.TestCase):
    """#3535: a diff that starts hosted web's Playwright job merges only once that job passed on its head."""

    class Checks:
        repo = 'o/r'

        def __init__(self, *polls):  # each poll: the check runs GitHub answers with; the last one repeats
            self.polls, self.calls = list(polls), []

        def api(self, path):
            self.calls.append(path)
            polls = self.polls.pop(0) if len(self.polls) > 1 else self.polls[0]
            if isinstance(polls, Exception):
                raise polls
            return json.dumps({'check_runs': polls})

    @staticmethod
    def check_run(conclusion='success', status='completed', **changes):
        return {'id': 1, 'status': status, 'conclusion': conclusion, 'app': {'slug': 'github-actions'},
                'started_at': '2026-11-06T10:00:00Z', 'html_url': 'https://example.test/web', **changes}

    def check(self, github, paths=('Web/src/a.ts',), policy=scope, wait=0, alive=lambda: None, **kwargs):
        now = {'t': 0.0}

        def sleep(seconds):
            now['t'] += seconds
        self.slept = now
        lane.STEP_RUNS.clear()
        self.addCleanup(lane.STEP_RUNS.clear)
        with mock.patch.object(lane, 'base_policy', return_value=policy), \
                mock.patch.object(lane, 'committed_changes', return_value=(list(paths), {})):
            return lane.hosted_web_check(github, Path('.'), 'main', HEAD, alive=alive, env={}, wait=wait,
                                         clock=lambda: now['t'], sleep=sleep, out=io.StringIO(), **kwargs)

    def test_a_diff_that_starts_no_web_job_asks_github_nothing(self):
        for paths in (('docs/a.md',), ('Packages/SessionKit/Sources/SessionKit/X.swift',), ('research/B4/server/x.go',),
                      ('Webby/a.ts',), ('web/a.ts',)):
            with self.subTest(paths=paths):
                github = self.Checks([])
                self.assertEqual(self.check(github, paths), (None, ''))
                self.assertEqual(github.calls, [])
                self.assertEqual(lane.STEP_RUNS, [])

    def test_a_base_without_the_rule_asks_github_nothing(self):
        github = self.Checks([])
        self.assertEqual(self.check(github, policy=None), (None, ''))
        self.assertEqual(self.check(github, policy=object()), (None, ''))
        self.assertEqual(github.calls, [])

    def test_every_diff_that_starts_the_job_waits_for_it(self):
        for paths in (('Web/src/a.ts',), ('Web/README.md',), ('docs/a.md', 'Web/src/a.ts'),
                      ('Packages/SessionKit/Sources/SessionKit/X.swift', 'Web/src/a.ts'),
                      ('research/B4/server/internal/links/page.go',), ('.github/workflows/hosted-web.yml',)):
            with self.subTest(paths=paths):
                self.assertEqual(self.check(self.Checks([self.check_run()]), paths)[0], 'PASS')

    def test_only_a_pass_passes(self):
        table = {'success': 'PASS', 'failure': 'FAIL', 'timed_out': 'FAIL', 'cancelled': 'INCONCLUSIVE',
                 'skipped': 'INCONCLUSIVE', 'neutral': 'INCONCLUSIVE', 'action_required': 'INCONCLUSIVE',
                 'stale': 'INCONCLUSIVE', None: 'INCONCLUSIVE'}
        for conclusion, verdict in table.items():
            with self.subTest(conclusion=conclusion):
                found, line = self.check(self.Checks([self.check_run(conclusion)]))
                self.assertEqual(found, verdict)
                self.assertIn(lane.HOSTED_WEB_CHECK, line)
                self.assertEqual([(r['step'], r['verdict']) for r in lane.STEP_RUNS], [(lane.HOSTED_WEB_STEP, verdict)])

    def test_it_waits_while_the_job_queues_and_runs_then_takes_the_verdict(self):
        for last, verdict in ((self.check_run(), 'PASS'), (self.check_run('failure'), 'FAIL')):
            with self.subTest(verdict=verdict):
                github = self.Checks([], [self.check_run(None, 'queued')], [self.check_run(None, 'in_progress')], [last])
                self.assertEqual(self.check(github, wait=3600)[0], verdict)
                self.assertEqual(len(github.calls), 4)

    def test_it_holds_when_the_job_never_finishes_or_never_shows_up(self):
        found, line = self.check(self.Checks([self.check_run(None, 'in_progress')]), wait=120, poll=30)
        self.assertEqual(found, 'INCONCLUSIVE')
        self.assertIn(lane.NOT_FINISHED, line)
        self.assertEqual(self.slept['t'], 120)
        found, line = self.check(self.Checks([]), wait=3600, poll=30, grace=300)
        self.assertEqual(found, 'INCONCLUSIVE')
        self.assertIn('no "hosted web: build and Playwright" check ran', line)
        self.assertEqual(self.slept['t'], 300)
        self.assertEqual(self.check(self.Checks([]))[0], 'INCONCLUSIVE')

    def test_a_run_from_another_app_is_not_the_job(self):
        forged = self.check_run(app={'slug': 'someone-else'})
        self.assertEqual(self.check(self.Checks([forged]))[0], 'INCONCLUSIVE')

    def test_the_newest_run_decides(self):
        old, new = self.check_run('failure', id=1, started_at='2026-11-06T10:00:00Z'), self.check_run(id=2, started_at='2026-11-06T11:00:00Z')
        self.assertEqual(self.check(self.Checks([old, new]))[0], 'PASS')
        self.assertEqual(self.check(self.Checks([new, old]))[0], 'PASS')
        old, new = self.check_run(id=1, started_at='2026-11-06T10:00:00Z'), self.check_run('failure', id=2, started_at='2026-11-06T11:00:00Z')
        self.assertEqual(self.check(self.Checks([old, new]))[0], 'FAIL')

    def test_a_failed_read_holds_and_never_passes(self):
        self.assertEqual(self.check(self.Checks(OSError('network')))[0], 'INCONCLUSIVE')
        github = self.Checks(subprocess.SubprocessError('gh'), [self.check_run()])  # a passing blip is waited out
        self.assertEqual(self.check(github, wait=3600)[0], 'PASS')
        with mock.patch.object(lane, 'base_policy', side_effect=OSError('git')):
            found, line = lane.hosted_web_check(self.Checks([]), Path('.'), 'main', HEAD, env={}, wait=0)
        self.assertEqual(found, 'INCONCLUSIVE')
        self.assertIn('could not tell', line)

    def test_it_stops_waiting_when_the_pr_moves_on(self):
        github = self.Checks([self.check_run(None, 'in_progress')])
        found, line = self.check(github, wait=3600, alive=lambda: f'{lane.MOVED_ON}the PR is closed')
        self.assertEqual(found, 'INCONCLUSIVE')
        self.assertIn('the PR is closed', line)
        self.assertEqual(github.calls, [])

    def test_only_a_lane_job_waits(self):
        github = self.Checks([self.check_run(None, 'in_progress')])
        with mock.patch.object(lane, 'base_policy', return_value=scope), \
                mock.patch.object(lane, 'committed_changes', return_value=(['Web/a.ts'], {})), \
                mock.patch.object(lane, 'HOSTED_REST_WAIT', 60):
            slept = []
            lane.hosted_web_check(github, Path('.'), 'main', HEAD, env={'GITHUB_ACTIONS': 'true'}, poll=30,
                                  clock=lambda: 30.0 * len(slept), sleep=slept.append, out=io.StringIO())
            self.assertEqual(slept, [30, 30])
            slept.clear()
            lane.hosted_web_check(github, Path('.'), 'main', HEAD, env={}, poll=30, clock=lambda: 0.0,
                                  sleep=slept.append, out=io.StringIO())
            self.assertEqual(slept, [])
        lane.STEP_RUNS.clear()

    def test_the_rule_names_what_the_workflow_runs_on(self):
        import yaml
        import re
        workflow = yaml.safe_load((ROOT / '.github/workflows/hosted-web.yml').read_text())
        # #4693: the paths moved from the trigger into the `changes` job's grep, so the check reports on every PR.
        step = next(step for step in workflow['jobs']['changes']['steps'] if step.get('id') == 'diff')
        pattern = re.search(r"grep -qE '\^\((.*)\)'", step['run']).group(1)
        prefixes = {alt.replace('\\.', '.').removesuffix('$') for alt in pattern.split('|')}
        self.assertEqual(prefixes, set(scope.HOSTED_WEB_PREFIXES))
        self.assertEqual(workflow['jobs']['web']['name'], lane.HOSTED_WEB_CHECK)


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

    def test_the_portable_job_waits_only_for_the_scope_job_and_skips_docs_only_changes(self):
        # #4693: no paths filter on a check the merge queue requires (a filtered-out workflow leaves its check pending),
        # so `portable` waits for the ~20 s scope job and is skipped, which reports success, when it says docs_only.
        job = self.jobs['portable']
        self.assertEqual(job['needs'], 'scope')
        self.assertIn("needs.scope.outputs.docs_only != 'true'", job['if'])
        self.assertTrue(job['if'].startswith("!cancelled() && needs.scope.result == 'success' && "), job['if'])
        self.assertIn('docs_only', self.jobs['scope']['outputs'])

    def test_no_required_workflow_has_a_paths_filter_and_both_listen_to_the_merge_queue(self):
        import yaml
        for name in ('hosted-portable.yml', 'hosted-web.yml'):
            with self.subTest(name):
                on = yaml.safe_load((ROOT / '.github/workflows' / name).read_text())[True]
                self.assertNotIn('paths', on['pull_request'])
                self.assertNotIn('paths-ignore', on['pull_request'])
                self.assertEqual(on['merge_group'], {'types': ['checks_requested'], 'branches': ['main']})

    def test_the_scope_job_asks_the_rule_for_the_mac_verdict(self):
        text = (ROOT / '.github/workflows/hosted-portable.yml').read_text()
        self.assertIn('--mac-required', text)

    def scope_says(self, layout, *, base_has_script=True, base_rule=None):
        """The scope step, run for real: a base whose rule needs the Mac for a Swift file, and a PR that changes that
        rule so its own copy says Mac-free. <layout>: 'pr' (GitHub's merge commit) or 'dispatch' (the PR's branch, with a base).
        <base_rule>: the text of the base's scripts/test-scope.py, the real one by default."""
        step = next(step for step in self.jobs['scope']['steps'] if step.get('id') == 'scope')['run']

        def git(*args, cwd):
            subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.test', *args], cwd=cwd,
                           check=True, capture_output=True)
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            origin, work = temp / 'origin', temp / 'work'
            (origin / 'scripts').mkdir(parents=True)
            git('init', '--quiet', '--initial-branch=main', cwd=origin)
            if base_has_script:
                (origin / 'scripts/test-scope.py').write_text(base_rule if base_rule is not None else (ROOT / 'scripts/test-scope.py').read_text())
            (origin / 'readme.txt').write_text('base\n')
            git('add', '.', cwd=origin)
            git('commit', '--quiet', '-m', 'base', cwd=origin)
            git('switch', '--quiet', '-c', 'pr', cwd=origin)
            (origin / 'scripts/test-scope.py').write_text('print("mac=false")\nprint("reason=the PR\'s own rule")\n')
            (origin / 'Packages').mkdir()
            (origin / 'Packages/New.swift').write_text('// a Swift input\n')
            git('add', '.', cwd=origin)
            git('commit', '--quiet', '-m', 'pr', cwd=origin)
            git('switch', '--quiet', 'main', cwd=origin)
            git('clone', '--quiet', str(origin), str(work), cwd=temp)
            git('switch', '--quiet', 'pr', cwd=work)
            if layout == 'pr':
                git('switch', '--quiet', '--detach', 'origin/main', cwd=work)
                git('merge', '--quiet', '--no-ff', '--no-edit', 'origin/pr', cwd=work)
            output = temp / 'output'
            ran = subprocess.run(['bash', '-e', '-c', step], cwd=work, capture_output=True, text=True,
                                 env={'PATH': '/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin', 'RUNNER_TEMP': str(temp),
                                      'GITHUB_OUTPUT': str(output), 'BASE': 'main' if layout == 'dispatch' else ''})
            self.assertEqual(ran.returncode, 0, ran.stderr)
            return dict(line.split('=', 1) for line in output.read_text().splitlines() if '=' in line)

    def test_the_scope_job_reads_the_base_s_rule_as_the_runner_does(self):
        # #3501 audit: the job read the PR's copy and the runner the base's, so a PR whose copy said Mac-free had its
        # Mac check skipped and required at once: an INCONCLUSIVE no fresh run could clear. A branch older than a
        # change to the rule on the base did the same.
        for layout in ('pr', 'dispatch'):
            with self.subTest(layout=layout):
                self.assertEqual(self.scope_says(layout)['mac'], 'true')

    def test_a_rule_that_crashes_or_says_nothing_runs_the_mac_checks(self):
        # #4303: the step's last line is the fail-safe. A rule that raises, exits 1 or prints no `mac=` line must leave
        # `mac=true` in the output, not a skipped Mac job. The step is the real one, run for real (not grepped), with
        # a base rule that misbehaves; the same run with a rule that says `mac=false` shows false is still reachable.
        # Not covered, on purpose: a rule that prints `mac=false` and then exits 1. The step has no pipefail (GitHub's
        # default `bash -e`), so `rule | tee || echo mac=true` never fires its `||` and the printed verdict stands; the
        # `grep -q '^mac='` line is what does the work here. Changing that is a `.github/` edit, the owner's tap (#4303).
        misbehaving = {
            'raises': 'raise RuntimeError("the rule broke")\n',
            'exits 1': 'import sys\nsys.exit(1)\n',
            'prints nothing': '',
            'prints other lines only': 'print("reason=I forgot the verdict")\n',
        }
        for layout in ('pr', 'dispatch'):
            for name, rule in misbehaving.items():
                with self.subTest(layout=layout, rule=name):
                    self.assertEqual(self.scope_says(layout, base_rule=rule).get('mac'), 'true')
            with self.subTest(layout=layout, rule='says mac=false'):
                self.assertEqual(self.scope_says(layout, base_rule='print("mac=false")\nprint("reason=docs only")\n')['mac'], 'false')

    def test_a_base_without_the_script_runs_the_mac_checks(self):
        for layout in ('pr', 'dispatch'):
            with self.subTest(layout=layout):
                self.assertEqual(self.scope_says(layout, base_has_script=False)['mac'], 'true')


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
