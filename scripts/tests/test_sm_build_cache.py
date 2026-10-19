"""Host tests for scripts/sm_build_cache.py: a worktree's build folders linked into ~/Library/Caches.

Why: the disk-relief job runs without Full Disk Access and can't read ~/Documents, where every worktree
and, until this, every build folder lived (2026-10-19: about 20 GiB there, "cleared 0 MiB" each run).
"""
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sm_build_cache as cache  # noqa: E402


class BuildCacheLinks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(os.path.realpath(self.temporary.name))
        self.documents = root / 'Documents'
        self.caches = root / 'Caches/SpokenMarginsBuilds'
        self.tree = self.documents / 'GitHub/spoken-margins-native/.claude/worktrees/w1'
        (self.tree / 'Packages/SessionKit').mkdir(parents=True)
        env = {'SM_BUILD_CACHE_ROOT': str(self.caches), 'SM_BUILD_CACHE_UNDER': str(self.documents),
               'SM_BUILD_CACHE': ''}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop('GITHUB_ACTIONS', None)

    def tearDown(self):
        self.temporary.cleanup()

    def old(self, folder: Path, age: float = 3600) -> None:
        t = time.time() - age
        for dirpath, dirs, files in os.walk(folder):
            for name in dirs + files:
                os.utime(os.path.join(dirpath, name), (t, t))
        os.utime(folder, (t, t))

    def test_links_both_folders_into_one_slot_per_worktree(self):
        cache.ensure_links(self.tree)
        slot = cache.slot_for(self.tree)
        self.assertEqual(Path(os.path.realpath(self.tree / '.build')), slot / 'root')
        self.assertEqual(Path(os.path.realpath(self.tree / 'Packages/SessionKit/.build')), slot / 'sessionkit')
        self.assertEqual((slot / 'owner.txt').read_text().strip(), str(self.tree))
        (self.tree / '.build/dd').mkdir()
        self.assertTrue((slot / 'root/dd').is_dir())
        self.assertEqual(cache.ensure_links(self.tree), [], 'a second call changed something')
        other = self.tree.parent / 'w2'
        self.assertNotEqual(cache.slot_for(other), slot, 'two worktrees would share DerivedData')

    def test_codex_style_paths_keep_their_id_in_the_slot_name(self):
        a = cache.slot_name(Path('/x/.codex/worktrees/0642/spoken-margins-native'))
        b = cache.slot_name(Path('/x/.codex/worktrees/78e2/spoken-margins-native'))
        self.assertTrue(a.startswith('0642-spoken-margins-native-'), a)
        self.assertNotEqual(a, b)

    def test_a_cleared_slot_is_put_back(self):
        cache.ensure_links(self.tree)
        slot = cache.slot_for(self.tree)
        (slot / 'root').rmdir()
        (slot / 'sessionkit').rmdir()
        cache.ensure_links(self.tree)
        self.assertTrue((self.tree / '.build').is_dir() and (self.tree / 'Packages/SessionKit/.build').is_dir())

    def test_an_idle_real_folder_moves_in_and_a_busy_one_stays(self):
        build = self.tree / '.build/dd/Build'
        build.mkdir(parents=True)
        (build / 'blob').write_text('built')
        self.old(self.tree / '.build')
        swiftpm = self.tree / 'Packages/SessionKit/.build/debug'
        swiftpm.mkdir(parents=True)
        (swiftpm / 'fresh').write_text('building now')
        results = dict(cache.ensure_links(self.tree))
        self.assertTrue((self.tree / '.build').is_symlink())
        self.assertEqual((self.tree / '.build/dd/Build/blob').read_text(), 'built')
        self.assertFalse((self.tree / 'Packages/SessionKit/.build').is_symlink())
        self.assertIn('10 minutes', results[self.tree / 'Packages/SessionKit/.build'])

    def test_a_folder_verify_tests_holds_stays(self):
        (self.tree / '.build').mkdir()
        lock = self.tree / '.build/verification.lock'
        lock.write_text('')
        self.old(self.tree / '.build')
        with lock.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            results = dict(cache.ensure_links(self.tree))
        self.assertFalse((self.tree / '.build').is_symlink())
        self.assertIn('verify-tests', results[self.tree / '.build'])

    def test_lane_links_outside_trees_and_the_off_switch_are_left_alone(self):
        lane = self.documents.parent / 'lane-warm/root'
        lane.mkdir(parents=True)
        (self.tree / '.build').symlink_to(lane, target_is_directory=True)
        cache.ensure_links(self.tree)
        self.assertEqual(Path(os.path.realpath(self.tree / '.build')), lane)
        runner = self.documents.parent / 'actions-runner/_work/spoken-margins-native'
        runner.mkdir(parents=True)
        self.assertEqual(cache.ensure_links(runner), [])
        self.assertFalse((runner / '.build').exists())
        with mock.patch.dict(os.environ, {'SM_BUILD_CACHE': 'off'}):
            other = self.tree.parent / 'w3'
            other.mkdir()
            self.assertEqual(cache.ensure_links(other), [])
            self.assertFalse((other / '.build').exists())

    def test_git_ignores_the_links(self):
        repo = self.documents / 'repo'
        (repo / 'Packages/SessionKit').mkdir(parents=True)
        gitignore = Path(__file__).resolve().parents[2] / '.gitignore'
        (repo / '.gitignore').write_text(gitignore.read_text())
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        cache.ensure_links(repo)
        status = subprocess.run(['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=all'],
                                capture_output=True, text=True, check=True).stdout
        self.assertNotIn('.build', status)


if __name__ == '__main__':
    unittest.main()
