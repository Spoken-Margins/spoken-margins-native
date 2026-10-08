import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_sim  # noqa: E402
import lane_sim_pool as pool  # noqa: E402
import lane_slots  # noqa: E402

RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
OLD_STANDING = '1330F268-5467-4421-9D55-1FCC3FF5CF8A'

# A simctl that remembers its devices in $FAKE_WORLD, so create, boot, shutdown, erase and delete change
# what the next `list` says, the way the real one does.
FAKE_SIMCTL = r'''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
world_path = os.environ["FAKE_WORLD"]
world = json.load(open(world_path))
def log(entry):
    with open(os.environ["FAKE_RECORD"], "a") as handle:
        handle.write(json.dumps(entry) + "\n")
def save():
    json.dump(world, open(world_path, "w"))
def listing(only_booted):
    groups = {}
    for udid, device in world["devices"].items():
        if only_booted and device["state"] != "Booted":
            continue
        groups.setdefault(device["runtime"], []).append(
            {"udid": udid, "name": device["name"], "state": device["state"], "isAvailable": True})
    print(json.dumps({"devices": groups}))
if args[:2] == ["list", "devices"]:
    listing(args[2] == "booted")
elif args[:2] == ["list", "runtimes"]:
    print(json.dumps({"runtimes": [{"isAvailable": True, "platform": "iOS", "version": "26.5",
                                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}]}))
elif args[0] == "create":
    world["next"] += 1
    udid = "NEW-%04d" % world["next"]
    world["devices"][udid] = {"name": args[1], "state": "Shutdown", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}
    save()
    log({"create": args[1], "udid": udid})
    print(udid)
elif args[0] == "boot":
    log({"boot": args[1]})
    if os.environ.get("FAKE_BOOT") == "invalid":
        sys.stderr.write("Unable to boot device in current state: Shutdown\nInvalid argument\n")
        sys.exit(149)
    world["devices"][args[1]]["state"] = "Booted"
    save()
elif args[0] == "bootstatus":
    time.sleep(0.1)
elif args[0] == "shutdown":
    log({"shutdown": args[1]})
    if args[1] in world["devices"]:
        world["devices"][args[1]]["state"] = "Shutdown"
        save()
elif args[0] == "erase":
    state = world["devices"][args[1]]["state"]
    log({"erase": args[1], "state": state})
    if state != "Shutdown" or os.environ.get("FAKE_ERASE_FAIL"):
        sys.stderr.write("Unable to erase contents and settings in current state: %s\n" % state)
        sys.exit(163)
elif args[0] == "delete":
    log({"delete": args[1]})
    world["devices"].pop(args[1], None)
    save()
'''


def entry(name, last_used=None, **rest):
    return {'name': name, **({'last_used': last_used} if last_used else {}), **rest}


def device(name, state='Shutdown', major=26):
    return {'name': name, 'state': state, 'major': major}


