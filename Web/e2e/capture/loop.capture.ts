// The sharing loop's flow map (#5280), photographed screen by screen in the browser: the link server's page, the
// arrival states, Now Playing, writing, recording and sharing a reply, the app invite, the Library and Margins tabs,
// and the join page. Each shot is named by its id in the flow map (`flowmap-<SCREEN_ID>.png`) and each test asserts
// its screen was reached first, so a missing picture means a broken step. Only the stub's fixture links, the seeded
// local link server and generated audio are used; nothing reaches the real network.
// Run: cd Web && npm run capture:flow-map
// Shots go to `artifacts/flow-map-capture/web/` at the repo root (git-ignored), or SM_FLOWMAP_DIR.
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { devices, expect, test, type Browser, type BrowserContextOptions, type Locator, type Page } from '@playwright/test';
import { nowTab, serveAudio, serveFixtures } from '../fixtures.ts';

const OUT = process.env.SM_FLOWMAP_DIR ?? fileURLToPath(new URL('../../../artifacts/flow-map-capture/web', import.meta.url));
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const STUB = 'http://127.0.0.1:4174';
const LINK = `${STUB}/l/vectorvoice01#${KEY}`;
const EPISODE = 'Episode 1 (example episode)';
const JOIN = pathToFileURL(fileURLToPath(new URL('../../../Site/join/index.html', import.meta.url))).href;
const PHONE: BrowserContextOptions = { ...devices['iPhone 15 Pro'], viewport: { width: 390, height: 844 }, serviceWorkers: 'block' };

test.use({ viewport: { width: 390, height: 844 } });

async function snap(page: Page, id: string, scrollTo?: Locator) {
  mkdirSync(OUT, { recursive: true });
  if (scrollTo) await scrollTo.scrollIntoViewIfNeeded();
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${OUT}/flowmap-${id}.png` });
}

async function friendPage(browser: Browser, extra: BrowserContextOptions = {}) {
  const context = await browser.newContext({ ...PHONE, ...extra });
  const page = await context.newPage();
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  return { context, page };
}

function seededLink(): string {
  return readFileSync(join(tmpdir(), 'sm-landing-seeded-link.txt'), 'utf8').trim();
}

async function waitForSeed() {
  await expect.poll(() => existsSync(join(tmpdir(), 'sm-landing-seeded-link.txt')), { timeout: 10_000 }).toBe(true);
}

/** Opens the fixture link, starts it from the beginning and returns Now Playing (on its Margins tab). */
async function openPlaying(page: Page) {
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Start from the beginning', exact: true }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing).toBeVisible();
  return playing;
}

async function writeAndSave(playing: Locator, words: string) {
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.getByLabel(/Your Margin at/).fill(words);
  await playing.getByRole('button', { name: 'Save Margin' }).click();
}

test('LINK_SERVER_PAGE: the link server page a friend meets first', async ({ page }) => {
  await waitForSeed();
  await page.goto(seededLink());
  await expect(page.getByRole('heading', { name: 'Shared Margins' })).toBeVisible();
  await snap(page, 'LINK_SERVER_PAGE');
});

test('LINK_SERVER_PAGE (no script): what a browser with JavaScript off shows', async ({ browser }) => {
  await waitForSeed();
  const context = await browser.newContext({ ...PHONE, javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto(seededLink());
  await expect(page.getByRole('heading', { name: 'Shared Margins' })).toBeVisible();
  await snap(page, 'LINK_SERVER_PAGE-nojs');
  await context.close();
});

test('LINK_SERVER_UNAVAILABLE: an unknown link on the server page', async ({ page }) => {
  await waitForSeed();
  const { origin } = new URL(seededLink());
  await page.goto(`${origin}/l/ffffffffffffffffffffffffffffffff#${KEY}`);
  await expect(page.getByRole('heading', { name: /This link isn.t available/ })).toBeVisible();
  await snap(page, 'LINK_SERVER_UNAVAILABLE');
});

test('LINK_SERVER_REPORT: ?report opens the report form on the server page', async ({ page }) => {
  await waitForSeed();
  const { origin, pathname } = new URL(seededLink());
  await page.goto(`${origin}${pathname}?report`);
  await expect(page.locator('details#report')).toHaveAttribute('open', '');
  await expect(page.locator('#category')).toBeVisible();
  await snap(page, 'LINK_SERVER_REPORT', page.locator('details#report'));
});

test('WebArrivalOpening: the link while its packet is still on the way', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  let release: () => void = () => {};
  const held = new Promise<void>((resolve) => { release = resolve; });
  await page.route('**/l/vectorvoice01/packet', async (route) => {
    await held;
    await route.continue();
  });
  await page.goto(LINK);
  await expect(page.getByRole('dialog', { name: 'Opening the Margins' })).toBeVisible();
  await expect(page.getByText('Opening the Margins…').first()).toBeVisible();
  await snap(page, 'WebArrivalOpening');
  release();
  await context.close();
});

