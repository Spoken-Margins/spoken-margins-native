"""The host-test run names the file whose hash changed when it fails with "Inputs changed" (#1773).

#1758 failed twice with a bare "Inputs changed during fast verification" and no way to see which of the
thousands of hashed files had changed. The cause was Packages/SessionKit/Package.resolved: the branch had
committed the copy SwiftPM writes on Linux, and the Mac's `swift build` rewrote it mid-run.
"""
import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('verification', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)

RESOLVED = 'Packages/SessionKit/Package.resolved'


def git(root, *args):
    subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)


class InputsChangedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        git(self.root, 'init', '-q')
        for relative, text in {RESOLVED: 'onnxruntime pins\n', 'App/Sources/A.swift': 'a\n', 'README.md': 'readme\n',
                               'project.yml': 'name: x\n', 'docs/plan.md': 'plan\n'}.items():
            (self.root / relative).parent.mkdir(parents=True, exist_ok=True)
            (self.root / relative).write_text(text)
        git(self.root, 'add', '-A')
        patcher = patch.object(verification, 'ROOT', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def message(self, before):
        return verification.inputs_changed_message('Inputs changed during fast verification', before)

    def test_it_names_the_file_a_step_rewrote(self):
        before = verification.input_digests()
        (self.root / RESOLVED).write_text('swift-crypto pins\n')
        message = self.message(before)
        self.assertIn(f'Inputs changed during fast verification: {RESOLVED}.', message)
        self.assertIn('git checkout origin/main -- Packages/SessionKit/Package.resolved', message)

    def test_the_hint_is_only_for_package_resolved(self):
        before = verification.input_digests()
        (self.root / 'App/Sources/A.swift').write_text('changed\n')
        message = self.message(before)
        self.assertEqual(message, 'Inputs changed during fast verification: App/Sources/A.swift')

    def test_it_lists_new_deleted_and_untracked_files_and_counts_the_rest(self):
        before = verification.input_digests()
        (self.root / 'App/Sources/A.swift').unlink()
        for index in range(7):
            (self.root / f'App/Sources/New{index}.swift').write_text('new\n')
        message = self.message(before)
        self.assertEqual(message.count('App/Sources/'), 5)
        self.assertIn('and 3 more', message)
        self.assertIn('App/Sources/A.swift', message)  # sorted: the deleted file comes first

    def test_files_outside_the_hashed_folders_are_ignored(self):
        before = verification.input_digests()
        self.assertEqual(sorted(before), ['App/Sources/A.swift', RESOLVED, 'project.yml'])
        (self.root / 'docs/plan.md').write_text('edited\n')
        (self.root / 'README.md').write_text('edited\n')
        self.assertEqual(verification.input_identity(), self.identity_of(before))
        self.assertIn('no file hash differs', self.message(before))

    def identity_of(self, digests):
        with patch.object(verification, 'input_digests', return_value=digests):
            return verification.input_identity()

    def test_the_identity_changes_with_content_and_with_path(self):
        first = verification.input_identity()
        (self.root / 'project.yml').write_text('name: y\n')
        self.assertNotEqual(verification.input_identity(), first)
        (self.root / 'project.yml').write_text('name: x\n')
        self.assertEqual(verification.input_identity(), first)


if __name__ == '__main__':
    unittest.main()
