// Keeping Margins when browser storage fails (#3012), at phone size: a write the browser refuses is named in a
// problem the listener can read, persistent storage is asked for after the first Margin (not on load), and
// "Back up all Margins" saves a file this web app and the iPhone app open.
import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { readPacket } from '../src/packet/read.ts';
import { listZip, readZip } from '../src/packet/zip.ts';
import { FEED_ORIGIN, SHOTS_DIR, seconds, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const EPISODE_3 = 'Episode 3: No link, GUID and audio';

/**
 * Before the app loads: a StorageManager that refuses to persist and counts the asks, and an IndexedDB whose put()
 * throws the browser's own QuotaExceededError for whichever store `window.__failStore` names.
 */
async function rigStorage(page: Page) {
  await page.addInitScript(() => {
    const w = window as unknown as { __persistCalls: number; __failStore?: string };
    w.__persistCalls = 0;
    Object.defineProperty(navigator, 'storage', {
      configurable: true,
      value: {
        persisted: async () => false,
        persist: async () => {
          w.__persistCalls += 1;
          return false;
        },
        estimate: async () => ({ usage: 0, quota: 0 }),
      },
    });
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (this: IDBObjectStore, ...args: Parameters<IDBObjectStore['put']>) {
      if (w.__failStore === this.name) throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');
      return put.apply(this, args);
    };
  });
}

const failStore = (page: Page, store: string | undefined) =>
  page.evaluate((s) => {
    (window as unknown as { __failStore?: string }).__failStore = s;
  }, store);
const persistCalls = (page: Page) => page.evaluate(() => (window as unknown as { __persistCalls: number }).__persistCalls);

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

async function followAndPlay(page: Page) {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
  await expect.poll(async () => seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00'), { timeout: 10_000 }).toBeGreaterThanOrEqual(2);
  return nowPlaying;
}

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'The storage journeys run at phone size (390×844).');
  await serveFixtures(page);
});

test('a write the browser refuses is named, keeps the words, and is never a silent drop', async ({ page }, info) => {
  await rigStorage(page);
  const nowPlaying = await followAndPlay(page);
  expect(await persistCalls(page), 'nothing is asked on load').toBe(0);

  await failStore(page, 'margins');
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  const label = (await nowPlaying.locator('label[for="margin-text"]').textContent()) ?? '';
  const at = label.replace('Your Margin at ', '');
  await nowPlaying.getByLabel(/Your Margin at/).fill('Keep this one.');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  const problem = page.getByRole('alert');
  await expect(problem).toContainText(`Your Margin at ${at} wasn’t saved. This browser has run out of space for this site.`);
  await shot(page, info, '30-margin-not-saved');
  // The words are still there to save again, and nothing claims it was saved.
  await expect(nowPlaying.getByLabel(/Your Margin at/)).toHaveValue('Keep this one.');
  await expect(page.getByText(/Margin saved at/)).toHaveCount(0);
  expect(await persistCalls(page), 'a failed Margin is not a saved one').toBe(0);

  await failStore(page, undefined);
  await problem.getByRole('button', { name: 'Close' }).click();
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(`Margin saved at ${at}.`)).toBeVisible();
  // Asked once, right after the first saved Margin.
  await expect.poll(() => persistCalls(page)).toBe(1);

  // Your place, saved on every pause: one problem for a run of failures, not one per pause.
  await failStore(page, 'positions');
  for (let i = 0; i < 3; i += 1) {
    await nowPlaying.getByRole('button', { name: 'Pause' }).click();
    await nowPlaying.getByRole('button', { name: 'Play', exact: true }).click();
  }
  await expect(page.getByRole('alert').getByText(`Your place in “${EPISODE_3}” wasn’t saved.`, { exact: false })).toHaveCount(1);
  await failStore(page, undefined);

  // A second Margin doesn't ask again.
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  await nowPlaying.getByLabel(/Your Margin at/).fill('Another.');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(nowPlaying.getByLabel(/Your Margin at/)).toHaveCount(0);
  expect(await persistCalls(page)).toBe(1);

  // The browser said no, so Settings says so, quietly, once.
  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Settings');
  await expect(page.getByTestId('storage-note')).toHaveText(/hasn’t agreed to keep your Margins/);
  await shot(page, info, '31-settings-storage-note');
});

