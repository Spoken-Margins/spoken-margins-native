// The owner's phone feedback (#3038, 2026-10-31): "It is kind of discombobulating to need to stop the margin and
// then save it, but it does work." Stop now saves the voice Margin; its words stay editable, and Undo takes it away.
// Runs at iPhone size in Chrome and WebKit (`phone-*` projects).
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { devices, expect, test, type Page, type PlaywrightWorkerArgs } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const EPISODE = 'Episode 3: No link, GUID and audio';

// Playwright's usual WebKit context is ephemeral, like Safari's private browsing, where IndexedDB refuses to store a
// Blob. The voice Margin is stored as bytes now (#3043), so the last test here runs in that default context; the
// others keep a context with a real profile, as Safari on the owner's phone has. Chrome takes the fake microphone
// from its launch switches.
test.beforeEach(async ({ page }) => {
  await serveFixtures(page);
});

async function phonePage(page: Page, browserName: string, playwright: PlaywrightWorkerArgs['playwright'], baseURL: string | undefined) {
  if (browserName !== 'webkit') return { page, done: async () => {} };
  const dir = mkdtempSync(join(tmpdir(), 'sm-webkit-'));
  const context = await playwright.webkit.launchPersistentContext(dir, { ...devices['iPhone 15 Pro'], baseURL, permissions: ['microphone'], serviceWorkers: 'block' });
  const persistent = context.pages()[0] ?? (await context.newPage());
  await serveFixtures(persistent);
  return {
    page: persistent,
    done: async () => {
      await context.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

async function openEpisode(page: Page) {
  await page.goto('./');
  await page.getByRole('button', { name: 'Find a show to follow' }).click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await sheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await sheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following Spoken Margins Test Show/)).toBeVisible();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click();
  await page.getByRole('button', { name: new RegExp(EPISODE) }).click();
  return page.getByRole('dialog', { name: EPISODE });
}

async function record(page: Page, nowPlaying: ReturnType<Page['getByRole']>) {
  await nowPlaying.getByRole('button', { name: 'Record a Margin' }).click();
  await expect(nowPlaying.getByRole('button', { name: 'Stop and save' })).toBeEnabled({ timeout: 15_000 });
  await page.waitForTimeout(1200);
  await nowPlaying.getByRole('button', { name: 'Stop and save' }).click();
}

/** The voice Margins stored in this browser, as the Margins tab would read them. */
function storedVoiceMargins(page: Page) {
  return page.evaluate(
    () =>
      new Promise<Array<{ text?: string }>>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onerror = () => reject(open.error);
        open.onsuccess = () => {
          const get = open.result.transaction('margins').objectStore('margins').getAll();
          get.onsuccess = () => resolve((get.result as Array<{ voice?: unknown; text?: string }>).filter((m) => m.voice).map((m) => ({ text: m.text })));
        };
      }),
  );
}

test('Stop saves the voice Margin, Undo takes it away, and later words are kept', async ({ page: first, browserName, playwright, baseURL }, info) => {
  const { page, done } = await phonePage(first, browserName, playwright, baseURL);
  const nowPlaying = await openEpisode(page);

  // One tap after speaking: the Margin is saved and listed, with no Save step.
  await record(page, nowPlaying);
  await expect(nowPlaying.getByTestId('voice-saved')).toHaveText(/^Saved Voice Margin at \d+:\d\d\.$/);
  await expect(nowPlaying.getByRole('button', { name: /Hear this voice Margin/ })).toHaveCount(1);
  expect(await storedVoiceMargins(page)).toEqual([{ text: undefined }]);
  await expect(nowPlaying.getByRole('button', { name: 'Save Margin' })).toHaveCount(0);
  await shot(page, info, '3038-saved-on-stop');

  // Undo, right there: the Margin is gone again.
  await nowPlaying.getByRole('button', { name: 'Undo' }).click();
  await expect(page.getByText(/Voice Margin at \d+:\d\d removed\./)).toBeVisible();
  await expect(nowPlaying.getByRole('button', { name: /Hear this voice Margin/ })).toHaveCount(0);
  expect(await storedVoiceMargins(page)).toEqual([]);

  // Words typed after the save go on the saved Margin, even when the listener leaves without tapping Done.
  await record(page, nowPlaying);
  await expect(nowPlaying.getByTestId('voice-saved')).toHaveText(/^Saved/);
  await nowPlaying.getByLabel(/Words to go with your voice Margin at/).fill('The bit about tides.');
  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect.poll(() => storedVoiceMargins(page)).toEqual([{ text: 'The bit about tides.' }]);
  await done();
});

test.describe('a browser that refuses to store a Blob', () => {
  test.use({ permissions: ['microphone'] });
  test('a voice Margin saves in a browser that refuses to store a Blob, such as Safari private browsing (#3043)', async ({ page }, info) => {
    // The default page: ephemeral in WebKit, so IndexedDB refuses a Blob there.
    const nowPlaying = await openEpisode(page);
    await record(page, nowPlaying);
    await expect(nowPlaying.getByTestId('voice-saved')).toHaveText(/^Saved Voice Margin at \d+:\d\d\.$/);
    await expect(page.getByText(/wasn.t saved/)).toHaveCount(0);
    expect(await storedVoiceMargins(page)).toEqual([{ text: undefined }]);
    await shot(page, info, '3043-saved-without-blob-storage');

    // It is there after a reload, with its audio rebuilt for the Hear button.
    await page.reload();
    expect(await storedVoiceMargins(page)).toEqual([{ text: undefined }]);
    await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' }).click();
    await expect(page.getByRole('button', { name: /Hear this voice Margin/ })).toHaveCount(1);
  });
});
