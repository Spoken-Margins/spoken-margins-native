// #3058: a friend's spoken Margins play by themselves at their moment, as on the iPhone: the episode pauses, the clip
// plays, the episode carries on. A browser that won't start the clip leaves the episode paused at the Margin with a
// Play. Runs at iPhone size in Chrome and WebKit (`phone-*` projects), because the clips are AAC.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import type { Episode, Margin } from '../src/shared/model.ts';
import { writePacket } from '../src/packet/write.ts';
import { nowTab, serveFixtures, shot } from './fixtures.ts';

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

async function packet(list: readonly Margin[] = margins): Promise<{ name: string; buffer: Buffer }> {
  const written = await writePacket(episode, list, { sender: 'Sam' });
  return { name: written.fileName, buffer: Buffer.from(written.bytes) };
}

declare global {
  interface Window {
    __plays: Array<{ kind: 'episode' | 'clip'; at: number; episodePaused: boolean }>;
    __blockClips: boolean;
    __clipElements: HTMLMediaElement[];
  }
}

/** Records every play() in order, and, when `block` is set, refuses the first clip the way a strict browser does. */
async function watchPlays(page: Page, block: boolean): Promise<void> {
  await page.addInitScript((blockFirstClip: boolean) => {
    window.__plays = [];
    window.__blockClips = blockFirstClip;
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      // The player readies its clip element from a tap with a moment of silence (#4472); that is not a Margin's clip.
      if (this.src.startsWith('data:audio/wav')) return play.call(this);
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

async function openFile(page: Page, list: readonly Margin[] = margins) {
  await page.goto('./');
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: /Open a Margin file/ }).click();
  await (await choosing).setFiles(await packet(list));
  const nowPlaying = page.getByRole('dialog', { name: TITLE });
  await expect(nowPlaying).toBeVisible();
  // A friend's unheard Margins open Now Playing on Margins (part of #3216); these checks are on Now.
  await nowTab(page);
  return nowPlaying;
}

/**
 * Lets the opened file start at its first Margin: by itself where the browser allows it, or with the offer's tap where
 * it waits for one (WebKit). Waits for one or the other, since a single look while the audio still loads sees neither
 * and would leave the episode unstarted (#3254).
 */
async function startAtLanding(nowPlaying: ReturnType<Page['getByRole']>) {
  const offer = nowPlaying.getByRole('button', { name: /Play from the first Margin/ });
  const started = nowPlaying.getByRole('button', { name: 'Pause' }).or(nowPlaying.getByTestId('arrived-margin'));
  await expect(offer.or(started).first()).toBeVisible({ timeout: 15_000 });
  if (await offer.isVisible()) await offer.click();
}

/**
 * What the episode and the clips did, sent out by the page on the console as it happens. Reading it takes no
 * `evaluate`, so a test can wait on it through a lead-in without handing WebKit a gesture; and a failure prints it.
 */
type MediaTrace = { lines: string[]; episodeAt: number; clipStarts: number; clipEnds: number };

async function traceMedia(page: Page): Promise<MediaTrace> {
  const trace: MediaTrace = { lines: [], episodeAt: 0, clipStarts: 0, clipEnds: 0 };
  page.on('console', (message) => {
    const text = message.text();
    if (!text.startsWith('media-trace ')) return;
    trace.lines.push(text.slice(12));
    const [, who, what, at] = text.split(' ');
    if (who === 'episode' && at) trace.episodeAt = Number(at);
    if (who === 'clip' && what === 'playing') trace.clipStarts++;
    if (who === 'clip' && what === 'ended') trace.clipEnds++;
  });
  await page.addInitScript(() => {
    const t0 = performance.now();
    const say = (who: string, what: string, el: HTMLMediaElement) =>
      console.log(`media-trace ${who} ${what} ${el.currentTime.toFixed(2)} wall=${((performance.now() - t0) / 1000).toFixed(1)}s ready=${el.readyState}`);
    const events = ['playing', 'pause', 'ended', 'error', 'waiting', 'stalled', 'seeking', 'seeked'];
    const watched = new WeakSet<HTMLMediaElement>();
    let lastTick = 0;
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      const who = this.dataset.testid === 'audio' ? 'episode' : this.src.startsWith('data:') ? 'prime' : 'clip';
      if (!watched.has(this)) {
        watched.add(this);
        for (const type of events) this.addEventListener(type, () => say(this.dataset.testid === 'audio' ? 'episode' : this.src.startsWith('data:') ? 'prime' : 'clip', type, this));
        if (who === 'episode') {
          this.addEventListener('timeupdate', () => {
            if (performance.now() - lastTick < 500) return;
            lastTick = performance.now();
            say('episode', 'at', this);
          });
        }
      }
      say(who, 'play()', this);
      return play.call(this);
    };
  });
  return trace;
}

