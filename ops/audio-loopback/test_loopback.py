"""Host tests for the loopback analysis (#1790). No audio hardware: fixtures are synthetic speech-like wavs."""
import math
import random
import tempfile
import unittest
from pathlib import Path

import loopback

RATE = 16000


def syllable(rng, seconds):
    """A voiced burst: a few harmonics of a random pitch under a raised-cosine envelope, plus breath noise."""
    pitch = rng.uniform(90, 240)
    amp = rng.uniform(0.15, 0.6)
    n = int(seconds * RATE)
    phase = rng.uniform(0, 2 * math.pi)
    out = []
    for i in range(n):
        t = i / RATE
        shape = 0.5 - 0.5 * math.cos(2 * math.pi * i / n)
        voice = sum(math.sin(2 * math.pi * pitch * h * t + phase) / h for h in (1, 2, 3))
        out.append(amp * shape * (0.6 * voice + 0.1 * rng.uniform(-1, 1)))
    return out


def speech(seed, seconds):
    """Words of 1–3 syllables with short pauses inside words and longer ones between them."""
    rng = random.Random(seed)
    out = []
    while len(out) < seconds * RATE:
        for _ in range(rng.randint(1, 3)):
            out += syllable(rng, rng.uniform(0.12, 0.3))
            out += [0.0] * int(rng.uniform(0.02, 0.08) * RATE)
        out += [0.0] * int(rng.uniform(0.15, 0.35) * RATE)
    return out[:int(seconds * RATE)]


def silence(seconds):
    return [0.0] * int(seconds * RATE)


