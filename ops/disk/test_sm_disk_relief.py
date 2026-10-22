"""Host tests for disk relief. Temp folders only; copies use the real /usr/bin/rsync.

Run: python3 -m unittest ops/disk/test_sm_disk_relief.py
"""
import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import fcntl
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_disk_relief as d  # noqa: E402
import sm_lane_prune as lane_prune  # noqa: E402
import sm_build_cache  # noqa: E402
from unittest import mock  # noqa: E402

MiB = 1024 ** 2
# The fake clock and expected offload folders must agree after October 1 too.
NOW = time.mktime((2026, 10, 1, 12, 0, 0, 0, 0, -1))
DAY = 86400


def write(path: Path, size: int = 1024, age: float = 0) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(size))
    if age:
        os.utime(path, (NOW - age, NOW - age))
    return path


def age_tree(path: Path, age: float) -> None:
    t = NOW - age
    for dirpath, dirs, files in os.walk(path):
        for name in files + dirs:
            os.utime(os.path.join(dirpath, name), (t, t), follow_symlinks=False)
    os.utime(path, (t, t))


def git(cwd: Path, *args) -> None:
    subprocess.run(['git', '-C', str(cwd), *args], check=True, capture_output=True,
                   env={**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t', 'GIT_COMMITTER_NAME': 't',
                        'GIT_COMMITTER_EMAIL': 't@t'})


