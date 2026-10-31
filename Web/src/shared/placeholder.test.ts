import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PLACEHOLDER_TITLE_CHARACTERS, placeholderDate, placeholderTitle, voicePlaceholder } from './placeholder.ts';

// Built from local parts, so the expected calendar day holds in any time zone the tests run in.
const day = new Date(2026, 9, 30, 14, 5);

test('names the moment, the item and the day', () => {
  assert.equal(
    voicePlaceholder({ atSeconds: 754.9, title: 'Episode 1 (example episode)', recordedAt: day }),
    'Voice Margin at 12:34 in “Episode 1 (example episode)”, recorded 30 Oct 2026',
  );
});

test('an hour-plus moment uses the player clock', () => {
  assert.equal(voicePlaceholder({ atSeconds: 3725, title: 'Long one', recordedAt: day }), 'Voice Margin at 1:02:05 in “Long one”, recorded 30 Oct 2026');
});

test('no title, or only spaces, leaves the "in" part out', () => {
  for (const title of [undefined, '', '   \n\t ']) {
    assert.equal(voicePlaceholder({ atSeconds: 5, ...(title !== undefined && { title }), recordedAt: day }), 'Voice Margin at 0:05, recorded 30 Oct 2026');
  }
});

test('an unreadable date leaves the "recorded" part out', () => {
  assert.equal(voicePlaceholder({ atSeconds: 5, title: 'T', recordedAt: new Date('not a date') }), 'Voice Margin at 0:05 in “T”');
});

test('the date is day, month word and year, never a numeric order', () => {
  assert.equal(placeholderDate(new Date(2026, 0, 2)), '2 Jan 2026');
  assert.equal(placeholderDate(new Date(2027, 11, 31, 23, 59)), '31 Dec 2027');
  assert.doesNotMatch(placeholderDate(day), /\d+[/.-]\d+/);
});

test('a very long title is cut to a whole character with an ellipsis', () => {
  const long = 'A '.repeat(200);
  const cut = placeholderTitle(long);
  assert.equal([...cut].length, PLACEHOLDER_TITLE_CHARACTERS);
  assert.ok(cut.endsWith('…'));
  assert.doesNotMatch(cut, / …$/, 'no space before the ellipsis');
  const exact = 'x'.repeat(PLACEHOLDER_TITLE_CHARACTERS);
  assert.equal(placeholderTitle(exact), exact, 'a title at the limit is kept whole');
  const placeholder = voicePlaceholder({ atSeconds: 1, title: long, recordedAt: day });
  assert.ok(placeholder.length < 140, placeholder);
});

test('Unicode titles: line breaks fold, emoji and accents are never split', () => {
  assert.equal(placeholderTitle('Café\nau  lait'), 'Café au lait');
  // A decomposed é becomes one character, so the packet carries the same text whichever form the feed used.
  assert.equal(placeholderTitle('Café'), 'Café');
  const family = '👨‍👩‍👧‍👦';
  const cut = placeholderTitle(family.repeat(100), 10);
  assert.equal(cut, `${family.repeat(9)}…`);
  assert.equal(voicePlaceholder({ atSeconds: 61, title: '日本語のポッドキャスト', recordedAt: day }), 'Voice Margin at 1:01 in “日本語のポッドキャスト”, recorded 30 Oct 2026');
});