class ChooseTests(unittest.TestCase):
    """The pool's rules, without a simulator: what the next desk run does (#688)."""

    def choose(self, entries, devices, unsafe=None, busy=(), size=3):
        return pool.choose(entries, devices, unsafe or {}, set(busy), size)

    def test_an_empty_pool_creates_the_first_device(self):
        plan = self.choose({}, {})
        self.assertEqual((plan.action, plan.name, plan.drop), ('create', 'SM Lane Desk pool 1', []))

    def test_a_free_device_is_erased_and_reused_not_replaced(self):
        plan = self.choose({'A': entry('SM Lane Desk pool 1', '2026-10-08T01:00:00+00:00')},
                           {'A': device('SM Lane Desk pool 1')})
        self.assertEqual((plan.action, plan.udid), ('reuse', 'A'))

    def test_the_least_recently_used_free_device_goes_first_and_a_new_one_before_that(self):
        entries = {'A': entry('SM Lane Desk pool 1', '2026-10-08T03:00:00+00:00'),
                   'B': entry('SM Lane Desk pool 2', '2026-10-08T01:00:00+00:00')}
        devices = {'A': device('SM Lane Desk pool 1'), 'B': device('SM Lane Desk pool 2')}
        self.assertEqual(self.choose(entries, devices).udid, 'B')
        entries['C'] = entry('SM Lane Desk pool 3')  # never used
        devices['C'] = device('SM Lane Desk pool 3')
        self.assertEqual(self.choose(entries, devices).udid, 'C')

    def test_a_busy_device_is_skipped(self):
        entries = {'A': entry('SM Lane Desk pool 1', '2026-10-08T01:00:00+00:00'),
                   'B': entry('SM Lane Desk pool 2', '2026-10-08T03:00:00+00:00')}
        devices = {'A': device('SM Lane Desk pool 1', 'Booted'), 'B': device('SM Lane Desk pool 2')}
        self.assertEqual(self.choose(entries, devices, busy={'A'}).udid, 'B')

    def test_a_pool_with_room_grows_when_every_device_is_busy_and_names_the_gap(self):
        entries = {'A': entry('SM Lane Desk pool 1'), 'C': entry('SM Lane Desk pool 3')}
        devices = {'A': device('SM Lane Desk pool 1', 'Booted'), 'C': device('SM Lane Desk pool 3', 'Booted')}
        plan = self.choose(entries, devices, busy={'A', 'C'})
        self.assertEqual((plan.action, plan.name), ('create', 'SM Lane Desk pool 2'))

    def test_a_full_pool_of_busy_devices_never_grows_past_its_size(self):
        entries = {u: entry(f'SM Lane Desk pool {n}') for n, u in enumerate('ABC', 1)}
        devices = {u: device(f'SM Lane Desk pool {n}', 'Booted') for n, u in enumerate('ABC', 1)}
        plan = self.choose(entries, devices, busy='ABC')
        self.assertEqual((plan.action, plan.udid, plan.name), ('busy', None, None))

    def test_a_device_marked_unsafe_is_retired_and_deleted_never_reused(self):
        entries = {'A': entry('SM Lane Desk pool 1', '2026-10-08T01:00:00+00:00'),
                   'B': entry('SM Lane Desk pool 2', '2026-10-08T03:00:00+00:00')}
        devices = {'A': device('SM Lane Desk pool 1'), 'B': device('SM Lane Desk pool 2')}
        plan = self.choose(entries, devices, unsafe={'A': {'reason': 'simctl boot failed: Invalid argument'}})
        self.assertEqual((plan.action, plan.udid), ('reuse', 'B'))
        self.assertEqual([(udid, delete) for udid, _, delete in plan.drop], [('A', True)])
        self.assertIn('Invalid argument', plan.drop[0][1])
        self.assertNotIn('A', plan.pool)

    def test_with_the_only_device_unsafe_the_next_run_gets_a_new_one(self):
        plan = self.choose({'A': entry('SM Lane Desk pool 1')}, {'A': device('SM Lane Desk pool 1')},
                           unsafe={'A': {'reason': 'crash flood'}})
        self.assertEqual((plan.action, plan.name), ('create', 'SM Lane Desk pool 1'))

    def test_an_unsafe_device_a_run_still_holds_is_kept_but_never_chosen(self):
        entries = {'A': entry('SM Lane Desk pool 1')}
        devices = {'A': device('SM Lane Desk pool 1', 'Booted')}
        plan = self.choose(entries, devices, unsafe={'A': {'reason': 'late crash report'}}, busy={'A'})
        self.assertEqual((plan.action, plan.drop), ('create', []))
        self.assertIn('A', plan.pool)  # --done retires it; the run that holds it is not pulled from under

    def test_the_old_standing_device_is_dropped_untouched_and_never_adopted(self):
        plan = self.choose({OLD_STANDING: entry('SM Lane Desk pool 1')}, {OLD_STANDING: device('SM Lane Desk pool 1')})
        self.assertEqual(plan.action, 'create')
        self.assertEqual([(udid, delete) for udid, _, delete in plan.drop], [(OLD_STANDING, False)])
        lost = self.choose({}, {OLD_STANDING: device('SM Lane Desk pool 1')})  # no pool file: adoption by name
        self.assertEqual((lost.action, lost.pool), ('create', {}))

    def test_a_device_simctl_lost_or_on_another_ios_leaves_the_pool_without_being_deleted(self):
        entries = {'GONE': entry('SM Lane Desk pool 1'), 'NEWER': entry('SM Lane Desk pool 2')}
        plan = self.choose(entries, {'NEWER': device('SM Lane Desk pool 2', major=27)})
        self.assertEqual(plan.action, 'create')
        self.assertEqual(sorted((udid, delete) for udid, _, delete in plan.drop), [('GONE', False), ('NEWER', False)])

    def test_a_lost_pool_file_takes_the_pool_devices_back_by_name_up_to_the_pool_size(self):
        devices = {u: device(f'SM Lane Desk pool {n}') for n, u in enumerate('ABCD', 1)}
        devices['Z'] = device('Someone else\'s phone')
        plan = self.choose({}, devices)
        self.assertEqual((plan.action, sorted(plan.pool)), ('reuse', ['A', 'B', 'C']))

    def test_a_lost_pool_file_does_not_adopt_a_device_marked_unsafe(self):
        plan = self.choose({}, {'A': device('SM Lane Desk pool 1')}, unsafe={'A': {'reason': 'crash'}})
        self.assertEqual((plan.action, plan.pool), ('create', {}))

    def test_busy_means_up_in_simctl_watched_or_claimed_by_a_live_process(self):
        entries = {'UP': entry('1'), 'WATCHED': entry('2'), 'CLAIMED': entry('3', claimed={'pid': 7}),
                   'STALE': entry('4', claimed={'pid': 8}), 'IDLE': entry('5')}
        devices = {name: device(name) for name in entries}
        devices['UP']['state'] = 'Booted'
        busy = pool.busy_devices(entries, devices, alive=lambda pid: pid == 7, watching=lambda udid: udid == 'WATCHED')
        self.assertEqual(busy, {'UP', 'WATCHED', 'CLAIMED'})


