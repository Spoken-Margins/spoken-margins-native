// A share link for an Apple Podcasts episode that carries only the episode's page (#4767, #4783): the owner's 2026-11-20
// share, whose packet held the Apple page and no audio address. A friend in a browser opens it, and the page asks Apple's
// public lookup for that episode's audio, so Play starts sound at once and the sender's Margins land at their times.
// Against the local link stub (e2e/link-stub-server.ts), as link-arrival.spec.ts is; Apple's lookup is answered by a route.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page, type Request } from '@playwright/test';
import { feedFixture, serveAudio, serveFixtures } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const LINK = `${STUB}/l/vectorapple01#${KEY}`;
const TITLE = 'People, Parks, and Policy with RFF’s Margaret Walls';
const LOOKUP = 'https://itunes.apple.com/lookup**';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'The link stub is one server; this runs once, at a phone size.');
});

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);

const episode = (extra: object = {}) => ({
  wrapperType: 'podcastEpisode',
  kind: 'podcast-episode',
  trackId: 1000427709574,
  trackName: TITLE,
  collectionName: 'Resources Radio',
  // Apple lists some enclosures over http; the page asks for the https address a browser can load.
  episodeUrl: 'http://example.com/podcast/people-parks-and-policy.mp3',
  episodeGuid: 'tag:soundcloud,2010:tracks/559432260',
  trackTimeMillis: 1_800_000,
  ...extra,
});

/** Answers Apple's lookup with `results` (the show first), and records what was asked. */
async function appleLookup(page: Page, results: object[] | 'down' | 'offline'): Promise<string[]> {
  const asked: string[] = [];
  await page.route(LOOKUP, (route) => {
    asked.push(route.request().url());
    if (results === 'offline') return route.abort('failed');
    if (results === 'down') return route.fulfill({ status: 503, body: 'busy', headers: { 'access-control-allow-origin': '*' } });
    return route.fulfill({
      status: 200,
      body: JSON.stringify({ resultCount: results.length + 1, results: [{ wrapperType: 'track', kind: 'podcast', collectionId: 1445582279 }, ...results] }),
      headers: { 'access-control-allow-origin': '*', 'content-type': 'text/javascript; charset=utf-8' },
    });
  });
  return asked;
}

async function friendPage(page: Page): Promise<void> {
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
}

test('a share link for an Apple Podcasts episode with only its page plays that episode and the sender’s Margins', async ({ page }) => {
  const log: Request[] = [];
  page.on('request', (request) => log.push(request));
  await friendPage(page);
  const asked = await appleLookup(page, [episode({ trackId: 1000427709000, episodeUrl: 'https://example.com/podcast/other.mp3' }), episode()]);

  await page.goto(LINK);

  // 1. Not the "no audio" card: a Play button and the Margins' count. Apple's lookup was asked once, when the link opened,
  // for the show's episodes by its public id, and nothing about the link or the Margins went with it.
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('heading', { name: TITLE })).toBeVisible();
  await expect(arrival.getByText('2 Margins', { exact: false })).toBeVisible();
  await expect(arrival.getByText('no audio the browser can play')).toHaveCount(0);
  await expect(arrival.getByRole('button', { name: 'Play' })).toBeEnabled();
  expect(asked).toEqual(['https://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200']);
  for (const request of log.filter((r) => r.url().includes('apple.com'))) {
    expect(request.method()).toBe('GET');
    expect(request.url()).not.toContain(KEY.slice(0, 12));
    expect(request.postData()).toBeNull();
  }

  // 2. Play starts the episode that matches the page's own episode id (not the neighbour), from the https address.
  await arrival.getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: TITLE });
  await expect(playing).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(0.3);
  const src = await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentSrc);
  expect(src).toBe('https://example.com/podcast/people-parks-and-policy.mp3');

  // 3. The countdown points at the sender's first Margin, and the Library holds the episode with its audio found.
  await expect(playing.getByTestId('margin-cue')).toBeVisible();
  expect(asked).toHaveLength(1);
});

test('an Apple Podcasts episode that Apple does not list says it cannot play here, and keeps the Margins', async ({ page }) => {
  await friendPage(page);
  // Another episode with the same title and a re-upload's id: never matched by title.
  await appleLookup(page, [episode({ trackId: 1000427709999 })]);
  await page.goto(LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('heading', { name: TITLE })).toBeVisible();
  await expect(arrival.getByText('no audio the browser can play', { exact: false })).toBeVisible();
  await expect(arrival.getByText('Spoken Margins app on iPhone', { exact: false })).toBeVisible();
  await expect(arrival.getByRole('button', { name: /^Keep .* Margins$/ })).toBeVisible();
  await expect(arrival.getByRole('button', { name: 'Play' })).toHaveCount(0);
});

test('when Apple does not answer, Play asks again and says so plainly, never that the post has no voice', async ({ page }) => {
  await friendPage(page);
  const asked = await appleLookup(page, 'down');
  await page.goto(LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('button', { name: 'Play' })).toBeVisible();
  expect(asked).toHaveLength(1);
  await arrival.getByRole('button', { name: 'Play' }).click();
  await expect(page.getByText('Apple Podcasts can’t look this episode up right now', { exact: false }).first()).toBeVisible();
  await expect(page.getByText('neither the writer nor Substack', { exact: false })).toHaveCount(0);
  expect(asked.length).toBeGreaterThanOrEqual(2);
});

