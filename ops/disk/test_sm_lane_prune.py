"""Host tests for the lane folder cap and evidence pruning (#1775). Temp folders and real flocks only.

Run: python3 -m unittest ops/disk/test_sm_lane_prune.py
"""
import contextlib
import fcntl
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_lane_prune as p  # noqa: E402

MiB = 1024 ** 2
DAY = 86400
NOW = 1_790_000_000.0
CAP = 100 * MiB


def fill(folder: Path, size: int, age: float, name: str = 'blob') -> Path:
    """A folder holding one file of size bytes, last changed age seconds ago."""
    folder.mkdir(parents=True, exist_ok=True)
    blob = folder / name
    blob.write_bytes(os.urandom(size))
    for path in (blob, folder):
        os.utime(path, (NOW - age, NOW - age))
    return folder


class LaneTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.tmp.name))
        self.lane = self.root / 'SpokenMarginsLane'
        self.warm = self.lane / 'warm-build'
        self.evidence = self.lane / 'evidence'
        self.artifacts = self.root / 'checkout/artifacts/lane'
        self.runner_a = self.root / 'runner-a/_work/spoken-margins-native/spoken-margins-native'
        self.runner_b = self.root / 'runner-b/_work/spoken-margins-native/spoken-margins-native'
        self.held = []

    def tearDown(self):
        for handle in self.held:
            handle.close()
        self.tmp.cleanup()

    def cache(self, tree: Path, key: str, size: int, age: float) -> Path:
        checkout = self.warm / p.checkout_folder(tree)
        made = fill(checkout / f'sk-{key}', size, age)
        newest = max(c.stat().st_mtime for c in checkout.iterdir())
        os.utime(checkout, (newest, newest))  # the folder changes when a cache is added, as in use
        return made

    def hold(self, cache: Path):
        """A job takes the cache's lock. The test keeps the folder's age, so what it shows is the lock's effect."""
        before = cache.stat().st_mtime
        handle = open(cache / '.lock', 'a+')
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.utime(cache, (before, before))
        self.held.append(handle)

    def plan(self, open_prs=frozenset(), live=None, cap=CAP, trees=True):
        live = [self.runner_a, self.runner_b] if live is None and trees else live
        return p.plan_prune(self.lane, [self.evidence, self.artifacts], live,
                            None if open_prs is None else set(open_prs), NOW, cap=cap)

    def paths(self, plan):
        return {item.path for item in plan.items}


