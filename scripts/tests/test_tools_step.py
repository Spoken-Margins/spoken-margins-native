"""coop-packet and phone-plan live in their own package, Packages/SessionKitTools (#1873).

They used to be executables in Packages/SessionKit, so a project depending on SessionKit resolved this repo's
developer tools too, and coop-packet's tests ran inside SessionKitTests. Now SessionKit's manifest names neither,
every caller builds them from the tools package, and the fast plan's `tools` step runs their tests when a diff
reaches the tools or the SessionKit code they build on.
"""
import contextlib
import io
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_lane_runner import verification  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'Packages/SessionKitTools'
MOVED = ('phone-plan', 'coop-packet')


class ThePackages(unittest.TestCase):
    def test_sessionkit_lists_neither_tool(self):
        manifest = (ROOT / 'Packages/SessionKit/Package.swift').read_text()
        for name in (*MOVED, 'PhonePlan', 'CoopPacket'):
            with self.subTest(name):
                self.assertNotIn(f'"{name}"', manifest)
        self.assertFalse((ROOT / 'Packages/SessionKit/Sources/CoopPacket').exists())
        self.assertFalse((ROOT / 'Packages/SessionKit/Sources/PhonePlan').exists())

    def test_the_tools_package_builds_both_on_sessionkit_by_path(self):
        manifest = (TOOLS / 'Package.swift').read_text()
        for name in MOVED:
            with self.subTest(name):
                self.assertIn(f'.executable(name: "{name}"', manifest)
        self.assertIn('.package(path: "../SessionKit")', manifest)
        self.assertNotIn('url:', manifest)  # every outside dependency comes through SessionKit's own pins

    def test_coop_packet_tests_import_it_only_from_the_tools_package(self):
        importing = re.compile(r'^\s*(?:@testable\s+)?import\s+(CoopPacket|PhonePlan)\s*$', re.M)
        stray = [str(path.relative_to(ROOT)) for path in (ROOT / 'Packages/SessionKit').rglob('*.swift')
                 if '.build' not in path.parts and importing.search(path.read_text(errors='replace'))]
        self.assertEqual(stray, [])
        self.assertTrue(verification.swift_tests(TOOLS / 'Tests/CoopPacketTests'))

    def test_every_caller_builds_a_tool_from_the_package_that_makes_it(self):
        # A `--package-path X ... --product <tool>` or `X/.build/<config>/<tool>` that names SessionKit would fail
        # after the move. Tracked files only; the daily plan's pre-#1873 fallback is named and allowed.
        files = subprocess.run(['git', '-C', str(ROOT), 'ls-files', 'scripts', 'docs', 'ops', 'Contracts', 'Packages',
                                'BUILDING.md', 'README.md', 'AGENTS.md'], capture_output=True, text=True,
                               check=True).stdout.split()
        tool = '|'.join(MOVED)
        wrong = re.compile(rf'(--package-path\s+\S*Packages/SessionKit\b(?!Tools)[^\n]*--product\s+({tool})\b'
                           rf'|Packages/SessionKit/\.build/(debug|release)/({tool})\b)')
        allowed = {'scripts/daily-phone-plan', 'ops/disk/README.md', 'scripts/sm_build_cache.py', 'scripts/tests/test_sm_build_cache.py',
                   'docs/workstreams/daily-phone-plan.md', 'scripts/tests/test_daily_phone_plan.py'}
        hits = []
        for name in files:
            path = ROOT / name
            if name in allowed or not path.is_file() or path.suffix in ('.spokenmargins', '.png', '.onnx', '.bin'):
                continue
            text = path.read_text(errors='replace')
            hits += [f'{name}: {m.group(0)}' for m in wrong.finditer(text)]
        self.assertEqual(hits, [])


