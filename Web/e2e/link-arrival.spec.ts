// The page a share link opens (#2168, slice 4 of #3247), against the local link stub (e2e/link-stub-server.ts), which
// holds the shared test vector's key. What a friend does: tap the link, see who sent it and what it is, tap Play,
// hear the episode, see the countdown to the sender's Margin and a Skip, and hear the Margin. Run at a laptop size,
// at a Pixel (Android Chrome's user agent, touch and screen) and at an iPhone-sized window. The network log is the
// privacy evidence: the key and the Margins' words never leave the browser.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { devices, expect, test, type BrowserContext, type Page, type Request } from '@playwright/test';
import { readPacket } from '../src/packet/read.ts';
import { listZip } from '../src/packet/zip.ts';
import { seconds, serveAudio, serveFixtures, shot } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const LINK = `${STUB}/l/vectorvoice01#${KEY}`;
const EPISODE = 'Episode 1 (example episode)';
const WRITTEN = 'A written Margin at half a minute.';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'These journeys open their own contexts: laptop, Android and iPhone-sized.');
});

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);

async function friendPage(context: BrowserContext): Promise<Page> {
  const page = await context.newPage();
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  return page;
}

/** Every request the page makes, with its address, method, body and headers, to check what leaves the browser. */
function networkLog(page: Page): Request[] {
  const seen: Request[] = [];
  page.on('request', (request) => seen.push(request));
  return seen;
}

function assertNothingPlainLeft(log: Request[]): void {
  const stub = log.filter((r) => r.url().startsWith(STUB));
  // The server is asked for the sealed packet, by id, with a plain GET; the app's own files are the rest.
  const asked = stub.filter((r) => /\/l\/[^/]+\/(packet|preview)$/.test(new URL(r.url()).pathname));
  expect(asked.map((r) => new URL(r.url()).pathname)).toEqual(['/l/vectorvoice01/packet']);
  for (const request of log) {
    const where = `${request.method()} ${request.url()}`;
    expect(request.method(), where).toBe('GET');
    expect(request.postData(), where).toBeNull();
    expect(request.url(), where).not.toContain(KEY);
    expect(request.url(), where).not.toContain(KEY.slice(0, 12));
    for (const [name, value] of Object.entries(request.headers())) {
      expect(`${name}: ${value}`, where).not.toContain(KEY.slice(0, 12));
      expect(`${name}: ${value}`, where).not.toContain('half a minute');
    }
  }
}

async function journey(page: Page, info: { project: { name: string } } & Parameters<typeof shot>[1], label: string): Promise<void> {
  const log = networkLog(page);
  await page.goto(LINK);

  // 1. The link opens on who sent it, what it is, and one Play. Nothing plays yet.
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByText('From Web fixture')).toBeVisible();
  await expect(arrival.getByRole('heading', { name: EPISODE })).toBeVisible();
  await expect(arrival.getByText('2 Margins', { exact: false })).toBeVisible();
  // One of the two Margins is written, so "Margin" is explained in its second version (2026-11-02 call).
  await expect(arrival.getByText('A Margin is a note Web fixture left at a moment in this episode. You’ll hear each one there.')).toBeVisible();
  await expect(arrival.getByText('Starts at the beginning. Web fixture’s Margins play when the episode reaches them.')).toBeVisible();
  // One app link, to the join guide; nobody is told to ask for an invite (2026-11-09 call, #3783).
  await expect(arrival.getByRole('link', { name: 'Get Spoken Margins for iPhone' })).toHaveAttribute('href', 'https://spokenmargins.com/join');
  await expect(arrival.getByText('for an invite', { exact: false })).toHaveCount(0);
  await expect(arrival.getByRole('link', { name: 'Report this link' })).toHaveAttribute('href', new RegExp(`/l/vectorvoice01\\?report$`));
  const play = arrival.getByRole('button', { name: 'Play' });
  const box = await play.boundingBox();
  expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
  await shot(page, info as never, `${label}-1-arrival`);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);

  // 2. One tap on Play: the episode plays from the beginning, with the countdown and Skip on screen.
  await play.click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(0.3);
  expect(await audioTime(page)).toBeLessThan(10);
  const cue = playing.getByTestId('margin-cue');
  await expect(cue).toContainText('Web fixture’s first Margin in');
  await shot(page, info as never, `${label}-2-playing`);

  // 3. Skip lands inside the lead-in (20 s before the Margin at 0:30); the second Skip goes to the Margin.
  await cue.getByRole('button', { name: 'Skip to just before Web fixture' }).click();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(9.5);
  expect(await audioTime(page)).toBeLessThan(15);
  await expect(cue.getByTestId('margin-cue-clock')).toHaveText(/^0:\d\d$/);
  await shot(page, info as never, `${label}-3-lead-in`);
  await cue.getByRole('button', { name: 'Skip to Web fixture now' }).click();

  // 4. The Margin plays in place: its card says who and which, and the words show while the voice reads them.
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture wrote this');
  await expect(arrived).toContainText('1 of 2');
  await expect(arrived).toContainText(WRITTEN);
  await shot(page, info as never, `${label}-4-margin`);
  expect(seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00')).toBeGreaterThanOrEqual(29);

  // 5. The key and the words never left the browser: one plain GET for sealed bytes, and nothing else carries them.
  assertNothingPlainLeft(log);
  expect(page.url()).not.toContain(KEY);
}