class Evidence(LaneTests):
    def test_old_evidence_goes_in_both_places_and_new_stays(self):
        old = fill(self.evidence / 'pr10-r1', MiB, 8 * DAY)
        new = fill(self.evidence / 'pr11-r2', MiB, 2 * DAY)
        old_artifacts = fill(self.artifacts / 'pr12-r3', MiB, 9 * DAY)
        new_artifacts = fill(self.artifacts / 'pr13-r4', MiB, DAY)
        plan = self.plan()
        self.assertEqual(self.paths(plan), {old, old_artifacts})
        p.prune(plan, NOW, lambda message: None)
        self.assertFalse(old.exists() or old_artifacts.exists())
        self.assertTrue(new.exists() and new_artifacts.exists())

    def test_a_folder_with_one_recent_file_is_new(self):
        folder = fill(self.evidence / 'pr10-r1', MiB, 20 * DAY)
        fill(folder, 10, DAY, name='late.png')
        self.assertEqual(self.paths(self.plan()), set())

    def test_the_latest_run_of_an_open_pr_stays_whatever_its_age(self):
        latest = fill(self.evidence / 'pr10-r5', MiB, 40 * DAY)
        auto = fill(self.evidence / 'pr10-r5-auto', MiB, 40 * DAY)
        retry = fill(self.evidence / 'pr10-r5-a2', MiB, 41 * DAY)
        older = fill(self.evidence / 'pr10-r4', MiB, 45 * DAY)
        closed = fill(self.evidence / 'pr99-r9', MiB, 40 * DAY)
        plan = self.plan(open_prs={10})
        self.assertEqual(self.paths(plan), {older, closed})
        self.assertTrue(latest.exists() and auto.exists() and retry.exists())

    def test_the_latest_run_is_the_newest_not_the_highest_numbered(self):
        newer = fill(self.evidence / 'pr10-r3', MiB, 30 * DAY)
        older = fill(self.evidence / 'pr10-r8', MiB, 35 * DAY)
        self.assertEqual(self.paths(self.plan(open_prs={10})), {older})
        self.assertTrue(newer.exists())

    def test_when_github_cannot_be_asked_recent_prs_stay_and_old_ones_go(self):
        recent = fill(self.evidence / 'pr10-r1', MiB, 20 * DAY)
        stale = fill(self.evidence / 'pr11-r1', MiB, 31 * DAY)
        self.assertEqual(self.paths(self.plan(open_prs=None)), {stale})
        self.assertTrue(recent.exists())

    def test_names_that_are_not_lane_requests_age_out_without_protection(self):
        odd = fill(self.evidence / 'full-old', MiB, 10 * DAY)
        self.assertEqual(self.paths(self.plan(open_prs={10})), {odd})

    def test_evidence_changed_in_the_last_hour_is_never_deleted(self):
        folder = fill(self.evidence / 'pr10-r1', MiB, 9 * DAY)
        fill(folder, 10, 60, name='still-writing.log')
        self.assertEqual(self.paths(self.plan()), set())
        # and a plan made earlier is checked again before acting
        stale = fill(self.evidence / 'pr11-r1', MiB, 9 * DAY)
        plan = self.plan()
        self.assertEqual(self.paths(plan), {stale})
        fill(stale, 10, 60, name='just-now.png')
        p.prune(plan, NOW, lambda message: None)
        self.assertTrue(stale.exists())

    def test_an_unreadable_evidence_folder_is_skipped_and_listed(self):
        fill(self.evidence / 'pr10-r1', MiB, 9 * DAY)
        original = p.Path.iterdir

        def deny(path):
            if path == self.artifacts:
                raise PermissionError(1, 'Operation not permitted', str(path))
            return original(path)

        self.artifacts.mkdir(parents=True)
        p.Path.iterdir = deny
        try:
            plan = self.plan()
        finally:
            p.Path.iterdir = original
        self.assertEqual(len(plan.items), 1)
        self.assertTrue(any('will not let this job read it' in line for line in plan.skipped), plan.skipped)


class NoAccess(LaneTests):
    def test_an_evidence_folder_macos_refuses_even_to_stat_does_not_stop_the_rest(self):
        # Under launchd without Full Disk Access, Python 3.9's Path.is_dir() raises on ~/Documents.
        old = fill(self.evidence / 'pr10-r1', MiB, 9 * DAY)
        spare = self.cache(self.runner_a, 'spare', 30 * MiB, 3 * DAY)
        self.cache(self.runner_a, 'new', 30 * MiB, DAY)
        original = p.Path.is_dir

        def deny(path):
            if str(path).startswith(str(self.artifacts)):
                raise PermissionError(1, 'Operation not permitted', str(path))
            return original(path)

        p.Path.is_dir = deny
        try:
            plan = self.plan(cap=40 * MiB)
        finally:
            p.Path.is_dir = original
        self.assertEqual(self.paths(plan), {old, spare})
        self.assertTrue(any('will not let this job read it' in line for line in plan.skipped), plan.skipped)


