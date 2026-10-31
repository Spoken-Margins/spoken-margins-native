// On-device transcription of voice Margins, end to end in real Chrome (`channel: 'chrome'`, the `chrome-transcribe`
// project in playwright.config.ts). Chrome's fake microphone plays `audio/ask-not-16k.wav`, a public-domain clip of
// President Kennedy's 1961 inaugural address, so the real recorder, the real decoder and the real model all run.
//
// The model is served from `~/Library/Caches/spoken-margins-web-models/` in place of huggingface.co, so the test
// needs the network only the first time on a machine (it fills that folder from Hugging Face at the pinned revision).
// Every request the page and its worker make is recorded, and each test ends by checking that none carried a body
// (no audio left the browser) and that the only model requests were GETs of the pinned files.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { expect, test, type BrowserContext, type Page, type Request } from '@playwright/test';
import { HUGGING_FACE, TRANSCRIPTION_MODEL, isModelRequest } from '../src/transcribe/catalog.ts';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const EPISODE_3 = 'Episode 3: No link, GUID and audio';
/** The episode's audio, which fixtures.ts serves; the player GETs it, as any podcast app would. */
const MEDIA_ORIGIN = 'https://media.example.com';
const MODEL_CACHE_DIR = join(homedir(), 'Library/Caches/spoken-margins-web-models');
/** What the clip says, give or take punctuation and case. */
const SPOKEN = 'ask not what your country can do for you';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'chrome-transcribe', 'Runs in real Chrome with the speech clip as the microphone.');
  await serveFixtures(page);
});

/**
 * Serves Hugging Face from the local model cache, filling it from the real site once. With SM_E2E_LIVE_MODEL=1 the
 * browser downloads from Hugging Face itself instead (and follows its redirect to Hugging Face's file CDN).
 */
async function serveModel(context: BrowserContext): Promise<void> {
  if (process.env.SM_E2E_LIVE_MODEL === '1') return;
  await context.route(`${HUGGING_FACE}/**`, async (route) => {
    const url = route.request().url();
    if (!isModelRequest(url) || route.request().method() !== 'GET') return route.fulfill({ status: 404, body: 'not the pinned model' });
    const path = new URL(url).pathname.split('/resolve/')[1]?.split('/').slice(1).join('/') ?? '';
    const file = join(MODEL_CACHE_DIR, TRANSCRIPTION_MODEL.repo, TRANSCRIPTION_MODEL.revision, path);
    if (!existsSync(file)) {
      const fetched = await fetch(url);
      if (!fetched.ok) return route.fulfill({ status: fetched.status, body: '' });
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, Buffer.from(await fetched.arrayBuffer()));
    }
    const body = readFileSync(file);
    return route.fulfill({
      status: 200,
      body,
      headers: { 'content-type': 'application/octet-stream', 'content-length': String(body.length), 'access-control-allow-origin': '*' },
    });
  });
}

/** Every request the page, its worker and anything else in the context makes. */
function recordRequests(context: BrowserContext): Request[] {
  const seen: Request[] = [];
  context.on('request', (request) => seen.push(request));
  return seen;
}

/** A pinned model file, or where Hugging Face redirected a request for one (its cache API or its file CDN). */
function fromPinnedFile(request: Request): boolean {
  for (let r: Request | null = request; r; r = r.redirectedFrom()) if (isModelRequest(r.url())) return true;
  return false;
}

/** Nothing uploaded: no request carried a body, and Hugging Face was asked only for the pinned files. */
function expectNothingUploaded(requests: readonly Request[]) {
  const withBody = requests.filter((r) => (r.postDataBuffer()?.length ?? 0) > 0 || !['GET', 'HEAD'].includes(r.method()));
  expect(withBody.map((r) => `${r.method()} ${r.url()}`)).toEqual([]);
  const elsewhere = requests.filter((r) => {
    const { origin, protocol } = new URL(r.url());
    if (['data:', 'blob:'].includes(protocol) || /^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) return false;
    if (origin === FEED_ORIGIN || origin === MEDIA_ORIGIN) return false;
    return !fromPinnedFile(r);
  });
  expect(elsewhere.map((r) => r.url())).toEqual([]);
}