test('saving a Margin on a friend\u2019s item says what Share does with it, until the next friend Margin plays (2026-11-06)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.getByLabel(/Your Margin at/).fill('My answer.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  // The sentence sits on top of the countdown, so Skip stays after the listener's own Margin (#4092).
  const card = playing.getByTestId('margin-cue');
  await expect(card).toContainText('Your Margin is saved. Share sends it to Web fixture. You pick which of your Margins go.');
  await expect(card.getByTestId('margin-cue-clock')).toHaveText(/^0:\d\d$/);
  await expect(card).toContainText('Web fixture\u2019s first Margin in');
  const skipBefore = await audioTime(page);
  await card.getByRole('button', { name: /^Skip to (just before )?Web fixture/ }).click();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(skipBefore);
  // Back near the start, so the friend's Margin at 0:30 does not fire early while the rest of this test runs.
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 1; });
  // #3784: the Margin just written starts ticked, so Save is not greyed out with no reason, and saving says what to do next.
  const reply = playing.locator('.reply-back');
  await expect(reply.getByRole('checkbox', { name: /My answer\./ })).toBeChecked();
  const save = playing.getByRole('button', { name: 'Save as a file' });
  await expect(save).toBeEnabled();
  await expect(playing.getByText(/Tick at least one Margin/)).toHaveCount(0);
  await reply.getByRole('checkbox', { name: /My answer\./ }).uncheck();
  await expect(save).toBeDisabled();
  await expect(playing.getByRole('status').filter({ hasText: 'Tick at least one Margin above to send it.' })).toBeVisible();
  await expect(save).toHaveAttribute('aria-describedby', 'share-why-not');
  await reply.getByRole('checkbox', { name: /My answer\./ }).check();
  const downloading = page.waitForEvent('download');
  await save.click();
  expect((await downloading).suggestedFilename()).toMatch(/\.spokenmargins$/);
  await expect(page.getByText(/Saved 1 Margin as .*\. Send this file to Web fixture in a message\./)).toBeVisible();
  // The instruction stays on the panel after the toast is gone.
  await expect(playing.locator('#share-why-not')).toHaveText('Send this file to Web fixture in a message.');
  // Playing on to the friend's Margin (0:30) clears it. Move the clock to just before it rather than sitting through
  // half a minute of real playback, which used up the whole 45 s test budget on a slow hosted runner.
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 28; });
  await expect(playing.getByTestId('arrived-margin')).toContainText('Web fixture wrote this', { timeout: 30_000 });
  await expect(playing.getByText('Your Margin is saved.')).toHaveCount(0);
  await context.close();
});

test('the reply list has one Select all / Select none button, and none for a single row (#4093)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  const write = async (words: string) => {
    await playing.getByRole('button', { name: 'Write a Margin' }).click();
    await playing.getByLabel(/Your Margin at/).fill(words);
    await playing.getByRole('button', { name: 'Save Margin' }).click();
  };
  await write('First answer.');
  const reply = playing.locator('.reply-back');
  await expect(reply.getByRole('checkbox', { name: /First answer\./ })).toBeChecked();
  // One row is one tap either way: no button.
  await expect(reply.getByRole('button')).toHaveCount(0);
  await write('Second answer.');
  // Two rows, both ticked (made since the page opened): the button offers to untick them.
  const toggle = reply.getByRole('button', { name: 'Select none' });
  await expect(toggle).toBeVisible();
  const save = playing.getByRole('button', { name: 'Save as a file' });
  await toggle.click();
  await expect(reply.getByRole('checkbox', { checked: true })).toHaveCount(0);
  await expect(save).toBeDisabled();
  await expect(playing.getByRole('status').filter({ hasText: 'Tick at least one Margin above to send it.' })).toBeVisible();
  // Select all ticks every row again; unticking one turns the label back.
  await reply.getByRole('button', { name: 'Select all' }).click();
  await expect(reply.getByRole('checkbox', { checked: true })).toHaveCount(2);
  await expect(save).toBeEnabled();
  await reply.getByRole('checkbox', { name: /Second answer\./ }).uncheck();
  await expect(reply.getByRole('button', { name: 'Select all' })).toBeVisible();
  await context.close();
});

