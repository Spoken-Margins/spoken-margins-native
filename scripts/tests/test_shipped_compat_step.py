"""The runner's fast plan runs the shipped-build compatibility checks for a diff that reaches them (#1899).

.github/workflows/shipped-build-compat.yml was the only place the frozen packet reader and the Build 29 database
checks ran. The lane runner builds a merge commit and pushes it straight to next, so a required check can never
stand on that commit and a red workflow did not stop a PR landing. verify-tests.py now runs the same two
commands as the `shipped-compat` step of the plan the runner merges on, for a diff that touches a file the
workflow's `paths` names, and the step's failure fails the run.
"""
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_lane_runner import verification  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / verification.SHIPPED_COMPAT_WORKFLOW

PERSISTENCE = 'Packages/SessionKit/Sources/SessionKitPersistence/SQLiteStore.swift'


class WhichDiffsNeedTheChecks(unittest.TestCase):
    """The workflow's own path filter decides, read from the tree under test, so the two cannot drift apart."""

    def needed(self, *changed):
        return verification.shipped_compat_needed(list(changed), root=ROOT)[0]

    def test_files_that_define_a_stored_type_or_a_packet_need_them(self):
        for path in (PERSISTENCE,
                     'Packages/SessionKit/Sources/SessionKitSharing/PacketExporter.swift',
                     'Packages/SessionKit/Sources/SessionKit/Models.swift',          # *Models*.swift
                     'Packages/SessionKit/Sources/SessionKit/ItemCollection.swift',  # named in the list
                     'Packages/SessionKit/Tests/ShippedReader/SessionKit/Models.swift',  # ** crosses folders
                     'scripts/check-build29-database.sh',
                     'scripts/build29-db-reader/main.swift',
                     '.github/workflows/shipped-build-compat.yml'):
            with self.subTest(path):
                self.assertTrue(self.needed(path))

    def test_one_matching_path_among_others_is_enough(self):
        self.assertTrue(self.needed('README.md', 'App/SpokenMarginsApp/Gate1RootView.swift', PERSISTENCE))

    def test_neighbouring_paths_that_the_filter_does_not_name_do_not(self):
        for path in ('App/SpokenMarginsApp/Gate1AppModel.swift',
                     'Packages/SessionKit/Sources/SessionKit/PlaybackRate.swift',   # a file the list does not name
                     'Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift',
                     'Packages/SessionKit/Sources/SessionKitPersistence',            # the folder itself, no file
                     'Packages/SessionKit/Sources/SessionKitPersistenceX/A.swift',   # lookalike folder
                     'scripts/check-build29-database.sh.bak',
                     'docs/areas.md'):
            with self.subTest(path):
                self.assertFalse(self.needed(path))

    def test_no_diff_information_runs_them_like_every_other_step(self):
        for nothing in (None, []):
            run, why = verification.shipped_compat_needed(nothing, root=ROOT)
            self.assertTrue(run)
            self.assertIn('no list of changed paths', why)

    def test_a_tree_without_the_workflow_skips_them_and_says_why(self):
        with tempfile.TemporaryDirectory() as empty:
            run, why = verification.shipped_compat_needed([PERSISTENCE], root=empty)
        self.assertFalse(run)
        self.assertIn('shipped-build-compat.yml', why)

    def test_a_workflow_whose_paths_cannot_be_read_stops_the_run_instead_of_skipping_quietly(self):
        with tempfile.TemporaryDirectory() as temporary:
            workflow = Path(temporary) / verification.SHIPPED_COMPAT_WORKFLOW
            workflow.parent.mkdir(parents=True)
            workflow.write_text('name: shipped-build-compat\non:\n  pull_request:\n    branches: [next]\n')
            with self.assertRaises(RuntimeError):
                verification.shipped_compat_needed([PERSISTENCE], root=temporary)


