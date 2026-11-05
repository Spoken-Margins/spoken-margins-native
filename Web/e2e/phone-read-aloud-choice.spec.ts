// #3445: a written Margin the sender asked not to be read aloud (`readAloud: false`, from the iPhone app) shows its
// words and is not spoken by the browser's voice. Runs at iPhone size in Chrome and WebKit (`phone-*` projects).
// The web writer never writes the key, so the packet is a web packet re-signed with it set on one Margin.
import { expect, test, type Page } from '@playwright/test';
import type { Episode, Margin } from '../src/shared/model.ts';
import { writePacket } from '../src/packet/write.ts';
import { withLayer } from '../src/packet/resign.ts';
import { serveFixtures } from './fixtures.ts';

const TITLE = 'The tide tables, explained';
const episode: Episode = {
  id: 'ra-episode',
  showId: 'ra-show',
  title: TITLE,
  guid: 'ra-episode-guid',
  audioUrl: 'https://media.example.com/tide-tables.mp3',
  audioOrigin: 'podcast-enclosure',
  durationSeconds: 180,
};
const SILENT = 'Sam wants this one only on the screen.';
const SPOKEN = 'Sam is fine with this one being read.';
const margins: Margin[] = [
  { id: 'a', episodeId: episode.id, atSeconds: 42, createdAt: '2026-11-05T10:00:00Z', text: SILENT },
  { id: 'b', episodeId: episode.id, atSeconds: 46, createdAt: '2026-11-05T10:01:00Z', text: SPOKEN },
];

/** The packet the iPhone app writes: the first Margin (by moment) carries `readAloud: false`. */
async function packet(): Promise<{ name: string; buffer: Buffer }> {
  const written = await writePacket(episode, margins, { sender: 'Sam' });
  const bytes = await withLayer(written.bytes, (records) => {
    const silent = records.find((r) => JSON.stringify(r).includes(SILENT));
    if (!silent) throw new Error('the silent Margin is not in the packet');
    silent.readAloud = false;
  });
  return { name: written.fileName, buffer: Buffer.from(bytes) };
}

declare global {
  interface Window {
    __smSilent: { spoken: string[] };
  }
}

/** What the browser's voice has been asked to say: the e2e builds replace it with a stub that records and speaks nothing. */
const spoken = (page: Page) => page.evaluate(() => window.__smSilent.spoken.filter((text) => text.trim() !== ''));

async function openFile(page: Page) {
  await page.goto('./');
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: /Open a Margin file/ }).click();
  await (await choosing).setFiles(await packet());
  const nowPlaying = page.getByRole('dialog', { name: TITLE });
  await expect(nowPlaying).toBeVisible();
  return nowPlaying;
}

test.beforeEach(async ({ page }) => {
  await serveFixtures(page);
});

test('during the episode, a Margin marked not-read-aloud shows its words and is not spoken; the next one is (#3445)', async ({ page }) => {
  const nowPlaying = await openFile(page);
  const offer = nowPlaying.getByRole('button', { name: /Play from the first Margin/ });
  const started = nowPlaying.getByRole('button', { name: 'Pause' }).or(nowPlaying.getByTestId('arrived-margin'));
  await expect(offer.or(started).first()).toBeVisible({ timeout: 15_000 });
  if (await offer.isVisible()) await offer.click();

  const arrived = nowPlaying.getByTestId('arrived-margin');
  await expect(arrived).toContainText(SILENT, { timeout: 15_000 });
  await expect(arrived).not.toContainText('voice is reading');
  expect(await spoken(page)).toEqual([]);

  // The Margin four seconds later has no key: the card says the voice is reading it, and the voice is asked to.
  await expect(arrived).toContainText(SPOKEN, { timeout: 15_000 });
  await expect(arrived).toContainText('voice is reading');
  await expect.poll(() => spoken(page)).toEqual([expect.stringContaining(SPOKEN)]);
});

test('with no episode, the run shows a not-read-aloud Margin for the usual time and moves on to the next (#3445)', async ({ page }) => {
  // The episode's address fails, so the page offers the Margins on their own.
  await page.route('https://media.example.com/**', (route) => route.fulfill({ status: 404, body: 'Not found', headers: { 'content-type': 'text/html' } }));
  const nowPlaying = await openFile(page);
  await nowPlaying.getByTestId('margin-cue').getByRole('button', { name: 'Hear Sam’s Margins' }).click({ timeout: 20_000 });

  const arrived = nowPlaying.getByTestId('arrived-margin');
  await expect(arrived).toContainText(SILENT);
  await expect(arrived).toContainText('1 of 2');
  await expect(arrived).not.toContainText('voice is reading');
  expect(await spoken(page)).toEqual([]);

  await expect(arrived).toContainText(SPOKEN, { timeout: 30_000 });
  await expect(arrived).toContainText('2 of 2');
  await expect(arrived).toContainText('voice is reading');
  await expect.poll(() => spoken(page)).toEqual([expect.stringContaining(SPOKEN)]);
});