test('the name typed in Share goes on the file, is kept for next time, and a blank one signs nothing (#4107)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  const openShare = async () => {
    await page.goto(LINK);
    await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
    return page.getByRole('dialog', { name: EPISODE });
  };
  const savedFile = async (playing: Page) => {
    const downloading = page.waitForEvent('download');
    await playing.getByRole('button', { name: 'Save as a file' }).click();
    return readPacket(new Uint8Array(readFileSync((await (await downloading).path()) as string)));
  };
  let playing = await openShare();
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.getByLabel(/Your Margin at/).fill('My answer.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  // The field is empty and says who it is for and where the name is kept.
  const name = playing.getByLabel('Your name (optional)');
  await expect(name).toHaveValue('');
  await expect(playing.locator('#share-name-hint')).toHaveText('So Web fixture knows who these are from. Kept in this browser.');
  await expect((await savedFile(playing)).sender).toBeUndefined();
  // Typed once, it signs the file.
  await name.fill('  Sam ');
  expect((await savedFile(playing)).sender).toBe('Sam');
  // And it is there the next time, in a fresh page of the same browser.
  await page.reload();
  playing = await openShare();
  await expect(playing.getByLabel('Your name (optional)')).toHaveValue('Sam');
  // Clearing it signs nothing again. A Margin from before this page opened starts unticked, so tick it.
  await playing.getByRole('checkbox', { name: /My answer\./ }).check();
  await playing.getByLabel('Your name (optional)').fill('');
  await playing.getByLabel('Your name (optional)').blur();
  expect((await savedFile(playing)).sender).toBeUndefined();
  await context.close();
});

/** The file Save as a file just wrote, read back: the Margins it carries and whether it has the reply artifact. */
async function savedPacket(page: Page, playing: Page | ReturnType<Page['getByRole']>) {
  const downloading = page.waitForEvent('download');
  await playing.getByRole('button', { name: 'Save as a file' }).click();
  const bytes = new Uint8Array(readFileSync((await (await downloading).path()) as string));
  return { read: await readPacket(bytes), paths: listZip(bytes).map((e) => e.path) };
}
const CONVERSATION = 'artifacts/margin-conversation.json';
const FRIEND_FIRST = /^packet:[0-9a-f]{64}:margin-0001$/;
const FRIEND_SECOND = /^packet:[0-9a-f]{64}:margin-0002$/;

test('a Margin written while a friend’s shows answers it: the row says so, the file carries the link, and × makes it independent (#4107, B4)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  // Nothing has played yet, so a Margin now answers nothing: no row.
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await expect(playing.locator('.reply-row')).toHaveCount(0);
  await playing.getByRole('button', { name: 'Cancel' }).click();
  // The friend's written Margin (0:30) comes up. Write a Margin while it shows.
  // The episode is playing and the countdown is up before the clock is moved, so the seek is not overwritten by the page's own resume.
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 28; });
  await expect(playing.getByTestId('arrived-margin')).toContainText('Web fixture wrote this', { timeout: 30_000 });
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  const row = playing.locator('.reply-row');
  await expect(row).toContainText(`Replying to Web fixture: “${WRITTEN}”`);
  await playing.getByLabel(/Your Margin at/).fill('Agreed, and here is why.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  // Share lists it as a reply, ticked, and nothing else is offered ticked.
  const list = playing.locator('.reply-back');
  const replyBox = list.getByRole('checkbox', { name: /Agreed, and here is why\./ });
  await expect(replyBox).toBeChecked();
  await expect(list.locator('.tag', { hasText: 'Reply' })).toHaveCount(1);
  // A second Margin made inside the window, made independent with the ×: not a reply, and not ticked beside one.
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await expect(row).toContainText('Replying to Web fixture');
  await row.getByRole('button', { name: 'Stop replying' }).click();
  await expect(row).toHaveText(/^Not a reply/);
  await expect(row.getByRole('button', { name: 'Reply to Web fixture' })).toBeVisible();
  await playing.getByLabel(/Your Margin at/).fill('A note of my own.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  await expect(list.getByRole('checkbox', { name: /A note of my own\./ })).not.toBeChecked();
  await expect(list.locator('.tag', { hasText: 'Reply' })).toHaveCount(1);
  // The file carries the one reply, linked to the friend's Margin, and the artifact that links it.
  const saved = await savedPacket(page, playing);
  expect(saved.read.margins.map((m) => m.text)).toEqual(['Agreed, and here is why.']);
  expect(saved.read.margins[0].replyToId).toMatch(FRIEND_FIRST);
  expect(saved.paths).toContain(CONVERSATION);
  await context.close();
});

