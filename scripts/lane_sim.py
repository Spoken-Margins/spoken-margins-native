"""Booting lane simulators safely. Used by scripts/lane-sim-boot (the Test Desk), the runner, and
verify-tests.py, so every lane boot follows the same rules.

Two SpringBoard crash floods reached the owner's screen (2026-09-28 17:46, 2026-09-29 09:58, #184).
Both followed a `simctl boot` that failed with "Invalid argument" and then a retry on the same device.
So each boot:
- refuses a device marked unsafe (a failed boot or a crash during boot marks it);
- holds the Mac-wide simulator-boot lock, so one simulator boots at a time;
- waits while another simulator is booted (one at a time on this 16 GB Mac);
- holds both build slots, so no build runs while a simulator boots;
- never retries a failed `simctl boot`: it shuts the device down and marks it unsafe;
- watches the device's SpringBoard process until it is ready, and stops at the first restart or
  disappearance (crash reports reach DiagnosticReports about 80 s late, after a flood is under way),
  with crash reports as a second signal.
The whole simulator job holds the Mac-wide simulator slot (lane_slots.py), so the runner's T3 and
the Test Desk's T4 never run simulators at the same time. After the boot, a background watcher
(`lane-sim-boot --watch`) keeps watching SpringBoard, shuts the device down and marks it unsafe at
the first crash, and holds the Test Desk's simulator slot until the device is gone.
`lane-sim-boot --done <udid>` tells the watcher a shutdown is coming, so it isn't counted as a
crash, then shuts the device down and deletes it; the slot frees when the watcher exits.
A fresh device's first boot migrates data for several minutes, hence the long readiness wait.

The unsafe list is ~/Library/Caches/SpokenMarginsLane/unsafe-simulators.json. The lane guard blocks
any command naming a device on it, except deleting or shutting it down.
Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import contextlib
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

from lane_slots import build_slot_file, simulator_boot_lock, state_dir, SLOTS

IOS_MAJOR = 26  # iOS 27's Apple Intelligence services crash-flood on this Mac (#184)
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
FIRST_BOOT_TIMEOUT = 900
LOCK_WAIT = 1800
MAX_BOOTED = 1  # 16 GB Mac: a second simulator plus builds filled swap (#184)
RELEASE_WAIT = 130
# Both boots the watcher stopped on 2026-09-29 happened under memory pressure (#184), so a boot first
# waits, holding the build slots so no new build adds to it, for pressure to be normal again.
PRESSURE_WAIT = 600
PRESSURE_NAMES = {1: 'normal', 2: 'warn', 4: 'critical'}
# Three first boots on 2026-09-29 stopped on a SpringBoard change in their first 8-12 s with no crash
# report. The owner accepted "one simulator failure or crash" (#184), so during the first 30 s of a
# first boot one change is tolerated; a second, or any crash report, still stops the boot, and the
# watcher rechecks crash reports for a while after the boot (they land about 80 s late).
FIRST_BOOT_TOLERANCE = 30
LATE_REPORT_WAIT = 150
CRASH_POLL_SECONDS = 1.0


def crash_reports_dir() -> Path:
    return Path(os.environ.get('SM_LANE_CRASH_REPORTS') or Path.home() / 'Library/Logs/DiagnosticReports')


class BootError(Exception):
    """The device isn't ready and must not be retried as is."""


def simctl() -> list[str]:
    return shlex.split(os.environ.get('SM_LANE_SIMCTL', 'xcrun simctl'))


def unsafe_path() -> Path:
    return state_dir() / 'unsafe-simulators.json'


def unsafe_devices() -> dict:
    try:
        return json.loads(unsafe_path().read_text())
    except (OSError, ValueError):
        return {}


def mark_unsafe(udid: str, reason: str) -> None:
    devices = unsafe_devices()
    devices[udid] = {'reason': reason, 'marked': datetime.datetime.now().isoformat(timespec='seconds')}
    unsafe_path().parent.mkdir(parents=True, exist_ok=True)
    unsafe_path().write_text(json.dumps(devices, indent=2, sort_keys=True) + '\n')


def booted_udids() -> set:
    listing = json.loads(subprocess.check_output(simctl() + ['list', 'devices', 'booted', '--json'], text=True))
    return {d['udid'] for group in listing.get('devices', {}).values() for d in group}