// The owner's 2026-11-22 share: an episode from 2019, which Apple's lookup of the show does not list (it lists the newest
// 200). The packet holds the Apple page and no audio address, so the audio is in the show's own feed, found by the title the
// packet carries. The lookup and the feed below are trimmed copies of the real answers (Contracts/fixtures/feeds/): the real
// lookup leaves the episode out, so a test whose lookup lists it (the first test above) can't fail the way the share did.
const OUTSIDE_LINK = `${STUB}/l/vectorapple02#${KEY}`;
const SHOW_FEED = 'https://feeds.soundcloud.com/users/**';
const ENCLOSURE = 'https://feeds.soundcloud.com/stream/559432260-resourcesradio-people-parks-and-policy-with-rffs-margaret-walls.mp3';
const REAL_LOOKUP = feedFixture('apple-lookup-resources-radio.txt').toString('utf8');
const REAL_FEED = feedFixture('resources-radio-apple-gap.rss').toString('utf8');
const OUTSIDE_TITLE = "People, Parks, and Policy, with RFF's Margaret Walls";

async function outsideLookupPage(page: Page, feed: 'readable' | 'refused-by-browsers', feedXml = REAL_FEED) {
  const asked = { lookup: [] as string[], feed: [] as string[], relay: [] as string[] };
  await serveFixtures(page);
  await serveAudio(page, 'https://feeds.soundcloud.com/stream/**');
  await page.route(LOOKUP, (route) => {
    asked.lookup.push(route.request().url());
    return route.fulfill({ status: 200, body: REAL_LOOKUP, headers: { 'access-control-allow-origin': '*', 'content-type': 'text/javascript; charset=utf-8' } });
  });
  await page.route(SHOW_FEED, (route) => {
    asked.feed.push(route.request().url());
    // Like feeds.soundcloud.com, which answers browsers on another site's origin with no permission (checked 2026-11-22).
    if (feed === 'refused-by-browsers') return route.abort('failed');
    return route.fulfill({ status: 200, body: feedXml, headers: { 'content-type': 'application/rss+xml', 'access-control-allow-origin': '*' } });
  });
  await page.route(`${STUB}/api/v1/relay**`, (route) => {
    asked.relay.push(route.request().url());
    return route.fulfill({ status: 200, body: feedXml, headers: { 'content-type': 'application/rss+xml', 'access-control-allow-origin': '*', 'x-final-url': new URL(route.request().url()).searchParams.get('url') ?? '' } });
  });
  return asked;
}

test('an Apple episode the lookup does not list plays from the show\'s feed, matched by its own title', async ({ page }) => {
  const asked = await outsideLookupPage(page, 'readable');
  await page.goto(OUTSIDE_LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('heading', { name: OUTSIDE_TITLE })).toBeVisible();
  await expect(arrival.getByText('no audio the browser can play')).toHaveCount(0);
  await expect(arrival.getByRole('button', { name: 'Play' })).toBeEnabled();
  await arrival.getByRole('button', { name: 'Play' }).click();
  await expect(page.getByRole('dialog', { name: OUTSIDE_TITLE })).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(0.3);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentSrc)).toBe(ENCLOSURE);
  // One lookup, one read of the show's feed, nothing from the link in either.
  expect(asked.lookup).toEqual(['https://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200']);
  expect(asked.feed).toHaveLength(1);
  for (const url of [...asked.lookup, ...asked.feed]) expect(url).not.toContain(KEY.slice(0, 12));
  expect(asked.relay).toEqual([]);
});

test('when the feed refuses browsers, Play asks once to read it through the server, then plays', async ({ page }) => {
  const asked = await outsideLookupPage(page, 'refused-by-browsers');
  await page.goto(OUTSIDE_LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('button', { name: 'Play' })).toBeEnabled();
  await expect(arrival.getByText('no audio the browser can play')).toHaveCount(0);
  await arrival.getByRole('button', { name: 'Play' }).click();
  const ask = page.getByRole('dialog', { name: 'Read this feed through our server?' });
  await expect(ask).toBeVisible();
  await ask.getByRole('button', { name: 'Use the server' }).click();
  await expect(page.getByRole('dialog', { name: OUTSIDE_TITLE })).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(0.3);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentSrc)).toBe(ENCLOSURE);
  expect(asked.relay).toHaveLength(1);
  expect(decodeURIComponent(asked.relay[0] as string)).toContain('https://feeds.soundcloud.com/users/');
  expect(asked.relay[0]).not.toContain(KEY.slice(0, 12));
});

test('two episodes in the feed with the packet\'s title are never guessed between', async ({ page }) => {
  const twin = REAL_FEED.replace('</channel>', `<item><title>People, Parks and Policy with RFF’s Margaret Walls</title><guid>twin</guid><enclosure type="audio/mpeg" url="https://feeds.soundcloud.com/stream/1-twin.mp3" length="1"/></item></channel>`);
  await outsideLookupPage(page, 'readable', twin);
  await page.goto(OUTSIDE_LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('heading', { name: OUTSIDE_TITLE })).toBeVisible();
  await expect(arrival.getByText('no audio the browser can play', { exact: false })).toBeVisible();
  await expect(arrival.getByRole('button', { name: 'Play' })).toHaveCount(0);
});
