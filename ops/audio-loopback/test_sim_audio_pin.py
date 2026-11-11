"""Whether the audio window sees a Simulator as pinned to BlackHole, and that sim-audio-pin.m still compiles."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import window

HERE = Path(__file__).resolve().parent
PINNED = {'useHostDefaultOutputDevice': False, 'sim_output_device_uid': 'BlackHole2ch_UID'}
FOLLOWS_MAC = {'useHostDefaultOutputDevice': True, 'sim_output_device_uid': 'BlackHole2ch_UID'}
OTHER_DEVICE = {'useHostDefaultOutputDevice': False, 'sim_output_device_uid': 'BuiltInSpeakerDevice'}
SHUTDOWN, BOOTED = 1, 3


class PinnedTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def device(self, name, state, audio=None):
        path = self.root / name
        (path / 'data/var/run').mkdir(parents=True)
        (path / 'device.plist').write_bytes(plistlib.dumps({'state': state}))
        if audio is not None:
            (path / window.AUDIO_SETTINGS).write_bytes(plistlib.dumps(audio))

    def pinned(self):
        return window.simulators_pinned(roots=(self.root, self.root / 'no-such-set'))

    def test_every_booted_simulator_on_blackhole_counts(self):
        self.device('a', BOOTED, PINNED)
        self.device('b', BOOTED, PINNED)
        self.assertTrue(self.pinned())

    def test_nothing_booted_does_not_count(self):
        self.device('a', SHUTDOWN, PINNED)
        self.assertFalse(self.pinned())

    def test_a_simulator_that_follows_the_mac_does_not_count_even_when_the_mac_is_on_blackhole(self):
        self.device('a', BOOTED, FOLLOWS_MAC)
        self.assertFalse(self.pinned())

    def test_a_simulator_pinned_to_another_device_does_not_count(self):
        self.device('a', BOOTED, OTHER_DEVICE)
        self.assertFalse(self.pinned())

    def test_one_unpinned_simulator_among_pinned_ones_does_not_count(self):
        self.device('a', BOOTED, PINNED)
        self.device('b', BOOTED, FOLLOWS_MAC)
        self.assertFalse(self.pinned())

    def test_a_shutdown_simulator_does_not_matter(self):
        self.device('a', BOOTED, PINNED)
        self.device('b', SHUTDOWN, FOLLOWS_MAC)
        self.assertTrue(self.pinned())

    def test_a_booted_simulator_with_no_settings_file_does_not_count(self):
        self.device('a', BOOTED)
        self.assertFalse(self.pinned())

    def test_an_unreadable_settings_file_does_not_count(self):
        self.device('a', BOOTED)
        (self.root / 'a' / window.AUDIO_SETTINGS).write_text('not a plist')
        self.assertFalse(self.pinned())


BLACKHOLE_DRIVER = Path('/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver')


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'builds a macOS program')
class BuildTests(unittest.TestCase):
    def build(self, folder):
        pin = Path(folder) / 'pin'
        subprocess.run(['clang', '-O2', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'CoreAudio',
                        str(HERE / 'sim-audio-pin.m'), '-o', str(pin)], check=True, capture_output=True, timeout=120)
        return pin

    def test_the_pin_compiles(self):
        with tempfile.TemporaryDirectory() as folder:
            self.build(folder)

    @unittest.skipUnless(BLACKHOLE_DRIVER.exists(), 'BlackHole 2ch is not installed on this Mac')
    def test_the_pin_finds_blackhole_when_it_is_installed(self):
        # The pin's first check used the Simulator's host device list, whose entries never show their UID, so it
        # said "no BlackHole" on a Mac that had it and pinned nothing for two days (2026-11-08 to 11-10).
        with tempfile.TemporaryDirectory() as folder:
            found = subprocess.run([str(self.build(folder)), '--blackhole'], capture_output=True, timeout=30)
        self.assertEqual(found.returncode, 0, 'the pin does not see BlackHole 2ch, so it would never pin')


if __name__ == '__main__':
    unittest.main()
