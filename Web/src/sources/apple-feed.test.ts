import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode } from '../shared/model.ts';
import { episodeInFeed, titleKey } from './apple-feed.ts';

const ep = (title: string, extra: Partial<Episode> = {}): Episode => ({ id: title, showId: 's', title, audioUrl: `https://example.com/${encodeURIComponent(title)}.mp3`, ...extra });
const TITLE = "People, Parks, and Policy, with RFF's Margaret Walls";

// The same episode as a feed, Apple's page and the packet word it; none of these is another episode.
const sameTitle: Array<[string, string]> = [
  ['identical', TITLE],
  ['curly apostrophe, no comma after Policy (Apple’s page)', 'People, Parks, and Policy with RFF’s Margaret Walls'],
  ['upper case', TITLE.toUpperCase()],
  ['extra and odd spaces', '  People,  Parks, and Policy, with RFF\'s   Margaret Walls '],
  ['dashes for commas', 'People - Parks - and Policy - with RFFs Margaret Walls'],
];
for (const [name, other] of sameTitle) {
  test(`one title: ${name}`, () => {
    assert.equal(titleKey(other), titleKey(TITLE));
    assert.equal(episodeInFeed([ep('Another one'), ep(TITLE, { id: 'wanted' })], other)?.id, 'wanted');
  });
}

test('accents and Unicode forms of one title match', () => {
  assert.equal(titleKey('Café Économie'), titleKey('Café Economie'));
  assert.equal(titleKey('Café'), titleKey('Cafe'));
  assert.equal(titleKey('ＡＢＣ 123'), titleKey('abc 123'));
});

// Titles that look alike and are not the same episode.
const different: Array<[string, string]> = [
  ['a part number', `${TITLE} Part 2`],
  ['a year', `${TITLE} (2019)`],
  ['a different guest', "People, Parks, and Policy, with RFF's Penny Liao"],
  ['a prefix of it', 'People, Parks, and Policy'],
  ['digits in place of a word', 'People 2 Parks and Policy with RFFs Margaret Walls'],
  ['another script', '人々、公園'],
];
for (const [name, other] of different) {
  test(`not the same episode: ${name}`, () => {
    assert.equal(episodeInFeed([ep(other)], TITLE), undefined);
  });
}

test('an empty or punctuation-only title matches nothing', () => {
  for (const blank of ['', '   ', '...', '——', '!?']) {
    assert.equal(episodeInFeed([ep(blank), ep('x')], blank), undefined, JSON.stringify(blank));
  }
});

test('two items with the title are never guessed between, even when one has no audio', () => {
  assert.equal(episodeInFeed([ep(TITLE, { id: 'a' }), ep("People, Parks and Policy, with RFF’s Margaret Walls", { id: 'b' })], TITLE), undefined);
  const { audioUrl: _gone, ...noAudio } = ep(TITLE, { id: 'twin' });
  assert.equal(episodeInFeed([ep(TITLE, { id: 'a' }), noAudio], TITLE), undefined);
});

test('the one item with the title is not an answer when it has no audio address', () => {
  const { audioUrl: _gone, ...noAudio } = ep(TITLE);
  assert.equal(episodeInFeed([noAudio], TITLE), undefined);
});

test('a very long title still matches itself and nothing else', () => {
  const long = 'Long '.repeat(2_000);
  assert.ok(episodeInFeed([ep(long, { id: 'l' })], long));
  assert.equal(episodeInFeed([ep(`${long}x`)], long), undefined);
});