test('× before saving: the Margin is the listener’s own, the file has no reply artifact, and "Reply to" puts the link back (#4107, B4)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  // The episode is playing and the countdown is up before the clock is moved, so the seek is not overwritten by the page's own resume.
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 28; });
  await expect(playing.getByTestId('arrived-margin')).toContainText('Web fixture wrote this', { timeout: 30_000 });
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  const row = playing.locator('.reply-row');
  await row.getByRole('button', { name: 'Stop replying' }).click();
  await playing.getByLabel(/Your Margin at/).fill('Not an answer.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  // With no reply in the list, a Margin made since the page opened still starts ticked (#3784).
  await expect(playing.locator('.reply-back').getByRole('checkbox', { name: /Not an answer\./ })).toBeChecked();
  await expect(playing.locator('.reply-back .tag')).toHaveCount(0);
  const saved = await savedPacket(page, playing);
  expect(saved.read.margins.map((m) => m.text)).toEqual(['Not an answer.']);
  expect(saved.read.margins[0].replyToId).toBeUndefined();
  expect(saved.paths).not.toContain(CONVERSATION);
  // Put the link back before saving: the Margin is a reply again.
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await row.getByRole('button', { name: 'Stop replying' }).click();
  await row.getByRole('button', { name: 'Reply to Web fixture' }).click();
  await expect(row).toContainText('Replying to Web fixture');
  await playing.getByLabel(/Your Margin at/).fill('An answer after all.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  const again = await savedPacket(page, playing);
  expect(again.read.margins.map((m) => m.text)).toEqual(['An answer after all.']);
  expect(again.read.margins[0].replyToId).toMatch(FRIEND_FIRST);
  await context.close();
});

test('Record stops the friend’s clip so the microphone does not hear it, names whom it answers, and "Write it instead" keeps the reply (#4107, B4)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  // A browser that will not give the microphone: the case where "Write it instead" is offered. (The bundled Chromium
  // records WebM, which a voice Margin cannot be saved from; the saved-voice path is phone-voice-margin's.)
  await context.addInitScript(() => {
    Object.defineProperty(navigator.mediaDevices, 'getUserMedia', {
      configurable: true,
      value: () => Promise.reject(new DOMException('Permission denied', 'NotAllowedError')),
    });
  });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  // The friend's spoken Margin (2:05) is playing: the card says so, and the episode waits for the clip.
  // The episode is playing and the countdown is up before the clock is moved, so the seek is not overwritten by the page's own resume.
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 124; });
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture is speaking', { timeout: 30_000 });
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);
  await playing.getByRole('button', { name: 'Record a Margin' }).click();
  // The clip is cut so the microphone does not record it: its card is gone, as if it had ended, and the Margin is still on the list.
  await expect(arrived).toHaveCount(0);
  const row = playing.locator('.reply-row');
  await expect(row).toContainText('Replying to Web fixture: “This is a web Margin, recorded for the packet test.”');
  await expect(playing.getByRole('listitem').filter({ hasText: 'This is a web Margin' })).toHaveCount(1);
  await expect(playing.getByRole('alert')).toContainText('Recording didn’t start');
  // × in the problem view is kept through "Write it instead", and so is the reply itself.
  await row.getByRole('button', { name: 'Stop replying' }).click();
  await expect(row).toHaveText(/^Not a reply/);
  await row.getByRole('button', { name: 'Reply to Web fixture' }).click();
  await expect(row).toContainText('Replying to Web fixture');
  await playing.getByRole('button', { name: 'Write it instead' }).click();
  await expect(row).toContainText('Replying to Web fixture: “This is a web Margin, recorded for the packet test.”');
  // The episode, which the clip had paused, carries on.
  await expect.poll(() => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => !a.paused), { timeout: 10_000 }).toBe(true);
  await playing.getByLabel(/Your Margin at/).fill('Typed instead.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  const saved = await savedPacket(page, playing);
  expect(saved.read.margins.map((m) => m.text)).toEqual(['Typed instead.']);
  expect(saved.read.margins[0].replyToId).toMatch(FRIEND_SECOND);
  expect(saved.paths).toContain(CONVERSATION);
  await context.close();
});

