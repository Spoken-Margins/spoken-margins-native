"""#2596: the hosted Mac checks run, and the runner waits for them, only when the diff reaches a Swift input.

Before: every PR ran SessionKit core and Mac rest on a hosted Mac, and the runner required both. 22 of 62 PRs in one day
touched no Swift input and spent 23% of the Mac minutes, with a queue p90 of about 52 minutes; a skipped job would have
sent the runner to the build Mac after its 5-minute grace.
"""
import ast
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_test_scope as scope_tests
import test_fast_portable as portable_tests

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
        for path in ('.github/workflows/hosted-portable.yml', '.github/workflows/main-t3.yml', '.github/actions/x/action.yml',
                     'scripts/verify-tests.py', 'scripts/lane_t3.py', 'scripts/test-scope.py',
                     'scripts/sessionkit_pass.py', 'scripts/tests/test_lane_t3.py', 'scripts/xcodebuild-lane'):
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
    are not followed: verify-tests.py names nearly every script, and the tests stub what they run.
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
        for path in ('scripts/phone-build', 'scripts/sm_paths.py', 'scripts/sm_build_cache.py', 'scripts/lane_slots.py'):
            self.assertIn(path, reach)


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
                # And on `guards` (merge groups only), whose red cancels the run (#5281); no guards result skips them.
                self.assertEqual(job['needs'], ['scope', 'guards'])
                self.assertIn("needs.scope.outputs.mac != 'false'", job['if'])
                # Without a status function GitHub adds success(), so a failed scope job would skip the Mac jobs
                # (audit on 07cedaa). They run unless the scope job was cancelled, skipped or said mac=false.
                condition = ' '.join(job['if'].split())
                self.assertTrue(condition.startswith("!cancelled() && needs.scope.result != 'skipped' && "), job['if'])
                self.assertNotIn('needs.guards', condition)
                self.assertIn('xcode', ' '.join(job['runs-on']).lower() + str(job['runs-on']).lower())

    def test_the_portable_job_waits_only_for_the_scope_job_and_skips_docs_only_changes(self):
        # #4693: no paths filter on a check the merge queue requires (a filtered-out workflow leaves its check pending),
        # so `portable` waits for the ~20 s scope job and is skipped, which reports success, when it says docs_only.
        job = self.jobs['portable']
        self.assertEqual(job['needs'], 'scope')
        self.assertIn("needs.scope.outputs.docs_only != 'true'", job['if'])
        self.assertTrue(job['if'].startswith("!cancelled() && needs.scope.result == 'success' && "), job['if'])
        self.assertIn('docs_only', self.jobs['scope']['outputs'])

    def test_a_merge_group_always_runs_the_portable_job(self):
        # #5179: the queue merges every entry ahead of a green head on that head's result (HEADGREEN), so a docs-only
        # head that skipped `portable` merged #5087 and #5102 untested and left main red for about 3 hours (2026-11-23).
        # On merge_group the docs_only skip must not apply: evaluate the condition as GitHub would.
        sys.path.insert(0, str(ROOT / 'scripts'))
        import ci_model
        condition = self.jobs['portable']['if']
        needs = {'scope': {'result': 'success', 'outputs': {'docs_only': 'true', 'mac': 'false'}}}
        for event, runs in (('merge_group', True), ('workflow_dispatch', False)):
            with self.subTest(event=event):
                ctx = {'github': {'event_name': event, 'repository': 'o/r', 'event': {}},
                       'vars': {'LANE_HOSTED_FAST': 'on'}, 'needs': needs, 'inputs': {}}
                self.assertEqual(ci_model.condition(condition, ctx, ['success']), runs, condition)

    def test_the_docs_only_check_skips_docs_but_not_the_quiz_scripts(self):
        # #5048: Site/quiz/ holds the quiz's code (page.js, quiz.js), tested by scripts/tests/quiz_* and test_quiz_page.
        # Counted as docs, a PR that edited only Site/quiz/page.js skipped the portable plan in the PR and the merge
        # group, so a broken quiz merged and went to the deploy with no test. Run as the step runs it: python3 -c, exit 0
        # is docs-only.
        sys.path.insert(0, str(ROOT / 'scripts'))
        import ci_model
        rule = ci_model.docs_only_rule((ROOT / '.github/workflows/hosted-portable.yml').read_text())
        cases = {('Site/quiz/page.js',): 1, ('Site/quiz/quiz.js',): 1, ('Site/quiz/v1/find-something.json',): 1,
                 ('Site/privacy/index.html', 'Site/quiz/index.html'): 1, ('Site/quiz/page.js', 'docs/a.md'): 1,
                 ('Site/privacy/index.html',): 0, ('Site/join/index.html',): 0, ('Site/quizzes/index.html',): 0,
                 ('docs/a.md', 'Design/x.png', 'Contracts/docs/y.txt'): 0, ('README.md',): 0,
                 ('scripts/x.py',): 1}
        with tempfile.TemporaryDirectory() as tmp:
            listing = Path(tmp) / 'changed-files.txt'
            for paths, code in cases.items():
                with self.subTest(paths=paths):
                    listing.write_text(''.join(f'{path}\n' for path in paths))
                    run = subprocess.run([sys.executable, '-c', rule, str(listing)], capture_output=True, text=True)
                    self.assertEqual(run.returncode, code, run.stderr)

    def test_no_required_workflow_has_a_paths_filter_and_both_listen_to_the_merge_queue(self):
        import yaml
        for name in ('hosted-portable.yml', 'hosted-web.yml'):
            with self.subTest(name):
                on = yaml.safe_load((ROOT / '.github/workflows' / name).read_text())[True]
                self.assertNotIn('paths', on['pull_request'])
                self.assertNotIn('paths-ignore', on['pull_request'])
                self.assertEqual(on['merge_group'], {'types': ['checks_requested'], 'branches': ['main']})

    def test_with_the_queue_switch_on_mac_rest_skips_pr_pushes_only(self):
        # #4693: MERGE_QUEUE_MAC=queue-only keeps the Mac job off PR pushes; merge groups and dispatches still run it.
        condition = self.jobs['mac-rest']['if']
        self.assertIn("vars.MERGE_QUEUE_MAC != 'queue-only'", condition)
        pr_part = condition.split("github.event_name != 'pull_request' ||", 1)
        self.assertEqual(len(pr_part), 2, condition)
        self.assertIn("vars.MERGE_QUEUE_MAC != 'queue-only'", pr_part[1])
        self.assertNotIn('MERGE_QUEUE_MAC', pr_part[0])

    def test_the_scope_job_asks_the_rule_for_the_mac_verdict(self):
        text = (ROOT / '.github/workflows/hosted-portable.yml').read_text()
        self.assertIn('--mac-required', text)

    def scope_says(self, layout, *, base_has_script=True, base_rule=None):
        """The scope step, run for real: a base whose rule needs the Mac for a Swift file, and a PR that changes that
        rule so its own copy says Mac-free. <layout>: 'pr' (GitHub's merge commit), 'dispatch' (the PR's branch, with a base) or 'merge_group' (a
        queue entry behind another: main, then the PR's entry, then a docs-only entry on top, as GitHub builds it).
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
            output = temp / 'output'
            env = {'PATH': '/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin', 'RUNNER_TEMP': str(temp),
                   'GITHUB_OUTPUT': str(output), 'BASE': 'main' if layout == 'dispatch' else ''}
            if layout in ('pr', 'merge_group'):
                git('switch', '--quiet', '--detach', 'origin/main', cwd=work)
                git('merge', '--quiet', '--no-ff', '--no-edit', 'origin/pr', cwd=work)
            if layout == 'merge_group':
                previous_entry = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=work, capture_output=True,
                                                text=True, check=True).stdout.strip()
                (work / 'docs').mkdir()
                (work / 'docs/note.md').write_text('a docs-only entry\n')
                git('add', '.', cwd=work)
                git('commit', '--quiet', '-m', 'docs-only entry', cwd=work)
                # What GitHub sends: base_sha is the previous entry's queue commit, base_ref the trunk.
                env.update(EVENT='merge_group', QUEUE_BASE=previous_entry, QUEUE_TRUNK='refs/heads/main')
            ran = subprocess.run(['bash', '-e', '-c', step], cwd=work, capture_output=True, text=True, env=env)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            return dict(line.split('=', 1) for line in output.read_text().splitlines() if '=' in line)

    def test_the_scope_job_reads_the_base_s_rule_as_the_runner_does(self):
        # #3501 audit: the job read the PR's copy and the runner the base's, so a PR whose copy said Mac-free had its
        # Mac check skipped and required at once: an INCONCLUSIVE no fresh run could clear. A branch older than a
        # change to the rule on the base did the same.
        for layout in ('pr', 'dispatch'):
            with self.subTest(layout=layout):
                self.assertEqual(self.scope_says(layout)['mac'], 'true')

    def test_a_merge_group_scopes_against_main_not_the_previous_queue_entry(self):
        # #5179: the step diffed against merge_group.base_sha, the previous entry's queue commit, so a docs-only entry
        # behind a Swift PR saw only its own docs change and said mac=false, docs_only=true. The group must be scoped
        # by everything it adds to main, with main's rule.
        said = self.scope_says('merge_group')
        self.assertEqual(said['mac'], 'true', said)
        self.assertEqual(said['docs_only'], 'false', said)

    def test_no_workflow_scopes_a_merge_group_by_its_base_sha(self):
        # #5179: base_sha is the previous queue entry's commit, not main's tip, so a diff from it misses every entry
        # ahead. The scope, Mac rest and web change steps all used it; none may decide what a queue entry tests by it.
        for path in sorted((ROOT / '.github/workflows').glob('*.yml')):
            with self.subTest(path.name):
                self.assertNotIn('github.event.merge_group.base_sha', path.read_text())

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

    def test_the_separate_sessionkit_job_runs_only_with_the_mac_rest_switch_off(self):
        self.assertIn("vars.LANE_HOSTED_MAC_REST != 'on'", self.jobs['sessionkit']['if'])
        self.assertNotIn("!= 'on'", self.jobs['mac-rest']['if'])

    def test_the_job_has_room_for_both_plans(self):
        self.assertGreaterEqual(self.jobs['mac-rest']['timeout-minutes'],
                                self.jobs['sessionkit']['timeout-minutes'] + 20)


if __name__ == '__main__':
    unittest.main()