class PoolDeviceTests(unittest.TestCase):
    """take() and `lane-sim-boot --pool` / `--done` against a simctl that remembers its devices."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        folder = Path(self.temporary.name)
        fake = folder / 'simctl'
        fake.write_text(FAKE_SIMCTL)
        fake.chmod(0o755)
        (folder / 'reports').mkdir()
        self.world = folder / 'world.json'
        self.world.write_text(json.dumps({'devices': {}, 'next': 0}))
        self.record = folder / 'record.jsonl'
        self.env = {'SM_LANE_STATE_DIR': str(folder / 'state'), 'SM_LANE_SIMCTL': str(fake),
                    'SM_LANE_CRASH_REPORTS': str(folder / 'reports'), 'FAKE_RECORD': str(self.record),
                    'FAKE_WORLD': str(self.world), 'SM_LANE_MEMORY_PRESSURE': '1', 'SM_LANE_BUILD_NEEDS_ROOM': ''}
        for patch in (mock.patch.dict(os.environ, self.env), mock.patch.object(lane_sim, 'CRASH_POLL_SECONDS', 0.05),
                      mock.patch.object(lane_slots, 'POLL_SECONDS', 0.05)):
            patch.start()
            self.addCleanup(patch.stop)
        self.quiet = open(os.devnull, 'w')
        self.addCleanup(self.quiet.close)
        self.addCleanup(self.end_watchers)
        self.helper = [sys.executable, str(SCRIPTS / 'lane-sim-boot')]

    def end_watchers(self):
        for pid_file in Path(self.env['SM_LANE_STATE_DIR']).glob('watch-*.pid'):
            udid = pid_file.name[len('watch-'):-len('.pid')]
            lane_sim.watch_files(udid)[0].write_text('test ended\n')
            try:
                pid = int(pid_file.read_text())
            except (OSError, ValueError):
                continue
            for _ in range(100):
                command = subprocess.run(['ps', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout
                if f'--watch {udid}' not in command:
                    break
                time.sleep(0.1)
            else:
                os.kill(pid, signal.SIGKILL)

    def records(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def seed(self, udid, name, state='Shutdown', pooled=True, last_used=None):
        world = json.loads(self.world.read_text())
        world['devices'][udid] = {'name': name, 'state': state, 'runtime': RUNTIME}
        self.world.write_text(json.dumps(world))
        if pooled:
            entries = pool.load()
            entries[udid] = entry(name, last_used)
            pool.save(entries)

    def devices(self):
        return json.loads(self.world.read_text())['devices']

    def run_helper(self, *arguments, **env):
        return subprocess.run(self.helper + list(arguments), env=dict(os.environ, **env), capture_output=True,
                              text=True, timeout=90)

    def test_the_second_desk_run_erases_the_first_device_instead_of_creating_another(self):
        first = self.run_helper('--pool')
        self.assertEqual(first.returncode, 0, first.stderr)
        udid = first.stdout.strip()
        self.assertEqual(self.devices()[udid]['name'], 'SM Lane Desk pool 1')
        self.assertEqual(self.devices()[udid]['state'], 'Booted')
        self.assertEqual(self.run_helper('--done', udid).returncode, 0)

        second = self.run_helper('--pool')
        self.assertEqual((second.returncode, second.stdout.strip()), (0, udid), second.stderr)
        self.assertEqual([r['create'] for r in self.records() if 'create' in r], ['SM Lane Desk pool 1'])  # once
        sequence = [next(k for k in r if k != 'state') for r in self.records() if r.get('boot') or r.get('erase')]
        self.assertEqual(sequence, ['boot', 'erase', 'erase', 'boot'])  # boot; --done erases; erase again; boot
        self.assertEqual(self.run_helper('--done', udid).returncode, 0)

    def test_done_shuts_a_pool_device_down_erases_and_keeps_it_but_still_deletes_other_devices(self):
        udid = self.run_helper('--pool').stdout.strip()
        done = self.run_helper('--done', udid)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('kept in the desk pool', done.stderr)
        self.assertIn(udid, self.devices())
        self.assertNotIn({'delete': udid}, self.records())
        self.assertIn({'erase': udid, 'state': 'Shutdown'}, self.records())
        self.assertEqual(list(pool.load()), [udid])
        self.assertNotIn('claimed', pool.load()[udid])
        fresh = self.run_helper('--fresh', 'SM Lane Desk one-off').stdout.strip()
        self.assertEqual(self.run_helper('--done', fresh).returncode, 0)
        self.assertNotIn(fresh, self.devices())  # --fresh devices are still deleted
        self.assertEqual(list(pool.load()), [udid])

    def test_a_failed_boot_retires_the_device_and_the_next_run_gets_a_new_one(self):
        failed = self.run_helper('--pool', FAKE_BOOT='invalid')
        self.assertEqual(failed.returncode, 3)
        self.assertIn('STOP', failed.stderr)
        (bad,) = lane_sim.unsafe_devices()
        self.assertEqual(list(pool.load()), [bad])
        self.assertNotIn('claimed', pool.load()[bad])

        again = self.run_helper('--pool')
        self.assertEqual(again.returncode, 0, again.stderr)
        replacement = again.stdout.strip()
        self.assertNotEqual(replacement, bad)
        self.assertNotIn(bad, self.devices())  # deleted, never erased or booted again
        self.assertEqual(list(pool.load()), [replacement])
        self.assertEqual([r['boot'] for r in self.records() if 'boot' in r], [bad, replacement])
        self.assertFalse([r for r in self.records() if r.get('erase') == bad])
        self.assertEqual(self.run_helper('--done', replacement).returncode, 0)

    def test_done_on_a_pool_device_marked_unsafe_deletes_it_and_drops_it_from_the_pool(self):
        self.seed('BAD-0001', 'SM Lane Desk pool 1')
        lane_sim.mark_unsafe('BAD-0001', 'crashed during boot')
        done = self.run_helper('--done', 'BAD-0001')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('deleted', done.stderr)
        self.assertNotIn('BAD-0001', self.devices())
        self.assertEqual(pool.load(), {})
        self.assertFalse([r for r in self.records() if r.get('erase')])

    def test_the_old_standing_device_is_never_erased_or_booted(self):
        self.seed(OLD_STANDING, 'SM Lane Desk pool 1')
        result = self.run_helper('--pool')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(result.stdout.strip(), OLD_STANDING)
        self.assertIn(OLD_STANDING, self.devices())  # left alone, not deleted
        self.assertFalse([r for r in self.records() if OLD_STANDING in r.values()])
        self.assertNotIn(OLD_STANDING, pool.load())
        self.assertEqual(self.run_helper('--done', result.stdout.strip()).returncode, 0)

    def test_an_erase_that_fails_stops_without_booting_and_keeps_the_device_in_the_pool(self):
        self.seed('KEEP-0001', 'SM Lane Desk pool 1')
        result = self.run_helper('--pool', FAKE_ERASE_FAIL='1')
        self.assertEqual(result.returncode, 3)
        self.assertIn('STOP: simctl erase failed', result.stderr)
        self.assertFalse([r for r in self.records() if 'boot' in r])
        self.assertEqual(list(pool.load()), ['KEEP-0001'])
        self.assertEqual(lane_sim.unsafe_devices(), {})  # an approved device isn't retired over an erase

    def test_a_listing_that_fails_does_not_retire_the_pool(self):
        self.seed('KEEP-0001', 'SM Lane Desk pool 1')
        with mock.patch.object(pool.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'simctl')):
            with self.assertRaises(lane_sim.BootError):
                pool.take('test', out=self.quiet)
        self.assertEqual(list(pool.load()), ['KEEP-0001'])

    def test_two_runs_at_once_never_get_the_same_device(self):
        self.seed('A-0001', 'SM Lane Desk pool 1', last_used='2026-10-08T01:00:00+00:00')
        first = pool.take('first run', out=self.quiet)
        second = pool.take('second run', out=self.quiet)  # the first's claim is a live process: this one
        third = pool.take('third run', out=self.quiet)
        self.assertEqual(first, 'A-0001')
        self.assertEqual(len({first, second, third}), 3)
        self.assertEqual(sorted(e['name'] for e in pool.load().values()),
                         ['SM Lane Desk pool 1', 'SM Lane Desk pool 2', 'SM Lane Desk pool 3'])
        with self.assertRaisesRegex(lane_sim.BootError, 'all 3 desk simulators are in use'):
            pool.take('fourth run', out=self.quiet)
        self.assertEqual(len([r for r in self.records() if 'create' in r]), 2)

    def test_unclaim_hands_a_device_back_for_the_next_run(self):
        self.seed('A-0001', 'SM Lane Desk pool 1')
        self.assertEqual(pool.take('run', out=self.quiet), 'A-0001')
        self.assertIn('claimed', pool.load()['A-0001'])
        pool.unclaim('A-0001')
        self.assertEqual(pool.take('another run', out=self.quiet), 'A-0001')


if __name__ == '__main__':
    unittest.main()
