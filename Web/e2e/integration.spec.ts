// Seams between pieces that landed in parallel (#2977's integration audit), at phone size: Settings' backup
// (#3012) inside the Android app (#3009), and a backup `.zip` arriving the ways other than the file picker.
import { expect, test, type Page } from '@playwright/test';
import { buildBackup } from '../src/app/logic/backup.ts';
import { episode, show, writtenMargins } from '../src/packet/fixtures.ts';
import { writePacket } from '../src/packet/write.ts';
import type { Episode, Margin } from '../src/shared/model.ts';
import { FEED_ORIGIN, seconds, serveAudio, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const EPISODE_3 = 'Episode 3: No link, GUID and audio';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'The integration journeys run at phone size (390×844).');
  await serveFixtures(page);
});

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

async function writeOneMargin(page: Page, words: string) {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
  await expect.poll(async () => seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00'), { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  await nowPlaying.getByLabel(/Your Margin at/).fill(words);
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByRole('status').getByText(/Margin saved at/)).toBeVisible();
  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
}

/**
 * Turns the page into "inside the Android app" from here on: a stand-in for the bridge Capacitor injects, recording
 * each plugin call. `cancel` makes the share sheet answer as Android does when the listener closes it.
 */
async function becomeAndroidApp(page: Page, { cancel = false } = {}) {
  await page.evaluate((cancelShare) => {
    const w = window as unknown as { __calls: Array<{ plugin: string; method: string; options: Record<string, unknown> }>; Capacitor: unknown };
    w.__calls = [];
    w.Capacitor = {
      isNativePlatform: () => true,
      nativePromise: async (plugin: string, method: string, options: Record<string, unknown>) => {
        w.__calls.push({ plugin, method, options });
        if (plugin === 'Filesystem' && method === 'writeFile') return { uri: `file:///data/cache/${String(options.path)}` };
        if (plugin === 'Share' && method === 'share') {
          if (cancelShare) throw new Error('Share canceled');
          return { activityType: 'com.google.android.apps.docs' };
        }
        throw new Error(`${plugin}.${method} is not in this stand-in`);
      },
    };
  }, cancel);
}

const nativeCalls = (page: Page) =>
  page.evaluate(() => (window as unknown as { __calls: Array<{ plugin: string; method: string; path?: unknown }> }).__calls.map((c) => `${c.plugin}.${c.method}`));

test('inside the Android app, Back up all Margins goes to the share sheet, and a closed sheet backs nothing up', async ({ page }, info) => {
  await writeOneMargin(page, 'Back me up on Android.');
  const downloads: string[] = [];
  page.on('download', (download) => downloads.push(download.suggestedFilename()));

  // The listener closes the share sheet: nothing was saved, so nothing says it was.
  await becomeAndroidApp(page, { cancel: true });
  await tab(page, 'Settings');
  await page.getByRole('button', { name: 'Back up all Margins' }).click();
  await expect.poll(() => nativeCalls(page)).toEqual(['Filesystem.writeFile', 'Share.share']);
  await expect(page.getByTestId('last-backup')).toHaveText('Not backed up yet.');
  await expect(page.getByText(/^Backed up/)).toHaveCount(0);

  // The listener picks a place: the file went through Android, never a blob download the WebView ignores.
  await becomeAndroidApp(page);
  await page.getByRole('button', { name: 'Back up all Margins' }).click();
  await expect(page.getByRole('status')).toContainText(/Backed up 1 Margin from 1 episode as .+\.spokenmargins\./);
  expect(await nativeCalls(page)).toEqual(['Filesystem.writeFile', 'Share.share']);
  const written = await page.evaluate(() => (window as unknown as { __calls: Array<{ options: { path?: string } }> }).__calls[0]?.options.path);
  expect(written).toMatch(/^packets\/.+\.spokenmargins$/);
  await expect(page.getByTestId('last-backup')).toHaveText(/^Last backed up .+\.$/);
  expect(downloads).toEqual([]);
  await shot(page, info, '40-android-backup');
});

test.describe('installed app', () => {
  test.use({ serviceWorkers: 'allow' });

  test('a backup .zip shared to the installed app opens every packet in it', async ({ page, request }, info) => {
    await serveAudio(page, 'https://example.com/**');
    // A Settings backup of two episodes, written by the app's own backup and packet code.
    const second: Episode = {
      ...episode,
      id: 'episode-two',
      title: 'Episode 2',
      guid: 'example-episode-guid-2',
      pageUrl: 'https://example.com/podcast/episode-2',
      audioUrl: 'https://example.com/podcast/episode-2.mp3',
    };
    const two: Margin = { id: 'b1', episodeId: second.id, atSeconds: 4, createdAt: '2026-10-30T11:00:00Z', text: 'From the second episode.' };
    const backup = await buildBackup({ episodes: [episode, second], shows: [show], margins: [...writtenMargins(), two] }, async (ep, margins, sh) => {
      const w = await writePacket(ep, margins, sh ? { show: sh, sender: 'Sam' } : { sender: 'Sam' });
      return { bytes: w.bytes, fileName: w.fileName, mimeType: w.mimeType, included: w.included };
    });
    expect(backup.file?.name).toMatch(/\.zip$/);

    const { share_target: share } = await (await request.get('./manifest.webmanifest')).json();
    await page.goto('./');
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.reload();
    await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);

    // Shared the way Android shares to an installed web app: a POST to the manifest's action.
    const landedAt = await page.evaluate(
      async ({ action, field, name, bytes }) => {
        const form = new FormData();
        form.append(field, new File([new Uint8Array(bytes)], name, { type: 'application/zip' }));
        return (await fetch(action, { method: 'POST', body: form })).url;
      },
      { action: share.action as string, field: share.params.files[0].name as string, name: backup.file!.name, bytes: Array.from(backup.file!.bytes) },
    );
    await page.goto(landedAt);
    await expect(page.getByText('Opened 1 Margin from Sam on “Episode 2”.')).toBeVisible();
    await expect(page.getByRole('alert')).toHaveCount(0);
    await page.getByRole('button', { name: 'Close Now Playing' }).click();
    await tab(page, 'Margins');
    for (const words of ['A written Margin from the web, 1:05 in.', 'Another at ten minutes.', 'From the second episode.']) {
      await expect(page.getByRole('button', { name: new RegExp(words.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')) })).toBeVisible();
    }
    await shot(page, info, '41-shared-backup');
  });
});
