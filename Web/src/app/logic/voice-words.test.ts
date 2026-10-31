import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isPlaceholder, prefillOverPlaceholder, wordsToSave } from './voice-words.ts';

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
