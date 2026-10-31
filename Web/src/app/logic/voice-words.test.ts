import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isPlaceholder, prefillOverPlaceholder, voiceMarginOnStop, withWords, wordsToSave } from './voice-words.ts';

const placeholder = 'Voice Margin at 1:05 in “Episode 1”, recorded 30 Oct 2026';

test('a transcript replaces the placeholder', () => {
  assert.deepEqual(prefillOverPlaceholder(placeholder, false, ' Ask not. ', placeholder), { words: 'Ask not.' });
  // Even when the listener clicked into the box and left it as it was.
  assert.deepEqual(prefillOverPlaceholder(`${placeholder} `, true, 'Ask not.', placeholder), { words: 'Ask not.' });
  // Cleared the box: the transcript goes in.
  assert.deepEqual(prefillOverPlaceholder('', true, 'Ask not.', placeholder), { words: 'Ask not.' });
});

test('an empty transcript leaves the placeholder', () => {
  assert.deepEqual(prefillOverPlaceholder(placeholder, false, '  ', placeholder), { words: placeholder });
});

test("the listener's own words always win over a transcript", () => {
  assert.deepEqual(prefillOverPlaceholder('my words', true, 'Ask not.', placeholder), { words: 'my words', suggestion: 'Ask not.' });
  // Edited the placeholder rather than replacing it: still theirs.
  const edited = `${placeholder}, about the tide`;
  assert.deepEqual(prefillOverPlaceholder(edited, true, 'Ask not.', placeholder), { words: edited, suggestion: 'Ask not.' });
});

test('the placeholder is never stored as the Margin’s words', () => {
  assert.equal(wordsToSave(placeholder, placeholder), undefined);
  assert.equal(wordsToSave(`  ${placeholder}\n`, placeholder), undefined);
  assert.equal(wordsToSave('   ', placeholder), undefined);
  assert.equal(wordsToSave(' my words ', placeholder), 'my words');
  assert.equal(wordsToSave('Ask not.', placeholder), 'Ask not.');
  assert.equal(isPlaceholder('Voice Margin at 1:05', placeholder), false);
});

const voice = { blob: new Blob([new Uint8Array([1, 2, 3])]), mimeType: 'audio/mp4', durationSeconds: 4 };

test('Stop saves the voice Margin at once, with no words of its own (#3038)', () => {
  const recordedAt = new Date('2026-10-31T21:04:00Z');
  const margin = voiceMarginOnStop({ id: 'm1', episodeId: 'e1', atSeconds: 65, recordedAt, voice });
  assert.deepEqual(margin, { id: 'm1', episodeId: 'e1', atSeconds: 65, createdAt: '2026-10-31T21:04:00.000Z', voice });
  // No `text` key at all: the packet writer gives it the placeholder at export.
  assert.equal('text' in margin, false);
});

test('words after the save update the stored Margin, and only when they change it', () => {
  const saved = voiceMarginOnStop({ id: 'm1', episodeId: 'e1', atSeconds: 65, recordedAt: new Date('2026-10-31T21:04:00Z'), voice });
  // The box still holds the placeholder, or nothing: nothing to write.
  assert.equal(withWords(saved, placeholder, placeholder), undefined);
  assert.equal(withWords(saved, '  ', placeholder), undefined);
  // A transcript or typed words go on the Margin, trimmed.
  const worded = withWords(saved, ' Ask not. ', placeholder);
  assert.deepEqual(worded, { ...saved, text: 'Ask not.' });
  // The same words again write nothing.
  assert.equal(withWords(worded!, 'Ask not.', placeholder), undefined);
  // Back to the placeholder takes the words off; the audio and the moment stay.
  const cleared = withWords(worded!, placeholder, placeholder);
  assert.deepEqual(cleared, saved);
  assert.equal('text' in cleared!, false);
});