class Warm(LaneTests):
    def test_evidence_outside_the_lane_folder_that_goes_does_not_count_as_room_in_it(self):
        fill(self.artifacts / 'pr30-r1', 60 * MiB, 9 * DAY)
        self.cache(self.runner_a, 'new', 30 * MiB, DAY)
        spare = self.cache(self.runner_a, 'spare', 30 * MiB, 3 * DAY)
        plan = self.plan(cap=40 * MiB)
        self.assertIn(spare, self.paths(plan))
        self.assertTrue(plan.after < plan.total)

    def test_a_job_starting_mid_delete_finds_no_cache_to_lock(self):
        newest = self.cache(self.runner_a, 'new', 30 * MiB, DAY)
        victim = self.cache(self.runner_a, 'old', 30 * MiB, 6 * DAY)
        seen = []
        real_rmtree = p.shutil.rmtree

        def watching(path, *args, **kwargs):
            if Path(path).exists():  # the real delete, not the clean-up of an absent leftover
                seen.append((victim.exists(), [c.name for c in p.checkout_caches(victim.parent)]))
            return real_rmtree(path, *args, **kwargs)

        p.shutil.rmtree = watching
        try:
            self.assertEqual(p.remove_cache(victim), (True, 'deleted'))
        finally:
            p.shutil.rmtree = real_rmtree
        self.assertTrue(seen and all(not exists and names == ['sk-new'] for exists, names in seen), seen)
        self.assertTrue(newest.exists())

    def test_a_delete_cut_off_in_the_middle_is_finished_by_the_next_run(self):
        self.cache(self.runner_a, 'new', 30 * MiB, DAY)
        tomb = fill(self.warm / p.checkout_folder(self.runner_a) / '.deleting-sk-old', MiB, 2 * DAY)
        p.prune(self.plan(), NOW, lambda message: None)
        self.assertFalse(tomb.exists())


    def test_under_the_cap_no_warm_cache_goes_whatever_the_free_disk(self):
        for i in range(4):
            self.cache(self.runner_a, f'k{i}', 10 * MiB, i * DAY)
        self.assertEqual(self.paths(self.plan()), set())

    def test_over_the_cap_idle_caches_go_oldest_first_across_checkouts(self):
        a_new = self.cache(self.runner_a, 'a-new', 30 * MiB, 1 * DAY)
        a_mid = self.cache(self.runner_a, 'a-mid', 30 * MiB, 3 * DAY)
        b_new = self.cache(self.runner_b, 'b-new', 30 * MiB, 2 * DAY)
        b_old = self.cache(self.runner_b, 'b-old', 30 * MiB, 5 * DAY)
        plan = self.plan(cap=100 * MiB)
        # Four 30 MiB caches. A directory takes blocks on ext4 and none on APFS, so the total is 120 MiB on the Mac
        # and a little over on Linux (#1781).
        self.assertGreaterEqual(plan.total, 120 * MiB)
        self.assertEqual([i.path for i in plan.items], [b_old])  # 120 MiB falls to 90 with the oldest gone
        plan = self.plan(cap=70 * MiB)
        self.assertEqual([i.path for i in plan.items], [b_old, a_mid])
        p.prune(plan, NOW, lambda message: None)
        self.assertTrue(a_new.exists() and b_new.exists())
        self.assertFalse(b_old.exists() or a_mid.exists())

    def test_before_a_build_it_leaves_room_under_the_cap_for_that_build(self):
        # Pruned only to the cap, each build took the folder over it until the next run (19.5 GiB on 10-18, cap 16).
        a_new = self.cache(self.runner_a, 'a-new', 30 * MiB, 1 * DAY)
        a_old = self.cache(self.runner_a, 'a-old', 30 * MiB, 4 * DAY)
        b_new = self.cache(self.runner_b, 'b-new', 30 * MiB, 2 * DAY)
        b_mid = self.cache(self.runner_b, 'b-mid', 30 * MiB, 3 * DAY)
        self.assertEqual(self.paths(self.plan(cap=130 * MiB)), set())  # 120 MiB is under the cap
        plan = p.plan_prune(self.lane, [self.evidence], [self.runner_a, self.runner_b], set(), NOW,
                            cap=130 * MiB, room=50 * MiB)
        self.assertEqual([i.path for i in plan.items], [a_old, b_mid])  # 120 MiB down to 60, under 130 - 50
        self.assertLessEqual(plan.after + 50 * MiB, 130 * MiB)
        self.assertFalse(plan.over_cap)
        p.prune(plan, NOW, lambda message: None)
        self.assertTrue(a_new.exists() and b_new.exists())

    def test_the_command_line_run_the_lane_runner_makes_leaves_room_and_disk_relief_does_not(self):
        seen = {}
        real_plan, real_open = p.plan_prune, p.open_pull_requests
        p.plan_prune = lambda *args, **kwargs: seen.update(kwargs) or real_plan(*args, **kwargs)
        p.open_pull_requests = lambda repo: set()
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                p.main(['--dry-run', '--lane-dir', str(self.lane)])
        finally:
            p.plan_prune, p.open_pull_requests = real_plan, real_open
        self.assertEqual(seen['room'], p.BUILD_ROOM_BYTES)
        self.assertGreaterEqual(p.BUILD_ROOM_BYTES, 3 * 1024 ** 3)  # an app build's warm cache is 3 to 4 GB
        self.assertEqual(p.Plan().room, 0)

    def test_the_newest_cache_of_each_checkout_is_never_evicted(self):
        a = self.cache(self.runner_a, 'a', 60 * MiB, 9 * DAY)
        b = self.cache(self.runner_b, 'b', 60 * MiB, 8 * DAY)
        plan = self.plan(cap=MiB)
        self.assertEqual(plan.items, [])
        self.assertTrue(plan.over_cap)
        self.assertTrue(a.exists() and b.exists())

    def test_a_busy_cache_is_never_evicted_and_never_counts_as_the_one_to_keep(self):
        newest = self.cache(self.runner_a, 'new', 30 * MiB, DAY)
        busy = self.cache(self.runner_a, 'busy', 30 * MiB, 6 * DAY)
        idle = self.cache(self.runner_a, 'idle', 30 * MiB, 5 * DAY)
        self.hold(busy)
        plan = self.plan(cap=40 * MiB)
        self.assertEqual([i.path for i in plan.items], [idle])
        self.assertTrue(any('a job holds it' in line for line in plan.skipped))
        p.prune(plan, NOW, lambda message: None)
        self.assertTrue(newest.exists() and busy.exists())

    def test_a_cache_a_job_takes_after_planning_is_kept(self):
        newest = self.cache(self.runner_a, 'new', 30 * MiB, DAY)
        victim = self.cache(self.runner_a, 'old', 30 * MiB, 6 * DAY)
        plan = self.plan(cap=40 * MiB)
        self.assertEqual([i.path for i in plan.items], [victim])
        self.hold(victim)
        messages = []
        self.assertEqual(p.prune(plan, NOW, messages.append), 0)
        self.assertTrue(victim.exists() and newest.exists())
        self.assertTrue(any('a job holds it' in m for m in messages), messages)

    def test_state_files_and_the_compilation_cache_are_never_touched(self):
        names = ['step-ledger.json', 'unsafe-simulators.json', 'desk-simulator-pool.json', 'guard.log',
                 'inherited-holds.json', 'boot-events.log', 'beside-simulator.log']
        for name in names:
            fill(self.lane, MiB, 30 * DAY, name=name)
        compilation = fill(self.lane / 'compilation-cache', 200 * MiB, 30 * DAY)
        locks = fill(self.lane / 'simulator-quiet', 10, 30 * DAY)
        self.cache(self.runner_a, 'a', 10 * MiB, 3 * DAY)
        plan = self.plan(cap=MiB)
        self.assertEqual(plan.items, [])
        self.assertTrue(plan.over_cap)
        p.prune(plan, NOW, lambda message: None)
        for name in names:
            self.assertTrue((self.lane / name).exists(), name)
        self.assertTrue(compilation.exists() and locks.exists())

    def test_over_the_cap_the_oldest_evidence_goes_after_the_warm_caches_and_open_prs_stay(self):
        a = self.cache(self.runner_a, 'a', 30 * MiB, DAY)
        spare = self.cache(self.runner_a, 'spare', 30 * MiB, 3 * DAY)
        open_latest = fill(self.evidence / 'pr10-r2', 30 * MiB, 3 * DAY)
        closed_old = fill(self.evidence / 'pr20-r1', 30 * MiB, 5 * DAY)
        closed_new = fill(self.evidence / 'pr21-r1', 30 * MiB, 2 * DAY)
        recent = fill(self.evidence / 'pr22-r1', 30 * MiB, 60)  # a job may be writing it
        plan = self.plan(open_prs={10}, cap=80 * MiB)
        self.assertEqual([i.path for i in plan.items], [spare, closed_old, closed_new])
        self.assertEqual(plan.items[0].kind, 'warm-cache')
        p.prune(plan, NOW, lambda message: None)
        self.assertTrue(a.exists() and open_latest.exists() and recent.exists())

    def test_evidence_outside_the_lane_folder_does_not_count_against_its_cap(self):
        fill(self.artifacts / 'pr30-r1', 200 * MiB, DAY)
        self.cache(self.runner_a, 'a', 10 * MiB, DAY)
        plan = self.plan(cap=50 * MiB)
        self.assertEqual(plan.items, [])
        self.assertFalse(plan.over_cap)


