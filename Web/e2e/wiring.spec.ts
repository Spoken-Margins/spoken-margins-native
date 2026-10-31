// The wired web app end to end (#2979), at phone size only: the real sources and packet modules behind the UI,
// with every network answer served from the repo's fixtures. Each test is one listener journey.
import { readFileSync } from 'node:fs';
import { expect, test, type Page, type Request } from '@playwright/test';
import { MESSAGES } from '../src/app/logic/messages.ts';
import { readPacket } from '../src/packet/read.ts';
import { FEED_ORIGIN, SHOTS_DIR, feedFixture, seconds, serveAudio, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const EPISODE_3 = 'Episode 3: No link, GUID and audio';
const RELAY = 'https://relay.test';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'The wiring journeys run at phone size (390×844).');
  await serveFixtures(page);
});

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

async function elapsed(page: Page): Promise<number> {
  return seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00');
}

async function follow(page: Page, address: string) {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(address);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
}

/** Counts every request to the relay, so a journey can show none was made before the listener said yes. */
function countRelay(page: Page): Request[] {
  const calls: Request[] = [];
  page.on('request', (request) => {
    if (request.url().startsWith(RELAY)) calls.push(request);
  });
  return calls;
}

test('follow, play, write and record Margins, export them, and open the file in a fresh profile at the Margin’s moment', async ({ page, browser, baseURL }, info) => {
  const relayCalls = countRelay(page);
  await follow(page, FEED);
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(3);

  // A written Margin, anchored where the listener tapped.
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  const label = await nowPlaying.locator('label[for="margin-text"]').textContent();
  const writtenAt = seconds(label?.replace('Your Margin at ', '') ?? '0:00');
  await nowPlaying.getByLabel(/Your Margin at/).fill('The tide bit is the one to send Sam.');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Margin saved at/)).toBeVisible();
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(writtenAt + 2);

  // A voice Margin with words, so it can travel in the file.
  await nowPlaying.getByRole('button', { name: 'Record a Margin' }).click();
  await expect(nowPlaying.getByRole('status').filter({ hasText: 'Recording' })).toBeVisible();
  await page.waitForTimeout(1500);
  await nowPlaying.getByRole('button', { name: 'Stop', exact: true }).click();
  await nowPlaying.getByLabel(/Words to go with your voice Margin at/).fill('Listen to the tide bit again.');
  await shot(page, info, '20-voice-words');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Voice Margin saved at [\d:]+\.$/)).toBeVisible();

  // Export: a real `.spokenmargins` file, which the packet reader (the iPhone app's rules) opens.
  const downloading = page.waitForEvent('download');
  await nowPlaying.getByRole('button', { name: 'Save as a file' }).click();
  const download = await downloading;
  const fileName = download.suggestedFilename();
  expect(fileName).toMatch(/\.spokenmargins$/);
  const filePath = `${SHOTS_DIR}/wiring-${fileName}`;
  await download.saveAs(filePath);
  await expect(page.getByText(new RegExp(`Saved .* as ${fileName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`))).toBeVisible();
  await shot(page, info, '21-exported');

  const bytes = new Uint8Array(readFileSync(filePath));
  const packet = await readPacket(bytes, { fileName });
  expect(packet.episode.title).toBe(EPISODE_3);
  expect(packet.margins).toHaveLength(2);
  const written = packet.margins.find((m) => !m.voice);
  const voice = packet.margins.find((m) => m.voice);
  expect(written?.text).toBe('The tide bit is the one to send Sam.');
  // The label shows whole seconds; the Margin keeps the exact moment.
  expect(Math.floor(written?.atSeconds ?? -1)).toBe(writtenAt);
  expect(voice?.voice?.mimeType).toBe('audio/mp4');
  expect(voice?.voice?.blob.size).toBeGreaterThan(0);
  expect(voice?.text).toBe('Listen to the tide bit again.');
  expect(relayCalls).toHaveLength(0);

  // A friend with an empty Library opens the file: the episode arrives under the sender, and Now Playing
  // lands on the first Margin's moment.
  const friend = await browser.newContext({ baseURL, viewport: { width: 390, height: 844 }, hasTouch: true, serviceWorkers: 'block' });
  const friendPage = await friend.newPage();
  await serveFixtures(friendPage);
  await friendPage.goto('./#margins');
  await expect(friendPage.getByText(/A friend’s Margins arrive as a file/)).toBeVisible();
  await friendPage.getByTestId('margin-file').setInputFiles(filePath);
  await expect(friendPage.getByText(new RegExp(`Opened 2 Margins .*${EPISODE_3}`))).toBeVisible();
  const friendPlaying = friendPage.getByRole('dialog', { name: EPISODE_3 });
  await expect(friendPlaying).toBeVisible();
  const audioTime = () => friendPage.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
  await expect.poll(audioTime, { timeout: 10_000 }).toBeGreaterThanOrEqual(writtenAt - 0.5);
  expect(await audioTime()).toBeLessThan(writtenAt + 4);
  await expect(friendPlaying.getByRole('button', { name: /^Play from .*tide bit is the one/ })).toBeVisible();
  await shot(friendPage, info, '22-friend-landed');

  await friendPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(friendPage, 'Margins');
  await expect(friendPage.getByRole('button', { name: /Hear this voice Margin/ })).toBeVisible();
  await tab(friendPage, 'Following');
  await expect(friendPage.getByRole('button', { name: /Open Shared (by|with)/ })).toBeVisible();
  await shot(friendPage, info, '23-friend-following');
  await friend.close();
});