/** Opens the link, waits for the friend's written Margin (0:30) to show, and writes `words` while it does: a saved reply. */
async function saveReply(page: Page, words: string): Promise<Page> {
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  // The episode is playing and the countdown is up before the clock is moved, so the seek is not overwritten by the page's own resume.
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 28; });
  await expect(playing.getByTestId('arrived-margin')).toContainText('Web fixture wrote this', { timeout: 30_000 });
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.getByLabel(/Your Margin at/).fill(words);
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  return playing;
}

test('a saved reply says whom it answers; "Stop replying" takes it out of the file and "Reply to" puts it back (#4107, B5)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  const playing = await saveReply(page, 'Agreed, and here is why.');
  const mine = playing.locator('li.margin').filter({ hasText: 'Agreed, and here is why.' });
  await expect(mine).toContainText('Reply to Web fixture’s Margin at 0:30');
  expect(await mine.getByRole('button').first().getAttribute('aria-label')).toContain('Reply to Web fixture’s Margin at 0:30');
  expect((await savedPacket(page, playing)).read.margins[0].replyToId).toMatch(FRIEND_FIRST);
  // While a composer is open the row's button waits, so it can't change a Margin under the composer's own copy.
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await expect(mine.getByRole('button', { name: 'Stop replying' })).toBeDisabled();
  await playing.getByRole('button', { name: 'Cancel' }).click();
  // Stop replying: the row says so, and the file carries the Margin as the listener's own, with no reply artifact.
  const stop = mine.getByRole('button', { name: 'Stop replying' });
  expect((await stop.boundingBox())?.height).toBeGreaterThanOrEqual(44);
  await stop.click();
  await expect(mine).toContainText('Not a reply');
  await expect(mine).not.toContainText('Reply to Web fixture’s Margin');
  const stopped = await savedPacket(page, playing);
  expect(stopped.read.margins.map((m) => m.text)).toEqual(['Agreed, and here is why.']);
  expect(stopped.read.margins[0].replyToId).toBeUndefined();
  expect(stopped.paths).not.toContain(CONVERSATION);
  // It stays stopped after a reload (the link is kept on the stored Margin, not in the page), and the Margins tab can put it back.
  await page.reload();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' }).click();
  const inTab = page.locator('li.margin').filter({ hasText: 'Agreed, and here is why.' });
  await expect(inTab).toContainText('Not a reply');
  await inTab.getByRole('button', { name: 'Reply to Web fixture', exact: true }).click();
  await expect(inTab).toContainText('Reply to Web fixture’s Margin at 0:30');
  await expect(inTab.getByRole('button', { name: 'Stop replying' })).toBeVisible();
  await context.close();
});

test('a Margin saved after × is "Not a reply" in its row, with a way back (#4107, B5)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 28; });
  await expect(playing.getByTestId('arrived-margin')).toContainText('Web fixture wrote this', { timeout: 30_000 });
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.locator('.reply-row').getByRole('button', { name: 'Stop replying' }).click();
  await playing.getByLabel(/Your Margin at/).fill('A note of my own.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  const mine = playing.locator('li.margin').filter({ hasText: 'A note of my own.' });
  await expect(mine).toContainText('Not a reply');
  await mine.getByRole('button', { name: 'Reply to Web fixture', exact: true }).click();
  await expect(mine).toContainText('Reply to Web fixture’s Margin at 0:30');
  expect((await savedPacket(page, playing)).read.margins[0].replyToId).toMatch(FRIEND_FIRST);
  // And the Margins tab says the same.
  await playing.getByRole('button', { name: 'Close Now Playing' }).click();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' }).click();
  await expect(page.locator('li.margin').filter({ hasText: 'A note of my own.' })).toContainText('Reply to Web fixture’s Margin at 0:30');
  await expect(page.locator('li.margin').filter({ hasText: 'A note of my own.' }).getByRole('button', { name: 'Stop replying' })).toBeVisible();
  // A friend's row there stays a list to play from: no Reply button.
  await expect(page.getByRole('button', { name: /^Reply to Web fixture’s Margin at/ })).toHaveCount(0);
  await context.close();
});

