"""The shipped builds' playback check (scripts/build29-db-reader/voice-playback.swift, #3218) must pass a real
HE-AAC Margin and refuse a file that only looks like one.

Builds 32 and 34 play an imported Margin by handing its file to AVPlayer, AVAudioPlayer and AVAudioFile, with no
format check of their own. Before this check, check-build29-database.sh only imported packets, so a voice that
imported but would not play in those builds passed. The check is compiled here with a small driver and run on
files made with afconvert: a tone, never anyone's recording. It is compiled in Swift 6 mode, as the shipped
readers' Package.swift builds it.
"""
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / 'scripts' / 'build29-db-reader' / 'voice-playback.swift'
PACKET_READER = ROOT / 'scripts' / 'build29-db-reader' / 'packet-reader.swift'
COMPAT_SCRIPT = ROOT / 'scripts' / 'check-build29-database.sh'
DRIVER = """import Foundation
let ms = Int(CommandLine.arguments[2])
print(await voicePlaybackProblem(at: URL(fileURLWithPath: CommandLine.arguments[1]), expectedMs: ms) ?? "plays")
"""


def require(tool):
    path = shutil.which(tool)
    if path is None:
        # SM_REQUIRE_TOOLS marks a machine that must have it: skipping there would report a pass that never ran (#1905).
        if os.environ.get('SM_REQUIRE_TOOLS'):
            raise AssertionError(f'SM_REQUIRE_TOOLS is set but {tool} is not on PATH')
        raise unittest.SkipTest(f'{tool} is not installed')
    return path


def write_tone(path, seconds, loud=True):
    rate = 44_100
    with wave.open(str(path), 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        level = 8_000 if loud else 0
        out.writeframes(b''.join(
            struct.pack('<h', int(level * (0.5 + 0.5 * math.sin(2 * math.pi * 3.5 * t / rate))
                                  * math.sin(2 * math.pi * 180 * t / rate)))
            for t in range(int(seconds * rate))))


class VoicePlaybackCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        swiftc = require('swiftc')
        cls.afconvert = require('afconvert')
        cls.tmp = tempfile.TemporaryDirectory()
        main = Path(cls.tmp.name) / 'main.swift'
        main.write_text(DRIVER, encoding='utf-8')
        cls.binary = Path(cls.tmp.name) / 'voice-playback'
        subprocess.run([swiftc, '-swift-version', '6', str(CHECK), str(main), '-o', str(cls.binary)], check=True,
                       capture_output=True, text=True, timeout=300)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def encode(self, name, seconds, *codec, loud=True):
        wav = Path(self.tmp.name) / f'{name}.wav'
        write_tone(wav, seconds, loud)
        m4a = Path(self.tmp.name) / f'{name}.m4a'
        subprocess.run([self.afconvert, '-f', 'm4af', *codec, str(wav), str(m4a)], check=True,
                       capture_output=True, timeout=60)
        return m4a

    def check(self, path, ms):
        return subprocess.run([str(self.binary), str(path), str(ms)], check=True, capture_output=True,
                              text=True, timeout=60).stdout.strip()

    def test_a_shared_he_aac_margin_plays(self):
        voice = self.encode('he-aac', 4, '-d', 'aach', '-c', '1', '-b', '24000')
        self.assertEqual(self.check(voice, 4_000), 'plays')

    def test_a_recording_at_todays_quality_plays(self):
        voice = self.encode('aac', 4, '-d', 'aac', '-c', '1')
        self.assertEqual(self.check(voice, 4_000), 'plays')

    def test_a_file_that_only_has_an_m4a_header_does_not_play(self):
        # The importer accepts this (it checks the `ftyp` box); no shipped build can play it.
        fake = Path(self.tmp.name) / 'fake.m4a'
        fake.write_bytes(bytes([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0])
                         + bytes([7]) * 40_000)
        self.assertNotEqual(self.check(fake, 4_000), 'plays')

    def test_a_voice_shorter_than_the_manifest_says_does_not_pass(self):
        voice = self.encode('short', 2, '-d', 'aach', '-c', '1', '-b', '24000')
        self.assertIn('the manifest says', self.check(voice, 4_000))

    def test_a_voice_that_decodes_to_silence_does_not_pass(self):
        voice = self.encode('silent', 4, '-d', 'aac', '-c', '1', loud=False)
        self.assertIn('silence', self.check(voice, 4_000))


class VoicePlaybackWiringTests(unittest.TestCase):
    """The check only counts if the shipped builds' reader runs it: compiled in, and called for marked packets."""

    def test_the_compat_script_compiles_the_check_into_each_shipped_reader(self):
        self.assertIn('build29-db-reader/voice-playback.swift" "$dir/packet-reader/', COMPAT_SCRIPT.read_text())

    def test_the_packet_reader_plays_the_voices_of_a_marked_packet(self):
        text = PACKET_READER.read_text()
        self.assertIn('"voicesMustPlay"', text)
        self.assertIn('await voicePlaybackProblem(at:', text)
        self.assertIn('guard played > 0', text, 'no marked packet must fail, not pass with nothing played')


if __name__ == '__main__':
    unittest.main()