class Orphans(LaneTests):
    def test_a_checkout_nothing_maps_to_goes_once_idle(self):
        gone = self.root / 'runner-gone/_work/spoken-margins-native/spoken-margins-native'
        stale = self.cache(gone, 'x', MiB, 3 * DAY).parent
        self.cache(gone, 'y', MiB, 4 * DAY)
        kept = self.cache(self.runner_a, 'a', MiB, 3 * DAY)
        plan = self.plan()
        self.assertEqual(self.paths(plan), {stale})
        self.assertEqual(plan.items[0].kind, 'orphan-checkout')
        p.prune(plan, NOW, lambda message: None)
        self.assertFalse(stale.exists())
        self.assertTrue(kept.exists())

    def test_it_goes_whatever_the_cap(self):
        gone = self.root / 'old-checkout'
        stale = self.cache(gone, 'x', MiB, 3 * DAY).parent
        self.assertEqual(self.paths(self.plan(cap=10 * 1024 * MiB)), {stale})

    def test_a_checkout_used_in_the_last_day_or_held_by_a_job_stays(self):
        recent = self.cache(self.root / 'gone-recent', 'x', MiB, 3600).parent
        busy_cache = self.cache(self.root / 'gone-busy', 'x', MiB, 5 * DAY)
        self.hold(busy_cache)
        plan = self.plan()
        self.assertEqual(plan.items, [])
        p.prune(plan, NOW, lambda message: None)
        self.assertTrue(recent.exists() and busy_cache.exists())

    def test_a_job_that_takes_an_orphan_cache_after_planning_keeps_it(self):
        cache = self.cache(self.root / 'gone', 'x', MiB, 3 * DAY)
        plan = self.plan()
        self.hold(cache)
        p.prune(plan, NOW, lambda message: None)
        self.assertTrue(cache.exists())

    def test_without_a_list_of_live_checkouts_nothing_counts_as_gone(self):
        cache = self.cache(self.root / 'gone', 'x', MiB, 30 * DAY)
        self.assertEqual(self.plan(live=None, trees=False).items, [])
        self.assertTrue(cache.exists())