class WhichDiffsRunTheTools(unittest.TestCase):
    def needed(self, *changed):
        return verification.tools_tests_needed(list(changed))[0]

    def test_the_tools_and_what_they_build_on_run_them(self):
        for path in ('Packages/SessionKitTools/Sources/CoopPacket/CoopCheck.swift',
                     'Packages/SessionKitTools/Package.swift',
                     'Packages/SessionKit/Sources/SessionKitSharing/PacketExporter.swift',
                     'Packages/SessionKit/Tests/ShippedReader/Reader/Reader.swift',  # ShippedPacketReader's source
                     'Packages/SessionKit/Package.swift',
                     'scripts/run-sessionkit-tests.sh'):
            with self.subTest(path):
                self.assertTrue(self.needed(path))

    def test_neighbouring_paths_do_not(self):
        for path in ('App/SpokenMarginsApp/Gate1AppModel.swift', 'Packages/SessionKitX/A.swift',
                     'scripts/run-sessionkit-linux-tests.sh', 'docs/areas.md', 'Packages/README.md'):
            with self.subTest(path):
                self.assertFalse(self.needed(path))

    def test_no_diff_information_runs_them(self):
        for nothing in (None, []):
            self.assertTrue(verification.tools_tests_needed(nothing)[0])


class TheStepInThePlan(unittest.TestCase):
    def run_plan(self, plan, changed):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            run = verification.Run(tree / 'run', plan, changed)
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args, kw))), \
                    mock.patch.object(run, 'ops_steps'), \
                    mock.patch.object(run, 'package_steps'), \
                    mock.patch.object(run, 'shipped_compat'), \
                    mock.patch.object(verification, 'ROOT', tree), \
                    mock.patch.object(verification, 'swift_tests', return_value={'T/test'}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    mock.patch.object(verification.sessionkit_pass, 'toolchain', return_value=None), \
                    mock.patch.object(verification.sessionkit_pass, 'find', return_value=None), \
                    mock.patch.object(verification, 'host_test_slot', return_value=contextlib.nullcontext({})), \
                    mock.patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']), \
                    contextlib.redirect_stdout(io.StringIO()):
                (tree / 'node_modules').mkdir()
                run.fast()
            skipped = {step['name']: step['skipped'] for step in run.manifest['steps'] if 'skipped' in step}
        return [call for call in calls if call[0] == 'tools'], skipped

    def test_a_sessionkit_diff_runs_the_tools_tests_in_both_mac_plans(self):
        for plan in ('fast', 'fast-mac-rest'):
            with self.subTest(plan):
                steps, skipped = self.run_plan(plan, ['Packages/SessionKit/Sources/SessionKitSharing/A.swift'])
                self.assertEqual(len(steps), 1)
                _, args, kwargs = steps[0]
                self.assertEqual(args, [*verification.PACKAGE_RUNNER, '--tools'])
                self.assertEqual(kwargs['expected'], {'CoopPacketTests/T/test'})
                self.assertTrue(kwargs['tests'])
                self.assertNotIn('tools', skipped)

    def test_an_app_diff_names_the_step_as_skipped(self):
        steps, skipped = self.run_plan('fast-mac-rest', ['App/SpokenMarginsApp/Gate1AppModel.swift'])
        self.assertEqual(steps, [])
        self.assertIn('SessionKitTools', skipped['tools'])

    def test_only_the_mac_lane_runs_it(self):
        self.assertIn('tools', verification.MAC_REST_STEPS)
        self.assertIn('tools', verification.PORTABLE_LEFT_OUT)
        self.assertNotIn('tools', verification.HOSTED_SESSIONKIT_STEPS)

    def test_the_runner_script_builds_the_tools_package_inside_sessionkits_cache(self):
        script = (ROOT / 'scripts/run-sessionkit-tests.sh').read_text()
        line = next(line for line in script.splitlines() if line.strip().startswith('--tools)'))
        self.assertIn('--package-path "$ROOT/Packages/SessionKitTools"', line)
        self.assertIn('--scratch-path "$PACKAGE/.build/tools"', line)


if __name__ == '__main__':
    unittest.main()