test.beforeEach(async ({ page }) => {
  await serveFixtures(page);
});

test('each spoken Margin plays by itself at its moment, in order, and the episode resumes after it', async ({ page }, info) => {
  await watchPlays(page, false);
  const nowPlaying = await openFile(page);
  // The first Margin is where the file lands; play from there if the browser waited for a tap.
  await startAtLanding(nowPlaying);

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
  await startAtLanding(nowPlaying);

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
  await startAtLanding(nowPlaying);
  await expect.poll(async () => (await plays(page)).filter((p) => p.kind === 'clip').length, { timeout: 25_000 }).toBe(1);
  // Jump to well past the second Margin before it comes up (the first clip may still be playing).
  await nowPlaying.getByLabel('Position').fill('100');
  await page.waitForTimeout(3000);
  expect((await plays(page)).filter((p) => p.kind === 'clip')).toHaveLength(1);
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(100);
});

test('while a spoken Margin plays, the main button shows Pause and pauses it; Play carries it on (#4473)', async ({ page }) => {
  test.setTimeout(120_000);
  await watchPlays(page, false);
  // Every clip element, so the test can see whether the friend's voice is paused. The clip plays at a third of its
  // speed, so its 2.8 s last long enough for the taps to land while it plays.
  await page.addInitScript(() => {
    const play = HTMLMediaElement.prototype.play;
    window.__clipElements = [];
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      if (this !== document.querySelector('audio[data-testid="audio"]') && !this.src.startsWith('data:audio/wav')) {
        if (!window.__clipElements.includes(this)) window.__clipElements.push(this);
        this.playbackRate = 0.33;
      }
      return play.call(this);
    };
  });
  const clipPaused = () => page.evaluate(() => window.__clipElements.at(-1)?.paused ?? null);
  const trace = await traceMedia(page);
  const nowPlaying = await openFile(page);
  await startAtLanding(nowPlaying);
  const card = nowPlaying.getByTestId('arrived-margin');
  await expect(card).toContainText('Sam is speaking', { timeout: 20_000 });
  await expect.poll(clipPaused, { timeout: 10_000 }).toBe(false);
  // The friend's voice is what is sounding, so the main button offers Pause, not Play.
  const main = nowPlaying.locator('.play-button');
  await expect(main).toHaveAccessibleName('Pause');
  // In WebKit this tap lands while the clip is still loading; its play() then rejects with AbortError, which once
  // skipped the Margin and started the episode under the card.
  await main.click();
  // Pause holds the clip; the episode stays paused under it and the card stays up.
  await expect.poll(clipPaused).toBe(true);
  await expect(main).toHaveAccessibleName('Play');
  await expect(card).toContainText('Sam is speaking');
  const held = await audioTime(page);
  await page.waitForTimeout(1500);
  expect(await clipPaused()).toBe(true);
  expect(Math.abs((await audioTime(page)) - held)).toBeLessThan(0.1);
  // Play carries the clip on, and then the episode as usual.
  await main.click();
  await expect.poll(clipPaused).toBe(false);
  await expect(main).toHaveAccessibleName('Pause');
  try {
    // The clip ends first. Its time is the clip's own, at a third of its speed, and slower again where the runner's
    // media clock lags the wall (hosted CI's Chrome: a clip "playing" for 1.7 s moved 0.01 s), so wait on its end.
    await expect.poll(() => trace.clipEnds, { timeout: 60_000, intervals: [500] }).toBeGreaterThan(0);
    await expect.poll(() => audioTime(page), { timeout: 15_000 }).toBeGreaterThan(held + 0.5);
  } catch (error) {
    console.log(`Media trace:\n${trace.lines.join('\n')}`);
    throw error;
  }
});

