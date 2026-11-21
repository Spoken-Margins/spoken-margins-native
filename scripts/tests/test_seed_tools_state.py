"""scripts/seed-sessionkit-tools-state.sh: the tools build reuses SessionKit's binary artifacts (#4664).

On 2026-11-21 the merge queue's Mac job failed in its `tools` step: Packages/SessionKitTools builds into its own scratch
folder (SessionKit/.build/tools), found no state there, and fetched the onnxruntime binary targets again from
download.onnxruntime.ai, whose certificate was invalid, 6 s after the `package` step had passed from the same package's
.build. SwiftPM won't fetch an artifact its workspace state says it has, at the recorded (absolute) path, so the script
copies SessionKit's state into the tools folder when the artifacts it lists are on disk.
"""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts' / 'seed-sessionkit-tools-state.sh'
RUNNER = ROOT / 'scripts' / 'run-sessionkit-tests.sh'


def state(*paths):
    return json.dumps({'version': 6, 'object': {'artifacts': [
        {'packageRef': {'identity': 'onnxruntime-swift-package-manager'}, 'targetName': 'onnxruntime',
         'path': str(path), 'source': {'type': 'remote', 'url': 'https://example.invalid/o.zip', 'checksum': 'abc'}}
        for path in paths], 'dependencies': []}})


class SeedToolsStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.package = Path(self.tmp.name) / 'SessionKit'
        (self.package / '.build').mkdir(parents=True)
        self.tools_state = self.package / '.build' / 'tools' / 'workspace-state.json'

    def run_script(self):
        done = subprocess.run(['bash', str(SCRIPT), str(self.package)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)  # never a reason to stop the build
        return done.stdout

    def artifact(self, name='onnxruntime.xcframework'):
        path = self.package / '.build' / 'artifacts' / 'onnxruntime-swift-package-manager' / name
        path.mkdir(parents=True)
        return path

    def test_it_copies_the_state_when_every_artifact_it_lists_is_on_disk(self):
        text = state(self.artifact())
        (self.package / '.build' / 'workspace-state.json').write_text(text)
        self.assertIn('seeded', self.run_script())
        self.assertEqual(self.tools_state.read_text(), text)

    def test_a_warm_tools_folder_keeps_its_own_state(self):
        (self.package / '.build' / 'workspace-state.json').write_text(state(self.artifact()))
        self.tools_state.parent.mkdir(parents=True)
        self.tools_state.write_text('its own')
        self.assertIn('kept', self.run_script())
        self.assertEqual(self.tools_state.read_text(), 'its own')

    def test_neighbouring_inputs_that_leave_the_folder_alone(self):
        missing = self.package / '.build' / 'artifacts' / 'gone.xcframework'
        for label, text in (('no state file', None), ('an artifact the state lists is not on disk', state(missing)),
                            ('no artifacts listed', state()), ('not JSON', '{oops'), ('empty file', ''),
                            ('an artifact entry with no path', json.dumps({'object': {'artifacts': [{}]}}))):
            with self.subTest(label):
                state_file = self.package / '.build' / 'workspace-state.json'
                state_file.unlink(missing_ok=True)
                if text is not None:
                    state_file.write_text(text)
                self.assertIn('not seeded', self.run_script())
                self.assertFalse(self.tools_state.exists())

    def test_one_missing_artifact_among_present_ones_is_not_seeded(self):
        present = self.artifact()
        (self.package / '.build' / 'workspace-state.json').write_text(
            state(present, self.package / '.build' / 'artifacts' / 'gone.xcframework'))
        self.assertIn('not seeded', self.run_script())
        self.assertFalse(self.tools_state.exists())

    def test_the_tools_run_seeds_before_it_builds(self):
        lines = RUNNER.read_text().splitlines()
        seed = next(i for i, line in enumerate(lines) if 'seed-sessionkit-tools-state.sh' in line and '--tools)' in line)
        build = next(i for i, line in enumerate(lines) if 'SessionKitTools' in line and 'swift test' in line)
        self.assertLess(seed, build)
        self.assertIn('--tools)', lines[seed], 'the seed belongs to the --tools case only')


if __name__ == '__main__':
    unittest.main()
