import subprocess
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_audio

LID_OPEN = '  |   "AppleClamshellCausesSleep" = Yes\n  |   "AppleClamshellState" = No\n'
LID_CLOSED = '  |   "AppleClamshellCausesSleep" = Yes\n  |   "AppleClamshellState" = Yes\n'
BUILT_IN_ONLY = '''Graphics/Displays:
    Apple M4 Pro:
      Displays:
        Color LCD:
          Display Type: Built-in Liquid Retina XDR Display
          Online: Yes
          Connection Type: Internal
'''
WITH_EXTERNAL = BUILT_IN_ONLY + '''        DELL U2723QE:
          Online: Yes
          Connection Type: DisplayPort
'''


def audio(default, transport):
    others = '        Microsoft Teams Audio:\n          Transport: Virtual\n'
    return (f'Audio:\n    Devices:\n        MacBook Pro Microphone:\n          Transport: Built-in\n'
            f'        {default}:\n          Default Output Device: Yes\n          Transport: {transport}\n{others}')


def reader(ioreg, displays, sound):
    def read(command):
        if isinstance(ioreg, Exception) and command[0].endswith('ioreg'):
            raise ioreg
        return {'ioreg': ioreg, 'system_profiler': displays if 'SPDisplaysDataType' in command else sound}[
            Path(command[0]).name]
    return read


class HostAudioTests(unittest.TestCase):
    def test_a_closed_lid_with_nothing_else_to_play_through_has_no_sound_output(self):
        # #909, 2026-10-07: every real-player host test failed on the lane Mac with its lid closed.
        for name, args, usable in (
                ('lid open', (LID_OPEN, BUILT_IN_ONLY, audio('MacBook Pro Speakers', 'Built-in')), True),
                ('lid closed, built-in panel and speakers only',
                 (LID_CLOSED, BUILT_IN_ONLY, audio('MacBook Pro Speakers', 'Built-in')), False),
                ('lid closed, default output is a virtual device',
                 (LID_CLOSED, BUILT_IN_ONLY, audio('ZoomAudioDevice', 'Virtual')), False),
                ('lid closed, default output has no transport line',
                 (LID_CLOSED, BUILT_IN_ONLY, 'Audio:\n    Devices:\n        Speakers:\n          Default Output Device: Yes\n'), False),
                ('lid closed, external display',
                 (LID_CLOSED, WITH_EXTERNAL, audio('MacBook Pro Speakers', 'Built-in')), True),
                ('lid closed, Bluetooth speaker is the default',
                 (LID_CLOSED, BUILT_IN_ONLY, audio('JBL Flip', 'Bluetooth')), True),
                ('lid closed, USB headphones are the default',
                 (LID_CLOSED, BUILT_IN_ONLY, audio('USB Headset', 'USB')), True)):
            with self.subTest(name):
                state = host_audio.audio_output(reader(*args))
                self.assertEqual(state['usable'], usable, state)
                self.assertTrue(state['why'])

    def test_what_it_cannot_read_counts_as_usable_so_a_real_failure_is_never_called_a_lane_fault(self):
        for error in (OSError('no ioreg'), subprocess.TimeoutExpired('ioreg', 60)):
            with self.subTest(type(error).__name__):
                self.assertTrue(host_audio.audio_output(reader(error, '', ''))['usable'])
        self.assertTrue(host_audio.audio_output(reader('garbage', '', ''))['usable'])


if __name__ == '__main__':
    unittest.main()