test('Back up all Margins saves one file that opens here and in a fresh browser, and says when', async ({ page, browser, baseURL }, info) => {
  const nowPlaying = await followAndPlay(page);
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  await nowPlaying.getByLabel(/Your Margin at/).fill('Back me up.');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByRole('status').getByText(/Margin saved at/)).toBeVisible();
  // A voice Margin with no words: no packet can carry it, so the backup keeps its audio alongside.
  await nowPlaying.getByRole('button', { name: 'Record a Margin' }).click();
  await expect(nowPlaying.getByRole('status').filter({ hasText: 'Recording' })).toBeVisible();
  await page.waitForTimeout(1200);
  await nowPlaying.getByRole('button', { name: 'Stop', exact: true }).click();
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Voice Margin saved at .* It has no words/)).toBeVisible();
  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();

  await tab(page, 'Settings');
  await expect(page.getByTestId('last-backup')).toHaveText('Not backed up yet.');
  const downloading = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Back up all Margins' }).click();
  const download = await downloading;
  const fileName = download.suggestedFilename();
  expect(fileName).toMatch(/^Spoken-Margins-backup-\d{4}-\d{2}-\d{2}\.zip$/);
  const filePath = `${SHOTS_DIR}/storage-${fileName}`;
  await download.saveAs(filePath);
  await expect(page.getByRole('status')).toContainText(`Backed up 1 Margin from 1 episode as ${fileName}. 1 voice Margin has no words`);
  await expect(page.getByTestId('last-backup')).toHaveText(/^Last backed up .+\.$/);
  await shot(page, info, '32-backed-up');

  // What's in it: the episode's packet, which the packet reader (the iPhone app's rules) opens, and the audio.
  const bytes = new Uint8Array(readFileSync(filePath));
  const paths = listZip(bytes).map((e) => e.path);
  expect(paths).toHaveLength(2);
  expect(paths[1]).toMatch(/^Voice Margins without words\/.+ at \d+-\d\d\.m4a$/);
  const entries = await readZip(bytes, { totalBytes: Infinity, compressionRatio: Infinity, entryBytes: () => Infinity });
  const packet = await readPacket(entries.get(paths[0] as string) as Uint8Array);
  expect(packet.episode.title).toBe(EPISODE_3);
  expect(packet.margins.map((m) => m.text)).toEqual(['Back me up.']);

  // Opened again in the same browser, it adds nothing twice.
  await tab(page, 'Margins');
  await page.getByTestId('margin-file').setInputFiles(filePath);
  await expect(page.getByText(`Every Margin in this file is already here, on “${EPISODE_3}”.`)).toBeVisible();
  await page.getByRole('dialog', { name: EPISODE_3 }).getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(page.getByRole('button', { name: /Back me up\./ })).toHaveCount(1);

  // A browser whose storage was cleared gets the Margin back from the backup.
  const fresh = await browser.newContext({ baseURL, viewport: { width: 390, height: 844 }, hasTouch: true, serviceWorkers: 'block' });
  const freshPage = await fresh.newPage();
  await serveFixtures(freshPage);
  await freshPage.goto('./#margins');
  await freshPage.getByTestId('margin-file').setInputFiles(filePath);
  await expect(freshPage.getByText(new RegExp(`Opened 1 Margin .*${EPISODE_3}`))).toBeVisible();
  await freshPage.getByRole('dialog', { name: EPISODE_3 }).getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(freshPage.getByRole('button', { name: /Back me up\./ })).toBeVisible();
  await shot(freshPage, info, '33-restored');
  await fresh.close();
});
