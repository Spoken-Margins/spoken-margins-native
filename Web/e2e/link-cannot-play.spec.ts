// The listen-here card (#5265): a link whose Margins sit on something a browser can't play (an article on an ordinary
// site, a PDF, a book, a pasted text, an episode with no audio) lists the sender's Margins with their words, plays them
// here on one tap (the source's words first, then each Margin), and offers the iPhone app as the one next step. Links
// come from the local stub (e2e/link-stub-server.ts). Speech is the test builds' silent stub, which records each line.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { withLayer } from '../src/packet/resign.ts';
import { serveFixtures, shot } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const link = (id: string) => `${STUB}/l/${id}#${KEY}`;
const HEAR = 'Hear Web fixture’s Margins';

declare global {
  interface Window {
    __smSilent: { spoken: string[] };
  }
}
const spoken = (page: Page) => page.evaluate(() => window.__smSilent.spoken.filter((text) => text.trim() !== ''));

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'One phone-sized run covers the card; the Play card keeps its own journeys.');
  await serveFixtures(page);
});

async function open(page: Page, id: string) {
  await page.goto(link(id));
  const card = page.getByTestId('arrival-listen');
  await expect(card).toBeVisible();
  return card;
}

/** Plays the whole card and waits for the finished line. */
async function hearAll(page: Page) {
  const card = page.getByTestId('arrival-listen');
  await card.getByRole('button', { name: HEAR }).click();
  await expect(card.getByTestId('listen-status')).toContainText('1 of 2');
  await expect(card.getByTestId('listen-status')).toContainText('That was Web fixture’s last Margin.', { timeout: 40_000 });
}

const kinds = [
  { name: 'an article on an ordinary site', id: 'vectorarticle1', title: 'An essay on an ordinary site', source: 'Open the article', words: ['A written Margin from the web, 1:05 in.', 'Another at ten minutes.'], quote: 'A sentence in the essay.' },
  { name: 'a PDF', id: 'vectorpdf001', title: 'A paper as a PDF', source: undefined, words: ['A written Margin at half a minute.', 'This is a web Margin'], quote: 'The first quoted sentence of the source.' },
  { name: 'a book', id: 'vectorbook01', title: 'A book as an EPUB', source: undefined, words: ['A written Margin from the web, 1:05 in.', 'Another at ten minutes.'], quote: 'The first quoted sentence of the source.' },
  { name: 'an episode with no audio', id: 'vectornoaud1', title: 'An episode with no public audio', source: 'Open the episode’s page', words: ['A written Margin at half a minute.', 'This is a web Margin'], quote: undefined },
];