class TheStepInThePlan(unittest.TestCase):
    def run_mac_rest(self, changed):
        calls, skipped = [], {}
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            (tree / verification.SHIPPED_COMPAT_WORKFLOW).parent.mkdir(parents=True)
            shutil.copy(WORKFLOW, tree / verification.SHIPPED_COMPAT_WORKFLOW)
            run = verification.Run(tree / 'run', 'fast-mac-rest', changed)
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args, kw))), \
                    mock.patch.object(run, 'ops_steps'), \
                    mock.patch.object(run, 'package_steps'), \
                    mock.patch.object(verification, 'ROOT', tree), \
                    mock.patch.object(verification, 'swift_tests', return_value={'T/test'}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    mock.patch.object(verification.sessionkit_pass, 'toolchain', return_value=None), \
                    mock.patch.object(verification.sessionkit_pass, 'find', return_value=None), \
                    mock.patch.object(verification, 'host_test_slot', return_value=contextlib.nullcontext({})), \
                    mock.patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']), \
                    contextlib.redirect_stdout(io.StringIO()):
                run.fast()
            skipped = {step['name']: step['skipped'] for step in run.manifest['steps'] if 'skipped' in step}
            notes = run.manifest.get('notes', [])
        return calls, skipped, notes

    def test_a_diff_that_reaches_the_shipped_build_runs_both_checks_in_order_with_the_workflows_budget(self):
        calls, skipped, notes = self.run_mac_rest([PERSISTENCE])
        steps = [call for call in calls if call[0] == 'shipped-compat']
        self.assertEqual(len(steps), 1)
        _, args, kwargs = steps[0]
        self.assertEqual(args, ['sh', '-c',
                                'scripts/freeze-shipped-reader.sh --check && scripts/check-build29-database.sh'])
        self.assertEqual(kwargs['timeout'], 2400)
        self.assertNotIn('shipped-compat', skipped)
        self.assertTrue(any(PERSISTENCE in note for note in notes), notes)

    def test_a_diff_that_does_not_reach_it_names_the_step_as_skipped(self):
        calls, skipped, _ = self.run_mac_rest(['App/SpokenMarginsApp/Gate1AppModel.swift'])
        self.assertNotIn('shipped-compat', [call[0] for call in calls])
        self.assertIn('watches', skipped['shipped-compat'])

    def test_the_other_plans_never_run_it(self):
        self.assertEqual(verification.PORTABLE_LEFT_OUT['shipped-compat'].split(';')[-1].strip(),
                         'only the Mac lane runs it')
        self.assertNotIn('shipped-compat', verification.HOSTED_SESSIONKIT_STEPS)


class TheCommandBlocksOnABrokenFrozenReader(unittest.TestCase):
    """The done-when's "deliberately broken frozen copy blocks a test PR", with the real script and a real git tag."""

    def git(self, cwd, *args):
        subprocess.run(['git', '-C', str(cwd), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                       check=True, capture_output=True)

    def repo(self, frozen_text):
        temporary = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temporary, ignore_errors=True)
        sources = temporary / 'Packages/SessionKit/Sources'
        for part in ('SessionKit', 'SessionKitSharing'):
            (sources / part).mkdir(parents=True)
            (sources / part / 'Reader.swift').write_text('import SessionKit\nlet reader = 1\n')
        self.git(temporary, 'init', '-q')
        self.git(temporary, 'add', '-A')
        self.git(temporary, 'commit', '-qm', 'the shipped build')
        self.git(temporary, 'tag', 'testflight/0.1-build-29')
        frozen = temporary / 'Packages/SessionKit/Tests/ShippedReader'
        for part in ('SessionKit', 'SessionKitSharing'):
            (frozen / part).mkdir(parents=True)
            text = frozen_text if part == 'SessionKit' else 'import ShippedSessionKit\nlet reader = 1\n'
            (frozen / part / 'Reader.swift').write_text(text)
        scripts = temporary / 'scripts'
        scripts.mkdir()
        shutil.copy(ROOT / 'scripts/freeze-shipped-reader.sh', scripts / 'freeze-shipped-reader.sh')
        # Stands in for the Swift-driven database check, to show whether the chain reached it.
        (scripts / 'check-build29-database.sh').write_text('#!/bin/sh\ntouch "$(dirname "$0")/../database-check-ran"\n')
        for script in scripts.iterdir():
            script.chmod(0o755)
        return temporary

    def run_command(self, tree):
        return subprocess.run(['sh', '-c', verification.SHIPPED_COMPAT_COMMAND], cwd=tree, capture_output=True,
                              text=True, env={**os.environ, 'TMPDIR': str(tree)})

    def test_an_edited_frozen_reader_fails_the_command_and_the_database_check_does_not_run(self):
        tree = self.repo('import SessionKit\nlet reader = 2  // edited after the freeze\n')
        done = self.run_command(tree)
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn('FAIL the frozen SessionKit differs from testflight/0.1-build-29', done.stderr)
        self.assertFalse((tree / 'database-check-ran').exists())

    def test_an_untouched_frozen_reader_goes_on_to_the_database_check(self):
        tree = self.repo('import SessionKit\nlet reader = 1\n')
        done = self.run_command(tree)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue((tree / 'database-check-ran').exists())


if __name__ == '__main__':
    unittest.main()
