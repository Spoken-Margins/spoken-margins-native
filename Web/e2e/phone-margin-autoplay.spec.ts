// #3058: a friend's spoken Margins play by themselves at their moment, as on the iPhone: the episode pauses, the clip
// plays, the episode carries on. A browser that won't start the clip leaves the episode paused at the Margin with a
// Play. Runs at iPhone size in Chrome and WebKit (`phone-*` projects), because the clips are AAC.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import type { Episode, Margin } from '../src/shared/model.ts';
import { writePacket } from '../src/packet/write.ts';
import { serveFixtures, shot } from './fixtures.ts';

const TITLE = 'The tide tables, explained';
const episode: Episode = {
  id: 'sam-episode',
  showId: 'sam-show',
  title: TITLE,
  guid: 'sam-episode-guid',
  audioUrl: 'https://media.example.com/tide-tables.mp3',
  audioOrigin: 'podcast-enclosure',
  durationSeconds: 180,
};
const FIRST_AT = 42;
const SECOND_AT = 47;
const clipBytes = readFileSync(fileURLToPath(new URL('../../Contracts/fixtures/web-packets/audio/voice-apple.m4a', import.meta.url)));
const voice = () => ({ blob: new Blob([clipBytes], { type: 'audio/mp4' }), mimeType: 'audio/mp4', durationSeconds: 2.8 });
const margins: Margin[] = [
  { id: 'm2', episodeId: episode.id, atSeconds: SECOND_AT, createdAt: '2026-10-31T10:05:00Z', text: 'Second voice note.', voice: voice() },
  { id: 'm1', episodeId: episode.id, atSeconds: FIRST_AT, createdAt: '2026-10-31T10:00:00Z', text: 'First voice note.', voice: voice() },
];

async function packet(): Promise<{ name: string; buffer: Buffer }> {
  const written = await writePacket(episode, margins, { sender: 'Sam' });
  return { name: written.fileName, buffer: Buffer.from(written.bytes) };
}

declare global {
  interface Window {
    __plays: Array<{ kind: 'episode' | 'clip'; at: number; episodePaused: boolean }>;
    __blockClips: boolean;
  }
}

/** Records every play() in order, and, when `block` is set, refuses the first clip the way a strict browser does. */
async function watchPlays(page: Page, block: boolean): Promise<void> {
  await page.addInitScript((blockFirstClip: boolean) => {
    window.__plays = [];
    window.__blockClips = blockFirstClip;
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      const episodeElement = document.querySelector('audio[data-testid="audio"]') as HTMLAudioElement | null;
      const clip = this !== episodeElement;
      window.__plays.push({ kind: clip ? 'clip' : 'episode', at: episodeElement?.currentTime ?? 0, episodePaused: episodeElement?.paused ?? true });
      if (clip && window.__blockClips) {
        window.__blockClips = false;
        return Promise.reject(new DOMException('play() needs a tap', 'NotAllowedError'));
      }
      return play.call(this);
    };
  }, block);
}

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
const plays = (page: Page) => page.evaluate(() => window.__plays);

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

test('each spoken Margin plays by itself at its moment, in order, and the episode resumes after it', async ({ page }, info) => {
  await watchPlays(page, false);
  const nowPlaying = await openFile(page);
  // The first Margin is where the file lands; play from there if the browser waited for a tap.
  const offer = nowPlaying.getByRole('button', { name: /Play from the first Margin/ });
  if (await offer.isVisible().catch(() => false)) await offer.click();

  // Two clips, each played with the episode paused, and the episode playing again after each.
  await expect
    .poll(async () => (await plays(page)).filter((p) => p.kind === 'clip').length, { timeout: 25_000 })
    .toBe(2);
  const log = await plays(page);
  const clips = log.filter((p) => p.kind === 'clip');
  expect(clips[0].episodePaused).toBe(true);
  expect(clips[1].episodePaused).toBe(true);
  expect(clips[0].at).toBeGreaterThanOrEqual(FIRST_AT);
  expect(clips[0].at).toBeLessThan(FIRST_AT + 2);
  expect(clips[1].at).toBeGreaterThanOrEqual(SECOND_AT);
  expect(clips[1].at).toBeLessThan(SECOND_AT + 2);
  const order = log.map((p) => p.kind);
  expect(order.slice(order.indexOf('clip'))).toEqual(['clip', 'episode', 'clip']);

  // After the second clip the episode is back, past the second Margin.
  await expect(nowPlaying.getByRole('button', { name: 'Pause' })).toBeVisible({ timeout: 15_000 });
  await expect.poll(() => audioTime(page), { timeout: 15_000 }).toBeGreaterThan(SECOND_AT + 1);
  await shot(page, info, '3058-after-second-margin');
});

test('a browser that blocks the clip leaves the episode paused at the Margin, with a Play', async ({ page }, info) => {
  await watchPlays(page, true);
  const nowPlaying = await openFile(page);
  const offer = nowPlaying.getByRole('button', { name: /Play from the first Margin/ });
  if (await offer.isVisible().catch(() => false)) await offer.click();

  const play = nowPlaying.getByRole('button', { name: 'Play Sam’s Margin' });
  await expect(play).toBeVisible({ timeout: 15_000 });
  await expect(nowPlaying.getByTestId('arrived-margin')).toContainText('First voice note.');
  const stoppedAt = await audioTime(page);
  expect(stoppedAt).toBeGreaterThanOrEqual(FIRST_AT);
  expect(stoppedAt).toBeLessThan(FIRST_AT + 2);
  await shot(page, info, '3058-blocked-clip');
  // Paused: the episode does not run on while the Play waits.
  await page.waitForTimeout(1500);
  expect(await audioTime(page)).toBeCloseTo(stoppedAt, 0);

  // A tap plays the clip, then the episode carries on.
  await play.click();
  await expect(play).toBeHidden();
  await expect(nowPlaying.getByRole('button', { name: 'Pause' })).toBeVisible({ timeout: 15_000 });
  await expect.poll(() => audioTime(page), { timeout: 15_000 }).toBeGreaterThan(stoppedAt + 1);
});

test('skipping forward past a Margin does not play it', async ({ page }) => {
  await watchPlays(page, false);
  const nowPlaying = await openFile(page);
  const offer = nowPlaying.getByRole('button', { name: /Play from the first Margin/ });
  if (await offer.isVisible().catch(() => false)) await offer.click();
  await expect.poll(async () => (await plays(page)).filter((p) => p.kind === 'clip').length, { timeout: 25_000 }).toBe(1);
  // Jump to well past the second Margin before it comes up (the first clip may still be playing).
  await nowPlaying.getByLabel('Position').fill('100');
  await page.waitForTimeout(3000);
  expect((await plays(page)).filter((p) => p.kind === 'clip')).toHaveLength(1);
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(100);
});