def newest_runtime(major: int = IOS_MAJOR) -> str | None:
    runtimes = json.loads(subprocess.check_output(simctl() + ['list', 'runtimes', '--json'], text=True))
    usable = [r for r in runtimes.get('runtimes', [])
              if r.get('isAvailable') and r.get('platform') == 'iOS' and r.get('version', '').split('.')[0] == str(major)]
    usable.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
    return usable[-1]['identifier'] if usable else None


def create_temporary(name: str) -> str:
    """Create a fresh iPhone on the newest iOS 26 runtime. The caller deletes it when done."""
    runtime = newest_runtime()
    if not runtime:
        raise BootError(f'No iOS {IOS_MAJOR} simulator runtime is installed.')
    return subprocess.check_output(simctl() + ['create', name, DEVICE_TYPE, runtime], text=True).strip()


def crash_snapshot(reports: Path) -> dict:
    return {p: (p.stat().st_mtime_ns, p.stat().st_size) for p in reports.glob('*.ips')} if reports.is_dir() else {}


def new_crash(reports: Path, baseline: dict, udid: str) -> Path | None:
    if not reports.is_dir():
        return None
    for path in reports.glob('*.ips'):
        try:
            if baseline.get(path) == (path.stat().st_mtime_ns, path.stat().st_size):
                continue
            if f'com.apple.CoreSimulator.SimDevice.{udid}' in path.read_text(errors='replace'):
                return path
        except OSError:
            continue
    return None


def device_processes(udid: str, ps_output: str | None = None) -> tuple:
    """(launchd_sim pid, SpringBoard pid) for a booted device, read from `ps`; None where absent."""
    text = ps_output if ps_output is not None else subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True)
    rows = []
    for line in text.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    launchd = next((pid for pid, _, command in rows
                    if command.split(' ', 1)[0].endswith('launchd_sim') and f'/{udid}/' in command), None)
    springboard = next((pid for pid, parent, command in rows
                        if launchd is not None and parent == launchd and command.endswith('SpringBoard.app/SpringBoard')),
                       None)
    return launchd, springboard


class SpringBoardMonitor:
    """Notices SpringBoard crashing on one device from its process ID, at once.

    check() returns a description of a crash, 'shut down' when the device is gone, or None.
    A vanished SpringBoard counts only if the device is still running after a short grace, because
    an intentional shutdown also ends SpringBoard a moment before launchd_sim.
    """

    def __init__(self, udid: str, processes=None, grace: float = 3.0, clock=time.monotonic, on_event=None):
        self.udid, self.grace, self.clock = udid, grace, clock
        self.processes = processes if processes is not None else device_processes
        self.seen, self.vanished_at, self.latest, self.shutdown_noted = None, None, None, False
        self.on_event = on_event  # records each SpringBoard change, to find out why some first boots see one

    def accept(self) -> None:
        """Take the current SpringBoard (or its absence) as the new normal after a tolerated change."""
        self.seen, self.vanished_at = self.latest, None

    def note(self, text: str) -> None:
        if self.on_event:
            self.on_event(text)

    def check(self) -> str | None:
        launchd, springboard = self.processes(self.udid)
        self.latest = springboard
        if launchd is None:
            if self.seen is not None and not self.shutdown_noted:
                self.note('device shut down')
                self.shutdown_noted = True
            return 'shut down' if self.seen is not None else None
        if springboard is not None:
            if self.seen is not None and springboard != self.seen:
                self.note(f'SpringBoard pid {springboard} replaced pid {self.seen}')
                return f'SpringBoard restarted (pid {self.seen} -> {springboard})'
            if self.seen is None:
                self.note(f'SpringBoard pid {springboard} up (launchd_sim {launchd})')
            self.seen, self.vanished_at = springboard, None
            return None
        if self.seen is None:
            return None  # still booting
        if self.vanished_at is None:
            self.note(f'SpringBoard pid {self.seen} gone, launchd_sim {launchd} still running')
            self.vanished_at = self.clock()
            return None
        if self.clock() - self.vanished_at >= self.grace:
            return f'SpringBoard (pid {self.seen}) vanished while the device kept running'
        return None


