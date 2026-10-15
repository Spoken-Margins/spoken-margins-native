"""Keep lane simulators on the Mac's built-in speakers and microphone (#1556).

A simulator plays and records through the Mac's default audio devices. On 2026-10-13 the owner's
AirPods kept moving from his iPhone to the Mac while lane simulators ran audio tests, and a voice memo
on the phone took five tries. So while a lane simulator is booted, the Mac's default input, output and
system-output devices are the built-in ones; when the last one is gone they go back to what they were.

- pin(udid) runs inside lane_sim.boot, before `simctl boot`. It saves the current defaults the first
  time, switches any wireless default (Bluetooth, AirPlay, the iPhone's Continuity microphone) to the
  built-in device, and records the simulator as a holder even when the defaults are already built-in.
- pin(udid, refresh=True) runs on each live watcher or self-booted verification tick. Only changed
  defaults are inspected for a wireless device, so headphones connecting after boot are pinned too.
  Unchanged ticks inspect only the three CoreAudio defaults and pin state; they do not query
  simctl, devices or the lid. Devices first pinned during refresh are never added to the saved
  defaults to restore.
- settle() runs wherever a simulator is shut down, and at the start of every boot (which heals a run
  that died without settling). It drops holders that are no longer booted and, with none left, puts
  each default back, but only where it is still the built-in device we pinned and the old device is
  still on the Mac. A non-wireless default someone changed by hand meanwhile is left alone.
- A refresh never fights the Mac. If a device takes a default back and a refresh switches it away more than
  REPIN_LIMIT times within REPIN_WINDOW seconds (AirPods that keep reclaiming the Mac, 2026-10-15: the output
  flipped every second), pinning stands down for REPIN_YIELD seconds. Each flip also tugs the AirPods between
  the iPhone and the Mac, which is the hijack this module exists to prevent.
- Wired and virtual defaults (USB, HDMI, aggregate, BlackHole-style devices) are never touched.
- Nothing changes when the lid is closed with no external display: the built-in speakers are off then
  (host_audio.py, #909), and playback would stall.
- Anything it cannot read or set is logged and skipped: audio pinning must never fail a lane run.

State is state_dir()/audio-pin.json under the lock audio-pin.lock. Reads CoreAudio through ctypes;
stdlib only. `python3 scripts/lane_audio.py status|settle` shows or settles it by hand.
"""
from __future__ import annotations

import contextlib
import ctypes
import ctypes.util
import fcntl
import json
import os
import struct
import sys
import time

from lane_slots import state_dir

KINDS = ('input', 'output', 'system')
# Bluetooth, Bluetooth LE, AirPlay and Continuity (the iPhone's microphone): only these are switched away from.
WIRELESS = ('blue', 'blea', 'airp', 'ccwd', 'ccwl')
BUILT_IN = 'bltn'
STATE_FILE = 'audio-pin.json'
# A holder that simctl doesn't list as booted yet (it is between pin() and the end of `simctl boot`) stays a
# holder this long, so another simulator's shutdown can't restore the AirPods under it.
BOOT_GRACE = 1200.0
LOCK_FILE = 'audio-pin.lock'
# Refresh re-pins that undo a device reclaiming a default: after this many within the window, stop for a while.
REPIN_LIMIT = 3
REPIN_WINDOW = 60.0
REPIN_YIELD = 600.0


def _code(text):
    return struct.unpack('>I', text.encode('ascii'))[0]


def _text(code):
    return struct.pack('>I', code).decode('ascii', 'replace')


SYSTEM_OBJECT = 1
SELECTORS = {'input': _code('dIn '), 'output': _code('dOut'), 'system': _code('sOut')}
DEVICES = _code('dev#')
TRANSPORT = _code('tran')
UID = _code('uid ')
NAME = _code('lnam')
STREAMS = _code('stm#')
GLOBAL, INPUT_SCOPE, OUTPUT_SCOPE = _code('glob'), _code('inpt'), _code('outp')


