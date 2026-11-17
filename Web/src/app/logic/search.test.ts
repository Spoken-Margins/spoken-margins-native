import { test } from 'node:test';
import assert from 'node:assert/strict';
import { foldForSearch, matchesSearch } from './search.ts';

test('an empty or blank query matches everything, even a row with no words', () => {
  for (const query of ['', '   ', '\n\t']) assert.equal(matchesSearch(query, []), true, JSON.stringify(query));
  assert.equal(matchesSearch('', [undefined]), true);
});

// The neighbours a listener types: case, accents, white space, punctuation, width, a lookalike and a longer title.
const rows: [string, string, boolean][] = [
  ['lemonade', 'The Lemonade Stand', true],
  ['LEMONADE', 'the lemonade stand', true],
  ['cafe', 'Café Society', true],
  ['café', 'Cafe Society', true],
  ['é', 'Café', true], // a typed accent in the decomposed form
  ['stand  up', 'Stand up comedy', true],
  ['  stand up  ', 'Stand up comedy', true],
  ['stand up', 'Stand up comedy', true], // a non-breaking space
  ['ＡＢＣ', 'abc news', true], // full-width letters
  ['abc', 'ＡＢＣ news', true],
  ['don’t', 'Don’t Stop', true],
  ['dont', 'Don’t Stop', false], // punctuation is kept, so an apostrophe has to be typed
  ['ǆ', 'Ǆ', true],
  ['stand', 'Stan', false],
  ['lemonade stand', 'Lemonade', false], // the whole query must be in one field
  ['x'.repeat(5000), 'short', false],
];
for (const [query, field, expected] of rows) {
  test(`${JSON.stringify(query.slice(0, 20))} against ${JSON.stringify(field)} is ${expected}`, () => {
    assert.equal(matchesSearch(query, [field]), expected);
  });
}

test('any field is enough, and a missing one is skipped', () => {
  assert.equal(matchesSearch('cole', ['Episode 1', undefined, 'Shared by Cole']), true);
  assert.equal(matchesSearch('cole', ['Episode 1', undefined, 'Shared by Sam']), false);
});

test('folding is the same for the query and the field', () => {
  assert.equal(foldForSearch(' Ｃａｆé  Society '), 'cafe society');
});