test('WebArrivalFailed: a link that can’t open (expired)', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  await page.goto(`${STUB}/l/expired00001#${KEY}`);
  await expect(page.getByTestId('arrival-failed').getByRole('heading')).toContainText('This link has expired.');
  await snap(page, 'WebArrivalFailed');
  await page.goto(`${STUB}/l/vectorvoice01`);
  await expect(page.getByTestId('arrival-failed').getByRole('heading')).toContainText('This link is cut off.');
  await snap(page, 'WebArrivalFailed-cut-off');
  await context.close();
});

test('WebArrivalPreview: who sent it, what it is, its Margins and one Play', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  await page.goto(LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByText('From Web fixture')).toBeVisible();
  await expect(arrival.getByRole('button', { name: 'Start from the beginning' })).toBeVisible();
  await snap(page, 'WebArrivalPreview');
  await context.close();
});

test('WebArrivalSimple: an article post with one Play', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  await page.goto(`${STUB}/l/vectorpost01#${KEY}`);
  await expect(page.getByTestId('arrival').getByRole('button', { name: 'Play', exact: true })).toBeVisible();
  await snap(page, 'WebArrivalSimple');
  await context.close();
});

test('WebNowPlayingMargins and WebNowPlaying: Play opens on the Margins tab, then Now shows the countdown', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  const playing = await openPlaying(page);
  await expect(playing.getByRole('tab', { name: /Margins/ })).toHaveAttribute('aria-selected', 'true');
  await snap(page, 'WebNowPlayingMargins');
  await nowTab(page);
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture’s first Margin in');
  await snap(page, 'WebNowPlaying');
  await context.close();
});

test('WebWriteMargin: the written Margin composer', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  const playing = await openPlaying(page);
  await nowTab(page);
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  const field = playing.getByLabel(/Your Margin at/);
  await expect(field).toBeVisible();
  await field.fill('My answer.');
  await snap(page, 'WebWriteMargin');
  await context.close();
});

test('WebRecordMargin: the voice Margin composer, recording from WebKit’s mock microphone', async ({ browser }) => {
  const { context, page } = await friendPage(browser, { permissions: ['microphone'] });
  const playing = await openPlaying(page);
  await nowTab(page);
  await playing.getByRole('button', { name: 'Record a Margin' }).click();
  await expect(playing.getByRole('button', { name: 'Stop and save' })).toBeEnabled({ timeout: 15_000 });
  await page.waitForTimeout(1200);
  await snap(page, 'WebRecordMargin');
  await context.close();
});

test('WebShareMargins: after Save Margin, the "Share replies with" list and Save as a file', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  const playing = await openPlaying(page);
  await nowTab(page);
  await writeAndSave(playing, 'My answer.');
  const reply = playing.locator('.reply-back');
  // The fieldset's legend reads "Share your Margins with <friend>" (the map's older notes say "Share replies with").
  await expect(reply).toContainText(/Share (your Margins|replies) with Web fixture/);
  await expect(reply.getByRole('checkbox', { name: /My answer\./ })).toBeChecked();
  await snap(page, 'WebShareMargins', reply);
  await context.close();
});

test('WebAppInvite: after the first reply leaves, the iPhone app is offered once', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  const playing = await openPlaying(page);
  await nowTab(page);
  await writeAndSave(playing, 'My answer.');
  const downloading = page.waitForEvent('download');
  await playing.getByRole('button', { name: 'Save as a file' }).click();
  await downloading;
  const invite = playing.getByRole('region', { name: 'Get the iPhone app' });
  await expect(invite).toBeVisible();
  await snap(page, 'WebAppInvite', invite);
  await context.close();
});

test('WebLibrary and WebMarginsTab: after closing Now Playing, the Library and the friend’s Margins', async ({ browser }) => {
  const { context, page } = await friendPage(browser);
  const playing = await openPlaying(page);
  await playing.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(playing).toHaveCount(0);
  const sections = page.getByRole('navigation', { name: 'Sections' });
  await sections.getByRole('button', { name: 'Library' }).click();
  await expect(page.getByRole('button', { name: new RegExp(EPISODE.replace(/[()]/g, '\\$&')) }).first()).toBeVisible();
  await snap(page, 'WebLibrary');
  await sections.getByRole('button', { name: 'Margins' }).click();
  await expect(page.locator('li.margin').first()).toBeVisible();
  await snap(page, 'WebMarginsTab');
  await context.close();
});

test('JOIN_PAGE: the join guide, light, dark and at 320 px', async ({ browser }) => {
  for (const [suffix, extra] of [
    ['', {}],
    ['-dark', { colorScheme: 'dark' as const }],
    ['-320', { viewport: { width: 320, height: 700 } }],
  ] as const) {
    const context = await browser.newContext({ ...PHONE, ...extra });
    const page = await context.newPage();
    // The page is self-contained; refuse anything that would leave the machine.
    await page.route(/^https?:/, (route) => route.abort());
    await page.goto(JOIN);
    await expect(page.getByRole('heading').first()).toBeVisible();
    await snap(page, `JOIN_PAGE${suffix}`);
    await context.close();
  }
});
