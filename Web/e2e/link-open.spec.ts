// Opening share links in the web app (#3003, phase 1 of #2168), at phone size, against a local stub link server
// (e2e/link-stub-server.ts) holding the shared test vector and a fixture packet sealed under the vector's key.
// The web app is receive-only for links (owner, 2026-11-05, #3542): the last journey here fails if the page ever sends
// a POST or PUT to /api/v1/links while it shares a file and opens a link.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page, type Request } from '@playwright/test';
import { FEED_ORIGIN, seconds, serveAudio, serveFixtures, shot } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const FIXTURE_EPISODE = 'Episode 1 (example episode)';
const DAMAGED = 'This link is incomplete or damaged.';
const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const EPISODE_3 = 'Episode 3: No link, GUID and audio';

test.use({ baseURL: `${STUB}/` });

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'The share-link journeys run at phone size (390×844).');
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
});

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

/** A toast holding `text`; with `whole`, one whose words are exactly `text` (the toast's icon aside). */
function toast(page: Page, text: string | RegExp, whole = false) {
  const escaped = typeof text === 'string' ? text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') : '';
  // Problems sit in the role="alert" region with a Close button, notes in role="status" (#2980).
  const pattern = typeof text === 'string' ? new RegExp(whole ? `^\\W?${escaped}(Close)?$` : escaped) : text;
  return page.locator('[role="status"] p, [role="alert"] p').filter({ hasText: pattern });
}

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);

/** Every request for a link's sealed bytes. */
function linkFetches(page: Page): Request[] {
  const seen: Request[] = [];
  page.on('request', (request) => {
    if (/\/l\/[^/]+\/(packet|preview)$/.test(new URL(request.url()).pathname)) seen.push(request);
  });
  return seen;
}

async function pasteLink(page: Page, link: string) {
  await tab(page, 'Margins');
  await page.getByRole('button', { name: 'Open a link' }).click();
  await page.getByLabel('A friend’s Spoken Margins link').fill(link);
  await page.getByRole('button', { name: 'Open', exact: true }).click();
}

test('a link opens on its arrival page; Play starts the episode at the beginning, with the episode added under its sender', async ({ page }, info) => {
  const fetches = linkFetches(page);
  await page.goto(`${STUB}/l/vectorvoice01#${KEY}`);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByText('From Web fixture')).toBeVisible();
  await expect(arrival.getByRole('heading', { name: FIXTURE_EPISODE })).toBeVisible();
  await shot(page, info, '30-link-arrival');
  // Nothing plays and nothing is stored until the friend taps Play.
  await expect(page.locator('.now-playing')).toHaveCount(0);

  await arrival.getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: FIXTURE_EPISODE });
  await expect(playing).toBeVisible();
  // From the beginning, not from the first Margin (it sits at 0:30): the cue counts down to it.
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(0.3);
  expect(await audioTime(page)).toBeLessThan(10);
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture’s first Margin in');
  await shot(page, info, '30-link-landed');

  // One request, for the packet only, and the key never in it. The address bar no longer holds the key.
  expect(fetches.map((r) => new URL(r.url()).pathname)).toEqual(['/l/vectorvoice01/packet']);
  expect(fetches[0].url()).not.toContain(KEY);
  expect(page.url()).not.toContain(KEY);

  await playing.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Following');
  await expect(page.getByRole('button', { name: /Open Shared by Web fixture/ })).toBeVisible();
});

test('a pasted link opens the same way, and other text is refused plainly', async ({ page }) => {
  await page.goto('./#margins');
  await pasteLink(page, 'https://example.com/podcast/episode-1');
  await expect(page.getByText('That isn’t a Spoken Margins link.', { exact: false })).toBeVisible();
  await pasteLink(page, `  ${STUB}/l/vectorvoice01#${KEY}  `);
  await expect(page.getByRole('dialog', { name: FIXTURE_EPISODE })).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(29.5);
});

test('a pasted link that is damaged or expired says so, and a link with no key asks the server for nothing', async ({ page }, info) => {
  const fetches = linkFetches(page);
  await page.goto('./#margins');
  // The vector's own link opens under its key (byte-for-byte, as the unit tests show) but its packet is filler.
  await pasteLink(page, `${STUB}/l/AbCdEf123456#${KEY}`);
  await expect(toast(page, DAMAGED)).toBeVisible();
  await shot(page, info, '31-link-damaged');

  const wrongKey = `${KEY.slice(0, -2)}${KEY.endsWith('AA') ? 'BA' : 'AA'}`;
  await pasteLink(page, `${STUB}/l/vectorvoice01#${wrongKey}`);
  await expect(toast(page, DAMAGED, true)).toHaveCount(1);
  expect(fetches.map((r) => new URL(r.url()).pathname)).toEqual(['/l/AbCdEf123456/packet', '/l/vectorvoice01/packet']);

  await pasteLink(page, `${STUB}/l/vectorvoice01#${KEY.slice(0, 20)}`);
  await expect(toast(page, DAMAGED, true)).toHaveCount(2);
  await pasteLink(page, `${STUB}/l/vectorvoice01`);
  await expect(toast(page, DAMAGED, true)).toHaveCount(3);
  expect(fetches).toHaveLength(2);

  await pasteLink(page, `${STUB}/l/expired00001#${KEY}`);
  await expect(page.getByText('This link has expired. Ask your friend to share it again.')).toBeVisible();
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('the page never sends a POST or PUT to /api/v1/links, however a listener shares or opens', async ({ page }) => {
  // Every request the page makes, from any origin, with its method; a link is only ever read (GET /l/<id>/packet).
  const sent: string[] = [];
  page.on('request', (request) => sent.push(`${request.method()} ${new URL(request.url()).pathname}`));

  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  await nowPlaying.getByLabel(/Your Margin at/).fill('A Margin to share.');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();

  // The Share panel: a file is saved, and no way to make a link is offered.
  await expect(nowPlaying.getByRole('button', { name: 'Save as a file' })).toBeVisible();
  await expect(nowPlaying.getByRole('button', { name: /link/i })).toHaveCount(0);
  const download = page.waitForEvent('download');
  await nowPlaying.getByRole('button', { name: 'Save as a file' }).click();
  expect((await download).suggestedFilename()).toMatch(/\.spokenmargins$/);
  await expect(page.getByText(/Saved 1 Margin as /)).toBeVisible();

  // Opening a link, pasted: it is read, never written.
  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await pasteLink(page, `${STUB}/l/vectorvoice01#${KEY}`);
  await expect(page.getByRole('dialog', { name: FIXTURE_EPISODE })).toBeVisible();

  expect(sent).toContain('GET /l/vectorvoice01/packet');
  const writes = sent.filter((entry) => !entry.startsWith('GET ') && !entry.startsWith('HEAD '));
  expect(writes.filter((entry) => /\/api\/v1\/links/.test(entry))).toEqual([]);
  expect(sent.filter((entry) => /\/api\/v1\/links/.test(entry))).toEqual([]);
});
