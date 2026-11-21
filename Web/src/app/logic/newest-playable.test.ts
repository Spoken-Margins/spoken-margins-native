import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode } from '../../shared/model.ts';
import { MESSAGES } from './messages.ts';
import {
  MAX_POST_LOOKUPS,
  newestPlayableMessage,
  playCandidates,
  playNewestAvailable,
  type PlayAttempt,
} from './newest-playable.ts';

const post = (id: string): Episode => ({ id, showId: 's', title: id, pageUrl: `https://e.test/p/${id}` });
const applePage = (id: string): Episode => ({ id, showId: 's', title: id, pageUrl: `https://podcasts.apple.com/us/podcast/x/id1?i=${id.replace(/\D/g, '') || '1'}` });
const spotifyPage = (id: string): Episode => ({ id, showId: 's', title: id, pageUrl: `https://open.spotify.com/episode/${id}` });
const audio = (id: string): Episode => ({ id, showId: 's', title: id, audioUrl: `https://e.test/${id}.mp3` });
const ids = (list: readonly Episode[]) => list.map((e) => e.id);

/** Walks `list`, answering from `answers`, and records what was tried. */
async function walk(list: readonly Episode[], answers: Record<string, PlayAttempt>) {
  const tried: string[] = [];
  const result = await playNewestAvailable(list, async (e) => {
    tried.push(e.id);
    return answers[e.id] ?? 'played';
  });
  return { tried, result };
}

test('candidates end at the first item whose audio is known', () => {
  assert.deepEqual(ids(playCandidates([post('a'), audio('b'), post('c'), audio('d')])), ['a', 'b']);
  assert.deepEqual(ids(playCandidates([audio('a'), post('b')])), ['a']);
});

test('one tap reads at most the limit of post pages, and can still reach audio past it', () => {
  const posts = Array.from({ length: MAX_POST_LOOKUPS + 4 }, (_, i) => post(`p${i}`));
  assert.equal(playCandidates(posts).length, MAX_POST_LOOKUPS);
  const list = playCandidates([...posts, audio('old')]);
  assert.equal(list.filter((e) => !e.audioUrl).length, MAX_POST_LOOKUPS);
  assert.equal(list.at(-1)?.id, 'old');
});

test('an item with neither audio nor a page is never tried', () => {
  const bare: Episode = { id: 'bare', showId: 's', title: 'bare' };
  assert.deepEqual(ids(playCandidates([bare, audio('a')])), ['a']);
  assert.deepEqual(playCandidates([]), []);
});

test('a free newest post plays and nothing older is touched', async () => {
  const { tried, result } = await walk([post('new'), audio('old')], {});
  assert.deepEqual(tried, ['new']);
  assert.deepEqual(result, { outcome: 'played' });
  assert.equal(newestPlayableMessage(result), undefined);
});

test('a paid newest post is passed over for the next that plays, and the listener is told', async () => {
  const { tried, result } = await walk([post('paid'), audio('free')], { paid: 'paid' });
  assert.deepEqual(tried, ['paid', 'free']);
  assert.deepEqual(result, { outcome: 'played', firstSkip: 'paid' });
  assert.deepEqual(newestPlayableMessage(result), { text: MESSAGES.newestSkipped });
});

test('a free post with no voice is passed over too', async () => {
  const { tried, result } = await walk([post('silent'), post('voiced')], { silent: 'no-voice' });
  assert.deepEqual(tried, ['silent', 'voiced']);
  assert.equal(result.outcome, 'played');
});

test('a refused or failed read ends the walk with no second message', async () => {
  const { tried, result } = await walk([post('a'), post('b'), audio('c')], { a: 'paid', b: 'stopped' });
  assert.deepEqual(tried, ['a', 'b']);
  assert.equal(result.outcome, 'stopped');
  assert.equal(newestPlayableMessage(result), undefined);
});

test('when nothing plays, the message names why the newest could not', async () => {
  const paid = await walk([post('a'), post('b')], { a: 'paid', b: 'no-voice' });
  assert.deepEqual(newestPlayableMessage(paid.result), { text: MESSAGES.paidPost, tone: 'problem' });
  const silent = await walk([post('a'), post('b')], { a: 'no-voice', b: 'paid' });
  assert.deepEqual(newestPlayableMessage(silent.result), { text: MESSAGES.noVoice, tone: 'problem' });
});

// #4767: an episode saved from a Spotify or other page is not a post and has nothing to look up. It costs no read, and a show
// of only those says the page has no audio for the web, not that a post has no voice.
test('an episode with only a Spotify page is never tried, and says why when it is all there is', async () => {
  assert.deepEqual(ids(playCandidates([spotifyPage('a'), post('p'), audio('b')])), ['p', 'b']);
  assert.deepEqual(playCandidates([spotifyPage('a'), spotifyPage('b')]), []);
  const none = await walk([], {});
  assert.deepEqual(newestPlayableMessage(none.result), { text: MESSAGES.noWebAudio, tone: 'problem' });
});

// #4783: an Apple Podcasts episode page names its episode, so Apple's lookup can give its audio on the tap. It counts toward
// the same limit as a post page, so one tap never asks more than a few times.
test('an Apple Podcasts episode page is tried, within the same limit, and ends at the first audio known', async () => {
  assert.deepEqual(ids(playCandidates([applePage('1'), spotifyPage('s'), post('p'), audio('b')])), ['1', 'p', 'b']);
  const many = Array.from({ length: MAX_POST_LOOKUPS + 3 }, (_, i) => applePage(`${i + 1}`));
  assert.equal(playCandidates(many).length, MAX_POST_LOOKUPS);
  const { tried, result } = await walk([applePage('1'), applePage('2')], { '1': 'no-audio' });
  assert.deepEqual(tried, ['1', '2']);
  assert.equal(result.outcome, 'played');
  assert.equal(result.firstSkip, 'no-audio');
  // An episode passed over is an episode, never a "post" (#4767).
  assert.deepEqual(newestPlayableMessage(result), { text: MESSAGES.newestEpisodeSkipped });
  assert.doesNotMatch(MESSAGES.newestEpisodeSkipped, /post/);
});
