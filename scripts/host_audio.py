"""Whether this Mac can play sound, for the SessionKit real-player host tests (#909).

AVPlayer does not advance its clock without a running output device. With the lid closed and no external
display, macOS turns the built-in speakers off while still listing them as the default output, and every
real-player test fails ("playback did not advance"), for every PR, on 2026-10-07. That is the Mac's state,
not the PR's code, so the lane reports it as a lane fault.

The default output can also be listed and awake but never start: on 2026-10-17 BlackHole 2ch was the default
and every `AVAudioPlayer.play()` waited inside Core Audio for good, so the SessionKit step hung for 17 minutes
on every PR (#1956). A silent `afplay` with a time limit finds that in under a second.
"""
import re
import subprocess
import tempfile
import wave
from pathlib import Path

START_TIMEOUT = 30  # a healthy output starts in well under a second, even with the load average above 100


def read(command):
    return subprocess.run(command, capture_output=True, text=True, timeout=60).stdout


def lid_closed(ioreg):
    return bool(re.search(r'"AppleClamshellState" = Yes', ioreg))


def external_display(displays):
    """Any online display whose connection isn't the built-in panel's `Internal`."""
    return any(kind.strip() != 'Internal' for kind in re.findall(r'^\s*Connection Type: (.+)$', displays, re.M))


def default_output_transport(audio):
    """The Transport of the device marked `Default Output Device: Yes`, or None."""
    blocks = re.split(r'^ {8}(?=\S[^\n]*:\s*$)', audio, flags=re.M)
    for block in blocks:
        if 'Default Output Device: Yes' in block:
            match = re.search(r'Transport: (.+)', block)
            return match[1].strip() if match else None
    return None


def default_output_name(audio):
    """The name of the device marked `Default Output Device: Yes`, or None."""
    for match in re.finditer(r'^ {8}(\S[^\n]*):\s*$((?:\n {10,}[^\n]*)*)', audio, re.M):
        if 'Default Output Device: Yes' in match[2]:
            return match[1].strip()
    return None


def output_starts(run=subprocess.run, timeout=START_TIMEOUT):
    """{'starts': bool, 'why': str}: plays 0.1 s of silence at volume 0 to the default output (#1956). Only a
    player still waiting at the time limit counts as not starting. No `afplay` (Linux), or one that fails at
    once, counts as starting: a fast failure isn't the hang, and this must never invent a lane fault."""
    with tempfile.TemporaryDirectory() as directory:
        silence = Path(directory) / 'silence.wav'
        with wave.open(str(silence), 'wb') as file:
            file.setnchannels(1)
            file.setsampwidth(2)
            file.setframerate(8000)
            file.writeframes(bytes(1600))
        try:
            run(['/usr/bin/afplay', '-v', '0', str(silence)], capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return {'starts': False, 'why': f'a silent afplay to the default output was still waiting after {timeout} s'}
        except OSError:
            return {'starts': True, 'why': 'no afplay on this machine'}
    return {'starts': True, 'why': 'the default output started'}


def audio_output(reader=read, starts=output_starts):
    """{'usable': bool, 'why': str}, plus `'stuck': True` when the default output never starts (#1956).
    Anything it can't read counts as usable: this must never turn a real failure into a lane fault by
    guessing."""
    state = speaker_state(reader)
    if not state['usable']:
        return state
    probe = starts()
    if probe['starts']:
        return state
    try:
        name = default_output_name(reader(['/usr/sbin/system_profiler', 'SPAudioDataType']))
    except (OSError, subprocess.SubprocessError):
        name = None
    return {'usable': False, 'stuck': True,
            'why': f'the default output ({name or "unknown device"}) does not start: {probe["why"]}, so every '
                   'real-player test would hang. Restart Core Audio (sudo killall coreaudiod) or choose another '
                   'output in Sound settings'}


def speaker_state(reader=read):
    """{'usable': bool, 'why': str} from the lid, the displays and the default output's transport (#909)."""
    try:
        if not lid_closed(reader(['/usr/sbin/ioreg', '-r', '-k', 'AppleClamshellState', '-d', '4'])):
            return {'usable': True, 'why': 'lid open'}
        if external_display(reader(['/usr/sbin/system_profiler', 'SPDisplaysDataType'])):
            return {'usable': True, 'why': 'lid closed, external display connected'}
        transport = default_output_transport(reader(['/usr/sbin/system_profiler', 'SPAudioDataType']))
    except (OSError, subprocess.SubprocessError):
        return {'usable': True, 'why': 'could not read the Mac\'s lid, display or audio state'}
    if transport not in (None, 'Built-in', 'Virtual', 'Unknown'):
        return {'usable': True, 'why': f'lid closed, default output is {transport}'}
    return {'usable': False, 'why': 'lid closed with no external display or other audio output, so the built-in '
                                    'speakers are off and AVPlayer cannot advance'}
