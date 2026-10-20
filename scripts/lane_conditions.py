"""What the Mac was doing when a T3 plan installed and launched its host app (#2176).

Startup stalls (#705, #1802) came 0 of 15 T3 runs on 2026-10-17 and 12 of 32 on 10-19, the day the Mac ran at load
140-212 with a second simulator slot on trial and under 25 GB free. Only the load average was on record, and on its
own it barely separates stalled launches from clean ones (#2176). So each launch attempt records these too, and
scripts/lane_stall_report.py counts stalls against them. Every reading is best effort: a missing one is None, and
nothing here raises.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess

import lane_slots

SWAP_USED = re.compile(r'used = ([\d.]+)M')


def swap_used_mb():
    """Swap in use, in MB (macOS `vm.swapusage`), or None where it can't be read."""
    try:
        text = subprocess.run(['sysctl', '-n', 'vm.swapusage'], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = SWAP_USED.search(text)
    return round(float(match[1])) if match else None


def free_disk_gb(path=None):
    """Free space on the volume holding the simulators' data (the home folder's volume), in GB."""
    try:
        return round(shutil.disk_usage(path or Path.home()).free / 1e9, 1)
    except OSError:
        return None


def folder_mb(path):
    """The size of a folder such as an .app bundle, in MB, or None when it isn't there."""
    total = 0
    try:
        for folder, _, files in os.walk(path):
            for name in files:
                try:
                    total += os.lstat(os.path.join(folder, name)).st_size
                except OSError:
                    pass
    except OSError:
        return None
    return round(total / 1e6, 1) if Path(path).is_dir() else None


def lane_jobs():
    """Who holds the Mac-wide lane slots right now: build slots, host-test slots and simulator slots."""
    found = {}
    for kind, holders in (('build', lane_slots.holders), ('host_test', lane_slots.host_holders),
                          ('simulator', lane_slots.simulator_holders)):
        try:
            found[kind] = [holder.get('label') for holder in holders()]
        except (OSError, ValueError):
            found[kind] = None
    return found


def snapshot():
    """One reading of the host's conditions, for a manifest."""
    try:
        load = [round(value, 1) for value in os.getloadavg()]
    except OSError:
        load = None
    pressure = lane_slots.memory_pressure_level()
    return {'load_average': load,
            'memory_pressure': lane_slots.PRESSURE_NAMES.get(pressure, pressure),
            'swap_used_mb': swap_used_mb(),
            'free_disk_gb': free_disk_gb(),
            'lane_jobs': lane_jobs()}