def watch_files(udid: str) -> tuple:
    folder = state_dir()
    return folder / f'watch-{udid}.stop', folder / f'watch-{udid}.log', folder / f'watch-{udid}.pid'


def report_time(text: str) -> float | None:
    """When the crash in a .ips report happened.

    The body's captureTime is the crash; the header's timestamp is when the report was written, about
    80 s later (SpringBoard at 09:58:01 was written at 09:59:24), so it's only a fallback.
    """
    match = re.search(r'"captureTime"\s*:\s*"([^"]+)"', text)
    try:
        stamp = match.group(1) if match else json.loads(text.split('\n', 1)[0])['timestamp']
        return datetime.datetime.strptime(stamp, '%Y-%m-%d %H:%M:%S.%f %z').timestamp()
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def late_report(reports: Path, udid: str, window: tuple) -> Path | None:
    """A crash report naming the device for a crash inside the boot window (a later app crash doesn't count)."""
    start, end = window
    if not reports.is_dir():
        return None
    for path in reports.glob('*.ips'):
        try:
            if path.stat().st_mtime < start:
                continue
            text = path.read_text(errors='replace')
        except OSError:
            continue
        when = report_time(text)
        if f'com.apple.CoreSimulator.SimDevice.{udid}' in text and when is not None and start - 1 <= when <= end + 1:
            return path
    return None


def watch(udid: str, poll: float = 1.0, monitor: SpringBoardMonitor | None = None, crash_window: tuple | None = None,
          now=time.time) -> str:
    """Watch a booted device until it shuts down or is released; stop it at the first SpringBoard crash.

    With crash_window (the boot's start and end, epoch seconds), it also looks for crash reports of a crash
    during the boot until LATE_REPORT_WAIT after it, and marks the device unsafe after the fact if one
    appears (the device keeps running; the guard then refuses further commands on it).
    """
    stop_flag, _, _ = watch_files(udid)
    monitor = monitor or SpringBoardMonitor(udid)
    recheck = crash_window
    while True:
        if recheck and now() > recheck[1] + LATE_REPORT_WAIT:
            print(f'[lane] no crash report for the boot of {udid}', flush=True)
            recheck = None
        if recheck:
            found = late_report(crash_reports_dir(), udid, recheck)
            if found:
                mark_unsafe(udid, f'late crash report for a crash during boot: {found.name}')
                print(f'[lane] {found.name} reports a crash during the boot of {udid}; marked unsafe', flush=True)
                record_event(udid, f'late crash report: {found.name}; marked unsafe')
                recheck = None
        if stop_flag.exists():
            # Released: keep any simulator slot this process holds until the device is really gone.
            deadline = time.monotonic() + RELEASE_WAIT
            while monitor.processes(udid)[0] is not None and time.monotonic() < deadline:
                time.sleep(poll)
            return 'released'
        seen = monitor.check()
        if seen == 'shut down':
            return 'shut down'
        if seen:
            stop(udid, f'{seen} after boot')
            return f'crash: {seen}; shut down and marked unsafe'
        time.sleep(poll)


