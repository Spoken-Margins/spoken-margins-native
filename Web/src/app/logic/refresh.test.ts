import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Episode, Show } from '../../shared/model.ts';
import { NeedsRelayConsent, readFeed } from '../../sources/read.ts';
import {
  REFRESH_CONCURRENCY,
  REFRESH_INTERVAL_MS,
  checkedLabel,
  dueShows,
  lastRefreshedAt,
  mergeRefresh,
  needsRelayLine,
  refreshResultLine,
  runRefresh,
  type RefreshOutcome,
} from './refresh.ts';

const FEED = 'https://feeds.test/show.rss';
const SHOW_ID = `feed:${FEED}`;
const show = (over: Partial<Show> = {}): Show => ({
  id: SHOW_ID,
  kind: 'podcast',
  title: 'The Show',
  feedUrl: FEED,
  followedAt: '2026-10-01T00:00:00.000Z',
  ...over,
});
const ep = (key: string, over: Partial<Episode> = {}): Episode => ({ id: `${SHOW_ID}#${key}`, showId: SHOW_ID, title: `Episode ${key}`, ...over });
const NOW = '2026-10-30T12:00:00.000Z';

// ---------- merge and dedupe ----------

test('a refresh adds only the new episodes, and a stored one keeps its id', () => {
  const stored = [ep('g1', { guid: 'g1', audioUrl: 'https://m.test/1.mp3', publishedAt: '2026-10-01T00:00:00.000Z' })];
  const read = { show: show(), episodes: [ep('g2', { guid: 'g2', audioUrl: 'https://m.test/2.mp3' }), ep('g1', { guid: 'g1', audioUrl: 'https://m.test/1.mp3', publishedAt: '2026-10-01T00:00:00.000Z' })] };
  const merged = mergeRefresh({ show: show(), episodes: stored }, read, NOW);
  assert.equal(merged.added, 1);
  assert.deepEqual(merged.write.map((e) => e.id), [`${SHOW_ID}#g2`]);
});

test('a GUID match keeps the stored id even when the enclosure address moved, so the place and Margins stay', () => {
  // Stored with its GUID; then the host moved the audio to a new CDN address.
  const stored = [ep('https://old.test/1.mp3', { guid: 'g1', audioUrl: 'https://old.test/1.mp3', title: 'Old title' })];
  const read = { show: show(), episodes: [ep('g1', { guid: 'g1', audioUrl: 'https://new.test/1.mp3', title: 'New title' })] };
  const merged = mergeRefresh({ show: show(), episodes: stored }, read, NOW);
  assert.equal(merged.added, 0);
  assert.equal(merged.write.length, 1);
  assert.equal(merged.write[0]?.id, `${SHOW_ID}#https://old.test/1.mp3`);
  assert.equal(merged.write[0]?.audioUrl, 'https://new.test/1.mp3');
  assert.equal(merged.write[0]?.title, 'New title');
});

test('with no GUID match, the enclosure address matches, as when a feed adds GUIDs later', () => {
  const stored = [ep('https://m.test/1.mp3', { audioUrl: 'https://m.test/1.mp3' })];
  const read = { show: show(), episodes: [ep('g1', { guid: 'g1', audioUrl: 'https://m.test/1.mp3' })] };
  const merged = mergeRefresh({ show: show(), episodes: stored }, read, NOW);
  assert.equal(merged.added, 0);
  assert.deepEqual(merged.write.map((e) => [e.id, e.guid]), [[`${SHOW_ID}#https://m.test/1.mp3`, 'g1']]);
});

test('a feed listing the same item twice adds it once', () => {
  const read = {
    show: show(),
    episodes: [ep('g9', { guid: 'g9', title: 'First copy' }), ep('g9', { guid: 'g9', title: 'Second copy' }), ep('x', { audioUrl: 'https://m.test/x.mp3' }), ep('y', { audioUrl: 'https://m.test/x.mp3' })],
  };
  const merged = mergeRefresh({ show: show(), episodes: [] }, read, NOW);
  assert.equal(merged.added, 2);
  assert.deepEqual(merged.write.map((e) => e.title), ['First copy', 'Episode x']);
});