for (const kind of kinds) {
  test(`${kind.name}: who, how many, each Margin's words, one next step, and Hear plays them all`, async ({ page }, info) => {
    const card = await open(page, kind.id);
    await expect(card.getByRole('heading', { name: kind.title })).toBeVisible();
    await expect(card).toContainText('From Web fixture');
    await expect(card).toContainText('2 Margins ·');
    await expect(card.getByTestId('listen-row')).toHaveCount(2);
    for (const words of kind.words) await expect(card.getByTestId('listen-row').filter({ hasText: words })).toHaveCount(1);
    if (kind.quote) await expect(card.getByText(`“${kind.quote}”`).first()).toBeVisible();
    if (kind.source) await expect(card.getByRole('link', { name: kind.source })).toBeVisible();
    else await expect(card.getByRole('link', { name: /^Open the/ })).toHaveCount(0);
    await expect(card.getByRole('link', { name: 'Get Spoken Margins for iPhone' })).toHaveAttribute('href', 'https://spokenmargins.com/join');
    await expect(card).toContainText('After installing, tap your friend’s link again to open it in the app.');
    // Nothing on the card says what the browser can't do.
    await expect(card.getByText(/can’t|can't/)).toHaveCount(0);
    await shot(page, info, `cannot-play-${kind.id}-ready`);

    await hearAll(page);
    await expect(card.getByTestId('listen-status')).toContainText('To answer Web fixture, add a Margin of your own in Spoken Margins on iPhone.');
    await expect(card.getByRole('button', { name: 'Hear them again' })).toBeVisible();
    await expect(card.getByText(/can’t|can't/)).toHaveCount(0);
    await shot(page, info, `cannot-play-${kind.id}-finished`);
  });
}

test('the voice reads the source’s words before each Margin, then the Margin', async ({ page }) => {
  await open(page, 'vectorbook01');
  await hearAll(page);
  const lines = await spoken(page);
  expect(lines[0]).toBe('Here are the book’s words just before Web fixture’s Margin: The first quoted sentence of the source.');
  expect(lines[1]).toContain('Web fixture wrote: A written Margin from the web, 1:05 in.');
  expect(lines[2]).toBe('Here are the book’s words just before Web fixture’s Margin: Words before the second Margin.');
  expect(lines[3]).toContain('Web fixture wrote: Another at ten minutes.');
});

test('an episode with no audio reads the time before each Margin, and Go to your web Library shows it tagged', async ({ page }) => {
  const card = await open(page, 'vectornoaud1');
  await hearAll(page);
  const lines = await spoken(page);
  expect(lines[0]).toBe('Web fixture’s Margin is at 0:30 in “An episode with no public audio”.');
  await card.getByRole('button', { name: 'Go to your web Library' }).click();
  await expect(card).toHaveCount(0);
  await expect(page.getByText('An episode with no public audio')).toBeVisible();
  await expect(page.getByText('No audio in the browser', { exact: false })).toBeVisible();
});

test('a voice Margin shows its length, and the playing row is marked', async ({ page }) => {
  const card = await open(page, 'vectorpdf001');
  await expect(card.getByText(/Voice · \d+:\d\d/)).toBeVisible();
  await card.getByRole('button', { name: HEAR }).click();
  await expect(card.getByTestId('listen-row').first()).toContainText('Playing');
});

test('a double tap on Hear gives one run: the second tap stops the first', async ({ page }) => {
  const card = await open(page, 'vectortext01');
  const button = card.locator('.arrival-starts button');
  await button.dblclick();
  await expect(button).toHaveText(HEAR);
  await expect(card.getByTestId('listen-status')).toContainText('Each Margin plays after the words just before it.');
  const before = (await spoken(page)).length;
  await page.waitForTimeout(1500);
  expect((await spoken(page)).length).toBe(before);
});

test('Hear this one plays that Margin alone, then says which it was', async ({ page }) => {
  const card = await open(page, 'vectortext01');
  await card.getByRole('button', { name: /^Hear Web fixture’s Margin$/ }).click();
  await expect(card.getByTestId('listen-status')).toContainText('That was 2 of 2.', { timeout: 30_000 });
  await expect(card.locator('.arrival-starts button')).toHaveText(HEAR);
  // The text's next step names its noun.
  await expect(card).toContainText('To hear them in place while the text is read aloud');
});

test('offline after the card opens, Hear still plays the first Margin', async ({ page, context }) => {
  const card = await open(page, 'vectorpdf001');
  await context.setOffline(true);
  await card.getByRole('button', { name: HEAR }).click();
  await expect(card.getByTestId('listen-status')).toContainText('Web fixture wrote this · 1 of 2', { timeout: 15_000 });
  await context.setOffline(false);
});

test('a text link stores nothing in the web Library', async ({ page }) => {
  const card = await open(page, 'vectorarticle1');
  await hearAll(page);
  await expect(card.getByRole('button', { name: 'Go to your web Library' })).toHaveCount(0);
});

test('opened as a file, a PDF’s Margins show on the same card, with “file” words, and nothing is stored', async ({ page }) => {
  const voice = new Uint8Array(readFileSync(fileURLToPath(new URL('../../Contracts/fixtures/web-packets/web-voice.spokenmargins', import.meta.url))));
  const pdf = await withLayer(
    voice,
    (records) => {
      records.forEach((record, i) => {
        record.anchor = i === 0
          ? { anchorType: 'text', exactText: 'The first quoted sentence of the source.', roughPercent: 25, machineEvidenceAssetIds: [] }
          : { anchorType: 'text', prefix: 'Words before the second Margin.', machineEvidenceAssetIds: [] };
      });
    },
    (manifest) => {
      manifest.item = { itemType: 'pdf', title: 'A paper as a PDF' };
      manifest.itemTransport = { kind: 'recipient_supplied' };
    },
  );
  await page.goto('/');
  await page.getByTestId('margin-file').first().setInputFiles({ name: 'paper.spokenmargins', mimeType: 'application/octet-stream', buffer: Buffer.from(pdf) });
  const card = page.getByTestId('arrival-listen');
  await expect(card).toBeVisible();
  await expect(card).toContainText('open Web fixture’s file in Spoken Margins on iPhone, with your own copy of the same PDF.');
  await expect(card).toContainText('After installing, open the file again in the app.');
  await expect(card.getByText('Report this link')).toHaveCount(0);
  await expect(page.locator('.toast')).toHaveCount(0);
  await card.getByRole('button', { name: 'Go to your web Library' }).click();
  await expect(card).toHaveCount(0);
  await expect(page.getByText('A paper as a PDF')).toHaveCount(0);
});
