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


def started():
    return {'starts': True, 'why': 'test'}


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
                state = host_audio.audio_output(reader(*args), starts=started)
                self.assertEqual(state['usable'], usable, state)
                self.assertTrue(state['why'])

    def test_what_it_cannot_read_counts_as_usable_so_a_real_failure_is_never_called_a_lane_fault(self):
        for error in (OSError('no ioreg'), subprocess.TimeoutExpired('ioreg', 60)):
            with self.subTest(type(error).__name__):
                self.assertTrue(host_audio.audio_output(reader(error, '', ''), starts=started)['usable'])
        self.assertTrue(host_audio.audio_output(reader('garbage', '', ''), starts=started)['usable'])

    def test_a_default_output_that_never_starts_is_stuck_and_named(self):
        # #1956, 2026-10-17: BlackHole 2ch was the default and every AVAudioPlayer.play() waited for good.
        state = host_audio.audio_output(reader(LID_OPEN, BUILT_IN_ONLY, audio('BlackHole 2ch', 'Virtual')),
                                        starts=lambda: {'starts': False, 'why': 'afplay still waiting after 30 s'})
        self.assertFalse(state['usable'])
        self.assertTrue(state['stuck'])
        self.assertIn('(BlackHole 2ch) does not start: afplay still waiting after 30 s', state['why'])

    def test_with_the_lid_closed_and_no_output_it_does_not_try_to_play(self):
        played = []
        state = host_audio.audio_output(reader(LID_CLOSED, BUILT_IN_ONLY, audio('MacBook Pro Speakers', 'Built-in')),
                                        starts=lambda: played.append(1) or started())
        self.assertFalse(state['usable'])
        self.assertNotIn('stuck', state)
        self.assertEqual(played, [])

    def test_only_a_player_still_waiting_at_the_limit_counts_as_not_starting(self):
        def runner(outcome):
            def run(command, **kw):
                self.assertEqual(command[:3], ['/usr/bin/afplay', '-v', '0'])
                self.assertTrue(Path(command[3]).read_bytes().startswith(b'RIFF'))
                self.assertEqual(kw['timeout'], 7)
                if isinstance(outcome, Exception):
                    raise outcome
                return subprocess.CompletedProcess(command, outcome)
            return run
        for name, outcome, starts in (('it played', 0, True), ('it failed at once', 1, True),
                                      ('no afplay (Linux)', FileNotFoundError('afplay'), True),
                                      ('still waiting', subprocess.TimeoutExpired('afplay', 7), False)):
            with self.subTest(name):
                self.assertEqual(host_audio.output_starts(runner(outcome), timeout=7)['starts'], starts)

    def test_the_default_output_s_name_is_read_from_system_profiler(self):
        self.assertEqual(host_audio.default_output_name(audio('BlackHole 2ch', 'Virtual')), 'BlackHole 2ch')
        self.assertEqual(host_audio.default_output_name(audio('MacBook Pro Speakers', 'Built-in')),
                         'MacBook Pro Speakers')
        self.assertIsNone(host_audio.default_output_name('Audio:\n    Devices:\n'))


if __name__ == '__main__':
    unittest.main()
