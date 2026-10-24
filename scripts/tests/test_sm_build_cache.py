"""Host tests for scripts/sm_build_cache.py: a worktree's build folders linked into ~/Library/Caches.

Why: the disk-relief job runs without Full Disk Access and can't read ~/Documents, where every worktree
and, until this, every build folder lived (2026-10-19: about 20 GiB there, "cleared 0 MiB" each run).
"""
import fcntl
import os
from pathlib import Path
import shutil
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
        (self.tree / '.git').write_text('gitdir: /x/.git/worktrees/w1\n')  # a linked worktree
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
        self.assertEqual((slot / 'owner.txt').read_text().splitlines()[0], str(self.tree))
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
            (other / '.git').write_text('gitdir: /x/.git/worktrees/w3\n')
            self.assertEqual(cache.ensure_links(other), [])
            self.assertFalse((other / '.build').exists())

    def test_git_ignores_the_links(self):
        repo = self.documents / 'repo'
        repo.mkdir()
        gitignore = Path(__file__).resolve().parents[2] / '.gitignore'
        (repo / '.gitignore').write_text(gitignore.read_text())
        (repo / 'Packages/SessionKit').mkdir(parents=True)
        (repo / 'Packages/SessionKit/keep').write_text('')
        run = lambda *a: subprocess.run(['git', '-C', str(repo), *a], check=True, capture_output=True)
        run('init', '-q')
        run('add', '.')
        run('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'one')
        tree = self.documents / 'wt'
        run('worktree', 'add', '-q', '--detach', str(tree))
        cache.ensure_links(tree)
        self.assertTrue((tree / '.build').is_symlink())
        status = subprocess.run(['git', '-C', str(tree), 'status', '--porcelain', '--untracked-files=all'],
                                capture_output=True, text=True, check=True).stdout
        self.assertNotIn('.build', status)

    def test_a_main_checkout_or_clone_keeps_its_build_folders(self):
        # The daily phone-plan job runs the main checkout's phone-plan (Packages/SessionKitTools/.build/release,
        # or Packages/SessionKit/.build/release when built before #1873), built once by hand (docs/workstreams/daily-phone-plan.md). Moved into a slot, disk relief would
        # empty it and the 8 am plan would never reach the owner (audit on 2b85624, finding 1).
        main = self.documents / 'GitHub/spoken-margins-native'
        (main / '.git').mkdir()
        release = main / 'Packages/SessionKit/.build/release'
        release.mkdir(parents=True)
        (release / 'phone-plan').write_text('binary')
        self.old(main / 'Packages/SessionKit/.build')
        self.assertEqual(cache.ensure_links(main), [])
        self.assertFalse((main / 'Packages/SessionKit/.build').is_symlink())
        self.assertFalse((main / '.build').exists())
        self.assertFalse(cache.applies_to(main))
        self.assertFalse(cache.applies_to(self.tree.parent / 'not-a-checkout'))
        self.assertTrue(cache.applies_to(self.tree))

    def test_a_new_worktree_at_a_reused_path_gets_an_empty_slot(self):
        # A slot is keyed by path; a removed worktree leaves its slot behind. A new worktree on another
        # branch at the same path must not build against the old one's DerivedData (finding 2).
        cache.ensure_links(self.tree)
        (self.tree / '.build/dd/Build').mkdir(parents=True)
        (self.tree / '.build/dd/Build/blob').write_text('old branch')
        (self.tree / 'Packages/SessionKit/.build/debug').mkdir(parents=True)
        cache.ensure_links(self.tree)
        self.assertTrue((self.tree / '.build/dd/Build/blob').exists(), 'the same worktree lost its build')
        first_inode = os.stat(self.tree).st_ino
        shutil.rmtree(self.tree)
        # The slot knows a worktree by path and directory inode. APFS does not hand a freed inode back, but ext4 and
        # tmpfs do at once (the cloud and the VPS runner), which made this recreated worktree look like the old
        # one (#2215). Park each directory that got the old inode aside, so the new worktree gets another.
        parked = 0
        while True:
            self.tree.mkdir(parents=True, exist_ok=True)
            if os.stat(self.tree).st_ino != first_inode:
                break
            parked += 1
            self.tree.rename(self.tree.parent / f'parked-{parked}')
        (self.tree / 'Packages/SessionKit').mkdir(parents=True)
        (self.tree / '.git').write_text('gitdir: /x/.git/worktrees/w1\n')
        cache.ensure_links(self.tree)
        self.assertTrue((self.tree / '.build').is_symlink())
        self.assertEqual(list((self.tree / '.build').iterdir()), [])
        self.assertEqual(list((self.tree / 'Packages/SessionKit/.build').iterdir()), [])

    def test_a_slot_written_before_identities_is_adopted_not_emptied(self):
        slot = cache.slot_for(self.tree)
        (slot / 'root/dd').mkdir(parents=True)
        (slot / 'sessionkit').mkdir()
        (slot / 'owner.txt').write_text(str(self.tree) + '\n')
        (self.tree / '.build').symlink_to(slot / 'root', target_is_directory=True)
        cache.ensure_links(self.tree)
        self.assertTrue((slot / 'root/dd').is_dir())
        self.assertEqual(cache.ensure_links(self.tree), [])
        self.assertTrue((slot / 'root/dd').is_dir())

    def test_a_link_made_by_a_parallel_build_is_taken_as_done(self):
        # The simulator and device builds started together in a fresh worktree: the second one's
        # symlink call finds the first one's link (finding 4).
        real_symlink = os.symlink

        def racing(src, dst, *args, **kwargs):
            real_symlink(src, dst, *args, **kwargs)
            raise FileExistsError(17, 'File exists', str(dst))

        with mock.patch('os.symlink', side_effect=racing):
            results = dict(cache.ensure_links(self.tree))
        self.assertTrue((self.tree / '.build').is_symlink())
        self.assertIn('linked', results[self.tree / '.build'])

if __name__ == '__main__':
    unittest.main()