/** Every clip element is recorded, and plays at a third of its speed, so a tap lands while the friend's voice sounds. */
async function slowClips(page: Page) {
  await page.addInitScript(() => {
    const play = HTMLMediaElement.prototype.play;
    window.__clipElements = [];
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      if (this !== document.querySelector('audio[data-testid="audio"]') && !this.src.startsWith('data:audio/wav')) {
        if (!window.__clipElements.includes(this)) window.__clipElements.push(this);
        this.playbackRate = 0.33;
      }
      return play.call(this);
    };
  });
  return () => page.evaluate(() => window.__clipElements.at(-1)?.paused ?? null);
}

test('"Skip this Margin" ends the Margin that is playing and the episode carries on from there (#4473)', async ({ page }) => {
  test.setTimeout(120_000);
  await watchPlays(page, false);
  const clipPaused = await slowClips(page);
  const nowPlaying = await openFile(page);
  await startAtLanding(nowPlaying);
  const card = nowPlaying.getByTestId('arrived-margin');
  await expect(card).toContainText('Sam is speaking', { timeout: 20_000 });
  await expect.poll(clipPaused, { timeout: 10_000 }).toBe(false);
  const before = await audioTime(page);
  await nowPlaying.getByTestId('skip-margin').click();
  // The friend's voice stops, the card goes, and the episode plays on, well before the clip would have ended by itself.
  await expect.poll(clipPaused).toBe(true);
  await expect(card).toHaveCount(0);
  await expect(nowPlaying.locator('.play-button')).toHaveAccessibleName('Pause');
  await expect.poll(() => audioTime(page), { timeout: 5_000 }).toBeGreaterThan(before + 0.5);
});

test('scrubbing out of a playing Margin stops it and the episode plays from the new place (#4473)', async ({ page }) => {
  test.setTimeout(120_000);
  await watchPlays(page, false);
  const clipPaused = await slowClips(page);
  const nowPlaying = await openFile(page);
  await startAtLanding(nowPlaying);
  const card = nowPlaying.getByTestId('arrived-margin');
  await expect(card).toContainText('Sam is speaking', { timeout: 20_000 });
  await expect.poll(clipPaused, { timeout: 10_000 }).toBe(false);
  await nowPlaying.getByLabel('Position').fill('100');
  await expect.poll(clipPaused).toBe(true);
  await expect(card).toHaveCount(0);
  await expect(nowPlaying.locator('.play-button')).toHaveAccessibleName('Pause');
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(100);
  const there = await audioTime(page);
  await expect.poll(() => audioTime(page), { timeout: 5_000 }).toBeGreaterThan(there + 0.3);
});

// #4472: after "Skip to just before" the next Margin comes up 20 s after the listener's last tap. Safari (WebKit, the
// engine of every iPhone browser) refused a clip started that long after a tap, so the Margin waited behind a Play;
// "Skip to <name> now", 0.3 s before it, was close enough to the tap to pass. Each row lands with the lead-in Skip and
// lets playback reach the Margin with no tap at all.
/**
 * Plays the episode at four times its speed, so a 20-second lead-in takes 5 and the rows below stop spending minutes of
 * real time on it (#4651). What the rows check is that the clip starts with no tap near it: 5 s after the last one is
 * still far past the moment WebKit allowed before the clip element was readied (#4472), and the old code fails them
 * at this speed too. Clips play at their own speed.
 */