test('Reply on a friend’s row moves to its moment and opens the composer answering it; the other Reply buttons wait (#4107, B5)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  // No microphone, so the Record composer shows its problem and offers "Write it instead", which keeps the reply.
  await context.addInitScript(() => {
    Object.defineProperty(navigator.mediaDevices, 'getUserMedia', {
      configurable: true,
      value: () => Promise.reject(new DOMException('Permission denied', 'NotAllowedError')),
    });
  });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  // Far from either Margin and not in a reply window: Record would answer nothing. The row's Reply answers the 2:05 one.
  const second = playing.getByRole('button', { name: 'Reply to Web fixture’s Margin at 2:05', exact: true });
  const first = playing.getByRole('button', { name: 'Reply to Web fixture’s Margin at 0:30', exact: true });
  await expect(first).toHaveText('Reply');
  expect((await second.boundingBox())?.height).toBeGreaterThanOrEqual(44);
  await second.click();
  const row = playing.locator('.reply-row');
  await expect(row).toContainText('Replying to Web fixture: “This is a web Margin, recorded for the packet test.”');
  expect(await audioTime(page)).toBeGreaterThanOrEqual(124.5);
  expect(await audioTime(page)).toBeLessThan(131);
  // One composer at a time: the Reply buttons are greyed while it is open.
  await expect(first).toBeDisabled();
  await expect(second).toBeDisabled();
  await playing.getByRole('button', { name: 'Write it instead' }).click();
  await expect(row).toContainText('Replying to Web fixture');
  await playing.getByLabel(/Your Margin at 2:05/).fill('Answering the spoken one.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  await expect(first).toBeEnabled();
  const saved = await savedPacket(page, playing);
  expect(saved.read.margins.map((m) => m.text)).toEqual(['Answering the spoken one.']);
  expect(saved.read.margins[0].replyToId).toMatch(FRIEND_SECOND);
  expect(saved.paths).toContain(CONVERSATION);
  await context.close();
});

test('Play or Pause while the friend’s clip is playing drops the clip and its card, so it stops answering that Margin (#4107, B4)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  // The episode is playing and the countdown is up before the clock is moved, so the seek is not overwritten by the page's own resume.
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 124; });
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture is speaking', { timeout: 30_000 });
  await playing.getByRole('button', { name: 'Play', exact: true }).or(playing.getByRole('button', { name: 'Pause', exact: true })).click();
  // The clip is cut and the card goes with it; nothing is left that a later Margin could be taken to answer.
  await expect(arrived).toHaveCount(0);
  await context.close();
});

test('a browser that refuses the share sheet: Send goes, Save as a file stays, and the listener reads the next step, not "Permission denied" (#4095)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  // Chrome on Android refuses a share that runs after the tap has gone stale; stand in for it.
  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'canShare', { configurable: true, value: () => true });
    Object.defineProperty(navigator, 'share', {
      configurable: true,
      value: () => Promise.reject(Object.assign(new Error('Permission denied'), { name: 'NotAllowedError' })),
    });
  });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.getByLabel(/Your Margin at/).fill('My answer.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  await expect(playing.getByTestId('margin-cue')).toContainText('Your Margin is saved.');
  const send = playing.getByRole('button', { name: 'Send', exact: true });
  await expect(send).toBeEnabled();
  await send.click();
  const next = 'This browser wouldn\u2019t open its share sheet. Tap Save as a file, then send the file to Web fixture in a message.';
  await expect(playing.locator('#share-why-not')).toHaveText(next);
  await expect(page.getByText('Permission denied')).toHaveCount(0);
  await expect(page.getByText(/weren\u2019t shared/)).toHaveCount(0);
  await expect(send).toHaveCount(0);
  await expect(playing.getByRole('button', { name: 'Save as a file' })).toBeEnabled();
  await context.close();
});

test('after the last Margin has been heard, the card stops saying the sender is speaking and the cue says it was the last (#3797)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture\u2019s first Margin in');
  // Just before the second Margin (spoken, at 2:05), rather than sitting through two minutes of playback.
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 124; });
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture is speaking', { timeout: 30_000 });
  await expect(arrived).toContainText('2 of 2');
  // The clip ends: nothing is speaking any more, and the cue is the one the app shows after a last Margin.
  await expect(arrived).toHaveCount(0, { timeout: 30_000 });
  await expect(playing.getByText('is speaking')).toHaveCount(0);
  await expect(playing.getByTestId('margin-cue')).toContainText('That was Web fixture\u2019s last Margin.');
  await context.close();
});

test('on a laptop: the link opens on its page, Play starts the episode, Skip reaches Cole’s Margin', async ({ browser }, info) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await journey(page, info, 'laptop');
  await context.close();
});