class CoreAudio:
    """The Mac's audio devices through CoreAudio. Raises OSError when it can't be loaded or a call fails."""

    class _Address(ctypes.Structure):
        _fields_ = [('selector', ctypes.c_uint32), ('scope', ctypes.c_uint32), ('element', ctypes.c_uint32)]

    def __init__(self):
        path = ctypes.util.find_library('CoreAudio')
        core = ctypes.util.find_library('CoreFoundation')
        if not path or not core:
            raise OSError('CoreAudio is not available here')
        self.audio = ctypes.CDLL(path)
        self.core = ctypes.CDLL(core)
        self.core.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        self.core.CFStringGetCString.restype = ctypes.c_bool
        self.core.CFRelease.argtypes = [ctypes.c_void_p]
        # This CLI never pumps CFRunLoopGetMain(). AudioHardwareDeprecated.h documents NULL rnlp
        # as asking HAL to manage a notification thread, so repeated reads see device changes.
        address = self._address(_code('rnlp'))
        run_loop = ctypes.c_void_p()
        status = self.audio.AudioObjectSetPropertyData(
            ctypes.c_uint32(SYSTEM_OBJECT), ctypes.byref(address), 0, None,
            ctypes.sizeof(run_loop), ctypes.byref(run_loop))
        if status:
            raise OSError(f'CoreAudio notification thread setup failed ({status})')

    def _address(self, selector, scope=GLOBAL):
        return self._Address(selector, scope, 0)

    def _size(self, object_id, address):
        size = ctypes.c_uint32(0)
        status = self.audio.AudioObjectGetPropertyDataSize(
            ctypes.c_uint32(object_id), ctypes.byref(address), 0, None, ctypes.byref(size))
        if status:
            raise OSError(f'CoreAudio size query failed ({status})')
        return size.value

    def _get(self, object_id, selector, scope=GLOBAL, ctype=ctypes.c_uint32):
        address = self._address(selector, scope)
        value = ctype()
        size = ctypes.c_uint32(ctypes.sizeof(value))
        status = self.audio.AudioObjectGetPropertyData(
            ctypes.c_uint32(object_id), ctypes.byref(address), 0, None, ctypes.byref(size), ctypes.byref(value))
        if status:
            raise OSError(f'CoreAudio read failed ({status})')
        return value

    def _string(self, object_id, selector):
        reference = self._get(object_id, selector, ctype=ctypes.c_void_p)
        if not reference.value:
            return ''
        try:
            buffer = ctypes.create_string_buffer(512)
            if not self.core.CFStringGetCString(reference, buffer, len(buffer), 0x08000100):  # kCFStringEncodingUTF8
                return ''
            return buffer.value.decode('utf-8', 'replace')
        finally:
            self.core.CFRelease(reference)

    def _has_streams(self, object_id, scope):
        try:
            return self._size(object_id, self._address(STREAMS, scope)) > 0
        except OSError:
            return False

    def devices(self):
        address = self._address(DEVICES)
        size = self._size(SYSTEM_OBJECT, address)
        count = size // 4
        ids = (ctypes.c_uint32 * count)()
        got = ctypes.c_uint32(size)
        status = self.audio.AudioObjectGetPropertyData(
            ctypes.c_uint32(SYSTEM_OBJECT), ctypes.byref(address), 0, None, ctypes.byref(got), ids)
        if status:
            raise OSError(f'CoreAudio device list failed ({status})')
        found = []
        for device in ids:
            try:
                found.append({'id': int(device), 'uid': self._string(device, UID), 'name': self._string(device, NAME),
                              'transport': _text(self._get(device, TRANSPORT).value),
                              'input': self._has_streams(device, INPUT_SCOPE),
                              'output': self._has_streams(device, OUTPUT_SCOPE)})
            except OSError:
                continue
        return found

    def default(self, kind):
        return int(self._get(SYSTEM_OBJECT, SELECTORS[kind]).value)

    def set_default(self, kind, device_id):
        address = self._address(SELECTORS[kind])
        value = ctypes.c_uint32(device_id)
        status = self.audio.AudioObjectSetPropertyData(
            ctypes.c_uint32(SYSTEM_OBJECT), ctypes.byref(address), 0, None, ctypes.sizeof(value), ctypes.byref(value))
        if status:
            raise OSError(f'CoreAudio could not set the default {kind} device ({status})')


