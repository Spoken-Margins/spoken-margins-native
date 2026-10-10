import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import sessionkit_pass as sk  # noqa: E402

ROOT = SCRIPTS.parent

# Literals in the SessionKit sources and tests that start with a repository folder's name but don't read the
# repository root's folder of that name (#1328). Each is relative to something else, or isn't a path at all.
NOT_REPOSITORY_READS = {
    'references': 'a heading word the Obsidian parser drops',
    'scripts/run.sh': 'a zip entry name in a packet-rejection test',
}


def git(root, *args):
    subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)


def make_repo(root):
    root = Path(root)
    git(root, 'init', '-q')
    files = {path: 'x' for path in (
        'Packages/SessionKit/Sources/SessionKit/A.swift', 'Packages/SessionKit/Package.swift',
        'Contracts/fixtures/a.json', 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift',
        'App/SpokenMarginsAppTests/T.swift', 'App/SpokenMarginsApp/Resources/Supertonic/asset-manifest.json',
        'research/B2/f.json', 'research/B4/v.json', 'fixtures/maps/m.json', 'Site/onboarding/catalog/v1/catalog.json', 'README.md',
        'traces/t.json', 'scripts/run-sessionkit-tests.sh', 'scripts/host-test-lane', 'scripts/verify-tests.py',
        'scripts/sessionkit_pass.py',
        # Not read by the package tests:
        'docs/a.md', 'App/Gate2Shared/G.swift', 'App/SpokenMarginsApp/Info.plist', 'ops/codex/x.py',
        'scripts/lane-runner.py', 'research/B1/n.md', 'Site/index.html', 'project.yml')}
    for relative, text in files.items():
        (root / relative).parent.mkdir(parents=True, exist_ok=True)
        (root / relative).write_text(text)
    git(root, 'add', '-A')
    return root, sorted(files)