class Fixture:
    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()

    def wav(self, samples, name='x.wav', rate=RATE):
        path = Path(self.dir.name) / name
        loopback.write_wav(path, rate, samples)
        return path


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.dir.cleanup)

    def analyse(self, samples, **kwargs):
        return loopback.analyse(self.fixture.wav(samples), **kwargs)

    def test_clean_speech_has_sound_and_no_stall_or_repeat(self):
        report = self.analyse(silence(0.5) + speech(1, 6) + silence(0.5))
        self.assertGreater(report['sound_seconds'], 3.5)
        self.assertAlmostEqual(report['first_sound'], 0.5, delta=0.1)
        self.assertEqual([g for g in report['stalls'] if g['where'] == 'between'], [])
        self.assertEqual(report['repeats'], [])
        self.assertGreater(report['peak_dbfs'], -12)
        self.assertLess(report['sound_rms_dbfs'], report['peak_dbfs'])
        self.assertEqual(loopback.verdict(report, max_stall=2.0), [])

    def test_a_stall_in_the_middle_is_reported(self):
        report = self.analyse(speech(2, 3) + silence(4) + speech(3, 3))
        between = [g for g in report['stalls'] if g['where'] == 'between']
        self.assertEqual(len(between), 1)
        self.assertAlmostEqual(between[0]['seconds'], 4.0, delta=0.5)
        self.assertTrue(loopback.verdict(report, max_stall=2.0))

    def test_audio_that_stops_early_fails_on_trailing_silence(self):
        # #1763: speech for a few seconds after locking, then nothing for the rest of the window.
        report = self.analyse(speech(4, 3) + silence(6))
        self.assertEqual(report['stalls'][-1]['where'], 'trailing')
        self.assertAlmostEqual(report['stalls'][-1]['seconds'], 6.0, delta=0.5)
        self.assertTrue(any('trailing' in p for p in loopback.verdict(report, max_stall=2.0)))

    def test_leading_silence_alone_does_not_fail(self):
        report = self.analyse(silence(3) + speech(5, 3))
        self.assertEqual(report['stalls'][0]['where'], 'leading')
        self.assertEqual(loopback.verdict(report, max_stall=2.0), [])

    def test_a_restarted_chunk_is_a_repeat(self):
        # #1762: the first words of a chunk play, then the chunk starts again from the top.
        chunk = speech(6, 4)
        report = self.analyse(chunk[:int(1.4 * RATE)] + chunk + silence(0.5))
        self.assertTrue(report['repeats'], report)
        first = report['repeats'][0]
        self.assertAlmostEqual(first['lag'], 1.4, delta=0.05)
        self.assertGreaterEqual(first['seconds'], 0.6)
        self.assertTrue(any('replays' in p for p in loopback.verdict(report)))

    def test_a_repeat_after_a_pause_and_level_change_is_still_found(self):
        chunk = speech(7, 3)
        shifted = [0.0] * 48 + [0.85 * s for s in chunk[:int(1.5 * RATE)]]  # 3 ms late, a little quieter
        report = self.analyse(chunk + silence(0.6) + shifted)
        self.assertTrue(report['repeats'], report)
        self.assertAlmostEqual(report['repeats'][0]['original_start'], 0.0, delta=0.2)

    def test_different_speech_is_not_a_repeat(self):
        for seed in range(10, 20):
            report = self.analyse(speech(seed, 5) + silence(0.3) + speech(seed + 100, 5))
            self.assertEqual(report['repeats'], [], f'seed {seed}: {report["repeats"]}')

    def test_digital_silence_warns(self):
        report = self.analyse(silence(2))
        self.assertEqual(report['sound_seconds'], 0)
        self.assertIn('warning', report)
        self.assertTrue(loopback.verdict(report, min_sound=1))

    def test_stereo_and_other_rates_read_as_mono(self):
        mono = speech(8, 1)
        stereo = [s for v in mono for s in (v, v)]
        path = Path(self.fixture.dir.name) / 'stereo.wav'
        import wave, array
        with wave.open(str(path), 'wb') as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(48000)
            w.writeframes(array.array('h', (int(s * 32767) for s in stereo)).tobytes())
        rate, samples = loopback.read_wav(path)
        self.assertEqual((rate, len(samples)), (48000, len(mono)))
        rate, down = loopback.downsample(rate, samples)
        self.assertEqual(rate, 16000)
        self.assertEqual(len(down), len(mono) // 3)

    def test_24_bit_reads(self):
        path = Path(self.fixture.dir.name) / 'deep.wav'
        import wave
        with wave.open(str(path), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(3)
            w.setframerate(RATE)
            w.writeframes(b''.join(int(v * 8388607).to_bytes(3, 'little', signed=True) for v in (0.5, -0.5, 0.25)))
        self.assertEqual([round(v, 3) for v in loopback.read_wav(path)[1]], [0.5, -0.5, 0.25])


class TranscriptTests(unittest.TestCase):
    def test_word_error_rate(self):
        result = loopback.score('the quick brown fox jumped over a lazy dog', 'The quick brown fox jumps over the lazy dog.')
        self.assertEqual((result['sub_count'], result['del_count'], result['ins_count']), (2, 0, 0))
        self.assertAlmostEqual(result['wer'], 2 / 9, places=3)

    def test_normalisation(self):
        for heard, expected in [('Café, “don’t” STOP', "cafe don't stop"), ('  spaced   out ', 'Spaced out.'),
                                ('', '')]:
            self.assertEqual(loopback.score(heard, expected)['wer'], 0, heard)

    def test_empty_heard_text_is_all_missing(self):
        result = loopback.score('', 'one two three')
        self.assertEqual((result['wer'], result['del_count']), (1.0, 3))

    def test_restarted_words_are_repeated_phrases(self):
        result = loopback.score('the cat sat the cat sat on the mat', 'The cat sat on the mat.')
        self.assertEqual(result['repeated_phrases'], [{'words': 'the cat sat', 'at_word': 3}])
        self.assertEqual(result['ins_count'], 3)

    def test_a_repeat_the_text_itself_has_is_fine(self):
        result = loopback.score('it was very very good', 'It was very, very good.')
        self.assertEqual(result['repeated_phrases'], [])
        result = loopback.score('so so so many', 'so so many')  # "so so" is in the text; a third isn't a phrase repeat
        self.assertEqual(result['repeated_phrases'], [])

    def test_verdict_reports_transcript_repeats_and_wer(self):
        report = {'sound_seconds': 5, 'stalls': [], 'repeats': [],
                  'score': loopback.score('one two one two three', 'one two three')}
        problems = loopback.verdict(report, max_wer=0.5)
        self.assertTrue(any('twice' in p for p in problems))
        self.assertTrue(any('word error rate' in p for p in problems))
        self.assertEqual(loopback.verdict(report, allow_repeats=True, max_wer=1.0), [])


if __name__ == '__main__':
    unittest.main()