def _state_path():
    return state_dir() / STATE_FILE


def _read_state():
    try:
        state = json.loads(_state_path().read_text())
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_state(state):
    path = _state_path()
    if not state:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    scratch = path.with_name(path.name + '.tmp')
    scratch.write_text(json.dumps(state, indent=2, sort_keys=True) + '\n')
    os.replace(scratch, path)  # a crash mid-write must not lose the saved devices


@contextlib.contextmanager
def _locked(wait=30.0):
    path = state_dir() / LOCK_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'a+') as handle:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise TimeoutError('the audio pin lock stayed busy')
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def _by_id(devices):
    return {device['id']: device for device in devices}


def _scope_key(kind):
    return 'input' if kind == 'input' else 'output'


def _builtin_for(kind, devices):
    return next((d for d in devices if d['transport'] == BUILT_IN and d[_scope_key(kind)]), None)


def speakers_off(reader=None):
    """Whether the built-in speakers are off: lid closed with no external display (host_audio.py, #909)."""
    import host_audio
    reader = reader or host_audio.read
    try:
        if not host_audio.lid_closed(reader(['/usr/sbin/ioreg', '-r', '-k', 'AppleClamshellState', '-d', '4'])):
            return False
        return not host_audio.external_display(reader(['/usr/sbin/system_profiler', 'SPDisplaysDataType']))
    except Exception:  # unreadable counts as open: pinning is the safer side
        return False


def disabled():
    """SM_LANE_AUDIO=off, or a fake simctl (SM_LANE_SIMCTL, the lane's own tests): no real simulator will play
    anything, so the Mac's audio devices must not be touched."""
    return os.environ.get('SM_LANE_AUDIO') == 'off' or bool(os.environ.get('SM_LANE_SIMCTL'))


def pin(udid, backend=None, out=sys.stderr, lid_closed=speakers_off, *, refresh=False):
    """Switch wireless default audio devices to the built-in ones for the simulator udid. Returns a list of
    what changed (empty when nothing needed to). Never raises.

    refresh checks an existing holder without settling or renewing its boot grace. It cannot recreate
    a holder removed by shutdown, and does expensive discovery only when the defaults changed."""
    if backend is None and disabled():
        return []
    try:
        backend = backend or CoreAudio()
        if not refresh:
            settle(backend=backend, out=out, drop=udid)  # heal a run that died without settling
        with _locked():
            state = _read_state()
            if refresh and udid not in state.get('holders', {}):
                return []
            defaults = {kind: backend.default(kind) for kind in KINDS}
            now = time.time()
            if refresh and state.get('yield_until') and now >= state['yield_until']:
                state.pop('yield_until')  # the stand-down is over: look at the defaults again
                state.pop('observed', None)
            if refresh and defaults == state.get('observed'):
                return []
            if refresh and now < state.get('yield_until', 0):
                state['observed'] = defaults  # standing down: the Mac's choice stands, don't look again until it moves
                _write_state(state)
                return []
            if refresh:
                recent = [t for t in state.get('repins', []) if now - t < REPIN_WINDOW]
                if len(recent) >= REPIN_LIMIT:
                    state['repins'] = []
                    state['yield_until'] = now + REPIN_YIELD
                    state['observed'] = defaults
                    _write_state(state)
                    print(f'[lane] audio: a device keeps taking the default audio devices back ({REPIN_LIMIT} '
                          f'switches in {REPIN_WINDOW:.0f}s); not fighting it for {REPIN_YIELD / 60:.0f} min',
                          file=out, flush=True)
                    return []
            else:
                state.pop('repins', None)  # a fresh boot starts the count again
                state.pop('yield_until', None)
            if lid_closed():
                if refresh:
                    state['observed'] = defaults
                    _write_state(state)
                print('[lane] audio: lid closed with no external display, so the built-in speakers are off; '
                      'leaving the default audio devices alone', file=out, flush=True)
                return []
            devices = backend.devices()
            known = _by_id(devices)
            changed = []
            for kind in KINDS:
                try:
                    current = known.get(defaults[kind])
                    builtin = _builtin_for(kind, devices)
                    if not current or not builtin or current['transport'] not in WIRELESS:
                        continue
                    if not refresh:
                        state.setdefault('saved', {}).setdefault(kind, {'uid': current['uid'], 'name': current['name']})
                    state.setdefault('pinned', {})[kind] = builtin['id']
                    backend.set_default(kind, builtin['id'])
                    defaults[kind] = builtin['id']
                    changed.append(f'{kind}: {current["name"]} -> {builtin["name"]}')
                except OSError as error:
                    print(f'[lane] audio: could not pin the {kind} device: {error}', file=out, flush=True)
            state['observed'] = defaults
            if refresh and changed:
                state['repins'] = recent + [now]
            if not refresh:
                state.setdefault('holders', {})[udid] = now
            _write_state(state)
            if changed:
                print('[lane] audio: pinned to the built-in devices while the simulator runs (' + '; '.join(changed)
                      + ')', file=out, flush=True)
            return changed
    except Exception as error:  # audio pinning must never fail a lane run
        print(f'[lane] audio: pinning skipped: {error}', file=out, flush=True)
        return []


