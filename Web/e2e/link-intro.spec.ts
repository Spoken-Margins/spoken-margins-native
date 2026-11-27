// Introduction links on the web (#4784, Design 2026-11-21, slice 2), against the local link stub (e2e/link-stub-server.ts),
// whose `intro*` links carry `answers: "none"` in their sealed preview, as `make-share-link --intro` seals it. A friend on an
// introduction link reads that their Margins stay in this browser, and the Share section never names the sender as a
// destination; a reply part on such a link is ignored. A conversation link keeps today's words, a slow preview fetch
// never holds up the first play, and a friend who comes back later from Library still sees the introduction words.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type BrowserContext, type Page } from '@playwright/test';
import { nowTab, serveAudio, serveFixtures, startFromBeginning } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const EPISODE = 'Episode 1 (example episode)';
const SENDER = 'Web fixture';
const linkTo = (id: string) => `${STUB}/l/${id}#${KEY}`;

const INTRO_TITLE = 'Share your Margins';
const INTRO_CAPTION = 'Your Margins stay in this browser. Share them as a file with anyone you like. They open it in Spoken Margins and hear each one at its moment.';
const INTRO_HINT = 'So whoever you share with knows who these are from. Kept in this browser.';
const INTRO_SAVED = 'Your Margin is saved in this browser. It stays here unless you share it.';
const TODAY_CAPTION = 'Share them as a file. Your friend opens it in Spoken Margins and hears each one at its moment.';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'These journeys open their own contexts.');
});

const newContext = (browser: import('@playwright/test').Browser) =>
  browser.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' });

async function friendPage(context: BrowserContext): Promise<Page> {
  const page = await context.newPage();
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  return page;
}

async function write(playing: ReturnType<Page['getByRole']>, words: string): Promise<void> {
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.getByLabel(/Your Margin at/).fill(words);
  await playing.getByRole('button', { name: 'Save Margin' }).click();
}

/** Opens a link, plays it, and writes one Margin; returns Now Playing. */
async function openAndWrite(page: Page, id: string, words = 'My own thought.') {
  await page.goto(linkTo(id));
  await startFromBeginning(page);
  const playing = page.getByRole('dialog', { name: EPISODE });
  await write(playing, words);
  return playing;
}

/** Screen A: every word of the Share section, and that none of it names the sender. */
async function expectIntroWords(playing: ReturnType<Page['getByRole']>): Promise<void> {
  const share = playing.locator('.share-margins');
  await expect(share.locator('legend')).toHaveText(INTRO_TITLE);
  await expect(share.getByText(INTRO_CAPTION)).toBeVisible();
  await expect(share.locator('#share-name-hint')).toHaveText(INTRO_HINT);
  await expect(share.getByText(TODAY_CAPTION)).toHaveCount(0);
  await expect(share.getByRole('button', { name: `Send to ${SENDER}` })).toHaveCount(0);
  expect(await share.innerText()).not.toContain(SENDER);
}

test('an introduction link: the saved card and Share say the Margins stay here and name no one (#4784)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const playing = await openAndWrite(page, 'introvoice01');
  await expect(playing.getByTestId('margin-cue')).toContainText(INTRO_SAVED);
  await expectIntroWords(playing);
  // The friend's row is never offered; theirs is, ticked, and Save as a file still works with today's toast and no "Send to".
  await expect(playing.locator('.reply-back li')).toHaveCount(1);
  await expect(playing.locator('.reply-back li input')).toBeChecked();
  const download = page.waitForEvent('download');
  await playing.getByRole('button', { name: 'Save as a file', exact: true }).click();
  await download;
  const toast = page.getByText(/Saved 1 Margin as /);
  await expect(toast).toBeVisible();
  await expect(toast).not.toContainText('Send this file');
  await expect(playing.locator('#share-why-not')).toHaveText('');
  await context.close();
});

test('a friend coming back from Library to an introduction episode still sees the introduction words (#4784)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  await openAndWrite(page, 'introvoice01');
  await expectIntroWords(page.getByRole('dialog', { name: EPISODE }));
  // A new visit, not through the link: nothing from the link is in memory, only what this browser stored.
  await page.goto(`${STUB}/`);
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click();
  await page.getByRole('button', { name: new RegExp(EPISODE.replace(/[()]/g, '\\$&')) }).first().click();
  await nowTab(page);
  await expectIntroWords(page.getByRole('dialog', { name: EPISODE }));
  await context.close();
});

test('an introduction mark wins over a reply part: no Send to, nothing posted (#4784)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const { box } = await (await page.request.get(`${STUB}/__stub/reply/introreply01`)).json();
  const before = ((await (await page.request.get(`${STUB}/__stub/box/${box}`)).json()).posts as string[]).length;
  const playing = await openAndWrite(page, 'introreply01');
  await expect(playing.getByTestId('margin-cue')).toContainText(INTRO_SAVED);
  await expectIntroWords(playing);
  const after = ((await (await page.request.get(`${STUB}/__stub/box/${box}`)).json()).posts as string[]).length;
  expect(after).toBe(before);
  await context.close();
});

test('a conversation link keeps today’s words (#4784 must not break)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const playing = await openAndWrite(page, 'vectorvoice01');
  const share = playing.locator('.share-margins');
  await expect(share.locator('legend')).toHaveText(`Share your Margins with ${SENDER}`);
  await expect(share.getByText(TODAY_CAPTION)).toBeVisible();
  await expect(share.locator('#share-name-hint')).toHaveText(`So ${SENDER} knows who these are from. Kept in this browser.`);
  await expect(share.getByText(INTRO_CAPTION)).toHaveCount(0);
  await context.close();
});

test('a preview that answers too late: play starts at once, and Share shows today’s words after the ceiling (#4784)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const opened = Date.now();
  await page.goto(linkTo('introslow001'));
  await startFromBeginning(page);
  // The first play never waits on the preview (it answers only after 8 seconds).
  expect(Date.now() - opened).toBeLessThan(8_000);
  const playing = page.getByRole('dialog', { name: EPISODE });
  await write(playing, 'Mine.');
  const share = playing.locator('.share-margins');
  await expect(share.locator('legend')).toHaveText(`Share your Margins with ${SENDER}`, { timeout: 10_000 });
  await expect(share.getByText(TODAY_CAPTION)).toBeVisible();
  await context.close();
});
