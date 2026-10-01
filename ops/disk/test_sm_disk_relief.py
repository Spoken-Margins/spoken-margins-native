"""Host tests for disk relief. Temp folders only; copies use the real /usr/bin/rsync.

Run: python3 -m unittest ops/disk/test_sm_disk_relief.py
"""
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

MiB = 1024 ** 2
NOW = time.time()
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
                 live_pids=(), copy=None, frozen_free=False):
        self.cfg = cfg
        self.base_free = base_free
        self.initial_used = d.tree_stats(cfg.home).disk_bytes
        self.procs = procs or []
        self.mounted = {cfg.drive, cfg.mirror} if mounted is None else set(mounted)
        self.drive_free = drive_free or {}
        self.live_pids = set(live_pids)
        self.copy_override = copy
        self.frozen_free = frozen_free
        self.notes = []

    def now(self):
        return NOW

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
            claude_tmp=home / 'tmp/claude-501',
            claude_sessions=home / '.claude/sessions',
            own_session=None,
            trigger_bytes=100 * MiB,
            target_bytes=104 * MiB,
        )
        self.log = d.Log(None, echo=False)

    def tearDown(self):
        self.tmp.cleanup()

    def make_repo(self, *worktrees):
        repo = self.cfg.repo
        repo.mkdir(parents=True, exist_ok=True)
        git(repo, 'init', '-q', '-b', 'next')
        write(repo / 'README.md', 10)
        (repo / '.gitignore').write_text('.build/\nartifacts/\nPackages/SessionKit/.build/\n')
        git(repo, 'add', '.')
        git(repo, 'commit', '-qm', 'one')
        git(repo, 'update-ref', 'refs/remotes/origin/next', 'HEAD')
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

    def test_drive_missing_means_no_action_at_all(self):
        _, (w,) = self.make_repo('a')
        c = self.cache(w, MiB)
        m = FakeMachine(self.cfg, base_free=10 * MiB, mounted=[])
        result = d.run(self.cfg, m, self.log)
        self.assertFalse(result.acted)
        self.assertIn('not mounted', result.reason)
        self.assertTrue(c.exists())
        self.assertEqual(m.notes, [])

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
        self.assertTrue(d.is_protected(self.cfg.home / '.codex/worktrees/x/.build', protected))
        self.assertTrue(d.is_protected(self.cfg.home / 'Library/Developer/CoreSimulator/Devices/U', protected))
        self.assertTrue(d.is_protected(self.cfg.home / 'Library', protected), 'a parent of a protected path')
        self.assertFalse(d.is_protected(self.cfg.repo / '.build/dd', protected))

    def test_protected_worktrees_are_not_planned_and_forced_candidates_are_refused(self):
        repo, _ = self.make_repo()
        codex = self.cfg.home / '.codex/worktrees/proj/spoken-margins-native'
        git(repo, 'worktree', 'add', '-q', '--detach', str(codex))
        codex_cache = self.cache(codex, MiB)
        sim = write(self.cfg.home / 'Library/Developer/CoreSimulator/Devices/U/data', MiB)
        m = FakeMachine(self.cfg, base_free=10 * MiB)
        plan = d.make_plan(self.cfg, m)
        self.assertNotIn(codex_cache, {c.path for c in plan.candidates})
        plan.candidates = [d.Candidate('cache', codex_cache, MiB, 'forced'), d.Candidate('cache', sim.parent, MiB, 'forced')]
        d.execute(self.cfg, m, plan, self.log, 10 * MiB)
        self.assertTrue(codex_cache.exists())
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

    def test_run_moves_old_evidence_and_skips_moves_without_the_mirror(self):
        self.make_repo()
        m = FakeMachine(self.cfg, base_free=99 * MiB, mounted=[self.cfg.drive])
        d.run(self.cfg, m, self.log)
        self.assertTrue(self.src.exists(), 'moved with only one copy')
        m = FakeMachine(self.cfg, base_free=99 * MiB)
        result = d.run(self.cfg, m, self.log)
        self.assertFalse(self.src.exists())
        self.assertTrue((self.primary / self.rel / 'report.md').exists())
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

    def test_stale_worktrees_are_listed_not_removed(self):
        repo, (clean, dirty, in_use) = self.make_repo('clean', 'dirty', 'in-use')
        desk = self.cfg.home / 'Documents/GitHub/spoken-margins-native-test-desk'
        git(repo, 'worktree', 'add', '-q', '--detach', str(desk))
        write(dirty / 'wip.txt', 10)
        m = FakeMachine(self.cfg, 0, procs=[d.Proc(5, str(in_use), 'claude')])
        plan = d.make_plan(self.cfg, m)
        self.assertEqual(plan.stale_worktrees, [clean])
        self.assertTrue(clean.exists())


if __name__ == '__main__':
    unittest.main()