def settle(backend=None, out=sys.stderr, booted=None, drop=None, now=time.time):
    """Drop holders whose simulator is gone; with none left, put the defaults back. Never raises.

    drop names a simulator that was just shut down or failed to boot, so it stops holding at once. Any other
    holder stays while simctl lists it as booted, or for BOOT_GRACE after pin() while it is still booting.
    booted is a function returning the booted udids (default: simctl via lane_sim, with a timeout)."""
    if backend is None and disabled():
        return []
    if not _state_path().exists():
        return []  # nothing pinned: the common case takes no lock
    try:
        if booted is None:
            import lane_sim
            booted = lambda: lane_sim.booted_udids(timeout=15)  # noqa: E731
        try:
            alive = booted()  # asked before taking the lock: a wedged simctl must not block other settles
        except Exception:
            return []  # can't tell which simulators run: restoring now could pull audio from a live one
        with _locked():
            state = _read_state()
            if not state:
                return []
            holders = state.get('holders', {})
            if isinstance(holders, list):  # a list is only what an older write left
                holders = {udid: 0 for udid in holders}
            kept = {udid: since for udid, since in holders.items()
                    if udid != drop and (udid in alive or now() - since < BOOT_GRACE)}
            if kept:
                state['holders'] = kept
                _write_state(state)
                return []
            backend = backend or CoreAudio()
            devices = backend.devices()
            restored = []
            for kind, saved in sorted(state.get('saved', {}).items()):
                try:
                    pinned = state.get('pinned', {}).get(kind)
                    if backend.default(kind) != pinned:
                        continue  # someone chose a device meanwhile: theirs stands
                    old = next((d for d in devices if d['uid'] == saved['uid'] and d[_scope_key(kind)]), None)
                    if old:
                        backend.set_default(kind, old['id'])
                        restored.append(f'{kind}: back to {old["name"]}')
                except OSError as error:
                    print(f'[lane] audio: could not restore the {kind} device: {error}', file=out, flush=True)
            _write_state({})
            if restored:
                print('[lane] audio: default devices restored (' + '; '.join(restored) + ')', file=out, flush=True)
            return restored
    except Exception as error:
        print(f'[lane] audio: settle skipped: {error}', file=out, flush=True)
        return []


def status(backend=None):
    backend = backend or CoreAudio()
    devices = backend.devices()
    known = _by_id(devices)
    lines = []
    for kind in KINDS:
        device = known.get(backend.default(kind), {})
        lines.append(f'default {kind}: {device.get("name", "?")} ({device.get("transport", "?")})')
    state = _read_state()
    lines.append('pin state: ' + (json.dumps(state, sort_keys=True) if state else 'none'))
    return lines


if __name__ == '__main__':
    command = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if command == 'status':
        print('\n'.join(status()))
    elif command == 'settle':
        settle()
        print('\n'.join(status()))
    else:
        sys.exit('usage: lane_audio.py status|settle')
