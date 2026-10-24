import contextlib
import os
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import research_tests


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scope = load('test_scope', 'test-scope.py')
verification = load('verification', 'verify-tests.py')
lane = load('lane_runner', 'lane-runner.py')


class ResearchRunnerTests(unittest.TestCase):
    """#1033: the Go server, research Python and Caddy script tests ran only when someone typed them."""

    def write(self, root, relative, text):
        path = Path(root) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(text))
        return path

    def test_scope_and_runner_agree_on_which_research_paths_are_tested(self):
        self.assertEqual(research_tests.TESTED_PREFIXES, scope.RESEARCH_TESTED_PREFIXES)

    def test_every_suite_points_at_something_that_exists(self):
        self.assertTrue((ROOT / 'research/B4/server/go.mod').is_file())
        self.assertTrue((ROOT / 'research/B4/deploy/test-edit-caddyfile.sh').is_file())
        for label, folder, arguments in research_tests.PYTHON_SUITES:
            self.assertTrue((ROOT / folder).is_dir(), label)

    def test_a_diff_that_touches_only_the_tested_research_code_is_t1_not_docs(self):
        # The lane runs nothing for T0, so a server-only PR never reached any gate.
        for path in ('research/B4/server/internal/maps/store.go', 'research/B4/deploy/edit-caddyfile.sh',
                     'research/B2/test_b2.py', 'research/B2/fixtures/01ce2f934341e9fd.json',
                     'research/D3/rank.py', 'research/C1/tools/test_net.py',
                     'research/B4/server/internal/links/share-link-open.test.mjs'):
            result = scope.classify([path], root=ROOT)
            self.assertEqual(result['tier'], 'T1', path)
            self.assertIn('.venv/bin/python scripts/research_tests.py', result['run'], path)
        for path in ('research/B4/README.md', 'research/B4/DESIGN.md', 'research/G2/comparison.json',
                     'research/C2/frontend/test_frontend.py', 'research/C1/results/summary.json'):
            self.assertEqual(scope.classify([path], root=ROOT)['tier'], 'T0', path)

    def test_the_fast_plan_runs_the_research_step(self):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')
            (Path(temporary) / 'node_modules').mkdir()  # host_steps insists on it; a cloud checkout has none
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args, kw))), \
                    patch.object(verification, 'ROOT', Path(temporary)), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.host_steps()
        steps = {name: (args, kw) for name, args, kw in calls}
        self.assertEqual(steps['research'][0][-1], 'scripts/research_tests.py')
        self.assertGreaterEqual(steps['research'][1]['timeout'], 300)  # a cold Go build on the Mac

    def run_step(self, script_output, exit_code=0, ci=False):
        script = f'import sys; sys.stdout.write({script_output!r}); sys.exit({exit_code})'
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')
            error = None
            environment = {name: value for name, value in os.environ.items() if name not in ('CI', 'GITHUB_ACTIONS')}
            if ci:
                environment['GITHUB_ACTIONS'] = 'true'
            with contextlib.redirect_stdout(io.StringIO()) as printed, patch.dict(os.environ, environment, clear=True):
                try:
                    run.command('research', [sys.executable, '-c', script])
                except RuntimeError as raised:
                    error = str(raised)
            return run.manifest['steps'][-1], error, printed.getvalue()

    def test_a_skipped_suite_is_in_the_report_with_its_reason(self):
        # Done when 3: no Go on the Mac must be said, not passed silently.
        step, error, printed = self.run_step(
            'passed: python research/B2 (15 tests)\n'
            'skipped: go research/B4/server - `go` is not on PATH; the server tests did not run\n'
            'research-tests: 15 tests in 1 suites; 1 skipped; 2 not covered\n')
        self.assertIsNone(error)
        self.assertEqual(step['executed_count'], 15)
        self.assertEqual(step['skipped'], ['go research/B4/server - `go` is not on PATH; the server tests did not run'])
        self.assertIn('warning: research skipped: go research/B4/server', printed)

    def test_in_ci_a_suite_skipped_for_a_missing_package_fails_the_step_and_names_it(self):
        # #2596: hosted-portable run 40108677003 printed "lxml is not installed" and passed the step.
        output = ('passed: python research/B2 (15 tests)\n'
                  'skipped: python research/C1/tools test_groundtruth - the Python package `lxml` is not installed\n'
                  'research-tests: 15 tests in 1 suites; 1 skipped; 2 not covered\n')
        step, error, _ = self.run_step(output, ci=True)
        self.assertIsNotNone(error)
        self.assertIn('`lxml`', error)
        self.assertTrue(step['errors'])
        step, error, printed = self.run_step(output)  # on a developer's machine it stays a warning
        self.assertIsNone(error)
        self.assertIn('warning: research skipped', printed)

    def test_in_ci_reads_both_variables(self):
        self.assertTrue(verification.in_ci({'CI': 'true'}))
        self.assertTrue(verification.in_ci({'GITHUB_ACTIONS': 'true'}))
        self.assertFalse(verification.in_ci({}))
        self.assertFalse(verification.in_ci({'CI': 'false'}))

    def test_the_portable_job_installs_lxml_through_the_requirements_file_it_already_uses(self):
        self.assertRegex((ROOT / 'requirements-dev.txt').read_text(), r'(?m)^lxml==')

    def test_a_research_step_that_ran_nothing_fails(self):
        step, error, _ = self.run_step('skipped: go research/B4/server - no go\nresearch-tests: 0 tests in 0 suites; 3 skipped\n')
        self.assertIn('research executed zero tests', error)
        step, error, _ = self.run_step('no summary line at all\n')
        self.assertIn('research executed zero tests', error)

    def test_a_failing_suite_fails_the_step(self):
        step, error, _ = self.run_step('FAILED: go research/B4/server\nfailed test: example/maps TestTakedownKeepsMapDown\nresearch-tests: 5 tests in 1 suites; 0 skipped; 2 not covered\n', 1)
        self.assertIn('Process exit 1', error)
        self.assertIn('failed test: example/maps TestTakedownKeepsMapDown', error)  # the lane's report names it

    def test_python_suite_counts_tests_and_reports_a_failure_with_its_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.write(temporary, 'good/test_good.py', """
                import unittest
                class T(unittest.TestCase):
                    def test_a(self): pass
                    def test_b(self): pass
            """)
            self.write(temporary, 'bad/test_bad.py', """
                import unittest
                class T(unittest.TestCase):
                    def test_a(self): self.assertEqual(1, 2)
            """)
            self.write(temporary, 'empty/test_nothing.py', 'import unittest\n')
            ok = research_tests.python_suite(Path(temporary), 'good', 'good', ('test_good',))
            self.assertEqual((ok.tests, ok.error), (2, None))
            bad = research_tests.python_suite(Path(temporary), 'bad', 'bad', ('test_bad',))
            self.assertIn('AssertionError: 1 != 2', bad.error)
            none = research_tests.python_suite(Path(temporary), 'empty', 'empty', ('test_nothing',))
            self.assertIn('after 0 tests', none.error)  # discovered nothing: not a pass

    def test_caddy_suite_needs_its_checks_to_pass_and_be_counted(self):
        # The fake scripts below don't use mapfile, so the probe is stubbed: on macOS bash 3.2 it would skip.
        with tempfile.TemporaryDirectory() as temporary, patch.object(research_tests, 'bash_has_mapfile', return_value=True):
            script = 'research/B4/deploy/test-edit-caddyfile.sh'
            self.write(temporary, script, 'echo "ok   one"\necho "8 checks passed"\n')
            self.assertEqual(research_tests.caddy_suite(Path(temporary)).tests, 8)
            self.write(temporary, script, 'echo "SKIPPED caddy validate"\necho "9 checks passed, but not the Caddy ones above"\n')
            self.assertEqual(research_tests.caddy_suite(Path(temporary)).tests, 9)   # no Caddy installed: still counted
            self.write(temporary, script, 'echo "FAIL the guard" >&2\nexit 1\n')
            self.assertIn('FAIL the guard', research_tests.caddy_suite(Path(temporary)).error)
            self.write(temporary, script, 'echo "nothing ran"\n')
            self.assertIn('after 0 checks', research_tests.caddy_suite(Path(temporary)).error)

    def test_no_go_means_a_named_skip_not_a_pass(self):
        with patch.object(research_tests, 'find_go', return_value=None):
            result = research_tests.go_suite(ROOT)
        self.assertFalse(result.ran)
        self.assertIn('`go` is not on PATH', result.skipped)
        self.assertIsNone(result.error)

    def test_find_go_looks_past_a_short_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            go = Path(temporary) / 'go'
            go.write_text('#!/bin/sh\n')
            go.chmod(0o755)
            with patch.object(research_tests, 'GO_DIRECTORIES', (temporary,)):
                self.assertEqual(research_tests.find_go(path='/nonexistent'), str(go))

    @unittest.skipUnless(research_tests.find_go(), 'needs the Go toolchain')
    def test_go_suite_counts_passing_tests_and_names_the_failing_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            server = Path(temporary) / 'research/B4/server'
            self.write(temporary, 'research/B4/server/go.mod', 'module example.test/server\n\ngo 1.21\n')
            self.write(temporary, 'research/B4/server/ok_test.go', """
                package server
                import "testing"
                func TestOne(t *testing.T) {}
                func TestTwo(t *testing.T) { t.Run("sub", func(t *testing.T) {}) }
            """)
            ok = research_tests.go_suite(Path(temporary))
            self.assertEqual((ok.tests, ok.error), (2, None))  # subtests are not counted twice
            self.write(temporary, 'research/B4/server/bad_test.go', """
                package server
                import "testing"
                func TestGuardIsGone(t *testing.T) { t.Fatal("ValidKey guard missing") }
            """)
            bad = research_tests.go_suite(Path(temporary))
            self.assertIn('failed test: example.test/server TestGuardIsGone', bad.error)
            self.assertIn('ValidKey guard missing', bad.error)
            (server / 'bad_test.go').write_text('package server\nfunc broken( {\n')
            self.assertIn('FAIL', research_tests.go_suite(Path(temporary)).error)  # a package that doesn't build

    def test_main_reports_each_suite_and_exits_one_on_a_failure_or_when_nothing_ran(self):
        ran = research_tests.Result('python x', tests=3)
        failed = research_tests.Result('go y', tests=1, error='unittest exited 1')
        skipped = research_tests.Result('go z', skipped='`go` is not on PATH')
        out = io.StringIO()
        with patch.object(research_tests, 'suites', return_value=[lambda: ran, lambda: skipped]), \
                patch.object(research_tests, 'NOT_COVERED', ()):
            self.assertEqual(research_tests.main(out=out), 0)
        self.assertIn('passed: python x (3 tests)', out.getvalue())
        self.assertIn('skipped: go z - `go` is not on PATH', out.getvalue())
        self.assertIn('research-tests: 3 tests in 1 suites; 1 skipped; 0 not covered', out.getvalue())
        out = io.StringIO()
        with patch.object(research_tests, 'suites', return_value=[lambda: ran, lambda: failed]), \
                patch.object(research_tests, 'NOT_COVERED', ()):
            self.assertEqual(research_tests.main(out=out), 1)
        self.assertIn('FAILED: go y\nunittest exited 1', out.getvalue())
        with patch.object(research_tests, 'suites', return_value=[lambda: skipped]), patch.object(research_tests, 'NOT_COVERED', ()):
            self.assertEqual(research_tests.main(out=io.StringIO()), 1)

    def test_bash_without_mapfile_skips_the_caddy_suite_by_name(self):
        # edit-caddyfile.sh uses `mapfile`; macOS /bin/bash 3.2 has none, so the suite would fail there
        # for a reason that says nothing about the filter.
        with patch.object(research_tests, 'bash_has_mapfile', return_value=False):
            result = research_tests.caddy_suite(ROOT)
        self.assertFalse(result.ran)
        self.assertIn('no `mapfile`', result.skipped)

    def test_the_mapfile_probe_asks_the_bash_on_path(self):
        seen = []
        with patch.object(research_tests, 'run',
                          side_effect=lambda args, cwd, env=None: seen.append(args) or subprocess.CompletedProcess(args, 1)):
            self.assertFalse(research_tests.bash_has_mapfile(ROOT))
        self.assertEqual(seen, [['bash', '-c', 'type mapfile']])

    def test_a_missing_third_party_package_skips_the_suite_but_a_missing_own_module_fails_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.write(temporary, 'a/test_third_party.py', 'import some_listed_package\nimport unittest\n')
            self.write(temporary, 'b/test_own.py', 'import module_that_was_renamed\nimport unittest\n')
            with patch.object(research_tests, 'THIRD_PARTY', ('some_listed_package',)):
                listed = research_tests.python_suite(Path(temporary), 'a', 'a', ('test_third_party',))
                own = research_tests.python_suite(Path(temporary), 'b', 'b', ('test_own',))
        self.assertIn('`some_listed_package` is not installed', listed.skipped)
        self.assertIsNone(listed.error)
        self.assertIsNone(own.skipped)  # a broken import of our own code must not hide as a skip
        self.assertIn('module_that_was_renamed', own.error)

    @unittest.skipUnless(research_tests.find_go(), 'needs the Go toolchain')
    def test_a_go_package_that_does_not_build_shows_the_compiler_message(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.write(temporary, 'research/B4/server/go.mod', 'module example.test/server\n\ngo 1.21\n')
            self.write(temporary, 'research/B4/server/broken_test.go',
                       'package server\nimport "testing"\nfunc TestX(t *testing.T) { undefinedThing() }\n')
            result = research_tests.go_suite(Path(temporary))
        self.assertIn('failed package: example.test/server', result.error)
        self.assertIn('undefined: undefinedThing', result.error)

    def test_a_passing_lane_run_lists_the_suites_the_machine_could_not_run(self):
        # Done when 3 (#1033): the PASS report, not only the log on the Mac, says a suite was skipped.
        def runner_writing(steps):
            def run(command, log, timeout):
                output = Path(command[command.index('--output') + 1])
                output.mkdir(parents=True, exist_ok=True)
                (output / 'manifest.json').write_text(json.dumps({'status': 'verified', 'steps': steps}))
                return 0
            return run

        steps = [{'name': 'runner-tests', 'skipped': 'Codex sandbox: `ps` cannot run here'},  # a string, not a list
                 {'name': 'research', 'skipped': ['go research/B4/server - `go` is not on PATH']}]
        with tempfile.TemporaryDirectory() as folder:
            verdict, details = lane.run_fast(Path(folder), runner=runner_writing(steps))
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(details, ['research skipped: go research/B4/server - `go` is not on PATH'])
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(lane.run_fast(Path(folder), runner=runner_writing([{'name': 'research'}])),
                             ('PASS', []))



if __name__ == '__main__':
    unittest.main()
