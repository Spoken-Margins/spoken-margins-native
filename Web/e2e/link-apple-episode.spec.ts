// A share link for an Apple Podcasts episode that carries only the episode's page (#4767, #4783): the owner's 2026-11-20
// share, whose packet held the Apple page and no audio address. A friend in a browser opens it, and the page asks Apple's
// public lookup for that episode's audio, so Play starts sound at once and the sender's Margins land at their times.
// Against the local link stub (e2e/link-stub-server.ts), as link-arrival.spec.ts is; Apple's lookup is answered by a route.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page, type Request } from '@playwright/test';
import { serveAudio, serveFixtures } from './fixtures.ts';

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
