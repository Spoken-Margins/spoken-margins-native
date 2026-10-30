// Share links in the web app (#3003, phase 1 of #2168), at phone size. Opening runs against a local stub link server
// (e2e/link-stub-server.ts) holding the shared test vector and a fixture packet sealed under the vector's key.
// Making a link runs only in the stub's build, the one build with SHARE_LINKS_ENABLED on; the shipped
// configuration is checked to offer no link and to carry no upload code.
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page, type Request } from '@playwright/test';
import { FEED_ORIGIN, seconds, serveAudio, serveFixtures, shot } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const SHIPPED = 'http://127.0.0.1:4173';
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

async function elapsed(page: Page): Promise<number> {
  return seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00');
}

/** A toast holding `text`; with `whole`, one whose words are exactly `text` (the toast's icon aside). */
function toast(page: Page, text: string | RegExp, whole = false) {
  const escaped = typeof text === 'string' ? text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') : '';
  const pattern = typeof text === 'string' ? new RegExp(whole ? `^\\W?${escaped}$` : escaped) : text;
  return page.getByRole('status').locator('p').filter({ hasText: pattern });
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

test('opening a link lands on the first Margin’s moment, with the episode added under its sender', async ({ page }, info) => {
  const fetches = linkFetches(page);
  await page.goto(`${STUB}/l/vectorvoice01#${KEY}`);
  await expect(page.getByText(`Opened 2 Margins from Web fixture on “${FIXTURE_EPISODE}”.`)).toBeVisible();
  const playing = page.getByRole('dialog', { name: FIXTURE_EPISODE });
  await expect(playing).toBeVisible();
  // The first Margin sits at 0:30.
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(29.5);
  expect(await audioTime(page)).toBeLessThan(34);
  await expect(playing.getByText('A written Margin at half a minute.')).toBeVisible();
  await expect(playing.getByText('This is a web Margin, recorded for the packet test.')).toBeVisible();
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

test('damaged and expired links say so, and a link with no key asks the server for nothing', async ({ page }, info) => {
  const fetches = linkFetches(page);
  // The vector's own link opens under its key (byte-for-byte, as the unit tests show) but its packet is filler.
  await page.goto(`${STUB}/l/AbCdEf123456#${KEY}`);
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

test('with links on, a Margin’s share menu makes a link that holds only sealed bytes and opens at the Margin', async ({ page, browser, request }, info) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(3);
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  const label = await nowPlaying.locator('label[for="margin-text"]').textContent();
  const writtenAt = seconds(label?.replace('Your Margin at ', '') ?? '0:00');
  const words = 'Send Sam the bit about the tide tables.';
  await nowPlaying.getByLabel(/Your Margin at/).fill(words);
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Margin saved at/)).toBeVisible();

  await nowPlaying.getByRole('button', { name: 'Make a link' }).click();
  const field = nowPlaying.getByLabel('Link to these Margins');
  await expect(field).toHaveValue(/^http:\/\/127\.0\.0\.1:4174\/l\/[0-9a-f]{32}#[A-Za-z0-9_-]{43}$/);
  await expect(toast(page, /(Link copied\.|Link ready\. Copy it below\.) It works until/)).toBeVisible();
  await shot(page, info, '32-link-made');
  const link = await field.inputValue();
  const id = /\/l\/([0-9a-f]{32})#/.exec(link)?.[1] ?? '';

  // The server holds sealed bytes only: no Margin words, no episode title, in either part.
  for (const part of ['packet', 'preview']) {
    const stored = Buffer.from(await (await request.get(`${STUB}/l/${id}/${part}`)).body());
    expect(stored.subarray(0, 6).toString('latin1')).toBe('SMLINK');
    for (const plain of [words, 'tide tables', EPISODE_3]) expect(stored.includes(Buffer.from(plain))).toBe(false);
  }

  // The same listener opens it: the episode matches theirs, so no "shared" show appears.
  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await pasteLink(page, link);
  await expect(page.getByText(new RegExp(`Opened 1 Margin( from .+)? on “${EPISODE_3}”`))).toBeVisible();
  await page.getByRole('dialog', { name: EPISODE_3 }).getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Following');
  await expect(page.getByRole('button', { name: /Open Shared (by|with)/ })).toHaveCount(0);

  // A friend with an empty Library opens it and lands at the Margin's moment.
  const friend = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, serviceWorkers: 'block' });
  const friendPage = await friend.newPage();
  await serveFixtures(friendPage);
  await friendPage.goto(link);
  const friendPlaying = friendPage.getByRole('dialog', { name: EPISODE_3 });
  await expect(friendPlaying).toBeVisible();
  await expect.poll(() => audioTime(friendPage), { timeout: 10_000 }).toBeGreaterThanOrEqual(writtenAt - 0.5);
  expect(await audioTime(friendPage)).toBeLessThan(writtenAt + 4);
  await expect(friendPlaying.getByText(words)).toBeVisible();
  await shot(friendPage, info, '33-friend-opened-link');
  await friend.close();
});

test('the shipped configuration offers no link and carries no upload code', async ({ page }) => {
  await page.goto(`${SHIPPED}/#following`);
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  await nowPlaying.getByLabel(/Your Margin at/).fill('A Margin to share.');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(nowPlaying.getByRole('button', { name: 'Save as a file' })).toBeVisible();
  await expect(nowPlaying.getByRole('button', { name: 'Make a link' })).toHaveCount(0);

  // The build behind it (dist-e2e/, default mode) compiled the upload away.
  const assets = fileURLToPath(new URL('../dist-e2e/assets/', import.meta.url));
  const code = readdirSync(assets)
    .filter((name) => name.endsWith('.js'))
    .map((name) => readFileSync(`${assets}${name}`, 'utf8'))
    .join('\n');
  expect(code).not.toContain('/api/v1/links');
});