test('a Substack post keeps the voice found when the listener tapped it', () => {
  const tapped = ep('p1', { guid: 'p1', pageUrl: 'https://n.substack.com/p/one', audioUrl: 'https://cdn.test/voice.mp3', audioOrigin: 'substack-voiceover', durationSeconds: 300 });
  // A reader may set a field it didn't find to undefined; that must not clear the stored value either.
  const read = { show: show({ kind: 'substack' }), episodes: [ep('p1', { guid: 'p1', pageUrl: 'https://n.substack.com/p/one', durationSeconds: undefined })] };
  const merged = mergeRefresh({ show: show({ kind: 'substack' }), episodes: [tapped] }, read, NOW);
  assert.deepEqual(merged.write, [], 'nothing changed, so nothing is written');
});

test('unchanged episodes are not rewritten, and ones the feed dropped are kept', () => {
  const stored = [ep('a', { guid: 'a' }), ep('old', { guid: 'old' })];
  const merged = mergeRefresh({ show: show(), episodes: stored }, { show: show(), episodes: [ep('a', { guid: 'a' })] }, NOW);
  assert.deepEqual(merged.write, []);
});

test('the show keeps its id and followedAt, takes the feed title and artwork, and records the refresh', () => {
  const read = { show: show({ title: 'Renamed', artworkUrl: 'https://a.test/art.png', followedAt: NOW }), episodes: [] };
  const merged = mergeRefresh({ show: show({ itunesId: 7 }), episodes: [] }, read, NOW);
  assert.deepEqual(merged.show, { ...show({ itunesId: 7 }), title: 'Renamed', artworkUrl: 'https://a.test/art.png', refreshedAt: NOW });
});

test('a new episode read from a feed address that changed still lands under the stored show', () => {
  const moved = 'https://feeds.test/moved.rss';
  const read = { show: show({ id: `feed:${moved}`, feedUrl: moved }), episodes: [{ id: `feed:${moved}#g1`, showId: `feed:${moved}`, title: 'One', guid: 'g1' }] };
  const merged = mergeRefresh({ show: show(), episodes: [] }, read, NOW);
  assert.deepEqual(merged.write.map((e) => [e.id, e.showId]), [[`${SHOW_ID}#g1`, SHOW_ID]]);
  assert.equal(merged.show.feedUrl, FEED);
});

// ---------- throttle ----------

test('an automatic refresh skips a feed read or tried in the last 30 minutes', () => {
  const now = Date.parse(NOW);
  const recent = new Date(now - REFRESH_INTERVAL_MS + 60_000).toISOString();
  const old = new Date(now - REFRESH_INTERVAL_MS - 1).toISOString();
  const shows = [show({ id: 'fresh', refreshedAt: recent }), show({ id: 'stale', refreshedAt: old }), show({ id: 'never' }), show({ id: 'tried' })];
  const attempts = new Map([['tried', now - 5 * 60_000]]);
  assert.deepEqual(dueShows(shows, attempts, now).map((s) => s.id), ['stale', 'never']);
  assert.deepEqual(dueShows(shows, attempts, now, { force: true }).map((s) => s.id), ['fresh', 'stale', 'never', 'tried']);
});

// ---------- the run: consent, concurrency, feeds only ----------

const needsRelay = (error: unknown) => error instanceof NeedsRelayConsent;

test('without the listener’s yes, a feed that needs the relay is skipped quietly and counted, never asked about', async () => {
  const seen: boolean[] = [];
  const outcomes = await runRefresh({
    shows: [show({ id: 'open', feedUrl: 'https://open.test/feed' }), show({ id: 'blocked', feedUrl: 'https://blocked.test/feed' })],
    relayAllowed: false,
    needsRelay,
    async readFeed(feedUrl, { relayAllowed }) {
      seen.push(relayAllowed);
      if (feedUrl.includes('blocked')) throw new NeedsRelayConsent(feedUrl);
      return { show: show(), episodes: [] };
    },
  });
  assert.deepEqual(seen, [false, false]);
  assert.deepEqual(outcomes.map((o) => [o.showId, o.status]).sort(), [['blocked', 'needs-relay'], ['open', 'read']]);
  assert.equal(needsRelayLine(outcomes.filter((o) => o.status === 'needs-relay').length), '1 show needs the Spoken Margins server to refresh.');
});