test('on an Android phone: the same link, the same journey', async ({ browser }, info) => {
  const context = await browser.newContext({ ...devices['Pixel 7'], serviceWorkers: 'block' });
  const page = await friendPage(context);
  expect(await page.evaluate(() => navigator.userAgent)).toContain('Android');
  await journey(page, info, 'android');
  await context.close();
});

test('a link that can’t open says what happened and one thing to do, in the same words for every cause', async ({ browser }, info) => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, serviceWorkers: 'block' });
  const page = await friendPage(context);
  const failed = page.getByTestId('arrival-failed');
  const wrongKey = `${KEY.slice(0, -2)}${KEY.endsWith('AA') ? 'BA' : 'AA'}`;
  const cases: Array<[string, string, string]> = [
    ['an expired link', `${STUB}/l/expired00001#${KEY}`, 'This link has expired.'],
    ['a link the server never made', `${STUB}/l/00000000000000000000000000000000#${KEY}`, 'This link has expired.'],
    ['links switched off', `${STUB}/l/switchedoff1#${KEY}`, 'Links are switched off for now.'],
    ['a link with its key cut off', `${STUB}/l/vectorvoice01#${KEY.slice(0, 20)}`, 'This link is cut off.'],
    ['a link with no key', `${STUB}/l/vectorvoice01`, 'This link is cut off.'],
    ['a link with the wrong key', `${STUB}/l/vectorvoice01#${wrongKey}`, 'This link is cut off.'],
    ['a file that opens under the key but is not a packet', `${STUB}/l/AbCdEf123456#${KEY}`, 'This file couldn’t be opened.'],
  ];
  for (const [name, address, headline] of cases) {
    await page.goto(address);
    await expect(failed.getByRole('heading'), name).toContainText(headline);
    // Nothing raw, and no way to play something that didn't open.
    await expect(page.getByText(/not_found|disabled|\{"error"/), name).toHaveCount(0);
    await expect(failed.getByRole('button'), name).toHaveCount(0);
  }
  await page.goto(`${STUB}/l/switchedoff1#${KEY}`);
  await expect(failed).toContainText('Ask your friend to send the Margins as a file.');
  await expect(failed).not.toContainText('Try again');
  await shot(page, info, 'link-off');
  await context.close();
});

test('when the episode can’t load: one problem toast, one sentence, and a button that plays the sender’s Margins without it (#3356)', async ({ browser }, info) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await context.newPage();
  await serveFixtures(page);
  // The enclosure answers 404, as a dead or geo-blocked episode address does.
  await page.route('https://example.com/podcast/**', (route) => route.fulfill({ status: 404, body: 'Not found', headers: { 'content-type': 'text/html' } }));
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();

  const playing = page.getByRole('dialog', { name: EPISODE });
  const cue = playing.getByTestId('margin-cue');
  await expect(playing).toBeVisible();
  // The card is the one sentence: no toast beside it, however the audio element's error and the rejected play() arrive.
  await expect(cue).toContainText('This episode can’t play here');
  await page.waitForTimeout(1500);
  await expect(page.locator('.toast-problem')).toHaveCount(0);
  await expect(page.getByText('couldn’t be loaded')).toHaveCount(0);
  await expect(page.getByText('This episode can’t play here', { exact: false })).toHaveCount(1);
  // The element really is failed, and the card says so in a sentence, with no countdown and no Skip.
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.error !== null && a.currentTime === 0)).toBe(true);
  await expect(cue).toContainText('This episode can’t play here, but you can still hear Web fixture’s Margins.');
  await expect(cue.getByTestId('margin-cue-clock')).toHaveCount(0);
  await expect(cue.getByRole('button', { name: /Skip/ })).toHaveCount(0);
  await shot(page, info, 'episode-failed-offer');

  // One tap plays the Margins in order, with the episode's clock still at 0.
  await cue.getByRole('button', { name: 'Hear Web fixture’s Margins' }).click();
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture wrote this');
  await expect(arrived).toContainText('1 of 2');
  await expect(arrived).toContainText(WRITTEN);
  await shot(page, info, 'episode-failed-margin-1');
  await expect(arrived).toContainText('Web fixture is speaking', { timeout: 30_000 });
  await expect(arrived).toContainText('2 of 2');
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime)).toBe(0);
  // When the last one ends, no countdown comes back.
  await expect(cue).toContainText('That was Web fixture’s last Margin', { timeout: 30_000 });
  await expect(cue.getByTestId('margin-cue-clock')).toHaveCount(0);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime)).toBe(0);
  await expect(page.locator('.toast-problem')).toHaveCount(0);
  await context.close();
});