class FakeMachine(d.Machine):
    """The real machine, except the clock, processes, mounts and the data volume's free space.
    Free space on the data volume follows what is deleted under the fake home."""

    def __init__(self, cfg: d.Config, base_free: int, procs=None, mounted=None, drive_free=None,
                 live_pids=(), copy=None, frozen_free=False, now=NOW, snapshots=(), backup=False,
                 undeletable=(), open_prs=None):
        self.cfg = cfg
        self.open_prs = open_prs
        self.base_free = base_free
        self.initial_used = d.tree_stats(cfg.home).disk_bytes
        self.procs = procs or []
        self.mounted = {cfg.drive, cfg.mirror} if mounted is None else set(mounted)
        self.drive_free = drive_free or {}
        self.live_pids = set(live_pids)
        self.copy_override = copy
        self.frozen_free = frozen_free
        self.notes = []
        self.clock = now
        self.snapshots = list(snapshots)
        self.backup = backup
        self.undeletable = set(undeletable)
        self.deleted_snapshots = []

    def now(self):
        return self.clock

    def open_pull_requests(self, repo):
        return self.open_prs

    def snapshot_dates(self, volume):
        return list(self.snapshots)

    def backup_running(self):
        return self.backup

    def delete_snapshot(self, date):
        if date in self.undeletable:
            return False
        self.snapshots.remove(date)
        self.deleted_snapshots.append(date)
        return True

    def free_bytes(self, path):
        if Path(path) == self.cfg.data_volume:
            if self.frozen_free:
                return self.base_free
            return self.base_free + self.initial_used - d.tree_stats(self.cfg.home).disk_bytes
        return self.drive_free.get(Path(path), 500 * d.GiB)

    def is_mounted(self, path):
        return Path(path) in self.mounted

    def processes(self):
        return list(self.procs)

    def pid_alive(self, pid):
        return pid in self.live_pids

    def copy(self, src, dst):
        if self.copy_override:
            return self.copy_override(src, dst)
        return super().copy(src, dst)

    def notify(self, title, message):
        self.notes.append((title, message))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(os.path.realpath(self.tmp.name))
        home = root / 'home'
        home.mkdir()
        (root / 'drive').mkdir()
        (root / 'mirror').mkdir()
        self.cfg = d.Config(
            home=home,
            repo=home / 'Documents/GitHub/spoken-margins-native',
            checkout_glob=str(home / 'Documents/GitHub/spoken-margins-native*'),
            data_volume=home,
            drive=root / 'drive',
            mirror=root / 'mirror',
            ops_dir=home / 'SpokenMarginsOps/disk-relief',
            phone_dir=home / 'SpokenMargins-phone',
            device_support=home / 'Library/Developer/Xcode/iOS DeviceSupport',
            launch_agents=home / 'Library/LaunchAgents',
            claude_projects=home / '.claude/projects',
            codex_sessions=home / '.codex/sessions',
            codex_worktrees=home / '.codex/worktrees',
            build_cache_dir=home / 'Library/Caches/SpokenMarginsBuilds',
            claude_tmp=home / 'tmp/claude-501',
            claude_sessions=home / '.claude/sessions',
            tmp_root=home / 'tmp',
            own_session=None,
            lane_dir=home / 'Library/Caches/SpokenMarginsLane',
            trigger_bytes=100 * MiB,
            target_bytes=104 * MiB,
        )
        self.log = d.Log(None, echo=False)

    def tearDown(self):
        self.tmp.cleanup()

    def make_repo(self, *worktrees):
        repo = self.cfg.repo
        repo.mkdir(parents=True, exist_ok=True)
        git(repo, 'init', '-q', '-b', 'main')
        write(repo / 'README.md', 10)
        (repo / '.gitignore').write_text('.build/\nartifacts/\nPackages/SessionKit/.build/\n.venv\nnode_modules\n.swiftpm\n')
        git(repo, 'add', '.')
        git(repo, 'commit', '-qm', 'one')
        git(repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        paths = []
        for name in worktrees:
            path = repo / '.claude/worktrees' / name
            git(repo, 'worktree', 'add', '-q', '--detach', str(path))
            paths.append(path)
        return repo, paths

    def cache(self, worktree: Path, size: int, sub='.build/dd', age=DAY) -> Path:
        folder = worktree / sub
        write(folder / 'Build/blob', size)
        age_tree(folder, age)
        return folder


class Thresholds(Base):
    def test_acts_only_below_the_trigger(self):
        self.assertTrue(d.should_run(self.cfg.trigger_bytes - 1, self.cfg))
        self.assertFalse(d.should_run(self.cfg.trigger_bytes, self.cfg))

    def test_above_the_trigger_does_nothing(self):
        _, (w,) = self.make_repo('a')
        c = self.cache(w, MiB)
        m = FakeMachine(self.cfg, base_free=self.cfg.trigger_bytes)
        result = d.run(self.cfg, m, self.log)
        self.assertFalse(result.acted)
        self.assertTrue(c.exists())

    def test_without_the_drive_caches_still_go_and_moves_wait(self):
        # 2026-10-04 to 10-09 every run logged "did nothing" because SlawBulk was unplugged or
        # unwritable, while free space fell to 16.9 GiB: deleting caches needs no drive (#1211).
        _, (w,) = self.make_repo('a')
        c = self.cache(w, MiB)
        evidence = write(self.cfg.repo / 'artifacts/lane/full-old/report.md', 1000).parent
        age_tree(evidence, 5 * DAY)
        m = FakeMachine(self.cfg, base_free=10 * MiB, mounted=[])
        result = d.run(self.cfg, m, self.log)
        self.assertTrue(result.acted)
        self.assertFalse(c.exists())
        self.assertTrue(evidence.exists(), 'moved evidence without the drive')
        self.assertTrue(any('moves skipped' in line and 'not mounted' in line for line in self.log.lines),
                        self.log.lines)

    def test_default_trigger_leaves_room_for_a_build(self):
        cfg = d.Config()
        self.assertGreaterEqual(cfg.trigger_bytes, 50 * d.GiB, 'one app build takes 8 to 9 GiB')
        self.assertGreater(cfg.target_bytes, cfg.trigger_bytes)

    def test_stops_once_free_space_reaches_the_target(self):
        _, (a, b, c) = self.make_repo('a', 'b', 'c')
        big = self.cache(a, 3 * MiB)
        mid = self.cache(b, 2 * MiB)
        small = self.cache(c, 1 * MiB)
        # 99 MiB free; target 104 MiB: the 3 and 2 MiB caches reach it, the 1 MiB one stays.
        m = FakeMachine(self.cfg, base_free=99 * MiB)
        result = d.run(self.cfg, m, self.log)
        self.assertFalse(big.exists())
        self.assertFalse(mid.exists())
        self.assertTrue(small.exists())
        self.assertTrue(result.acted)
        self.assertEqual(len(m.notes), 1)

    def test_stops_by_its_own_count_when_a_snapshot_holds_the_space(self):
        _, (a, b, c) = self.make_repo('a', 'b', 'c')
        self.cache(a, 3 * MiB)
        self.cache(b, 2 * MiB)
        small = self.cache(c, 1 * MiB)
        m = FakeMachine(self.cfg, base_free=99 * MiB, frozen_free=True)
        d.run(self.cfg, m, self.log)
        self.assertTrue(small.exists(), 'kept clearing although it had already cleared enough')
        self.assertTrue(any('local snapshot' in line for line in self.log.lines))

    def test_second_run_waits_for_the_lock(self):
        self.cfg.ops_dir.mkdir(parents=True)
        with open(self.cfg.lock_file, 'a+') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            m = FakeMachine(self.cfg, base_free=10 * MiB)
            result = d.locked_run(self.cfg, m, self.log)
        self.assertIn('lock', result.reason)
        self.assertFalse(result.acted)


class Idle(Base):
    def test_busy_worktrees_from_processes_and_locks(self):
        repo, (a, b, nested_parent) = self.make_repo('a', 'b', 'c')
        trees = [d.Worktree(repo), d.Worktree(a), d.Worktree(b, locked='claude agent x (pid 42 start Thu)'),
                 d.Worktree(nested_parent)]
        procs = [
            d.Proc(1, str(a / 'App'), 'zsh'),
            d.Proc(2, '/', f'xcodebuild -project X -derivedDataPath {nested_parent}/.build/dd build'),
            d.Proc(3, '/', f'vim {repo}/README.md'),
        ]
        m = FakeMachine(self.cfg, 0, live_pids={42})
        busy = d.busy_worktrees(trees, procs, m)
        self.assertIn(a, busy)
        self.assertIn(b, busy)
        self.assertIn(nested_parent, busy)
        self.assertNotIn(repo, busy, 'a nested worktree or a non-build command made the main checkout busy')
        m.live_pids = set()
        self.assertNotIn(b, d.busy_worktrees(trees, [], m), 'a dead agent\'s lock still counted')

    def test_busy_or_recent_caches_are_skipped(self):
        _, (a, b, c) = self.make_repo('a', 'b', 'c')
        busy = self.cache(a, MiB)
        recent = self.cache(b, MiB, age=10 * 60)
        idle = self.cache(c, MiB)
        swiftpm = self.cache(c, MiB, sub='Packages/SessionKit/.build')
        write(c / '.build/verification.lock', 0)
        m = FakeMachine(self.cfg, 0, procs=[d.Proc(7, str(a), 'claude')])
        plan = d.make_plan(self.cfg, m)
        paths = {x.path for x in plan.candidates}
        self.assertEqual(paths, {idle, swiftpm})
        self.assertNotIn(recent, paths)
        self.assertNotIn(busy, paths)


class NoAccess(Base):
    """The job runs without Full Disk Access by the owner's choice, so macOS refuses it some folders.
    2026-10-11 to 10-14 one refused .build folder crashed every run before anything was freed."""

    def lock(self, folder: Path) -> None:
        folder.chmod(0)
        # Before tearDown removes the temporary folder (cleanups run after tearDown).
        self.restore = getattr(self, 'restore', []) + [folder]

    def tearDown(self):
        for folder in getattr(self, 'restore', []):
            if folder.exists():
                folder.chmod(0o755)
        super().tearDown()

    def test_an_unreadable_build_folder_is_skipped_and_the_rest_still_goes(self):
        _, (blocked, free) = self.make_repo('a', 'b')
        kept = self.cache(blocked, MiB)
        gone = self.cache(free, MiB)
        self.lock(blocked / '.build')
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        result = d.run(self.cfg, m, self.log)
        self.assertTrue(result.acted)
        self.assertFalse(gone.exists())
        blocked.joinpath('.build').chmod(0o755)
        self.assertTrue(kept.exists())
        self.assertTrue(any(line.startswith('skip caches in') and str(blocked) in line and 'Full Disk Access' in line
                            for line in self.log.lines), self.log.lines)

    def test_an_unreadable_folder_in_one_step_does_not_stop_the_others(self):
        _, (w,) = self.make_repo('a')
        gone = self.cache(w, MiB)
        project = self.cfg.claude_tmp / '-Users-someone-Documents-x'
        project.mkdir(parents=True)
        self.lock(project)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        result = d.run(self.cfg, m, self.log)
        self.assertTrue(result.acted)
        self.assertFalse(gone.exists())
        self.assertTrue(any(line.startswith('skip session scratch') and 'Full Disk Access' in line
                            for line in self.log.lines), self.log.lines)


class NeverTouch(Base):
    def test_runner_dirs_come_from_their_launch_agents(self):
        agents = self.cfg.launch_agents
        agents.mkdir(parents=True)
        runner = self.cfg.home / 'actions-runner-x'
        (agents / 'actions.runner.o-r.n.plist').write_bytes(plistlib.dumps(
            {'WorkingDirectory': str(runner), 'ProgramArguments': [str(runner / 'runsvc.sh')]}))
        self.assertIn(runner, d.runner_dirs(agents))
        protected = self.cfg.protected()
        self.assertTrue(d.is_protected(runner / '_work/repo/.build/dd', protected))
        self.assertFalse(d.is_protected(self.cfg.home / '.codex/worktrees/x/.build', protected),
                         'owner, 2026-10-19: Codex worktrees follow the same rules as Claude\'s')
        self.assertTrue(d.is_protected(self.cfg.home / 'Library/Developer/CoreSimulator/Devices/U', protected))
        self.assertTrue(d.is_protected(self.cfg.home / 'Library', protected), 'a parent of a protected path')
        self.assertFalse(d.is_protected(self.cfg.repo / '.build/dd', protected))

    def test_forced_candidates_in_protected_folders_are_refused(self):
        sim = write(self.cfg.home / 'Library/Developer/CoreSimulator/Devices/U/data', MiB)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.Plan(candidates=[d.Candidate('cache', sim.parent, MiB, 'forced')])
        d.execute(self.cfg, m, plan, self.log, 10 * MiB)
        self.assertTrue(sim.exists())


class Selection(Base):
    def phone(self, *names):
        for n in names:
            write(self.cfg.phone_dir / n / 'build.json', 10)

    def test_phone_builds_keep_latest_installed_and_newest_two(self):
        self.phone('20260920-100000-aaaaaaa', '20260925-100000-bbbbbbb', '20260927-100000-ccccccc',
                   '20260930-100000-ddddddd', '20261001-100000-eeeeeee')
        os.symlink('20260925-100000-bbbbbbb', self.cfg.phone_dir / 'latest')
        (self.cfg.phone_dir / 'installed.txt').write_text('ccccccc1234567890abcdef1234567890abcdef1 2026-10-01T05:59 phone\n')
        moved = [p.name for p in d.phone_builds_to_move(self.cfg.phone_dir)]
        self.assertEqual(moved, ['20260920-100000-aaaaaaa'])

    def test_phone_builds_without_installed_or_latest(self):
        self.phone('20260920-100000-aaaaaaa', '20260925-100000-bbbbbbb', '20260927-100000-ccccccc')
        write(self.cfg.phone_dir / 'notes', 10)
        moved = [p.name for p in d.phone_builds_to_move(self.cfg.phone_dir)]
        self.assertEqual(moved, ['20260920-100000-aaaaaaa'])

    def test_artifact_age_filter_looks_one_level_into_busy_folders(self):
        art = self.cfg.repo / 'artifacts'
        old = art / 'velocity'
        write(old / 'x.json', 10)
        age_tree(old, 3 * DAY)
        young = art / 'briefings'
        write(young / 'y.md', 10)
        age_tree(young, 1 * DAY)
        lane = art / 'lane'
        write(lane / 'full-old/report.md', 10)
        age_tree(lane / 'full-old', 5 * DAY)
        write(lane / 'integration-new/report.md', 10)
        write(art / 'loose.log', 10, age=9 * DAY)
        picked = d.artifact_folders(art, NOW - d.ARTIFACT_AGE_SECONDS)
        self.assertEqual(picked, [lane / 'full-old', old])

    def test_session_log_age_filter(self):
        old = write(self.cfg.claude_projects / 'p/old.jsonl', 10, age=4 * DAY)
        write(self.cfg.claude_projects / 'p/new.jsonl', 10, age=1 * DAY)
        write(self.cfg.claude_projects / 'p/sess/subagents/deep.jsonl', 10, age=9 * DAY)
        codex_old = write(self.cfg.codex_sessions / '2026/09/20/rollout-1.jsonl', 10, age=11 * DAY)
        write(self.cfg.codex_sessions / '2026/09/30/rollout-2.jsonl', 10, age=1 * DAY)
        self.assertEqual(d.session_logs(self.cfg, NOW - d.SESSION_LOG_AGE_SECONDS), [old, codex_old])

    def test_device_support_keeps_the_newest_and_the_highest_version(self):
        ds = self.cfg.device_support
        a = write(ds / 'iPhone18,1 26.5 (23F1)/s', 10).parent
        b = write(ds / 'iPhone18,1 27.0 (24A437)/s', 10).parent
        c = write(ds / 'iPad16,3 26.4 (23E1)/s', 10).parent
        age_tree(a, 9 * DAY)
        age_tree(b, 5 * DAY)
        age_tree(c, 1 * DAY)
        plan = d.Plan()
        d.plan_device_support(self.cfg, [], self.cfg.protected(), plan)
        self.assertEqual([x.path for x in plan.candidates], [a])


class Moves(Base):
    def setUp(self):
        super().setUp()
        self.src = self.cfg.repo / 'artifacts/lane/full-old'
        write(self.src / 'report.md', 3000)
        write(self.src / 'logs/run.log', 5000)
        os.symlink('report.md', self.src / 'link')
        age_tree(self.src, 5 * DAY)
        self.rel = Path('Documents/GitHub/spoken-margins-native/artifacts/lane/full-old')
        self.primary = self.cfg.drive / 'Codex-Offload' / '2026-10-01-disk-relief'
        self.mirror = self.cfg.mirror / 'Current/SlawBulk/Codex-Offload/2026-10-01-disk-relief'

    def test_move_copies_to_both_disks_checks_and_then_deletes(self):
        m = FakeMachine(self.cfg, 0)
        ok, message = d.move_verified(self.cfg, m, self.src, '2026-10-01', mirror=True)
        self.assertTrue(ok, message)
        self.assertFalse(self.src.exists())
        for root in (self.primary, self.mirror):
            copy = root / self.rel
            self.assertEqual((copy / 'logs/run.log').stat().st_size, 5000)
            self.assertTrue((copy / 'link').is_symlink())
            self.assertFalse(Path(str(copy) + '.partial').exists())
            self.assertIn(str(self.src), (root / 'MANIFEST.txt').read_text())
        self.assertIn(str(self.primary / self.rel), (self.src.parent / 'MOVED-TO-SLAWBULK.txt').read_text())

    def test_a_copy_missing_a_file_keeps_the_source(self):
        def lossy(src, dst):
            ok = d.Machine().copy(src, dst)
            (dst / 'logs/run.log').unlink()
            return ok
        m = FakeMachine(self.cfg, 0, copy=lossy)
        ok, message = d.move_verified(self.cfg, m, self.src, '2026-10-01', mirror=True)
        self.assertFalse(ok)
        self.assertIn('does not match', message)
        self.assertTrue((self.src / 'logs/run.log').exists())
        self.assertFalse((self.primary / self.rel).exists(), 'an unchecked copy got its final name')

    def test_a_failed_mirror_copy_keeps_the_source(self):
        calls = []

        def second_fails(src, dst):
            calls.append(dst)
            return len(calls) == 1 and d.Machine().copy(src, dst)
        m = FakeMachine(self.cfg, 0, copy=second_fails)
        ok, _ = d.move_verified(self.cfg, m, self.src, '2026-10-01', mirror=True)
        self.assertFalse(ok)
        self.assertTrue(self.src.exists())

    def test_a_source_that_changes_during_the_copy_is_kept(self):
        def copy_then_touch(src, dst):
            ok = d.Machine().copy(src, dst)
            write(src / 'late.txt', 10)
            return ok
        m = FakeMachine(self.cfg, 0, copy=copy_then_touch)
        ok, message = d.move_verified(self.cfg, m, self.src, '2026-10-01', mirror=False)
        self.assertFalse(ok)
        self.assertIn('changed during the copy', message)
        self.assertTrue((self.src / 'late.txt').exists())

    def test_a_second_move_of_the_same_path_does_not_overwrite(self):
        m = FakeMachine(self.cfg, 0)
        self.assertTrue(d.move_verified(self.cfg, m, self.src, '2026-10-01', mirror=False)[0])
        write(self.src / 'report.md', 10)
        self.assertTrue(d.move_verified(self.cfg, m, self.src, '2026-10-01', mirror=False)[0])
        self.assertTrue((self.primary / (str(self.rel) + '~2') / 'report.md').exists())
        self.assertEqual((self.primary / self.rel / 'report.md').stat().st_size, 3000)

    def test_session_logs_get_no_pointer_file(self):
        log = write(self.cfg.claude_projects / 'p/old.jsonl', 100, age=4 * DAY)
        m = FakeMachine(self.cfg, 0)
        self.assertTrue(d.move_verified(self.cfg, m, log, '2026-10-01', mirror=False)[0])
        self.assertEqual(list(log.parent.iterdir()), [])

    def test_without_the_mirror_moves_make_one_copy_on_the_drive(self):
        # Owner, 2026-10-09: the mirror is for highly sensitive data and is stored away from the desk.
        self.assertFalse(d.Config().require_mirror)
        self.make_repo()
        m = FakeMachine(self.cfg, base_free=99 * MiB, mounted=[self.cfg.drive])
        result = d.run(self.cfg, m, self.log)
        self.assertTrue(result.acted)
        self.assertFalse(self.src.exists())
        day = time.strftime('%Y-%m-%d', time.localtime(m.now()))
        self.assertTrue((self.cfg.drive / 'Codex-Offload' / f'{day}-disk-relief' / self.rel / 'report.md').exists())
        self.assertFalse((self.cfg.mirror / 'Current').exists())

    def test_require_mirror_still_holds_moves_back(self):
        self.make_repo()
        self.cfg.require_mirror = True
        d.run(self.cfg, FakeMachine(self.cfg, base_free=99 * MiB, mounted=[self.cfg.drive]), self.log)
        self.assertTrue(self.src.exists(), 'moved with only one copy')

    def test_run_moves_old_evidence_to_both_disks_when_the_mirror_is_there(self):
        self.make_repo()
        m = FakeMachine(self.cfg, base_free=99 * MiB)
        result = d.run(self.cfg, m, self.log)
        self.assertFalse(self.src.exists())
        day = time.strftime('%Y-%m-%d', time.localtime(m.now()))
        primary = self.cfg.drive / 'Codex-Offload' / f'{day}-disk-relief'
        self.assertTrue((primary / self.rel / 'report.md').exists())
        self.assertTrue(result.acted)

    def test_a_drive_without_twice_the_space_skips_the_move(self):
        self.make_repo()
        m = FakeMachine(self.cfg, base_free=99 * MiB, drive_free={self.cfg.drive: 10 * 1024})
        result = d.run(self.cfg, m, self.log)
        self.assertTrue(self.src.exists())
        self.assertFalse(result.acted)

    def test_a_running_phone_build_holds_back_phone_moves(self):
        self.make_repo()
        for n in ('20260920-100000-aaaaaaa', '20260925-100000-bbbbbbb', '20260927-100000-ccccccc'):
            write(self.cfg.phone_dir / n / 'app.bin', 100 * 1024)
        old = self.cfg.phone_dir / '20260920-100000-aaaaaaa'
        with open(self.cfg.phone_dir / '.phone-build.lock', 'a+') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            d.run(self.cfg, FakeMachine(self.cfg, base_free=99 * MiB), self.log)
            self.assertTrue(old.exists())
        d.run(self.cfg, FakeMachine(self.cfg, base_free=99 * MiB), self.log)
        self.assertFalse(old.exists())


NIGHT = time.mktime((2026, 10, 1, 3, 0, 0, 0, 0, -1))


class Snapshots(Base):
    """Owner, 2026-10-09: "We can delete snapshots overnight." tmutil is faked; the stamp is real."""

    SNAPS = ('2026-10-01-010203', '2026-10-01-020304')

    def test_deletes_local_snapshots_once_a_night(self):
        m = FakeMachine(self.cfg, base_free=500 * MiB, now=NIGHT, snapshots=self.SNAPS)
        d.locked_run(self.cfg, m, self.log)
        self.assertEqual(m.deleted_snapshots, list(self.SNAPS))
        self.assertEqual(self.cfg.snapshot_stamp.read_text().strip(), '2026-10-01')
        m.snapshots = ['2026-10-01-033000']
        d.locked_run(self.cfg, m, self.log)
        self.assertEqual(m.snapshots, ['2026-10-01-033000'], 'deleted twice in one night')

    def test_daytime_keeps_snapshots(self):
        m = FakeMachine(self.cfg, base_free=10 * MiB, snapshots=self.SNAPS)
        d.run(self.cfg, m, self.log)
        self.assertEqual(m.deleted_snapshots, [])

    def test_a_running_backup_keeps_them_until_a_later_run(self):
        m = FakeMachine(self.cfg, base_free=500 * MiB, now=NIGHT, snapshots=self.SNAPS, backup=True)
        d.run(self.cfg, m, self.log)
        self.assertEqual(m.deleted_snapshots, [])
        self.assertFalse(self.cfg.snapshot_stamp.exists())
        m.backup = None
        d.run(self.cfg, m, self.log)
        self.assertEqual(m.deleted_snapshots, [], 'deleted without knowing whether a backup runs')
        m.backup = False
        d.run(self.cfg, m, self.log)
        self.assertEqual(m.deleted_snapshots, list(self.SNAPS))

    def test_a_failed_delete_is_logged_and_tried_again(self):
        m = FakeMachine(self.cfg, base_free=500 * MiB, now=NIGHT, snapshots=self.SNAPS,
                        undeletable={self.SNAPS[0]})
        d.run(self.cfg, m, self.log)
        self.assertTrue(any(line.startswith('FAILED snapshot') for line in self.log.lines), self.log.lines)
        self.assertFalse(self.cfg.snapshot_stamp.exists())
        m.undeletable = set()
        d.run(self.cfg, m, self.log)
        self.assertEqual(m.snapshots, [])


class SessionScratch(Base):
    """Real folders, the real lsof for open files; only the clock and pid liveness are faked."""

    def scratch(self, session: str, age: float, size: int = MiB, project='-Users-x-Documents-proj') -> Path:
        folder = self.cfg.claude_tmp / project / session
        write(folder / 'scratchpad/notes.bin', size)
        write(folder / 'tasks/b1.output', 100)
        age_tree(folder, age)
        return folder

    def register(self, pid: int, session: str) -> None:
        sessions = self.cfg.claude_sessions
        sessions.mkdir(parents=True, exist_ok=True)
        (sessions / f'{pid}.json').write_text(json.dumps({'pid': pid, 'sessionId': session, 'cwd': '/x'}))

    def test_old_scratch_goes_and_recent_scratch_stays(self):
        old = self.scratch('11111111-1111-4111-8111-111111111111', 2 * DAY)
        recent = self.scratch('22222222-2222-4222-8222-222222222222', 2 * 3600)
        loose = write(self.cfg.claude_tmp / 'cache-break-state-x.json', 10, age=9 * DAY)
        odd = self.scratch('33333333-3333-4333-8333-333333333333', 9 * DAY, project='bundled-skills')
        result = d.run(self.cfg, FakeMachine(self.cfg, base_free=99 * MiB), self.log)
        self.assertTrue(result.acted)
        self.assertFalse(old.exists())
        self.assertTrue(old.parent.exists(), 'removed the project folder too')
        self.assertTrue((recent / 'scratchpad/notes.bin').exists())
        self.assertTrue(loose.exists() and odd.exists(), 'touched something that is not a session folder')

    def test_scratch_with_an_open_file_stays(self):
        held = self.scratch('44444444-4444-4444-8444-444444444444', 2 * DAY)
        with open(held / 'tasks/b1.output', 'rb'):
            age_tree(held, 2 * DAY)
            d.run(self.cfg, FakeMachine(self.cfg, base_free=99 * MiB), self.log)
        self.assertTrue((held / 'scratchpad/notes.bin').exists())
        self.assertTrue(any('has' in line and 'open' in line for line in self.log.lines), self.log.lines)

    def test_running_and_own_sessions_stay_and_a_dead_registry_entry_does_not_protect(self):
        running = self.scratch('55555555-5555-4555-8555-555555555555', 2 * DAY)
        own = self.scratch('66666666-6666-4666-8666-666666666666', 2 * DAY)
        crashed = self.scratch('77777777-7777-4777-8777-777777777777', 2 * DAY)
        named = self.scratch('88888888-8888-4888-8888-888888888888', 2 * DAY)
        self.register(4242, running.name)
        self.register(4343, crashed.name)
        self.cfg.own_session = own.name
        procs = [d.Proc(9, '/', f'claude -p --resume {named.name}')]
        m = FakeMachine(self.cfg, base_free=90 * MiB, live_pids={4242}, procs=procs)
        d.run(self.cfg, m, self.log)
        self.assertTrue(running.exists())
        self.assertTrue(own.exists())
        self.assertTrue(named.exists())
        self.assertFalse(crashed.exists())

    def test_a_session_that_starts_again_after_planning_is_kept(self):
        folder = self.scratch('99999999-9999-4999-8999-999999999999', 2 * DAY)
        m = FakeMachine(self.cfg, base_free=99 * MiB)
        plan = d.make_plan(self.cfg, m)
        self.assertIn(folder, {c.path for c in plan.candidates})
        write(folder / 'scratchpad/new.txt', 10)
        d.execute(self.cfg, m, plan, self.log, 99 * MiB)
        self.assertTrue(folder.exists())

    def test_above_the_trigger_nothing_is_removed(self):
        old = self.scratch('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 9 * DAY)
        result = d.run(self.cfg, FakeMachine(self.cfg, base_free=self.cfg.trigger_bytes), self.log)
        self.assertFalse(result.acted)
        self.assertTrue((old / 'scratchpad/notes.bin').exists())

    def test_without_lsof_nothing_counts_as_ended(self):
        old = self.scratch('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 9 * DAY)

        class NoLsof(FakeMachine):
            def open_files(self):
                return None
        plan = d.make_plan(self.cfg, NoLsof(self.cfg, 0))
        self.assertNotIn(old, {c.path for c in plan.candidates})
        self.assertTrue(any('could not list open files' in s for s in plan.skipped))


class DryRun(Base):
    def test_dry_run_changes_nothing(self):
        _, (a,) = self.make_repo('a')
        c = self.cache(a, MiB)
        old = write(self.cfg.claude_projects / 'p/old.jsonl', 100, age=4 * DAY)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        before = sorted(str(p) for p in self.cfg.home.rglob('*'))
        out = d.dry_run(self.cfg, m, None)
        self.assertEqual(before, sorted(str(p) for p in self.cfg.home.rglob('*')))
        self.assertTrue(c.exists() and old.exists())
        self.assertTrue(any(str(c) in line for line in out))
        self.assertEqual(list(self.cfg.drive.iterdir()), [])

    def test_dry_run_removes_no_worktree(self):
        _, (done,) = self.make_repo('done')
        age_tree(done, 2 * DAY)
        out = d.dry_run(self.cfg, FakeMachine(self.cfg, base_free=10 * MiB), None)
        self.assertTrue(done.exists())
        self.assertTrue(any('worktree' in line and str(done) in line for line in out), out)


class Worktrees(Base):
    """Real git worktrees; `git worktree remove` does the removing."""

    def finished(self, tree: Path) -> Path:
        self.cache(tree, MiB)
        self.cache(tree, MiB, sub='Packages/SessionKit/.build')
        os.symlink(self.cfg.repo / '.venv', tree / '.venv')
        write(tree / 'Packages/SessionKit/.swiftpm/xcode/state.bin', 10)
        age_tree(tree, 2 * DAY)
        return tree

    def test_a_finished_worktree_goes_whole_and_its_cache_is_not_planned_twice(self):
        repo, (done,) = self.make_repo('done')
        self.finished(done)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.make_plan(self.cfg, m)
        self.assertEqual([(c.step, c.path) for c in plan.candidates], [('worktree', done)])
        result = d.run(self.cfg, m, self.log)
        self.assertTrue(result.acted)
        self.assertFalse(done.exists())
        listed = subprocess.run(['git', '-C', str(repo), 'worktree', 'list'], capture_output=True, text=True).stdout
        self.assertNotIn(str(done), listed)
        self.assertTrue((repo / 'README.md').exists())

    def test_worktrees_that_must_stay(self):
        repo, (dirty, busy, recent, evidence, locked, session, ahead) = self.make_repo(
            'dirty', 'busy', 'recent', 'evidence', 'locked', 'session', 'ahead')
        desk = self.cfg.home / 'Documents/GitHub/spoken-margins-native-test-desk'
        elsewhere = self.cfg.home / 'SpokenMarginsOps/finisher/pr-1'
        for path in (desk, elsewhere):
            git(repo, 'worktree', 'add', '-q', '--detach', str(path))
        write(dirty / 'wip.txt', 10)
        write(evidence / 'artifacts/run/report.md', 10)
        git(repo, 'worktree', 'lock', str(locked))
        git(ahead, 'commit', '-q', '--allow-empty', '-m', 'not in main yet')
        for tree in (dirty, busy, evidence, locked, session, ahead, desk, elsewhere):
            age_tree(tree, 2 * DAY)
        self.cfg.claude_sessions.mkdir(parents=True)
        (self.cfg.claude_sessions / '77.json').write_text(json.dumps(
            {'pid': 77, 'sessionId': 's', 'cwd': str(session / 'App')}))
        m = FakeMachine(self.cfg, base_free=10 * MiB, procs=[d.Proc(5, str(busy), 'zsh')], live_pids={77})
        plan = d.make_plan(self.cfg, m)
        self.assertNotIn('worktree', {c.step for c in plan.candidates})
        kept = dict(plan.stale_worktrees)
        self.assertIn('24 hours', kept[recent])
        self.assertIn('artifacts/', kept[evidence])
        self.assertIn('locked', kept[locked])
        self.assertIn('Claude Code session', kept[session])
        self.assertIn('.claude/worktrees', kept[elsewhere])
        for tree in (dirty, busy, ahead, desk):
            self.assertNotIn(tree, kept, 'listed a worktree that is not stale or is in use')
        d.run(self.cfg, m, self.log)
        for tree in (dirty, busy, recent, evidence, locked, session, ahead, desk, elsewhere):
            self.assertTrue(tree.exists(), tree)
        self.assertTrue((dirty / 'wip.txt').exists())

    def test_a_worktree_that_changes_after_planning_is_kept(self):
        _, (done,) = self.make_repo('done')
        self.finished(done)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.make_plan(self.cfg, m)
        write(done / 'new-idea.txt', 10)
        d.execute(self.cfg, m, plan, self.log, 10 * MiB)
        self.assertTrue((done / 'new-idea.txt').exists())


class CodexWorktrees(Base):
    """Owner, 2026-10-19: Codex app worktrees (~/.codex/worktrees/<id>/<name>) follow the same rules."""

    def codex(self, repo: Path, name: str) -> Path:
        path = self.cfg.codex_worktrees / name / 'spoken-margins-native'
        git(repo, 'worktree', 'add', '-q', '--detach', str(path))
        return path

    def test_found_by_their_git_file_without_git_worktree_list(self):
        repo, _ = self.make_repo()
        mine = self.codex(repo, 'a1')
        other = self.cfg.codex_worktrees / 'b2/other'
        (other).mkdir(parents=True)
        (other / '.git').write_text('gitdir: /somewhere/else/.git/worktrees/x\n')
        flat = self.cfg.codex_worktrees / 'tonight-journeys'
        git(repo, 'worktree', 'add', '-q', '--detach', str(flat))
        self.assertEqual(d.codex_worktrees(self.cfg, [repo]), [mine, flat])
        self.assertTrue(d.in_codex_worktrees(self.cfg, flat) and d.in_codex_worktrees(self.cfg, mine))
        self.assertFalse(d.in_codex_worktrees(self.cfg, d.real(self.cfg.codex_worktrees)))

    def test_a_finished_codex_worktree_goes_whole_with_its_id_folder(self):
        repo, _ = self.make_repo()
        done = self.codex(repo, 'a1')
        self.cache(done, MiB)
        age_tree(done, 2 * DAY)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.make_plan(self.cfg, m)
        self.assertEqual([(c.step, c.path) for c in plan.candidates], [('worktree', done)])
        d.run(self.cfg, m, self.log)
        self.assertFalse(done.parent.exists(), 'left the empty <id> folder behind')
        self.assertTrue((repo / 'README.md').exists())

    def test_a_codex_worktree_in_use_keeps_itself_and_an_idle_one_loses_its_cache(self):
        repo, _ = self.make_repo()
        dirty = self.codex(repo, 'a1')
        write(dirty / 'wip.txt', 10)
        cache = self.cache(dirty, MiB)
        recent = self.codex(repo, 'b2')
        age_tree(dirty, 2 * DAY)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.make_plan(self.cfg, m)
        self.assertEqual([(c.step, c.path) for c in plan.candidates], [('cache', cache)])
        self.assertIn('24 hours', dict(plan.stale_worktrees)[recent])
        d.run(self.cfg, m, self.log)
        self.assertFalse(cache.exists())
        self.assertTrue((dirty / 'wip.txt').exists() and recent.exists())


class BuildCacheFolder(Base):
    """Worktrees under ~/Documents keep their build folders in ~/Library/Caches/SpokenMarginsBuilds
    (scripts/sm_build_cache.py), because this job can't read ~/Documents (2026-10-19: 20 GiB, 0 cleared)."""

    def setUp(self):
        super().setUp()
        env = {'SM_BUILD_CACHE_ROOT': str(self.cfg.build_cache_dir),
               'SM_BUILD_CACHE_UNDER': str(self.cfg.home / 'Documents'), 'SM_BUILD_CACHE': ''}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop('GITHUB_ACTIONS', None)

    def linked(self, tree: Path, size=MiB, age=DAY) -> Path:
        (tree / 'Packages/SessionKit').mkdir(parents=True)
        sm_build_cache.ensure_links(tree)
        self.assertTrue((tree / '.build').is_symlink())
        self.cache(tree, size, age=age)
        self.cache(tree, size, sub='Packages/SessionKit/.build', age=age)
        write(tree / '.build/verification.lock', 0)
        slot = sm_build_cache.slot_for(tree)
        age_tree(slot, age)
        return slot

    def test_an_idle_worktrees_cache_is_emptied_and_its_links_still_work(self):
        _, (a,) = self.make_repo('a')
        slot = self.linked(a)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.make_plan(self.cfg, m)
        self.assertEqual(sorted(c.path for c in plan.candidates), [slot / 'root/dd', slot / 'sessionkit'],
                         'a linked .build was also planned through the worktree, or the lock file was')
        d.run(self.cfg, m, self.log)
        self.assertFalse((slot / 'root/dd').exists())
        self.assertEqual(list((slot / 'sessionkit').iterdir()), [])
        self.assertTrue((slot / 'root/verification.lock').exists() and (slot / 'owner.txt').exists())
        self.assertTrue((a / 'Packages/SessionKit/.build').is_dir(), 'the SessionKit link dangles')
        self.assertTrue((a / '.build').is_dir())

    def test_a_slot_whose_worktree_is_gone_goes_whole(self):
        repo, (a, b) = self.make_repo('a', 'b')
        gone = self.linked(a)
        kept = self.linked(b)
        git(repo, 'worktree', 'remove', '--force', str(a))
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.make_plan(self.cfg, m)
        self.assertIn(gone, {c.path for c in plan.candidates})
        d.run(self.cfg, m, self.log)
        self.assertFalse(gone.exists())
        self.assertTrue((kept / 'owner.txt').exists())

    def test_busy_recent_or_testing_slots_stay(self):
        _, (busy, recent, testing) = self.make_repo('a', 'b', 'c')
        busy_slot = self.linked(busy)
        recent_slot = self.linked(recent, age=10 * 60)
        testing_slot = self.linked(testing)
        m = FakeMachine(self.cfg, base_free=10 * MiB, procs=[d.Proc(7, str(busy / 'App'), 'zsh')])
        with open(testing_slot / 'root/verification.lock', 'a') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            plan = d.make_plan(self.cfg, m)
            d.execute(self.cfg, m, plan, self.log, 10 * MiB)
        self.assertEqual([c.path for c in plan.candidates], [])
        for slot in (busy_slot, recent_slot, testing_slot):
            self.assertTrue((slot / 'root/dd/Build/blob').exists(), slot)

    def test_a_slot_whose_worktree_a_live_agent_has_locked_stays(self):
        # A sub-agent's worktree, locked with its pid while the agent itself works from another folder:
        # its DerivedData must survive between build-for-testing and test-without-building (finding 3).
        repo, (a, b) = self.make_repo('a', 'b')
        locked_slot = self.linked(a)
        dead_slot = self.linked(b)
        git(repo, 'worktree', 'lock', '--reason', 'claude agent x (pid 42 start Thu)', str(a))
        git(repo, 'worktree', 'lock', '--reason', 'claude agent y (pid 43 start Thu)', str(b))
        m = FakeMachine(self.cfg, base_free=10 * MiB, live_pids={42})
        plan = d.make_plan(self.cfg, m)
        planned = {c.path for c in plan.candidates}
        self.assertFalse({locked_slot / 'root/dd', locked_slot / 'sessionkit'} & planned, planned)
        self.assertIn(dead_slot / 'root/dd', planned)
        self.assertTrue(any('live agent' in s for s in plan.skipped), plan.skipped)

    def test_a_worktree_this_job_may_not_look_into_is_not_counted_as_gone(self):
        _, (a,) = self.make_repo('a')
        slot = self.linked(a)
        a.parent.chmod(0)
        try:
            self.assertFalse(d.worktree_gone(str(a)))
        finally:
            a.parent.chmod(0o755)
        self.assertTrue(d.worktree_gone(str(a.parent / 'never-existed')))
        self.assertTrue(d.worktree_gone(None))
        self.assertTrue((slot / 'owner.txt').exists())

    def test_dry_run_lists_the_moved_caches(self):
        _, (a,) = self.make_repo('a')
        slot = self.linked(a)
        text = '\n'.join(d.dry_run(self.cfg, FakeMachine(self.cfg, base_free=10 * MiB), None))
        self.assertIn(str(slot / 'root/dd'), text)
        self.assertIn(str(slot / 'sessionkit'), text)
        self.assertTrue((slot / 'root/dd/Build/blob').exists())


class TmpFolders(Base):
    def folder(self, name: str, age: float) -> Path:
        path = self.cfg.tmp_root / name
        write(path / 'repo/blob', MiB)
        age_tree(path, age)
        return path

    def test_old_test_folders_go_and_others_stay(self):
        old = self.folder('spoken-margins-test-desk-1234', 2 * DAY)
        recent = self.folder('spoken-margins-test-desk-5678', 2 * 3600)
        other = self.folder('somebody-else', 9 * DAY)
        held = self.folder('spoken-margins-held', 2 * DAY)
        with open(held / 'repo/blob', 'rb'):
            age_tree(held, 2 * DAY)
            result = d.run(self.cfg, FakeMachine(self.cfg, base_free=90 * MiB), self.log)
        self.assertTrue(result.acted)
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists() and other.exists() and held.exists())

    def test_a_process_working_there_keeps_it(self):
        old = self.folder('spoken-margins-x', 2 * DAY)
        m = FakeMachine(self.cfg, base_free=90 * MiB, procs=[d.Proc(3, str(old / 'repo'), 'zsh')])
        d.run(self.cfg, m, self.log)
        self.assertTrue(old.exists())


if __name__ == '__main__':
    unittest.main()


class LaneFolder(Base):
    """#1775: the lane folder is capped and its evidence aged out on every run, whatever the free space.
    The folder rules have their own tests (test_sm_lane_prune.py); these check the job runs them."""

    def lane_fixture(self):
        lane = self.cfg.lane_dir
        runner = self.cfg.home / 'runner/_work/spoken-margins-native/spoken-margins-native'
        (self.cfg.launch_agents).mkdir(parents=True, exist_ok=True)
        (self.cfg.launch_agents / 'actions.runner.test.plist').write_bytes(plistlib.dumps(
            {'Label': 'actions.runner.test', 'WorkingDirectory': str(self.cfg.home / 'runner'),
             'ProgramArguments': [str(self.cfg.home / 'runner/runsvc.sh')]}))
        checkout = lane / 'warm-build' / lane_prune.checkout_folder(runner)
        self.newest = checkout / 'sk-new'
        self.spare = checkout / 'sk-spare'
        self.gone = lane / 'warm-build' / lane_prune.checkout_folder(self.cfg.home / 'deleted-runner') / 'sk-x'
        for cache, age in ((self.newest, DAY), (self.spare, 3 * DAY), (self.gone, 3 * DAY)):
            write(cache / 'Build/blob', 3 * MiB)
            age_tree(cache, age)
            age_tree(cache.parent, age)
        self.old = write(lane / 'evidence/pr1-r1/report.md', MiB).parent
        self.fresh = write(lane / 'evidence/pr2-r2/report.md', MiB).parent
        self.open_old = write(lane / 'evidence/pr3-r3/report.md', MiB).parent
        self.old_artifacts = write(self.cfg.repo / 'artifacts/lane/pr4-r4/report.md', MiB).parent
        age_tree(self.old, 9 * DAY)
        age_tree(self.fresh, 2 * DAY)
        age_tree(self.open_old, 40 * DAY)
        age_tree(self.old_artifacts, 9 * DAY)
        self.state = write(lane / 'step-ledger.json', 100, age=60 * DAY)

    def test_with_plenty_of_free_space_old_evidence_and_dead_checkouts_still_go(self):
        self.lane_fixture()
        m = FakeMachine(self.cfg, base_free=500 * MiB, open_prs={3})
        d.run(self.cfg, m, self.log)
        for gone in (self.old, self.old_artifacts, self.gone):
            self.assertFalse(gone.exists(), gone)
        for kept in (self.fresh, self.open_old, self.newest, self.spare, self.state):
            self.assertTrue(kept.exists(), kept)
        self.assertTrue(any(line.startswith('lane evidence') for line in self.log.lines), self.log.lines)

    def test_over_the_cap_idle_warm_caches_go_with_plenty_of_free_space(self):
        self.lane_fixture()
        self.cfg.lane_cap_bytes = 3 * MiB + MiB // 2
        m = FakeMachine(self.cfg, base_free=500 * MiB, open_prs={3})
        d.run(self.cfg, m, self.log)
        self.assertFalse(self.spare.exists())
        self.assertTrue(self.newest.exists(), 'the newest cache of a live checkout stays')

    def test_disk_relief_prunes_to_the_cap_with_no_room_for_a_build(self):
        # Only the lane runner's call, just before a build, leaves room under the cap (#1775).
        self.lane_fixture()
        m = FakeMachine(self.cfg, base_free=500 * MiB, open_prs={3})
        plan = d.plan_lane(self.cfg, m)
        self.assertEqual(plan.room, 0)
        self.assertEqual(plan.cap, self.cfg.lane_cap_bytes)

    def test_dry_run_lists_the_lane_step_and_changes_nothing(self):
        self.lane_fixture()
        m = FakeMachine(self.cfg, base_free=500 * MiB, open_prs={3})
        text = '\n'.join(d.dry_run(self.cfg, m, None))
        self.assertIn('Lane folder', text)
        self.assertIn(str(self.old), text)
        self.assertTrue(self.old.exists() and self.gone.exists())

    def test_a_fault_in_the_lane_step_does_not_stop_the_rest(self):
        _, (w,) = self.make_repo('a')
        c = self.cache(w, MiB)
        m = FakeMachine(self.cfg, base_free=10 * MiB)

        def broken(repo):
            raise RuntimeError('gh exploded')
        m.open_pull_requests = broken
        result = d.run(self.cfg, m, self.log)
        self.assertTrue(result.acted)
        self.assertFalse(c.exists())
        self.assertTrue(any('lane folder step failed' in line for line in self.log.lines), self.log.lines)

    def test_the_default_cap_is_one_documented_number(self):
        self.assertEqual(d.Config().lane_cap_bytes, 16 * d.GiB)
        doc = (Path(__file__).resolve().parents[2] / 'docs/workstreams/test-lane.md').read_text()
        self.assertIn('16 GiB', doc)