class InputsTests(unittest.TestCase):
    def test_a_change_to_anything_the_package_tests_read_changes_the_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, files = make_repo(temporary)
            base = sk.key(root, 'swift 6')
            self.assertEqual(len(base), 64)
            reads = [f for f in files if f.startswith(sk.READS) or f in sk.RUNNERS]
            self.assertGreaterEqual(len(reads), 15)
            for relative in reads:
                with self.subTest(relative):
                    path = root / relative
                    path.write_text('changed')
                    self.assertNotEqual(sk.key(root, 'swift 6'), base)
                    path.write_text('x')
                    self.assertEqual(sk.key(root, 'swift 6'), base)

    def test_new_deleted_and_untracked_files_in_the_inputs_change_the_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, _ = make_repo(temporary)
            base = sk.key(root, 'swift 6')
            for relative in ('Packages/SessionKit/Tests/SessionKitTests/New.swift', 'Contracts/fixtures/new.json',
                             'research/B2/new.json', 'App/SpokenMarginsAppTests/New.swift'):
                with self.subTest(relative):
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('new')  # untracked
                    self.assertNotEqual(sk.key(root, 'swift 6'), base)
                    git(root, 'add', relative)  # staged: same content, same key
                    staged = sk.key(root, 'swift 6')
                    self.assertNotEqual(staged, base)
                    git(root, 'rm', '-qf', relative)
                    self.assertEqual(sk.key(root, 'swift 6'), base)
            (root / 'Contracts/fixtures/a.json').unlink()  # tracked file deleted in the working tree
            self.assertNotEqual(sk.key(root, 'swift 6'), base)

    def test_changes_nothing_reads_leave_the_key_alone(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, files = make_repo(temporary)
            base = sk.key(root, 'swift 6')
            for relative in ('docs/a.md', 'App/Gate2Shared/G.swift', 'App/SpokenMarginsApp/Info.plist', 'ops/codex/x.py',
                             'scripts/lane-runner.py', 'research/B1/n.md', 'Site/index.html', 'project.yml'):
                with self.subTest(relative):
                    self.assertFalse(relative.startswith(sk.READS) or relative in sk.RUNNERS)
                    (root / relative).write_text('changed')
                    self.assertEqual(sk.key(root, 'swift 6'), base)
            (root / 'docs/new.md').write_text('new')
            self.assertEqual(sk.key(root, 'swift 6'), base)

    def test_the_toolchain_is_part_of_the_key_and_an_unknown_one_means_no_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, _ = make_repo(temporary)
            self.assertNotEqual(sk.key(root, 'swift 6.0'), sk.key(root, 'swift 6.1'))
            self.assertIsNone(sk.key(root, None))
            self.assertIsNone(sk.key(root, ''))

    def test_a_folder_with_no_inputs_has_no_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            git(temporary, 'init', '-q')
            self.assertIsNone(sk.key(temporary, 'swift 6'))
            self.assertIsNone(sk.key(Path(temporary) / 'missing', 'swift 6'))

    def test_toolchain_reads_swift_and_says_none_when_it_cannot(self):
        class Done:
            returncode, stdout, stderr = 0, 'Apple Swift version 6.2\nTarget: arm64-apple-macosx15.0', ''
        identity = sk.toolchain(run=lambda *a, **k: Done())
        self.assertIn('Apple Swift version 6.2', identity)
        Done.returncode = 1
        self.assertIsNone(sk.toolchain(run=lambda *a, **k: Done()))

        def missing(*a, **k):
            raise FileNotFoundError('swift')
        self.assertIsNone(sk.toolchain(run=missing))


class RecordTests(unittest.TestCase):
    def test_a_recorded_pass_is_found_by_its_key_only(self):
        with tempfile.TemporaryDirectory() as state:
            self.assertIsNone(sk.find(state, 'a' * 64))
            written = sk.record(state, 'a' * 64, head='abc1234', tests=900)
            self.assertEqual(sk.find(state, 'a' * 64), written)
            self.assertEqual(written['tests'], 900)
            self.assertIsNone(sk.find(state, 'b' * 64))
            self.assertIsNone(sk.find(state, None))
            self.assertIsNone(sk.record(state, None, head='x'))

    def test_a_damaged_or_mismatched_record_is_no_pass(self):
        with tempfile.TemporaryDirectory() as state:
            folder = sk.passes_dir(state)
            folder.mkdir(parents=True)
            for text in ('', 'not json', '[]', json.dumps({'key': 'other'})):
                (folder / f'{"c" * 64}.json').write_text(text)
                self.assertIsNone(sk.find(state, 'c' * 64), text)

    def test_only_the_newest_records_are_kept(self):
        with tempfile.TemporaryDirectory() as state, patch.object(sk, 'KEEP', 3):
            for index in range(6):
                key = str(index) * 64
                sk.record(state, key, head=str(index))
                os.utime(sk.passes_dir(state) / f'{key}.json', (1000 + index, 1000 + index))
            kept = sorted(path.stem[0] for path in sk.passes_dir(state).glob('*.json'))
            self.assertEqual(kept, ['3', '4', '5'])

    def test_recording_into_an_unwritable_place_fails_quietly(self):
        with tempfile.TemporaryDirectory() as temporary:
            blocker = Path(temporary) / 'file'
            blocker.write_text('not a folder')
            self.assertIsNone(sk.record(blocker, 'a' * 64, head='x'))


class ReaderGuardTests(unittest.TestCase):
    """The key is only as good as READS. Every path the SessionKit sources and tests name that starts with one of the
    repository's top-level folders or files has to be inside READS, or be listed above as not a repository read."""

    def test_every_repository_path_the_package_names_is_an_input(self):
        names = subprocess.check_output(['git', 'ls-tree', '--name-only', 'HEAD'], cwd=ROOT, text=True).split()
        folders = set(subprocess.check_output(['git', 'ls-tree', '-d', '--name-only', 'HEAD'], cwd=ROOT,
                                              text=True).split())
        uncovered = {}
        for path in sorted((ROOT / 'Packages/SessionKit').rglob('*.swift')):
            if '.build' in path.parts:
                continue
            for literal in re.findall(r'"((?:[^"\\\n]|\\.)*)"', path.read_text(errors='replace')):
                first = literal.split('/')[0]
                if not (first in folders or literal in names) or literal in sk.READS:
                    continue
                if any((literal + '/').startswith(read) or literal.startswith(read) for read in sk.READS):
                    continue
                if any(literal == exempt or literal.startswith(exempt + '/') for exempt in NOT_REPOSITORY_READS):
                    continue
                uncovered.setdefault(literal, path.name)
        self.assertEqual(uncovered, {}, 'the SessionKit tests name repository paths that sessionkit_pass.READS does not '
                         'cover: add the path to READS, or to NOT_REPOSITORY_READS here with the reason it is not a read')

    def test_every_read_exists_in_the_repository(self):
        tracked = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=ROOT,
                                          text=True).split('\n')
        for read in (*sk.READS, *sk.RUNNERS):
            with self.subTest(read):
                self.assertTrue(any(path == read or path.startswith(read) for path in tracked), read)


if __name__ == '__main__':
    unittest.main()
