import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initialSearchState, searchReducer, type SearchAction, type SearchState } from './search-state.ts';

const run = (state: SearchState, ...actions: SearchAction[]) => actions.reduce(searchReducer, state);

test('each tab keeps its own query', () => {
  const s = run(initialSearchState, { type: 'query', tab: 'library', query: 'lemonade' }, { type: 'query', tab: 'margins', query: 'turnip' });
  assert.deepEqual(s.queries, { library: 'lemonade', following: '', margins: 'turnip' });
});

test('search-time folds last until the Margins query is blank, and never touch the earlier folds', () => {
  let s = run(initialSearchState, { type: 'toggled', update: (c) => ({ ...c, a: false }) });
  s = run(s, { type: 'query', tab: 'margins', query: 'turnip' }, { type: 'searchToggled', update: (c) => ({ ...c, a: true }) });
  s = run(s, { type: 'query', tab: 'margins', query: 'sam' });
  assert.deepEqual(s.searchToggled, { a: true });
  // A query of spaces is blank.
  s = run(s, { type: 'query', tab: 'margins', query: '   ' });
  assert.deepEqual(s.searchToggled, {});
  assert.deepEqual(s.toggled, { a: false });
});

test('another tab clearing does not drop the Margins search folds', () => {
  let s = run(initialSearchState, { type: 'query', tab: 'margins', query: 'x' }, { type: 'searchToggled', update: () => ({ a: true }) });
  s = run(s, { type: 'query', tab: 'library', query: 'y' }, { type: 'query', tab: 'library', query: '' });
  assert.deepEqual(s.searchToggled, { a: true });
});

test('clear empties every query and the search folds, and leaves toggled', () => {
  let s = run(
    initialSearchState,
    { type: 'toggled', update: () => ({ a: true }) },
    { type: 'query', tab: 'library', query: 'a' },
    { type: 'query', tab: 'following', query: 'b' },
    { type: 'query', tab: 'margins', query: 'c' },
    { type: 'searchToggled', update: () => ({ g: false }) },
  );
  s = run(s, { type: 'clear' });
  assert.deepEqual(s, { ...initialSearchState, toggled: { a: true } });
});

test('clear on a clean state returns the same object', () => {
  assert.equal(searchReducer(initialSearchState, { type: 'clear' }), initialSearchState);
});
