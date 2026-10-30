// Test plumbing: feeds come from the repo's own fixtures (`Contracts/fixtures/feeds/`), served at a fake
// origin, and every episode's audio is a short generated WAV, so nothing reaches the network.
import { readFileSync } from 'node:fs';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Page, TestInfo } from '@playwright/test';

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

export async function serveFixtures(page: Page): Promise<void> {
  await page.route(`${FEED_ORIGIN}/**`, async (route) => {
    const name = new URL(route.request().url()).pathname.replace(/^\//, '');
    if (!/^[\w.-]+$/.test(name)) return route.fulfill({ status: 404 });
    try {
      const body = readFileSync(`${repoRoot}Contracts/fixtures/feeds/${name}`);
      await route.fulfill({ status: 200, body, headers: { 'content-type': 'application/rss+xml', 'access-control-allow-origin': '*' } });
    } catch {
      await route.fulfill({ status: 404, headers: { 'access-control-allow-origin': '*' } });
    }
  });
  // Served with byte ranges, as podcast hosts do: without them Chrome can't seek in the audio at all.
  await page.route('https://media.example.com/**', (route) => {
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
  // A feed whose host refuses browsers, to exercise the relay pop-up. Playwright's fulfilled responses
  // skip the CORS check, so the refusal is simulated as the failed fetch a CORS refusal produces.
  await page.route('https://blocked.test/**', (route) => route.abort('failed'));
}

export async function shot(page: Page, info: TestInfo, name: string): Promise<void> {
  mkdirSync(SHOTS_DIR, { recursive: true });
  await page.screenshot({ path: `${SHOTS_DIR}/${info.project.name}-${name}.png` });
}

/** Clock text like "1:05" to seconds. */
export function seconds(clock: string): number {
  return clock
    .trim()
    .split(':')
    .map(Number)
    .reduce((total, n) => total * 60 + n, 0);
}
