"""Host tests for the loopback analysis (#1790). No audio hardware: fixtures are synthetic speech-like wavs."""
import math
import random
import tempfile
import contextlib
import io
import json
import unittest
from pathlib import Path
from unittest import mock

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


def steady_voice(seed, seconds, rhythm=(0.19, 0.19, 0.24, 0.17, 0.21), pitch=120.0):
    """A steady synthetic voice like the phone's TTS: one pitch, one loudness, the same syllable rhythm
    throughout; only the vowel colour (where the harmonics peak) changes from syllable to syllable."""
    rng = random.Random(seed)
    out, index = [], 0
    while len(out) < seconds * RATE:
        n = int(rhythm[index % len(rhythm)] * RATE)
        centre = rng.uniform(1.5, 10.0)
        weights = [math.exp(-(((h - centre) / 1.4) ** 2)) for h in range(1, 13)]
        voice = [sum(w * math.sin(2 * math.pi * pitch * h * i / RATE) for h, w in enumerate(weights, 1))
                 for i in range(n)]
        norm = math.sqrt(sum(v * v for v in voice) / n) or 1.0
        out += [0.3 * (0.5 - 0.5 * math.cos(2 * math.pi * i / n)) * v / norm for i, v in enumerate(voice)]
        out += [0.0] * int(0.05 * RATE)
        index += 1
        if index % len(rhythm) == 0:
            out += [0.0] * int(0.25 * RATE)
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
        self.assertEqual(loopback.verdict(report, max_stall=2.0, allow_trailing=True), [])

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

    def test_a_steady_voice_saying_new_words_in_the_same_rhythm_is_not_a_repeat(self):
        # Desk run 2026-10-18: clean iOS-voice speech was flagged FAIL "repeats" (0.6 to 1.9 s stretches,
        # correlation 0.90 to 0.99) because a steady voice repeats its loudness pattern with new words.
        for seed in range(30, 36):
            report = self.analyse(steady_voice(seed, 8) + silence(0.3) + steady_voice(seed + 100, 8))
            self.assertEqual(report['repeats'], [], f'seed {seed}: {report["repeats"]}')

    def test_a_steady_voice_replayed_is_still_a_repeat(self):
        chunk = steady_voice(40, 4)
        report = self.analyse(chunk[:int(1.4 * RATE)] + chunk + silence(0.5))
        self.assertTrue(report['repeats'], report)
        self.assertAlmostEqual(report['repeats'][0]['lag'], 1.4, delta=0.05)

    def test_a_quieter_late_replay_of_a_steady_voice_is_still_a_repeat(self):
        chunk = steady_voice(41, 3)
        late = [0.0] * 48 + [0.85 * s for s in chunk[:int(1.5 * RATE)]]
        report = self.analyse(chunk + silence(0.6) + late)
        self.assertTrue(report['repeats'], report)

    def test_a_restart_after_a_short_silence_is_a_repeat_wherever_the_chunk_was_cut(self):
        # Spliced desk recordings (#1790): an exact replay was dropped because a lag one frame off held the
        # loudness match as long, won, then failed on brightness. These cut points all failed that way.
        for seed, cut in ((202, 1.3), (202, 1.6), (202, 2.05), (203, 1.15), (203, 1.45), (203, 1.9)):
            chunk = speech(seed, 6)
            report = self.analyse(chunk[:int(cut * RATE)] + silence(0.2) + chunk + silence(0.5))
            self.assertTrue(report['repeats'], f'seed {seed}, cut at {cut} s: {report.get("recurring")}')
            self.assertAlmostEqual(report['repeats'][0]['lag'], cut + 0.2, delta=0.05)

    def test_digital_silence_at_one_edge_does_not_sink_an_exact_replay(self):
        # Desk audio has true digital silence (-100 dB). An exact replay whose stretch ends one frame into
        # the original's silence scored correlation 0.81 until levels below the silence line were clamped.
        stretch = [-15 - 30 * (0.5 - 0.5 * math.cos(2 * math.pi * i / 20)) for i in range(79)] + [-25.0]
        env = stretch + [-30.0] * 20 + stretch[:-1] + [loopback.FLOOR_DB]
        self.assertLess(loopback.similarity(env, 100, 0, 80)[0], 0.9)
        corr, diff = loopback.similarity(env, 100, 0, 80, floor=-45.0)
        self.assertGreater(corr, 0.9)
        self.assertLess(diff, 1.0)

    def test_a_phrase_the_source_says_twice_is_recurring_not_a_repeat(self):
        # Desk run 2026-10-18, pdf-start.wav: "foundation for American innovation" in two authors'
        # affiliations, 3.5 s apart with a name between, rendered the same both times. New sound comes
        # between the two, and different words follow each, so nothing was replayed.
        phrase = steady_voice(51, 1.5)
        name = lambda seed, rhythm: steady_voice(seed, 2, rhythm=rhythm)  # noqa: E731
        samples = (name(50, (0.22, 0.17, 0.2)) + phrase + name(52, (0.16, 0.25, 0.19, 0.2))
                   + phrase + name(53, (0.24, 0.18)) + silence(0.5))
        report = self.analyse(samples)
        self.assertEqual(report['repeats'], [], report['repeats'])
        self.assertTrue(report['recurring'], report)
        self.assertAlmostEqual(report['recurring'][0]['lag'], 3.5, delta=0.1)
        self.assertGreaterEqual(report['recurring'][0]['sound_between'], 0.5)
        self.assertEqual(loopback.verdict(report), [])

    def test_a_replay_that_ends_the_audio_is_a_repeat_even_after_new_sound(self):
        # Review of #1790: a passage, a Margin, the passage again, then playback stops. Silence after the
        # second time shows nothing new, so it can't be a phrase the source says twice.
        phrase = steady_voice(51, 1.5)
        for seed in (70, 71, 72):
            margin = steady_voice(seed, 2, rhythm=(0.2, 0.26, 0.17))
            report = self.analyse(steady_voice(50, 2, rhythm=(0.22, 0.17, 0.2)) + phrase + margin + phrase
                                  + silence(1.5))
            self.assertTrue(report['repeats'], f'seed {seed}: {report["recurring"]}')
            self.assertEqual(report['recurring'], [], f'seed {seed}')

    def test_the_expected_words_decide_whether_a_recurring_match_is_a_replay(self):
        # Sound alone can't tell a phrase the source says twice from a replay after a Margin: both have
        # new sound between and new words after. The expected text can.
        phrase = steady_voice(51, 1.5)
        samples = (steady_voice(50, 2, rhythm=(0.22, 0.17, 0.2)) + phrase
                   + steady_voice(70, 2, rhythm=(0.2, 0.26, 0.17)) + phrase
                   + steady_voice(53, 2, rhythm=(0.24, 0.18)) + silence(0.5))
        fresh = lambda: self.analyse(samples)  # noqa: E731
        match = fresh()['recurring'][0]
        heard = [{'word': w, 'start': at + i * 0.3} for at in (match['original_start'], match['start'])
                 for i, w in enumerate(('the', 'harbour', 'master'))]
        for expected, recurs in (('we met the harbour master and later the harbour master again', True),
                                 ('we met the harbour master on the quay', False)):
            report = fresh()
            report['transcript'] = {'text': ' '.join(h['word'] for h in heard), 'words': heard}
            loopback.explain_recurring(report, expected)
            self.assertEqual(bool(report['recurring']), recurs, expected)
            self.assertEqual(bool(loopback.verdict(report)), not recurs, report['repeats'])
        self.assertEqual(report['repeats'][0]['words'], 'the harbour master')

    def test_check_with_expected_text_reads_multi_word_items_and_fails_an_unexplained_replay(self):
        # The recogniser returns items like "short term memory" with one start; each word needs its own.
        phrase = steady_voice(51, 1.5)
        path = self.fixture.wav(steady_voice(50, 2, rhythm=(0.22, 0.17, 0.2)) + phrase
                                + steady_voice(70, 2, rhythm=(0.2, 0.26, 0.17)) + phrase
                                + steady_voice(53, 2, rhythm=(0.24, 0.18)) + silence(0.5))
        match = loopback.analyse(path)['recurring'][0]
        # One item per hearing, starting before the match: only its later words fall inside it.
        heard = [{'word': 'long short term memory', 'start': at - 0.5, 'duration': 1.2}
                 for at in (match['original_start'], match['start'])]
        heard.append({'word': 'and', 'start': match['original_start'] + 1.6, 'duration': 0.2})
        heard.sort(key=lambda w: w['start'])
        transcript = {'text': ' '.join(w['word'] for w in heard), 'words': heard}
        with mock.patch.object(loopback, 'transcribe', return_value=transcript):
            twice = loopback.check_recording(path, expected='long short term memory and long short term memory')
            once = loopback.check_recording(path, expected='long short term memory and gated units')
        self.assertEqual(twice['verdict'], 'PASS', twice['problems'])
        self.assertEqual(twice['recurring'][0]['words'], 'term memory')
        self.assertEqual(once['verdict'], 'FAIL')
        self.assertEqual(once['repeats'][0]['words'], 'term memory')

    def test_a_seek_back_after_new_words_is_still_a_repeat(self):
        # Playback that jumps 2.3 s back keeps matching what it replays, so it never looks recurring.
        # (Not 3 s: this voice's rhythm repeats every 1.5 s, so loudness matches at that lag everywhere.)
        chunk = steady_voice(60, 8)
        report = self.analyse(chunk[:5 * RATE] + chunk[int(2.7 * RATE):] + silence(0.5))
        self.assertTrue(report['repeats'], report)
        self.assertAlmostEqual(report['repeats'][0]['lag'], 2.3, delta=0.1)
        self.assertEqual(report['recurring'], [])

    def test_a_restarted_chunk_followed_by_new_words_is_still_a_repeat(self):
        # #1762 with more after it: nothing new sits between the cut-off start and the restart.
        chunk = steady_voice(61, 3)
        report = self.analyse(chunk[:int(1.4 * RATE)] + silence(0.2) + chunk + steady_voice(62, 3)
                              + silence(0.5))
        self.assertTrue(report['repeats'], report)
        self.assertEqual(report['recurring'], [])

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


