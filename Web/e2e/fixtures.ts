// Test plumbing: feeds come from the repo's own fixtures (`Contracts/fixtures/feeds/`), served at a fake
// origin, and every episode's audio is a short generated WAV, so nothing reaches the network.
import { readFileSync } from 'node:fs';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, type Page, type TestInfo } from '@playwright/test';

const repoRoot = fileURLToPath(new URL('../../', import.meta.url));
export const FEED_ORIGIN = 'https://feeds.test';
export const SHOTS_DIR = `${repoRoot}artifacts/web-2982`;

/** A mono 8 kHz, 8-bit WAV of a quiet tone, `seconds` long. */
export function wav(seconds: number): Buffer {
  const rate = 8000;
  const samples = rate * seconds;
  const buffer = Buffer.alloc(44 + samples);
  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(36 + samples, 4);
  buffer.write('WAVEfmt ', 8);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(rate, 24);
  buffer.writeUInt32LE(rate, 28);
  buffer.writeUInt16LE(1, 32);
  buffer.writeUInt16LE(8, 34);
  buffer.write('data', 36);
  buffer.writeUInt32LE(samples, 40);
  for (let i = 0; i < samples; i += 1) buffer[44 + i] = 128 + Math.round(8 * Math.sin((2 * Math.PI * 220 * i) / rate));
  return buffer;
}

const audio = wav(180);

/**
 * Answers every request matching `pattern` with the generated WAV, with byte ranges as podcast hosts do: without
 * them Chrome can't seek in the audio at all.
 */
export async function serveAudio(page: Page, pattern: string): Promise<void> {
  await page.route(pattern, (route) => {
    const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers()['range'] ?? '');
    if (!range) {
      return route.fulfill({ status: 200, body: audio, headers: { 'content-type': 'audio/wav', 'accept-ranges': 'bytes' } });
    }
    const start = Number(range[1]);
    const end = range[2] ? Math.min(Number(range[2]), audio.length - 1) : audio.length - 1;
    return route.fulfill({
      status: 206,
      body: audio.subarray(start, end + 1),
      headers: { 'content-type': 'audio/wav', 'accept-ranges': 'bytes', 'content-range': `bytes ${start}-${end}/${audio.length}` },
    });
  });
}

/** A fixture from `Contracts/fixtures/feeds/`. */
export const feedFixture = (name: string): Buffer => readFileSync(`${repoRoot}Contracts/fixtures/feeds/${name}`);

export async function serveFixtures(page: Page): Promise<void> {
  await page.route(`${FEED_ORIGIN}/**`, async (route) => {
    const name = new URL(route.request().url()).pathname.replace(/^\//, '');
    if (!/^[\w.-]+$/.test(name)) return route.fulfill({ status: 404 });
    try {
      const body = feedFixture(name);
      await route.fulfill({ status: 200, body, headers: { 'content-type': 'application/rss+xml', 'access-control-allow-origin': '*' } });
    } catch {
      await route.fulfill({ status: 404, headers: { 'access-control-allow-origin': '*' } });
    }
  });
  await serveAudio(page, 'https://media.example.com/**');
  // A feed whose host refuses browsers, to exercise the relay pop-up. Playwright's fulfilled responses
  // skip the CORS check, so the refusal is simulated as the failed fetch a CORS refusal produces.
  await page.route('https://blocked.test/**', (route) => route.abort('failed'));
}

export async function shot(page: Page, info: TestInfo, name: string): Promise<void> {
  mkdirSync(SHOTS_DIR, { recursive: true });
  await page.screenshot({ path: `${SHOTS_DIR}/${info.project.name}-${name}.png` });
}

/**
 * A share link's start from the beginning (part of #3216): the arrival preview's "Start from the beginning", or an
 * article packet's one Play, then the Now tab, which a friend's unheard Margins would otherwise open on Margins.
 */
export async function startFromBeginning(page: Page, button: 'Start from the beginning' | 'Play' = 'Start from the beginning'): Promise<void> {
  await page.getByTestId('arrival').getByRole('button', { name: button, exact: true }).click();
  await nowTab(page);
}

/** The Now tab of Now Playing. */
export async function nowTab(page: Page): Promise<void> {
  await page.locator('.now-playing').getByRole('tab', { name: 'Now' }).click();
}

/**
 * After a follow, puts episodes in the Library the way a listener does (#4425): Following, the show's row, Add on each
 * title, then Back to the Following list. The Library holds only what is added, so a spec that expects Library rows
 * after a follow calls this. `episodeTitles` are the exact titles; a title that has no Add button fails here.
 */
export async function followAndAdd(page: Page, showTitle: string | RegExp, episodeTitles: readonly string[]): Promise<void> {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Following' }).click();
  await page.getByRole('button', { name: typeof showTitle === 'string' ? `Open ${showTitle}` : showTitle }).click();
  for (const title of episodeTitles) {
    const add = page.getByRole('button', { name: `Add ${title} to your Library`, exact: true });
    await add.click();
    await expect(add).toHaveCount(0);
  }
  await page.locator('.back-button').click();
}

/** Clock text like "1:05" to seconds. */
export function seconds(clock: string): number {
  return clock
    .trim()
    .split(':')
    .map(Number)
    .reduce((total, n) => total * 60 + n, 0);
}