test('with the listener’s yes, the reader is told the relay is allowed', async () => {
  const seen: boolean[] = [];
  await runRefresh({
    shows: [show()],
    relayAllowed: true,
    needsRelay,
    async readFeed(_url, { relayAllowed }) {
      seen.push(relayAllowed);
      return { show: show(), episodes: [] };
    },
  });
  assert.deepEqual(seen, [true]);
});

test('feeds are read a few at a time, and one failure doesn’t stop the rest', async () => {
  let inFlight = 0;
  let most = 0;
  const done: RefreshOutcome[] = [];
  const shows = Array.from({ length: 8 }, (_, i) => show({ id: `s${i}`, feedUrl: `https://f.test/${i}` }));
  const outcomes = await runRefresh({
    shows,
    relayAllowed: false,
    needsRelay,
    onOutcome: (o) => {
      done.push(o);
    },
    async readFeed(feedUrl) {
      inFlight += 1;
      most = Math.max(most, inFlight);
      await new Promise((resolve) => setTimeout(resolve, 5));
      inFlight -= 1;
      if (feedUrl.endsWith('/3')) throw new Error('offline');
      return { show: show(), episodes: [] };
    },
  });
  assert.equal(most, REFRESH_CONCURRENCY);
  assert.equal(outcomes.length, 8);
  assert.equal(done.length, 8);
  assert.deepEqual(outcomes.filter((o) => o.status === 'failed').map((o) => o.showId), ['s3']);
});

test('a refresh reads each feed and no post page, even for a Substack whose stored posts have pages', async () => {
  const fetched: string[] = [];
  const rss = `<?xml version="1.0"?><rss version="2.0"><channel><title>Notes</title><generator>Substack</generator>
    <item><title>Two</title><guid>p2</guid><link>https://notes.substack.com/p/two</link></item>
    <item><title>One</title><guid>p1</guid><link>https://notes.substack.com/p/one</link></item></channel></rss>`;
  const fetch = async (url: string) => {
    fetched.push(url);
    return new Response(rss, { status: 200 });
  };
  const substack = show({ id: 'feed:https://notes.substack.com/feed', kind: 'substack', feedUrl: 'https://notes.substack.com/feed' });
  const outcomes = await runRefresh({
    shows: [substack],
    relayAllowed: false,
    needsRelay,
    readFeed: (feedUrl, { relayAllowed }) => readFeed(feedUrl, { fetch, consent: relayAllowed, reason: 'feed-refresh' }),
  });
  assert.deepEqual(fetched, ['https://notes.substack.com/feed']);
  const outcome = outcomes[0];
  assert.equal(outcome?.status, 'read');
  if (outcome?.status !== 'read') return;
  const merged = mergeRefresh({ show: substack, episodes: [{ id: `${substack.id}#p1`, showId: substack.id, title: 'One', guid: 'p1', pageUrl: 'https://notes.substack.com/p/one' }] }, outcome.read, NOW);
  assert.deepEqual(merged.write.map((e) => e.title), ['Two']);
});

// ---------- words on the Following tab ----------

test('the lines the Following tab shows', () => {
  assert.equal(needsRelayLine(0), '');
  assert.equal(needsRelayLine(3), '3 shows need the Spoken Margins server to refresh.');
  assert.equal(refreshResultLine(0, 0), 'No new episodes.');
  assert.equal(refreshResultLine(1, 0), '1 new episode.');
  assert.equal(refreshResultLine(4, 2), '4 new episodes. 2 shows couldn’t be checked.');
  const now = Date.parse(NOW);
  assert.equal(checkedLabel(undefined, now), 'Not checked yet');
  assert.equal(checkedLabel(new Date(now - 20_000).toISOString(), now), 'Checked just now');
  assert.equal(checkedLabel(new Date(now - 60_000).toISOString(), now), 'Checked 1 minute ago');
  assert.equal(checkedLabel(new Date(now - 12 * 60_000).toISOString(), now), 'Checked 12 minutes ago');
  assert.match(checkedLabel(new Date(now - 3 * 3600_000).toISOString(), now, 'en-US'), /^Checked at \d{1,2}:\d{2}/);
  assert.equal(checkedLabel('2026-10-20T12:00:00.000Z', now, 'en-US'), 'Checked Oct 20');
  assert.equal(lastRefreshedAt([show({ refreshedAt: '2026-10-29T00:00:00.000Z' }), show({ refreshedAt: NOW }), show()]), NOW);
});
