import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
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
    time.sleep(60 if args[1] in os.environ.get("FAKE_STALL", "").split(",") else 0.1)  # a stall never gets ready
elif args[0] == "shutdown":
    log({"shutdown": args[1]})
    if args[1] in world["devices"]:
        world["devices"][args[1]]["state"] = "Shutdown"
        save()
elif args[0] == "erase":
    state = world["devices"][args[1]]["state"]
    log({"erase": args[1], "state": state})
    failing = os.environ.get("FAKE_ERASE_FAIL", "")
    if state != "Shutdown" or failing == "1" or args[1] in failing.split(","):
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

    def test_a_device_that_failed_an_erase_goes_last_but_stays_in_the_pool(self):
        entries = {'A': entry('SM Lane Desk pool 1', '2026-10-08T01:00:00+00:00', erase_failed='2026-10-08T02:00:00+00:00'),
                   'B': entry('SM Lane Desk pool 2', '2026-10-08T03:00:00+00:00')}
        devices = {'A': device('SM Lane Desk pool 1'), 'B': device('SM Lane Desk pool 2')}
        plan = self.choose(entries, devices)
        self.assertEqual((plan.udid, sorted(plan.pool)), ('B', ['A', 'B']))
        self.assertEqual(self.choose(entries, devices, busy={'B'}).udid, 'A')  # still used when it is all there is

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
                    'FAKE_WORLD': str(self.world), 'SM_LANE_MEMORY_PRESSURE': '1'}
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
        """lane-sim-boot's main() in this process, without the real watcher, so a run takes a fraction of a second.

        The whole scripts suite has 180 s in `--plan fast` (verify-tests.py), so these tests can't each pay for a
        subprocess and a watcher's poll. One test below runs the real command with a real watcher.
        """
        module = self.lane_sim_boot_module()
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env), mock.patch.object(lane_sim, 'start_watcher'), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = module.main(list(arguments))
        return subprocess.CompletedProcess(arguments, code, out.getvalue(), err.getvalue())

    def run_real_command(self, *arguments):
        return subprocess.run(self.helper + list(arguments), env=dict(os.environ), capture_output=True, text=True,
                              timeout=90)

    def test_the_real_command_boots_a_pool_device_with_a_watcher_and_done_keeps_it(self):
        booted = self.run_real_command('--pool')
        self.assertEqual(booted.returncode, 0, booted.stderr)
        udid = booted.stdout.strip()
        self.assertEqual(booted.stdout, udid + '\n')  # the UDID is the only thing on stdout
        watcher = int(lane_sim.watch_files(udid)[2].read_text())
        os.kill(watcher, 0)  # running
        self.assertEqual(self.devices()[udid]['state'], 'Booted')
        self.assertNotIn('claimed', pool.load()[udid])  # the Booted state and the watcher hold it from here
        done = self.run_real_command('--done', udid)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('kept in the desk pool', done.stderr)
        for _ in range(50):
            try:
                os.kill(watcher, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(watcher, signal.SIGKILL)
            self.fail('the watcher outlived --done')
        self.assertEqual(self.devices()[udid]['state'], 'Shutdown')
        self.assertIn({'erase': udid, 'state': 'Shutdown'}, self.records())
        self.assertEqual(list(pool.load()), [udid])

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

    def stalled_helper(self, *arguments, stalls=()):
        """run_helper with the listed devices' SpringBoard restarting twice while they boot (#705)."""
        calls = {}

        def processes(udid):
            calls[udid] = calls.get(udid, 0) + 1
            return (10, 20 + min(calls[udid] - 1, 2)) if udid in stalls else (10, 20)

        with mock.patch.object(lane_sim, 'device_processes', processes), \
                mock.patch.object(lane_sim, 'post_stall') as posted:
            return self.run_helper(*arguments, FAKE_STALL=','.join(stalls)), posted

    def test_a_pool_boot_stall_retires_the_device_and_boots_one_fresh_pool_device(self):
        booted, posted = self.stalled_helper('--pool', stalls=('NEW-0001',))
        self.assertEqual((booted.returncode, booted.stdout), (0, 'NEW-0002\n'), booted.stderr)
        self.assertNotIn('NEW-0001', self.devices())  # deleted, never booted again
        self.assertEqual([r['boot'] for r in self.records() if 'boot' in r], ['NEW-0001', 'NEW-0002'])
        self.assertEqual(list(pool.load()), ['NEW-0002'])
        self.assertNotIn('claimed', pool.load()['NEW-0002'])
        self.assertIn('recovered', posted.call_args.args[2])
        self.assertEqual(self.run_helper('--done', 'NEW-0002').returncode, 0)

    def test_a_fresh_device_that_stalls_twice_stops_and_leaves_no_device_behind(self):
        booted, posted = self.stalled_helper('--fresh', 'SM Lane Desk intrun', stalls=('NEW-0001', 'NEW-0002'))
        self.assertEqual(booted.returncode, 3)
        self.assertIn('STOP', booted.stderr)
        self.assertEqual(booted.stdout, '')
        self.assertEqual(self.devices(), {})  # the stalled one and its fresh replacement are both deleted
        self.assertEqual([r['boot'] for r in self.records() if 'boot' in r], ['NEW-0001', 'NEW-0002'])
        self.assertIn('not recovered (two in a row)', posted.call_args.args[2])

    def test_a_named_device_that_stalls_gets_no_retry(self):
        self.seed('PLAIN-01', 'Some other phone', pooled=False)
        booted, posted = self.stalled_helper('PLAIN-01', stalls=('PLAIN-01',))
        self.assertEqual(booted.returncode, 3)
        self.assertEqual([r['boot'] for r in self.records() if 'boot' in r], ['PLAIN-01'])
        posted.assert_not_called()

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

    def test_a_device_that_will_not_erase_is_passed_over_and_stays_in_the_pool(self):
        self.seed('STUCK-01', 'SM Lane Desk pool 1', last_used='2026-10-08T01:00:00+00:00')
        self.seed('GOOD-002', 'SM Lane Desk pool 2', last_used='2026-10-08T03:00:00+00:00')
        first = self.run_helper('--pool', FAKE_ERASE_FAIL='STUCK-01')
        self.assertEqual((first.returncode, first.stdout.strip()), (0, 'GOOD-002'), first.stderr)  # the older one failed
        self.assertTrue(pool.load()['STUCK-01']['erase_failed'])
        self.assertFalse([r for r in self.records() if r.get('boot') == 'STUCK-01'])  # never booted unerased
        self.assertEqual(lane_sim.unsafe_devices(), {})  # an approved device isn't retired over an erase
        # With GOOD-002 up, the stuck one is all that is free: the pool grows instead of stopping.
        second = self.run_helper('--pool', FAKE_ERASE_FAIL='STUCK-01')
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.devices()[second.stdout.strip()]['name'], 'SM Lane Desk pool 3')
        for udid in ('GOOD-002', second.stdout.strip()):
            self.assertEqual(self.run_helper('--done', udid).returncode, 0)

    def test_when_no_device_will_erase_and_the_pool_is_full_the_run_stops_without_booting(self):
        for number, udid in enumerate(('A-0001', 'B-0002', 'C-0003'), 1):
            self.seed(udid, f'SM Lane Desk pool {number}')
        result = self.run_helper('--pool', FAKE_ERASE_FAIL='1')
        self.assertEqual(result.returncode, 3)
        self.assertIn('STOP: simctl erase failed', result.stderr)
        self.assertFalse([r for r in self.records() if 'boot' in r or 'create' in r])
        self.assertEqual(sorted(pool.load()), ['A-0001', 'B-0002', 'C-0003'])
        self.assertEqual(lane_sim.unsafe_devices(), {})

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

    def test_retire_after_flood_marks_a_pool_device_unsafe_and_leaves_other_devices_alone(self):
        self.seed('POOL-001', 'SM Lane Desk pool 1')
        self.assertTrue(pool.retire_after_flood('POOL-001', 'crash flood during app-tests'))
        self.assertIn('crash flood', lane_sim.unsafe_devices()['POOL-001']['reason'])
        self.assertFalse(pool.retire_after_flood('RUNNER-01', 'crash flood'))  # not ours: its caller decides
        self.assertEqual(list(lane_sim.unsafe_devices()), ['POOL-001'])

    def test_a_pool_device_that_flooded_is_deleted_by_the_next_run_not_erased_and_booted_again(self):
        udid = self.run_helper('--pool').stdout.strip()
        pool.retire_after_flood(udid, 'crash flood during app-tests')  # what verify-tests.py does ...
        subprocess.run(lane_sim.simctl() + ['shutdown', udid], capture_output=True)  # ... before it shuts the device down
        again = self.run_helper('--pool')
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertNotEqual(again.stdout.strip(), udid)
        self.assertNotIn(udid, self.devices())
        self.assertNotIn(udid, pool.load())
        self.assertFalse([r for r in self.records() if r.get('erase') == udid])
        self.assertEqual([r['boot'] for r in self.records() if 'boot' in r].count(udid), 1)  # booted once, ever

    def test_a_device_marked_unsafe_while_still_up_is_retired_once_it_is_shut_down(self):
        udid = self.run_helper('--pool').stdout.strip()
        lane_sim.mark_unsafe(udid, 'late crash report for a crash during boot')  # the watcher's late mark: still booted
        other = self.run_helper('--pool')
        self.assertEqual(other.returncode, 0, other.stderr)
        self.assertIn(udid, self.devices())  # not pulled out from under the run that may still hold it
        self.assertIn(udid, pool.load())
        subprocess.run(lane_sim.simctl() + ['shutdown', udid], capture_output=True)  # the guard-permitted shutdown
        third = self.run_helper('--pool')
        self.assertEqual(third.returncode, 0, third.stderr)
        self.assertNotIn(udid, self.devices())
        self.assertNotIn(udid, pool.load())
        self.assertFalse([r for r in self.records() if r.get('erase') == udid])

    def test_a_real_watcher_that_has_exited_leaves_its_pid_file_and_the_unsafe_device_is_still_retired(self):
        # What the journey docs tell the desk after a late crash mark: shut the device down, wait for the watcher
        # to exit, run --pool. Nothing removes watch-<udid>.pid when a watcher ends (only --done does), so the
        # docs must not say to wait for the file to go (Codex audit on #1099), and the pool must read an exited
        # watcher as gone although its file is still there.
        udid = self.run_real_command('--pool').stdout.strip()
        pid_file = lane_sim.watch_files(udid)[2]
        watcher = int(pid_file.read_text())
        lane_sim.mark_unsafe(udid, 'late crash report for a crash during boot')
        subprocess.run(lane_sim.simctl() + ['shutdown', udid], capture_output=True)
        held = self.run_helper('--pool')  # the watcher is still up, so the device is still held
        self.assertEqual(held.returncode, 0, held.stderr)
        self.assertIn(udid, pool.load())
        self.assertNotEqual(held.stdout.strip(), udid)
        lane_sim.watch_files(udid)[0].write_text('test: end the watcher on its own path\n')
        for _ in range(100):
            try:
                os.kill(watcher, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(watcher, signal.SIGKILL)
            self.fail('the watcher did not end')
        self.assertTrue(pid_file.exists())  # it stays: waiting for it to disappear would never end
        self.assertFalse(pool.watcher_alive(udid))
        after = self.run_helper('--pool')
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertNotIn(udid, self.devices())
        self.assertNotIn(udid, pool.load())
        self.assertFalse([r for r in self.records() if r.get('erase') == udid])

    def test_retire_marks_a_pool_device_unsafe_then_shuts_it_down_and_deletes_it(self):
        udid = self.run_helper('--pool').stdout.strip()
        result = self.run_helper('--retire', udid, 'crash flood: SpringBoard x3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('crash flood: SpringBoard x3', lane_sim.unsafe_devices()[udid]['reason'])
        self.assertNotIn(udid, self.devices())
        self.assertNotIn(udid, pool.load())
        order = [next(k for k in r if k in ('shutdown', 'delete', 'erase')) for r in self.records()
                 if r.get('shutdown') == udid or r.get('delete') == udid or r.get('erase') == udid]
        self.assertEqual((order[0], order[-1], 'erase' in order), ('shutdown', 'delete', False))  # never erased on the way out

    def test_retire_also_works_on_a_device_that_is_not_in_the_pool(self):
        self.seed('ONEOFF-1', 'SM Lane Desk one-off', 'Booted', pooled=False)
        result = self.run_helper('--retire', 'ONEOFF-1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(lane_sim.unsafe_devices()['ONEOFF-1']['reason'], 'retired by hand')
        self.assertNotIn('ONEOFF-1', self.devices())

    def test_a_second_done_leaves_a_released_device_alone(self):
        udid = self.run_helper('--pool').stdout.strip()
        self.assertEqual(self.run_helper('--done', udid).returncode, 0)
        before = self.records()
        again = self.run_helper('--done', udid)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn('left alone', again.stderr)
        self.assertEqual(self.records(), before)  # no shutdown, no erase

    def test_a_run_cannot_take_a_device_while_done_is_releasing_it(self):
        udid = self.run_helper('--pool').stdout.strip()
        taken = []
        real = lane_sim.release

        def release_then_another_run_takes_one(*args, **kwargs):
            real(*args, **kwargs)  # the watcher is gone and the device is shut down, but not yet erased:
            taken.append(pool.take('another run', out=self.quiet))  # only the releasing claim keeps it busy

        with mock.patch.object(lane_sim, 'release', release_then_another_run_takes_one):
            self.assertEqual(pool.release(udid, out=self.quiet), 'kept')
        self.assertNotEqual(taken, [udid])
        self.assertNotIn('claimed', pool.load()[udid])
        self.assertEqual(pool.load()[taken[0]]['claimed']['label'], 'another run')  # still theirs

    def test_a_device_the_watcher_marks_unsafe_while_done_waits_is_deleted_not_kept(self):
        udid = self.run_helper('--pool').stdout.strip()
        real = lane_sim.release

        def release_then_a_late_crash_report(*args, **kwargs):
            real(*args, **kwargs)
            lane_sim.mark_unsafe(udid, 'late crash report for a crash during boot')

        with mock.patch.object(lane_sim, 'release', release_then_a_late_crash_report):
            self.assertEqual(pool.release(udid, out=self.quiet), 'retired')
        self.assertNotIn(udid, self.devices())
        self.assertNotIn(udid, pool.load())
        self.assertFalse([r for r in self.records() if r.get('erase') == udid])

    def test_a_boot_that_worked_leaves_no_claim_for_a_reused_pid_to_keep_alive(self):
        udid = self.run_helper('--pool').stdout.strip()
        self.assertNotIn('claimed', pool.load()[udid])
        self.assertEqual(self.run_helper('--done', udid).returncode, 0)

    def test_the_pool_lock_makes_a_second_run_wait(self):
        self.seed('A-0001', 'SM Lane Desk pool 1')
        finished = threading.Event()
        holding, release_it = threading.Event(), threading.Event()

        def hold():
            with pool.locked():
                holding.set()
                release_it.wait(30)

        def take():
            pool.take('second run', out=self.quiet)
            finished.set()

        holder = threading.Thread(target=hold)
        holder.start()
        self.assertTrue(holding.wait(10))
        taker = threading.Thread(target=take)
        taker.start()
        self.assertFalse(finished.wait(0.5), 'take() ran while another run held the pool lock')
        release_it.set()
        self.assertTrue(finished.wait(30))
        holder.join()
        taker.join()

    def test_retire_shuts_the_device_down_before_it_waits_for_the_pool_lock(self):
        # Another run's erase can hold the pool lock for minutes (ERASE_TIMEOUT). A crash flood must stop first
        # (Codex audit on #1099): the device is down while the lock is still held, and only then deleted.
        udid = self.run_helper('--pool').stdout.strip()
        retired = []
        with pool.locked():
            retirer = threading.Thread(target=lambda: retired.append(self.run_helper('--retire', udid, 'crash flood')))
            retirer.start()
            self.addCleanup(retirer.join, 30)  # a failed assertion must not leave it running past the test
            state = None
            for _ in range(100):
                try:
                    state = self.devices().get(udid, {}).get('state')
                except ValueError:  # the fake simctl rewrites its world file in place
                    pass
                if state == 'Shutdown':
                    break
                time.sleep(0.1)
            self.assertEqual(state, 'Shutdown', 'retire waited for the pool lock before shutting the device down')
            self.assertTrue(retirer.is_alive())  # still waiting for the lock
            self.assertIn(udid, pool.load())
            self.assertIn('crash flood', lane_sim.unsafe_devices()[udid]['reason'])
        retirer.join(30)
        self.assertEqual(retired[0].returncode, 0, retired[0].stderr)
        self.assertNotIn(udid, self.devices())
        self.assertNotIn(udid, pool.load())

    def lane_sim_boot_module(self):
        loader = importlib.machinery.SourceFileLoader('lane_sim_boot_for_pool_test', str(SCRIPTS / 'lane-sim-boot'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module

    def boot_through_main(self, *arguments):
        module = self.lane_sim_boot_module()
        out = io.StringIO()
        with mock.patch.object(lane_sim, 'boot', return_value=1.0) as boot, \
                mock.patch.object(lane_sim, 'start_watcher'), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(self.quiet):
            self.assertEqual(module.main(list(arguments)), 0)
        return boot, out.getvalue().strip()

    def test_a_pool_boot_gets_the_first_boot_tolerance_because_the_device_was_just_erased(self):
        boot, udid = self.boot_through_main('--pool')
        self.assertEqual(boot.call_args.kwargs['first_boot'], True)
        self.assertNotIn('claimed', pool.load()[udid])
        self.seed('PLAIN-01', 'Some other phone', pooled=False)
        boot, _ = self.boot_through_main('PLAIN-01')  # an existing device named on the command line: no tolerance
        self.assertEqual(boot.call_args.kwargs['first_boot'], False)


if __name__ == '__main__':
    unittest.main()
