import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  SEARCH_LABELS,
  followingMatchLine,
  groupCountLine,
  libraryMatchLine,
  lookToFollowLabel,
  marginsMatchLine,
  noMatchLine,
} from './search-words.ts';

// Every string is exact, from the #4427 Design (2026-11-22).

test('each tab has its own label, and Library keeps the one its e2e spec finds', () => {
  assert.deepEqual(SEARCH_LABELS, {
    library: 'Search the Library',
    following: 'Search the shows you follow',
    margins: 'Search your Margins',
  });
});

test('the no-match line names the tab and quotes the trimmed query', () => {
  assert.equal(noMatchLine('library', '  lemonade  '), 'Nothing in the Library matches “lemonade”.');
  assert.equal(noMatchLine('following', 'zzzz'), 'Nothing in the shows you follow matches “zzzz”.');
  assert.equal(noMatchLine('margins', '\tturnip soup\n'), 'Nothing in your Margins matches “turnip soup”.');
});

test('the Library count is singular at 1', () => {
  assert.equal(libraryMatchLine(1), '1 episode matches.');
  assert.equal(libraryMatchLine(2), '2 episodes match.');
  assert.equal(libraryMatchLine(40), '40 episodes match.');
});

test('the Following count names shows, episodes, or both, each singular at 1', () => {
  assert.equal(followingMatchLine(1, 0), '1 show matches.');
  assert.equal(followingMatchLine(3, 0), '3 shows match.');
  assert.equal(followingMatchLine(0, 1), '1 episode matches.');
  assert.equal(followingMatchLine(0, 5), '5 episodes match.');
  assert.equal(followingMatchLine(1, 3), '1 show and 3 episodes match.');
  assert.equal(followingMatchLine(2, 1), '2 shows and 1 episode match.');
  assert.equal(followingMatchLine(1, 1), '1 show and 1 episode match.');
  assert.equal(followingMatchLine(4, 7), '4 shows and 7 episodes match.');
});

test('the Margins count names the Margins and the episodes they sit on', () => {
  assert.equal(marginsMatchLine(1, 1), '1 Margin matches.');
  assert.equal(marginsMatchLine(2, 1), '2 Margins match, on 1 episode.');
  assert.equal(marginsMatchLine(9, 3), '9 Margins match, on 3 episodes.');
});

test('a group count reads as today when every Margin shows, and "k of n" when a search hides some', () => {
  assert.equal(groupCountLine(1, 1), '1 Margin');
  assert.equal(groupCountLine(4, 4), '4 Margins');
  assert.equal(groupCountLine(1, 3), '1 of 3 Margins');
  assert.equal(groupCountLine(2, 10), '2 of 10 Margins');
});

test('the Look for button quotes the trimmed query', () => {
  assert.equal(lookToFollowLabel('  zzzz '), 'Look for “zzzz” to follow');
  assert.equal(lookToFollowLabel('The Daily'), 'Look for “The Daily” to follow');
});
