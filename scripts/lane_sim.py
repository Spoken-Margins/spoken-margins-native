"""Booting lane simulators safely. Used by scripts/lane-sim-boot (the Test Desk), the runner, and
verify-tests.py, so every lane boot follows the same rules.

Two SpringBoard crash floods reached the owner's screen (2026-09-28 17:46, 2026-09-29 09:58, #184).
Both followed a `simctl boot` that failed with "Invalid argument" and then a retry on the same device.
So each boot:
- refuses a device marked unsafe (a failed boot or a crash during boot marks it);
- holds the Mac-wide simulator-boot lock, so one simulator boots at a time;
- waits while two simulators are already booted (the Mac's limit);
- holds both build slots, so no build runs while a simulator boots;
- never retries a failed `simctl boot`: it shuts the device down and marks it unsafe;
- watches for crash reports from that device until it is ready, and stops at the first one.
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
import shlex
import subprocess
import sys
import time

from lane_slots import build_slot, simulator_boot_lock, state_dir, SLOTS

IOS_MAJOR = 26  # iOS 27's Apple Intelligence services crash-flood on this Mac (#184)
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
FIRST_BOOT_TIMEOUT = 900
LOCK_WAIT = 1800
MAX_BOOTED = 2
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


@contextlib.contextmanager
def all_build_slots(label: str, out, max_wait: float):
    with contextlib.ExitStack() as stack:
        for _ in range(SLOTS):
            stack.enter_context(build_slot(label, out=out, max_wait=max_wait))
        yield


def wait_for_room(udid: str, max_wait: float, poll: float = 15, booted=booted_udids) -> None:
    started = time.monotonic()
    while True:
        running = booted() - {udid}
        if len(running) < MAX_BOOTED:
            return
        if time.monotonic() - started >= max_wait:
            raise BootError(f'{MAX_BOOTED} simulators stayed booted for {max_wait:.0f}s, so no other one was booted.')
        time.sleep(poll)


def stop(udid: str, reason: str) -> None:
    subprocess.run(simctl() + ['shutdown', udid], capture_output=True, timeout=120)
    mark_unsafe(udid, reason)


def boot(udid: str, label: str, out=sys.stderr, timeout: float | None = None, lock_wait: float | None = None) -> float:
    """Boot one simulator under the lane's rules and wait until it is ready. Returns seconds taken.

    Raises BootError with the reason; a failed boot or a crash during boot also marks the device unsafe.
    """
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
                started = time.monotonic()
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
                    while ready.poll() is None:
                        crash = new_crash(reports, baseline, udid)
                        if crash:
                            stop(udid, f'crashed during boot: {crash.name}')
                            raise BootError(f'{crash.name} while booting. The device is shut down and marked '
                                            'unsafe. Delete it and use a fresh device.')
                        if time.monotonic() - started > timeout:
                            subprocess.run(simctl() + ['shutdown', udid], capture_output=True, timeout=120)
                            raise BootError(f'not ready after {timeout:.0f}s; shut down (not marked unsafe).')
                        time.sleep(CRASH_POLL_SECONDS)
                finally:
                    if ready.poll() is None:
                        ready.kill()
                        ready.wait()
                if ready.returncode:
                    stop(udid, f'bootstatus exited {ready.returncode}')
                    raise BootError(f'bootstatus exited {ready.returncode}. The device is shut down and marked unsafe.')
                return time.monotonic() - started
    except TimeoutError as error:
        raise BootError(f'the lane stayed busy: {error}') from None