const modelRequests = (requests: readonly Request[]) => requests.filter((r) => r.url().startsWith(HUGGING_FACE));

async function openEpisode(page: Page) {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  return page.getByRole('dialog', { name: EPISODE_3 });
}

/** Records while the fake microphone plays the clip (11 s), then stops. */
async function recordClip(page: Page, nowPlaying: ReturnType<Page['getByRole']>) {
  await nowPlaying.getByRole('button', { name: 'Record a Margin' }).click();
  // Chrome's first start of the fake microphone, reading the clip, can take several seconds.
  await expect(nowPlaying.getByRole('status').filter({ hasText: 'Recording' })).toBeVisible({ timeout: 30_000 });
  await page.waitForTimeout(12_500);
  await nowPlaying.getByRole('button', { name: 'Stop', exact: true }).click();
}

const normalized = (text: string) => text.toLowerCase().replace(/[^a-z ]+/g, ' ').replace(/\s+/g, ' ').trim();

test('the first time, the composer offers transcription with its size, and nothing downloads until the listener says yes', async ({ page, context }, info) => {
  const requests = recordRequests(context);
  await serveModel(context);
  const nowPlaying = await openEpisode(page);
  await recordClip(page, nowPlaying);

  const offer = nowPlaying.getByTestId('transcribe-offer');
  await expect(offer).toContainText(/downloads a speech model once \(\d+ MB\)/);
  await expect(offer).toContainText('Your recording never leaves this device.');
  await page.waitForTimeout(1000);
  expect(modelRequests(requests)).toEqual([]);
  await shot(page, info, '40-transcribe-offer');

  await offer.getByRole('button', { name: 'Write out my words' }).click();
  const words = nowPlaying.getByLabel(/Words to go with your voice Margin at/);
  await expect.poll(async () => normalized(await words.inputValue()), { timeout: 90_000 }).toContain(SPOKEN);
  await expect(nowPlaying.getByTestId('transcribe-status')).toContainText('Check the words before you save.');
  // The transcript replaced the placeholder words rather than joining them.
  expect(await words.inputValue()).not.toContain('Voice Margin at');
  await expect(words).not.toHaveAttribute('data-placeholder', 'true');
  await shot(page, info, '41-transcribe-prefilled');

  // The words are the listener's to edit before saving; the saved Margin carries the edited text.
  const transcript = await words.inputValue();
  await words.fill(`${transcript} (JFK, 1961)`);
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Voice Margin saved at [\d:]+\.$/)).toBeVisible();
  await expect(nowPlaying.getByText('(JFK, 1961)')).toBeVisible();

  const fetched = modelRequests(requests).filter((r) => isModelRequest(r.url())).map((r) => new URL(r.url()).pathname.split(`/${TRANSCRIPTION_MODEL.revision}/`)[1]);
  expect(new Set(fetched)).toEqual(new Set(TRANSCRIPTION_MODEL.files.map((f) => f.path)));
  expectNothingUploaded(requests);
});

test('turned on in Settings, it downloads there, and later recordings are written out without asking', async ({ page, context }) => {
  const requests = recordRequests(context);
  await serveModel(context);

  await page.goto('./#settings');
  const section = page.getByRole('region', { name: 'Writing out voice Margins' });
  await expect(section.getByText(/Off\. Turning it on downloads \d+ MB once/)).toBeVisible();
  expect(modelRequests(requests)).toEqual([]);
  // A click, not check(): the switch follows the stored setting, which turns on a moment after the tap.
  const toggle = section.getByRole('switch', { name: 'Write out my words on this device' });
  await toggle.click();
  await expect(toggle).toBeChecked();
  await expect(section.getByText('On, the speech model is on this device')).toBeVisible({ timeout: 60_000 });
  expect(modelRequests(requests).length).toBeGreaterThanOrEqual(TRANSCRIPTION_MODEL.files.length);
  // The speech engine is kept with the model (not in the app shell), so "Remove" takes both away.
  const kept = await page.evaluate(async () => (await (await caches.open('sm-transcription-model')).keys()).map((r) => r.url));
  expect(kept.some((url) => /ort-wasm[^/]*\.wasm$/.test(url))).toBe(true);

  const nowPlaying = await openEpisode(page);
  await recordClip(page, nowPlaying);
  await expect(nowPlaying.getByTestId('transcribe-offer')).toHaveCount(0);
  const words = nowPlaying.getByLabel(/Words to go with your voice Margin at/);
  await expect.poll(async () => normalized(await words.inputValue()), { timeout: 90_000 }).toContain(SPOKEN);
  await expect(nowPlaying.getByTestId('transcribe-status')).toHaveAttribute('data-device', 'wasm');
  expectNothingUploaded(requests);

  // Removing the model forgets it and turns transcription off.
  await nowPlaying.getByRole('button', { name: 'Discard' }).click();
  // A fresh load of Settings, so the open episode's sheet doesn't sit over it.
  await page.goto('./#settings');
  await page.reload();
  await section.getByRole('button', { name: 'Remove the speech model' }).click();
  await expect(section.getByText(/Off\. Turning it on downloads \d+ MB once/)).toBeVisible();
  expect(await page.evaluate(async () => (await caches.keys()).includes('sm-transcription-model'))).toBe(false);
});