class ChunkedTranscriptionTests(unittest.TestCase):
    """The on-device recogniser drops what it heard when a long pause follows (#1790), so transcribe() must
    hand it stretches of speech with only short silence around them, and say why when nothing came back."""

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.dir.cleanup)

    def test_chunks_split_only_at_long_pauses(self):
        # Frames are 10 ms: a 0.5 s pause stays inside a chunk, a 2 s pause splits; padding is clamped to the file.
        chunks = loopback.speech_chunks([(0, 100), (150, 300), (500, 600)], 610)
        self.assertEqual(chunks, [(0.0, 3.2), (4.8, 6.1)])
        self.assertEqual(loopback.speech_chunks([], 100), [])

    def test_each_chunk_has_no_long_silence_and_words_keep_recording_time(self):
        # The 10-17 proof recording's shape: 4.9 s of silence first, a short pause, a long pause, 4.4 s at the end.
        samples = (silence(4.9) + speech(1, 2.7) + silence(0.6) + speech(2, 2.4) + silence(2.0) + speech(3, 1.5)
                   + silence(4.4))
        seen = []

        def run(piece, locale):
            report = loopback.analyse(piece)
            seen.append(report)
            n = len(seen)
            return {'text': f'chunk {n}', 'words': [{'word': 'chunk', 'start': 0.5, 'duration': 0.2}]}

        heard = loopback.transcribe(self.fixture.wav(samples), run=run)
        self.assertEqual(len(seen), 2)
        for report in seen:
            self.assertLessEqual(report['first_sound'], loopback.CHUNK_PAD + 0.05)
            self.assertLessEqual(report['seconds'] - report['last_sound'], loopback.CHUNK_PAD + 0.05)
        self.assertEqual(heard['text'], 'chunk 1 chunk 2')
        self.assertNotIn('empty_reason', heard)
        first, second = heard['chunks']
        self.assertAlmostEqual(first['start'], 4.9 - loopback.CHUNK_PAD, delta=0.05)
        self.assertAlmostEqual(second['start'], 4.9 + 2.7 + 0.6 + 2.4 + 2.0 - loopback.CHUNK_PAD, delta=0.1)
        self.assertEqual([w['start'] for w in heard['words']], [round(c['start'] + 0.5, 3) for c in heard['chunks']])

    def test_no_words_says_why(self):
        empty = {'text': '', 'words': [{'word': '', 'start': 0, 'duration': 0}], 'empty_reason': 'no speech detected'}
        heard = loopback.transcribe(self.fixture.wav(speech(4, 2.0) + silence(3)), run=lambda piece, locale: empty)
        self.assertEqual((heard['text'], heard['words']), ('', []))
        self.assertIn('heard no words', heard['empty_reason'])
        self.assertIn('no speech detected', heard['empty_reason'])

    def test_a_silent_recording_never_reaches_the_recogniser(self):
        heard = loopback.transcribe(self.fixture.wav(silence(3)), run=lambda piece, locale: self.fail('called'))
        self.assertIn('no sound', heard['empty_reason'])

    def test_check_with_an_empty_transcript_reports_why_not_a_word_error_rate(self):
        wav = self.fixture.wav(speech(5, 3.0))
        expected = Path(self.fixture.dir.name) / 'expected.txt'
        expected.write_text('one two three')
        empty = {'text': '', 'words': [], 'empty_reason': 'the recogniser heard no words in 3.0 s of sound'}
        out = io.StringIO()
        with mock.patch.object(loopback, 'transcribe', return_value=empty), contextlib.redirect_stdout(out):
            status = loopback.main(['check', str(wav), '--expected', str(expected), '--max-wer', '0.2'])
        report = json.loads(out.getvalue())
        self.assertEqual((status, report['verdict']), (1, 'FAIL'))
        self.assertIn('could not check the words: the recogniser heard no words in 3.0 s of sound', report['problems'])
        self.assertFalse(any('word error rate' in p for p in report['problems']))


if __name__ == '__main__':
    unittest.main()
