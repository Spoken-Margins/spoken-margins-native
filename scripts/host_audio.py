"""Whether this Mac can play sound, for the SessionKit real-player host tests (#909).

AVPlayer does not advance its clock without a running output device. With the lid closed and no external
display, macOS turns the built-in speakers off while still listing them as the default output, and every
real-player test fails ("playback did not advance"), for every PR, on 2026-10-07. That is the Mac's state,
not the PR's code, so the lane reports it as a lane fault.
"""
import re
import subprocess


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


def audio_output(reader=read):
    """{'usable': bool, 'why': str}. Anything it can't read counts as usable: this must never turn a
    real failure into a lane fault by guessing."""
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