test('a Substack post with only the automatic voice plays it after a tap, reading the page only then', async ({ page }, info) => {
  const POST = 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory';
  const TITLE = 'Leaked Anthropic Draft AI Regulatory Bill Is Unacceptable and Troubling';
  const cors = { 'access-control-allow-origin': '*' };
  const pageReads: string[] = [];
  await page.route('https://thezvi.substack.com/feed', (route) =>
    route.fulfill({ status: 200, body: feedFixture('substack-zvi-generated-voice.rss'), headers: { ...cors, 'content-type': 'application/rss+xml' } }),
  );
  await page.route(`${POST}*`, (route) => {
    pageReads.push(route.request().url());
    return route.fulfill({ status: 200, body: feedFixture('substack-preloads-json-generated-voice-page.html'), headers: { ...cors, 'content-type': 'text/html' } });
  });
  await serveAudio(page, 'https://substack-video.s3.amazonaws.com/**');
  const relayCalls = countRelay(page);

  await follow(page, 'https://thezvi.substack.com/feed');
  await expect(page.getByText(/Following .*1 episode/)).toBeVisible();
  await tab(page, 'Library');
  const row = page.getByRole('button', { name: new RegExp(TITLE) });
  await expect(row).toContainText('voice checked when you play');
  // Following the feed read no post page (owner, 2026-10-21: only on a listener's tap).
  expect(pageReads).toHaveLength(0);
  await shot(page, info, '24-substack-library');

  await row.click();
  const nowPlaying = page.getByRole('dialog', { name: TITLE });
  await expect(nowPlaying).toBeVisible();
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(2);
  expect(pageReads).toHaveLength(1);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentSrc)).toContain('substack-video.s3.amazonaws.com');
  expect(relayCalls).toHaveLength(0);
  await shot(page, info, '25-substack-playing');
});

test('a feed that blocks browsers asks before any relay call, then follows through the relay', async ({ page }, info) => {
  const relayCalls = countRelay(page);
  await page.route(`${RELAY}/**`, (route) =>
    route.fulfill({
      status: 200,
      body: feedFixture('enclosure-only-episodes.rss'),
      headers: {
        'content-type': 'application/rss+xml',
        'access-control-allow-origin': '*',
        'access-control-expose-headers': 'X-Final-URL',
        'x-final-url': 'https://blocked.test/moved/feed.rss',
      },
    }),
  );

  await follow(page, 'https://blocked.test/feed.rss');
  const ask = page.getByRole('dialog', { name: 'Read this feed through our server?' });
  await expect(ask).toBeVisible();
  expect(relayCalls).toHaveLength(0);
  await shot(page, info, '26-relay-ask');

  await ask.getByRole('button', { name: 'Use the server' }).click();
  await expect(page.getByText('Following Spoken Margins Test Show. 3 episodes added to your Library.')).toBeVisible();
  expect(relayCalls).toHaveLength(1);
  const asked = new URL(relayCalls[0]!.url());
  expect(asked.pathname).toBe('/api/v1/relay');
  expect(asked.searchParams.get('url')).toBe('https://blocked.test/feed.rss');

  await tab(page, 'Settings');
  await expect(page.getByRole('switch', { name: /Use the server for feeds that need it/ })).toBeChecked();
});

test.describe('offline', () => {
  test.use({ serviceWorkers: 'allow' });

  test('a followed show and its episodes are still there offline', async ({ page, context }, info) => {
    await follow(page, FEED);
    await expect(page.getByText(/Following Spoken Margins Test Show\./)).toBeVisible();
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.reload();
    await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);

    await context.setOffline(true);
    await page.reload();
    await tab(page, 'Library');
    await expect(page.getByRole('list', { name: 'Episodes, newest first' }).locator('.row-title')).toHaveCount(3);
    await tab(page, 'Following');
    await expect(page.getByRole('button', { name: 'Open Spoken Margins Test Show' })).toBeVisible();
    await shot(page, info, '27-offline-library');
    await context.setOffline(false);
  });
});

test.describe('plain messages', () => {
  test('a file that isn’t a Margin file', async ({ page }, info) => {
    await page.goto('./#margins');
    const picker = page.getByTestId('margin-file');
    await picker.setInputFiles({ name: 'holiday.spokenmargins', mimeType: 'application/octet-stream', buffer: Buffer.from('not a zip at all') });
    await expect(page.getByText('Couldn’t open holiday.spokenmargins. This isn\'t a Spoken Margins file. Margins arrive as a file ending in .spokenmargins.')).toBeVisible();
    await picker.setInputFiles({ name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('hello') });
    await expect(page.getByText(/Couldn’t open notes\.txt\. This isn't a Spoken Margins file\./)).toBeVisible();
    await shot(page, info, '28-bad-file');
  });

  test('a feed that is gone', async ({ page }, info) => {
    await follow(page, `${FEED_ORIGIN}/missing.rss`);
    await expect(page.getByText(MESSAGES.feedGone)).toBeVisible();
    await shot(page, info, '29-dead-feed');
  });

  test('a microphone the browser blocks', async ({ page }, info) => {
    await page.addInitScript(() => {
      navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('Permission denied', 'NotAllowedError'));
    });
    await follow(page, FEED);
    await page.getByRole('button', { name: /Play the newest episode/ }).click();
    const nowPlaying = page.getByRole('dialog', { name: EPISODE_3 });
    await nowPlaying.getByRole('button', { name: 'Record a Margin' }).click();
    await expect(page.getByText(`Recording didn’t start. ${MESSAGES.micBlocked}`)).toBeVisible();
    // Written Margins still work, as the message says, at the same moment.
    await nowPlaying.getByRole('button', { name: 'Write it instead' }).click();
    await expect(nowPlaying.getByLabel(/Your Margin at/)).toBeVisible();
    await nowPlaying.getByLabel(/Your Margin at/).fill('Typed instead.');
    await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
    await expect(page.getByText(/Margin saved at/)).toBeVisible();
    await shot(page, info, '30-mic-blocked');
  });
});
