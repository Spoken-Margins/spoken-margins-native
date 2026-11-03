// The page a share link opens (#2168, slice 4 of #3247), against the local link stub (e2e/link-stub-server.ts), which
// holds the shared test vector's key. What a friend does: tap the link, see who sent it and what it is, tap Play,
// hear the episode, see the countdown to the sender's Margin and a Skip, and hear the Margin. Run at a laptop size,
// at a Pixel (Android Chrome's user agent, touch and screen) and at an iPhone-sized window. The network log is the
// privacy evidence: the key and the Margins' words never leave the browser.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { devices, expect, test, type BrowserContext, type Page, type Request } from '@playwright/test';
import { seconds, serveAudio, serveFixtures, shot } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const LINK = `${STUB}/l/vectorvoice01#${KEY}`;
const EPISODE = 'Episode 1 (example episode)';
const WRITTEN = 'A written Margin at half a minute.';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'These journeys open their own contexts: laptop, Android and iPhone-sized.');
});

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);

async function friendPage(context: BrowserContext): Promise<Page> {
  const page = await context.newPage();
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  return page;
}

/** Every request the page makes, with its address, method, body and headers, to check what leaves the browser. */
function networkLog(page: Page): Request[] {
  const seen: Request[] = [];
  page.on('request', (request) => seen.push(request));
  return seen;
}

function assertNothingPlainLeft(log: Request[]): void {
  const stub = log.filter((r) => r.url().startsWith(STUB));
  // The server is asked for the sealed packet, by id, with a plain GET; the app's own files are the rest.
  const asked = stub.filter((r) => /\/l\/[^/]+\/(packet|preview)$/.test(new URL(r.url()).pathname));
  expect(asked.map((r) => new URL(r.url()).pathname)).toEqual(['/l/vectorvoice01/packet']);
  for (const request of log) {
    const where = `${request.method()} ${request.url()}`;
    expect(request.method(), where).toBe('GET');
    expect(request.postData(), where).toBeNull();
    expect(request.url(), where).not.toContain(KEY);
    expect(request.url(), where).not.toContain(KEY.slice(0, 12));
    for (const [name, value] of Object.entries(request.headers())) {
      expect(`${name}: ${value}`, where).not.toContain(KEY.slice(0, 12));
      expect(`${name}: ${value}`, where).not.toContain('half a minute');
    }
  }
}

async function journey(page: Page, info: { project: { name: string } } & Parameters<typeof shot>[1], label: string): Promise<void> {
  const log = networkLog(page);
  await page.goto(LINK);

  // 1. The link opens on who sent it, what it is, and one Play. Nothing plays yet.
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByText('From Web fixture')).toBeVisible();
  await expect(arrival.getByRole('heading', { name: EPISODE })).toBeVisible();
  await expect(arrival.getByText('2 Margins', { exact: false })).toBeVisible();
  // One of the two Margins is written, so "Margin" is explained in its second version (2026-11-02 call).
  await expect(arrival.getByText('A Margin is a note Web fixture left at a moment in this episode. You’ll hear each one there.')).toBeVisible();
  await expect(arrival.getByText('Starts at the beginning. Web fixture’s Margins play when the episode reaches them.')).toBeVisible();
  await expect(arrival.getByText('Want the app? Ask Web fixture for an invite.')).toBeVisible();
  await expect(arrival.getByRole('link', { name: 'Report this link' })).toHaveAttribute('href', new RegExp(`/l/vectorvoice01\\?report$`));
  const play = arrival.getByRole('button', { name: 'Play' });
  const box = await play.boundingBox();
  expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
  await shot(page, info as never, `${label}-1-arrival`);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);

  // 2. One tap on Play: the episode plays from the beginning, with the countdown and Skip on screen.
  await play.click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(0.3);
  expect(await audioTime(page)).toBeLessThan(10);
  const cue = playing.getByTestId('margin-cue');
  await expect(cue).toContainText('Web fixture’s first Margin in');
  await shot(page, info as never, `${label}-2-playing`);

  // 3. Skip lands inside the lead-in (20 s before the Margin at 0:30); the second Skip goes to the Margin.
  await cue.getByRole('button', { name: 'Skip to just before Web fixture' }).click();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(9.5);
  expect(await audioTime(page)).toBeLessThan(15);
  await expect(cue.getByTestId('margin-cue-clock')).toHaveText(/^0:\d\d$/);
  await shot(page, info as never, `${label}-3-lead-in`);
  await cue.getByRole('button', { name: 'Skip to Web fixture now' }).click();

  // 4. The Margin plays in place: its card says who and which, and the words show while the voice reads them.
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture wrote this');
  await expect(arrived).toContainText('1 of 2');
  await expect(arrived).toContainText(WRITTEN);
  await shot(page, info as never, `${label}-4-margin`);
  expect(seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00')).toBeGreaterThanOrEqual(29);

  // 5. The key and the words never left the browser: one plain GET for sealed bytes, and nothing else carries them.
  assertNothingPlainLeft(log);
  expect(page.url()).not.toContain(KEY);
}

test('on a laptop: the link opens on its page, Play starts the episode, Skip reaches Cole’s Margin', async ({ browser }, info) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await journey(page, info, 'laptop');
  await context.close();
});

test('on an Android phone: the same link, the same journey', async ({ browser }, info) => {
  const context = await browser.newContext({ ...devices['Pixel 7'], serviceWorkers: 'block' });
  const page = await friendPage(context);
  expect(await page.evaluate(() => navigator.userAgent)).toContain('Android');
  await journey(page, info, 'android');
  await context.close();
});

test('a link that can’t open says what happened and one thing to do, in the same words for every cause', async ({ browser }, info) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, serviceWorkers: 'block' });
  const page = await friendPage(context);
  const failed = page.getByTestId('arrival-failed');
  const wrongKey = `${KEY.slice(0, -2)}${KEY.endsWith('AA') ? 'BA' : 'AA'}`;
  const cases: Array<[string, string, string]> = [
    ['an expired link', `${STUB}/l/expired00001#${KEY}`, 'This link has expired.'],
    ['a link the server never made', `${STUB}/l/00000000000000000000000000000000#${KEY}`, 'This link has expired.'],
    ['links switched off', `${STUB}/l/switchedoff1#${KEY}`, 'Links are switched off for now.'],
    ['a link with its key cut off', `${STUB}/l/vectorvoice01#${KEY.slice(0, 20)}`, 'This link is cut off.'],
    ['a link with no key', `${STUB}/l/vectorvoice01`, 'This link is cut off.'],
    ['a link with the wrong key', `${STUB}/l/vectorvoice01#${wrongKey}`, 'This link is cut off.'],
    ['a file that opens under the key but is not a packet', `${STUB}/l/AbCdEf123456#${KEY}`, 'This file couldn’t be opened.'],
  ];
  for (const [name, address, headline] of cases) {
    await page.goto(address);
    await expect(failed.getByRole('heading'), name).toContainText(headline);
    // Nothing raw, and no way to play something that didn't open.
    await expect(page.getByText(/not_found|disabled|\{"error"/), name).toHaveCount(0);
    await expect(failed.getByRole('button'), name).toHaveCount(0);
  }
  await page.goto(`${STUB}/l/switchedoff1#${KEY}`);
  await expect(failed).toContainText('Ask your friend to send the Margins as a file.');
  await expect(failed).not.toContainText('Try again');
  await shot(page, info, 'link-off');
  await context.close();
});