test('when the episode can’t load and the browser refuses a clip that starts later, that Margin waits for a tap and the rest follow (#3356)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  // The first voice clip the page starts on its own is refused as iPhone Safari refuses one not started by a tap.
  await context.addInitScript(() => {
    const play = HTMLMediaElement.prototype.play;
    let refused = false;
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      if (!refused && !this.hasAttribute('data-testid')) {
        refused = true;
        return Promise.reject(new DOMException('refused', 'NotAllowedError'));
      }
      return play.call(this);
    };
  });
  const page = await context.newPage();
  await serveFixtures(page);
  await page.route('https://example.com/podcast/**', (route) => route.fulfill({ status: 404, body: 'Not found', headers: { 'content-type': 'text/html' } }));
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await playing.getByTestId('margin-cue').getByRole('button', { name: 'Hear Web fixture’s Margins' }).click();
  const arrived = playing.getByTestId('arrived-margin');
  // The voice Margin (2 of 2) is not skipped: it stays, with a Play, until the listener taps.
  await expect(arrived).toContainText('2 of 2', { timeout: 30_000 });
  await arrived.getByRole('button', { name: /Play Web fixture’s Margin/ }).click();
  await expect(playing.getByTestId('margin-cue')).toContainText('That was Web fixture’s last Margin', { timeout: 30_000 });
  await context.close();
});

test('star two of four Margins and Share starts only those ticked and writes only those; the stars stay after a reload (#4172)', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });
  const page = await friendPage(context);
  await page.goto(LINK);
  await page.getByTestId('arrival').getByRole('button', { name: 'Play' }).click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing.getByTestId('margin-cue')).toContainText('Web fixture’s first Margin in');
  // Four Margins before the friend's first one at 0:30, so none answers it: the list is "others", and stars decide.
  for (const words of ['First note.', 'Second note.', 'Third note.', 'Fourth note.']) {
    await playing.getByRole('button', { name: 'Write a Margin' }).click();
    await playing.getByLabel(/Your Margin at/).fill(words);
    await playing.getByRole('button', { name: 'Save Margin' }).click();
    await expect(playing.locator('li.margin').filter({ hasText: words })).toBeVisible();
  }
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => { a.currentTime = 1; });
  const row = (words: string) => playing.locator('li.margin').filter({ hasText: words });
  // The friend's own Margin has no star; every Margin of the listener's has one, the last control on the row.
  await expect(playing.getByRole('button', { name: 'Star for sharing' })).toHaveCount(4);
  const star = row('Second note.').getByRole('button', { name: 'Star for sharing' });
  expect((await star.boundingBox())?.height).toBeGreaterThanOrEqual(44);
  await expect(star).toHaveAttribute('aria-pressed', 'false');
  await star.click();
  await expect(star).toHaveAttribute('aria-pressed', 'true');
  await row('Fourth note.').getByRole('button', { name: 'Star for sharing' }).click();
  await expect(row('Second note.').getByRole('button', { name: /^Play from/ })).toHaveAccessibleName(/Starred/);
  // The reply list starts with the starred two ticked and the others not.
  const list = playing.locator('.reply-back');
  await expect(list.getByRole('checkbox', { checked: true })).toHaveCount(2);
  await expect(list.getByRole('checkbox', { name: /Second note\./ })).toBeChecked();
  await expect(list.getByRole('checkbox', { name: /Fourth note\./ })).toBeChecked();
  await expect(list.getByRole('checkbox', { name: /First note\./ })).not.toBeChecked();
  await expect(list.getByRole('checkbox', { name: /Third note\./ })).not.toBeChecked();
  const sent = await savedPacket(page, playing);
  expect(sent.read.margins.map((m) => m.text)).toEqual(['Second note.', 'Fourth note.']);
  // A star is not in the file at all.
  expect(JSON.stringify(sent.paths)).not.toContain('star');
  // Stars are kept with the Margin: a fresh page of the same browser still has them, and a tap clears one.
  await page.reload();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' }).click();
  const inTab = page.locator('li.margin').filter({ hasText: 'Second note.' });
  await expect(inTab.getByRole('button', { name: 'Star for sharing' })).toHaveAttribute('aria-pressed', 'true');
  await expect(inTab).toContainText('Starred');
  await inTab.getByRole('button', { name: 'Star for sharing' }).click();
  await expect(inTab.getByRole('button', { name: 'Star for sharing' })).toHaveAttribute('aria-pressed', 'false');
  await expect(inTab).not.toContainText('Starred');
  await context.close();
});