test('“No thanks” keeps the plain words box, downloads nothing, and is remembered', async ({ page, context }) => {
  const requests = recordRequests(context);
  await serveModel(context);
  const nowPlaying = await openEpisode(page);
  await recordClip(page, nowPlaying);
  await nowPlaying.getByTestId('transcribe-offer').getByRole('button', { name: 'No thanks' }).click();
  await expect(nowPlaying.getByTestId('transcribe-offer')).toHaveCount(0);
  // Without a transcript the box keeps its placeholder words (#3025), and typing replaces them.
  const words = nowPlaying.getByLabel(/Words to go with your voice Margin at/);
  await expect(words).toHaveValue(/^Voice Margin at \d+:\d\d in “.+”, recorded \d{1,2} [A-Z][a-z]{2} \d{4}$/);
  await words.fill('Typed by hand.');
  await expect(words).not.toHaveAttribute('data-placeholder', 'true');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Voice Margin saved at [\d:]+\.$/)).toBeVisible();

  // The next recording asks nothing and fetches nothing.
  await nowPlaying.getByRole('button', { name: 'Record a Margin' }).click();
  await page.waitForTimeout(1500);
  await nowPlaying.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(nowPlaying.getByLabel(/Words to go with your voice Margin at/)).toBeVisible();
  await expect(nowPlaying.getByTestId('transcribe-offer')).toHaveCount(0);
  expect(modelRequests(requests)).toEqual([]);
  await page.goto('./#settings');
  await expect(page.getByText(/Off\. Turning it on downloads \d+ MB once/)).toBeVisible();
  expectNothingUploaded(requests);
});

test.describe('installed app', () => {
  test.use({ serviceWorkers: 'allow' });

  // The worker is left out of the offline precache everyone downloads (#2977). Once a listener turns transcription
  // on, the service worker keeps it, so writing out words still works with no network.
  test('once turned on, transcription works offline in a fresh page', async ({ page, context }) => {
    await serveModel(context);
    await page.goto('./');
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.reload();
    await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);
    const optInKept = () =>
      page.evaluate(async () => {
        const urls: string[] = [];
        for (const key of (await caches.keys()).filter((k) => k.startsWith('sm-opt-in-'))) for (const r of await (await caches.open(key)).keys()) urls.push(r.url);
        return urls;
      });
    expect(await optInKept()).toEqual([]);

    await page.goto('./#settings');
    const section = page.getByRole('region', { name: 'Writing out voice Margins' });
    await section.getByRole('switch', { name: 'Write out my words on this device' }).click();
    await expect(section.getByText('On, the speech model is on this device')).toBeVisible({ timeout: 60_000 });
    await expect.poll(optInKept).toEqual([expect.stringMatching(/\/assets\/opt-in\/worker-[\w-]+\.js$/)]);
    await openEpisode(page);

    await context.setOffline(true);
    await page.reload();
    await page.getByRole('button', { name: /Play the newest episode/ }).click();
    const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
    await recordClip(page, nowPlaying);
    const words = nowPlaying.getByLabel(/Words to go with your voice Margin at/);
    await expect.poll(async () => normalized(await words.inputValue()), { timeout: 90_000 }).toContain(SPOKEN);
    await context.setOffline(false);
  });
});