const EPISODE_SPEED = 4;
async function fastEpisode(page: Page) {
  await page.addInitScript((speed: number) => {
    const play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      if (this.dataset.testid === 'audio') this.playbackRate = speed;
      return play.call(this);
    };
  }, EPISODE_SPEED);
}

const at = (id: string, seconds: number): Margin => ({
  id, episodeId: episode.id, atSeconds: seconds, createdAt: '2026-10-31T10:00:00Z', text: `Margin ${id}.`, voice: voice(),
});
const leadInRows: Array<{ name: string; list: Margin[]; clipsAt: number[] }> = [
  { name: 'a spoken Margin', list: [at('first', 30), at('target', 90)], clipsAt: [90] },
  { name: 'two spoken Margins five seconds apart', list: [at('first', 30), at('near', 85), at('target', 90)], clipsAt: [85, 90] },
  { name: 'the last spoken Margin, near the end of the episode', list: [at('first', 30), at('target', 175)], clipsAt: [175] },
];

for (const row of leadInRows) {
  test(`after "Skip to just before", ${row.name} plays by itself when playback reaches it (#4472)`, async ({ page }) => {
    test.setTimeout(150_000);
    await watchPlays(page, false);
    await fastEpisode(page);
    const trace = await traceMedia(page);
    const nowPlaying = await openFile(page, row.list);
    await startAtLanding(nowPlaying);
    // The landing Margin plays, the episode runs on past it, and the countdown offers the lead-in Skip.
    await expect.poll(() => audioTime(page), { timeout: 20_000 }).toBeGreaterThan(31);
    const skip = nowPlaying.getByRole('button', { name: 'Skip to just before Sam' });
    await expect(skip).toBeVisible({ timeout: 10_000 });
    const before = (await plays(page)).length;
    await skip.click();
    // Hands off through the lead-in and the clips: Playwright runs `evaluate` (which every poll and locator check uses)
    // as a user gesture in WebKit, and a poll here would hand the clip the tap the listener never makes. That is how the
    // tests above passed while the owner's phone refused the clip.
    const span = row.clipsAt[row.clipsAt.length - 1] - row.clipsAt[0];
    await page.waitForTimeout(((20 + span) / EPISODE_SPEED + 3.5 * row.clipsAt.length + 3) * 1000);
    if (trace.episodeAt < row.clipsAt[row.clipsAt.length - 1] + 1) {
      // The time above is the lead-in at the speed set above. A slow runner plays it slower, so wait on the console-fed trace
      // (no page reads) until the episode is past the last Margin.
      try {
        await expect.poll(() => trace.episodeAt, { timeout: 60_000, intervals: [500] }).toBeGreaterThan(row.clipsAt[row.clipsAt.length - 1] + 1);
      } catch (error) {
        console.log(`Media trace:\n${trace.lines.join('\n')}`);
        throw error;
      }
    }
    // No Margin waits behind a Play: each clip is heard where it sits, and the episode carries on after the last.
    await expect(nowPlaying.getByRole('button', { name: /^Play Sam’s Margin/ })).toHaveCount(0);
    const clips = (await plays(page)).slice(before).filter((p) => p.kind === 'clip');
    // Each clip starts where its Margin sits. The episode's time moves up to a second between the checks that fire a
    // Margin at the faster speed, so "where it sits" is the moment up to two seconds on, never before it.
    expect(clips).toHaveLength(row.clipsAt.length);
    row.clipsAt.forEach((moment, i) => {
      expect(clips[i].at).toBeGreaterThanOrEqual(moment);
      expect(clips[i].at).toBeLessThan(moment + 2);
    });
    expect(clips.every((p) => p.episodePaused)).toBe(true);
    const last = row.clipsAt[row.clipsAt.length - 1];
    expect(await audioTime(page)).toBeGreaterThan(last + 1);
  });
}