class RunnerContract(unittest.TestCase):
    """The names and the busy test are the lane runner's; if it changes them this must follow."""

    @classmethod
    def setUpClass(cls):
        scripts = Path(__file__).resolve().parents[2] / 'scripts'
        sys.path.insert(0, str(scripts))
        spec = importlib.util.spec_from_file_location('lane_runner_for_prune', scripts / 'lane-runner.py')
        cls.lane = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.lane)

    def test_checkout_folder_names_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp) / 'a/b'
            tree.mkdir(parents=True)
            self.assertEqual(p.checkout_folder(tree), self.lane.checkout_folder(tree))
            self.assertEqual(p.checkout_folder(tree / '..' / 'b'), self.lane.checkout_folder(tree))

    def test_busy_agrees_with_the_runner_for_a_cache_it_holds(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / 'sk-x'
            cache.mkdir()
            self.assertFalse(p.cache_busy(cache))
            self.assertFalse(self.lane._cache_busy(cache))
            with open(cache / '.lock', 'a+') as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertTrue(p.cache_busy(cache))
                self.assertTrue(self.lane._cache_busy(cache))

    def test_request_names_the_runner_makes_are_recognised(self):
        for attempt in (None, '1', '2'):
            name = self.lane.request_name(1775, '123456789', attempt)
            self.assertTrue(p.REQUEST_ID.match(name), name)
            self.assertTrue(p.REQUEST_ID.match(name + '-auto'), name)


if __name__ == '__main__':
    unittest.main()