def start_watcher(udid: str, helper: Path, slot=None, crash_window: tuple | None = None) -> None:
    """Run `lane-sim-boot --watch <udid>` in the background, logging next to the lane's other state.

    With slot (an open simulator-slot handle), the watcher inherits it and holds the slot until it exits.
    """
    stop_flag, log, pid_file = watch_files(udid)
    stop_flag.unlink(missing_ok=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('a') as handle:
        window = ['--crash-window', f'{crash_window[0]:.3f}', f'{crash_window[1]:.3f}'] if crash_window else []
        watcher = subprocess.Popen([sys.executable, str(helper), '--watch', udid, *window], stdout=handle,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True,
                                   pass_fds=(slot.fileno(),) if slot else ())
    pid_file.write_text(f'{watcher.pid}\n')


def release(udid: str, wait: float = RELEASE_WAIT) -> None:
    """Tell the watcher a shutdown is coming, shut the device down, delete it, and wait for the watcher."""
    stop_flag, _, pid_file = watch_files(udid)
    stop_flag.parent.mkdir(parents=True, exist_ok=True)
    stop_flag.write_text('released\n')
    subprocess.run(simctl() + ['shutdown', udid], capture_output=True, timeout=120)
    subprocess.run(simctl() + ['delete', udid], capture_output=True, timeout=120)
    try:
        pid = int(pid_file.read_text())
    except (OSError, ValueError):
        pid = None
    deadline = time.monotonic() + wait
    while pid and time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    stop_flag.unlink(missing_ok=True)
    pid_file.unlink(missing_ok=True)


def record_event(udid: str, text: str) -> None:
    """Append to the Mac-wide boot log, which keeps good boots' events too (#184)."""
    try:
        with (state_dir() / 'boot-events.log').open('a') as log:
            log.write(f'{datetime.datetime.now().isoformat(timespec="seconds")} {udid} {text}\n')
    except OSError:
        pass


def wait_until_ready(udid: str, is_ready, monitor, find_crash, timeout: float, clock=time.monotonic,
                     sleep=time.sleep, poll: float | None = None, out=None, tolerate_until: float | None = None,
                     record=None) -> str | None:
    """Poll until is_ready(); at a SpringBoard change or crash report, stop the device and raise.

    With tolerate_until (seconds), one SpringBoard change within that time from the start is logged
    and tolerated; returns its description, or None. The clock, sleep, monitor and crash source are
    injectable so the rules can be tested without real timing or the real DiagnosticReports folder.
    """
    started = clock()

    def note(text):
        if out is not None:
            print(f'[lane] +{clock() - started:.1f}s {text}', file=out, flush=True)
        if record is not None:
            record(f'+{clock() - started:.1f}s {text}')

    monitor.on_event = note
    tolerated = None
    while not is_ready():
        seen = monitor.check()
        if seen and seen != 'shut down' and tolerate_until is not None and tolerated is None \
                and clock() - started <= tolerate_until:
            tolerated = seen
            monitor.accept()
            note(f'tolerated: {seen}, in the first {tolerate_until:.0f}s of a first boot (owner, #184); '
                 'a second change or any crash report still stops the boot')
            seen = None
        if seen and seen != 'shut down':
            stop(udid, f'{seen} during boot')
            raise BootError(f'{seen} while booting. The device is shut down and marked unsafe. '
                            'Delete it and use a fresh device.')
        crash = find_crash()
        if crash:
            stop(udid, f'crashed during boot: {crash.name}')
            raise BootError(f'{crash.name} while booting. The device is shut down and marked '
                            'unsafe. Delete it and use a fresh device.')
        if clock() - started > timeout:
            subprocess.run(simctl() + ['shutdown', udid], capture_output=True, timeout=120)
            raise BootError(f'not ready after {timeout:.0f}s; shut down (not marked unsafe).')
        sleep(CRASH_POLL_SECONDS if poll is None else poll)
    return tolerated


@contextlib.contextmanager
def all_build_slots(label: str, out, max_wait: float):
    with contextlib.ExitStack() as stack:
        for index in range(SLOTS):  # by name: the one-slot rule during a simulator job mustn't apply here
            stack.enter_context(build_slot_file(index, label, out=out, max_wait=max_wait))
        yield


def memory_pressure_level() -> int | None:
    """The kernel's memory pressure level: 1 normal, 2 warn, 4 critical (None if unreadable)."""
    if os.environ.get('SM_LANE_MEMORY_PRESSURE'):  # tests
        return int(os.environ['SM_LANE_MEMORY_PRESSURE'])
    try:
        return int(subprocess.check_output(['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'], text=True))
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None


def wait_for_normal_pressure(max_wait: float, poll: float = 10, level=None, clock=time.monotonic,
                             sleep=time.sleep) -> tuple:
    """Wait up to max_wait for normal memory pressure; returns (level name, seconds waited). Never fails."""
    level = level or memory_pressure_level
    started = clock()
    while True:
        current = level()
        if current in (1, None) or clock() - started >= max_wait:
            return PRESSURE_NAMES.get(current, 'unknown'), clock() - started
        sleep(poll)


def wait_for_room(udid: str, max_wait: float, poll: float = 15, booted=booted_udids) -> None:
    started = time.monotonic()
    while True:
        running = booted() - {udid}
        if len(running) < MAX_BOOTED:
            return
        if time.monotonic() - started >= max_wait:
            raise BootError(f'another simulator stayed booted for {max_wait:.0f}s, so this one was not booted.')
        time.sleep(poll)


def stop(udid: str, reason: str) -> None:
    subprocess.run(simctl() + ['shutdown', udid], capture_output=True, timeout=120)
    mark_unsafe(udid, reason)


def boot(udid: str, label: str, out=sys.stderr, timeout: float | None = None, lock_wait: float | None = None,
         info: dict | None = None, first_boot: bool = False) -> float:
    """Boot one simulator under the lane's rules and wait until it is ready. Returns seconds taken.

    Raises BootError with the reason; a failed boot or a crash during boot also marks the device unsafe.
    If info is given, it receives the memory pressure at boot, how long the boot waited for it, the boot's
    window (epoch start and end, for the watcher's late crash-report check) and any tolerated change.
    first_boot marks a device that has never booted: its first 30 s may tolerate one SpringBoard change.
    """
    info = {} if info is None else info
    timeout = FIRST_BOOT_TIMEOUT if timeout is None else timeout
    lock_wait = LOCK_WAIT if lock_wait is None else lock_wait
    reports = crash_reports_dir()
    listed = unsafe_devices().get(udid)
    if listed:
        raise BootError(f'{udid} is marked unsafe ({listed["reason"]}). Delete it and use a fresh device.')
    try:
        with simulator_boot_lock(label, out=out, max_wait=lock_wait):
            wait_for_room(udid, lock_wait)
            with all_build_slots(f'{label} (no builds while booting)', out, lock_wait):
                pressure, waited = wait_for_normal_pressure(PRESSURE_WAIT)
                info.update(pressure=pressure, pressure_waited=round(waited))
                print(f'[lane] memory pressure at boot: {pressure} (waited {waited:.0f}s for normal)', file=out,
                      flush=True)
                started = time.monotonic()
                wall_start = time.time()
                record_event(udid, f'boot started ({"first boot" if first_boot else "existing device"}, '
                                   f'memory pressure {pressure})')
                baseline = crash_snapshot(reports)
                try:
                    booted = subprocess.run(simctl() + ['boot', udid], capture_output=True, text=True, timeout=120)
                except subprocess.TimeoutExpired:
                    stop(udid, 'simctl boot hung for 120s')
                    raise BootError('simctl boot hung for 120s. The device is shut down and marked unsafe; '
                                    'do not retry it. Delete it and use a fresh device.') from None
                if booted.returncode and 'current state: Booted' not in booted.stderr:
                    detail = (booted.stderr.strip().splitlines() or [f'exit {booted.returncode}'])[-1]
                    stop(udid, f'simctl boot failed: {detail}')
                    raise BootError(f'simctl boot failed: {detail}. The device is shut down and marked unsafe; '
                                    'do not retry it. Delete it and use a fresh device.')
                ready = subprocess.Popen(simctl() + ['bootstatus', udid], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
                try:
                    tolerated = wait_until_ready(udid, lambda: ready.poll() is not None, SpringBoardMonitor(udid),
                                                 lambda: new_crash(reports, baseline, udid), timeout, out=out,
                                                 tolerate_until=FIRST_BOOT_TOLERANCE if first_boot else None,
                                                 record=lambda text: record_event(udid, text))
                except BootError as error:
                    record_event(udid, f'stopped: {error}')
                    raise
                finally:
                    if ready.poll() is None:
                        ready.kill()
                        ready.wait()
                if ready.returncode:
                    stop(udid, f'bootstatus exited {ready.returncode}')
                    raise BootError(f'bootstatus exited {ready.returncode}. The device is shut down and marked unsafe.')
                seconds = time.monotonic() - started
                info.update(boot_window=(wall_start, time.time()), tolerated=tolerated)
                record_event(udid, f'ready after {seconds:.0f}s' + (f', one change tolerated: {tolerated}' if tolerated
                                                                    else ', no SpringBoard change'))
                return seconds
    except TimeoutError as error:
        raise BootError(f'the lane stayed busy: {error}') from None
    except BootError as error:
        if 'pressure' in info:
            raise BootError(f'{error} Memory pressure at boot: {info["pressure"]}.') from None
        raise
