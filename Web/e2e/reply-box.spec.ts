// "Send to <sender>" (#4675, Screen B of docs/design/reply-mailbox.md), against the local link stub
// (e2e/link-stub-server.ts), whose `reply*` links carry a reply part and whose box route answers each of the design's
// error rows. A friend opens the link, answers, and sends the answer back through the link; when the box can't take it,
// the file buttons are still there. A link with no reply part keeps today's Share section, and a slow reply fetch never
// holds up the first play.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type BrowserContext, type Page } from '@playwright/test';
import { readPacket } from '../src/packet/read.ts';
import { nowTab, serveAudio, serveFixtures, startFromBeginning } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const EPISODE = 'Episode 1 (example episode)';
const SENDER = 'Web fixture';
const linkTo = (id: string) => `${STUB}/l/${id}#${KEY}`;

const CAPTION = `They go back through this link. Only ${SENDER} can hear them.`;
const TODAY_CAPTION = 'Share them as a file. Your friend opens it in Spoken Margins and hears each one at its moment.';
const SENT = `Sent to ${SENDER}. They’ll get it the next time they open Spoken Margins.`;
const ENDED = `This link can’t take answers any more. Send them to ${SENDER} as a file instead.`;
const TOO_BIG = 'These are too big to send through the link. Untick a long recording, or send them as a file.';
const RETRY = 'Couldn’t send. Check your connection, then try again.';
// Playwright's Chromium can't hand files to a share sheet, so the file button is today's download.
const FILE_BUTTON = 'Save as a file instead';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'These journeys open their own contexts.');
});

async function friendPage(context: BrowserContext): Promise<Page> {
  const page = await context.newPage();
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  return page;
}

const newContext = (browser: import('@playwright/test').Browser) =>
  browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'block' });

/** Opens a link, plays it, and writes one Margin; returns Now Playing. */
async function openAndAnswer(page: Page, id: string, words = 'My answer.') {
  await page.goto(linkTo(id));
  await startFromBeginning(page);
  const playing = page.getByRole('dialog', { name: EPISODE });
  await write(playing, words);
  return playing;
}

async function write(playing: ReturnType<Page['getByRole']>, words: string): Promise<void> {
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await playing.getByLabel(/Your Margin at/).fill(words);
  await playing.getByRole('button', { name: 'Save Margin' }).click();
}

async function postsIn(page: Page, linkId: string): Promise<Uint8Array[]> {
  const { box } = await (await page.request.get(`${STUB}/__stub/reply/${linkId}`)).json();
  const { posts } = await (await page.request.get(`${STUB}/__stub/box/${box}`)).json();
  return (posts as string[]).map((p) => new Uint8Array(Buffer.from(p, 'base64')));
}

test('Send to the sender posts one sealed answer, says Sent, marks the row, and a reopened link keeps the marks (#4675)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const before = (await postsIn(page, 'replyvoice01')).length;
  const playing = await openAndAnswer(page, 'replyvoice01');

  // Screen B: the saved card, the caption, "Send to <sender>" first and the file button under its "instead" name.
  await expect(playing.getByTestId('margin-cue')).toContainText(`Your Margin is saved. Send to ${SENDER} sends it back. You pick which of your Margins go.`);
  await expect(playing.getByText(CAPTION)).toBeVisible();
  await expect(playing.getByText(TODAY_CAPTION)).toHaveCount(0);
  const send = playing.getByRole('button', { name: `Send to ${SENDER}` });
  const file = playing.getByRole('button', { name: FILE_BUTTON });
  await expect(send).toBeEnabled();
  await expect(file).toBeEnabled();
  await expect(playing.getByRole('button', { name: 'Save as a file', exact: true })).toHaveCount(0);
  const row = playing.locator('.reply-back li').filter({ hasText: 'My answer.' });
  await expect(row.getByRole('checkbox')).toBeChecked();

  // A double tap, both clicks before the page can re-render: one post.
  await send.evaluate((button: HTMLButtonElement) => {
    button.click();
    button.click();
  });
  const status = playing.locator('#share-why-not');
  await expect(status).toContainText(SENT);
  await expect(row.locator('.tag', { hasText: 'Sent' })).toBeVisible();
  await expect(row.getByRole('checkbox')).not.toBeChecked();
  await expect(status).toContainText('Everything here has been sent.');
  await expect(send).toBeDisabled();
  // #4671's invitation fires on the first answer that leaves.
  await expect(playing.getByRole('region', { name: 'Get the iPhone app' })).toBeVisible();

  const posts = await postsIn(page, 'replyvoice01');
  expect(posts.length).toBe(before + 1);
  // The answer is the packet a file send writes, so the phone's importer opens it.
  const answer = await readPacket(posts[posts.length - 1]);
  expect(answer.margins.map((m) => m.text)).toEqual(['My answer.']);

  // Reopen the link in the same browser: the Sent mark comes back; a new Margin starts ticked and can go.
  await page.goto(linkTo('replyvoice01'));
  await startFromBeginning(page);
  const again = page.getByRole('dialog', { name: EPISODE });
  const sentRow = again.locator('.reply-back li').filter({ hasText: 'My answer.' });
  await expect(sentRow.locator('.tag', { hasText: 'Sent' })).toBeVisible();
  await expect(sentRow.getByRole('checkbox')).not.toBeChecked();
  await expect(again.locator('#share-why-not')).toHaveText('Everything here has been sent.');
  await write(again, 'A second thought.');
  const secondRow = again.locator('.reply-back li').filter({ hasText: 'A second thought.' });
  await expect(secondRow.getByRole('checkbox')).toBeChecked();
  await expect(secondRow.locator('.tag', { hasText: 'Sent' })).toHaveCount(0);
  await again.getByRole('button', { name: `Send to ${SENDER}` }).click();
  await expect(again.locator('#share-why-not')).toContainText(SENT);
  expect((await postsIn(page, 'replyvoice01')).length).toBe(before + 2);
  await context.close();
});

/** Waits until every settings and Margins write the page already started has landed, so a reload can't cut one off. */
const settleWrites = (page: Page) =>
  page.evaluate(
    () =>
      new Promise<void>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onerror = () => reject(open.error);
        open.onsuccess = () => {
          const tx = open.result.transaction(['settings', 'margins'], 'readwrite');
          tx.oncomplete = () => resolve();
          tx.onerror = () => reject(tx.error);
          tx.onabort = () => reject(tx.error ?? new Error('The write was aborted.'));
        };
      }),
  );

test('a reload of the web app keeps the link’s reply box: the Sent tag, and Send to the sender for a new answer (#5419)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const before = (await postsIn(page, 'replyvoice01')).length;
  const playing = await openAndAnswer(page, 'replyvoice01');
  await playing.getByRole('button', { name: `Send to ${SENDER}` }).click();
  await expect(playing.locator('#share-why-not')).toContainText(SENT);
  await settleWrites(page);

  // A plain reload of the web app's own address, not the link: nothing fetches the reply part again.
  const asked: string[] = [];
  page.on('request', (request) => asked.push(new URL(request.url()).pathname));
  await page.goto(`${STUB}/`);
  await page.reload();
  await page.getByRole('button', { name: new RegExp(EPISODE.replace(/[()]/g, '\\$&')) }).first().click();
  await nowTab(page);
  const again = page.getByRole('dialog', { name: EPISODE });
  const sentRow = again.locator('.reply-back li').filter({ hasText: 'My answer.' });
  await expect(sentRow.locator('.tag', { hasText: 'Sent' })).toBeVisible();
  await expect(again.getByText(CAPTION)).toBeVisible();
  await write(again, 'After the reload.');
  const newRow = again.locator('.reply-back li').filter({ hasText: 'After the reload.' });
  await expect(newRow.getByRole('checkbox')).toBeChecked();
  await again.getByRole('button', { name: `Send to ${SENDER}` }).click();
  await expect(again.locator('#share-why-not')).toContainText(SENT);
  expect(asked.some((path) => path.endsWith('/reply'))).toBe(false);
  const posts = await postsIn(page, 'replyvoice01');
  expect(posts.length).toBe(before + 2);
  expect((await readPacket(posts[posts.length - 1])).margins.map((m) => m.text)).toEqual(['After the reload.']);
  await context.close();
});

test('a box that can’t take answers any more is not kept: after a reload the Share section is today’s (#5419)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const playing = await openAndAnswer(page, 'replyclosed1');
  await playing.getByRole('button', { name: `Send to ${SENDER}` }).click();
  await expect(playing.locator('#share-why-not')).toHaveText(ENDED);
  await settleWrites(page);
  await page.goto(`${STUB}/`);
  await page.reload();
  await page.getByRole('button', { name: new RegExp(EPISODE.replace(/[()]/g, '\\$&')) }).first().click();
  await nowTab(page);
  const again = page.getByRole('dialog', { name: EPISODE });
  await expect(again.getByText(TODAY_CAPTION)).toBeVisible();
  await expect(again.getByRole('button', { name: /^Send to / })).toHaveCount(0);
  await context.close();
});

test('a later link for the same episode with no reply part drops the kept box, before and after a reload (#5419)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const playing = await openAndAnswer(page, 'replyvoice01');
  await expect(playing.getByRole('button', { name: `Send to ${SENDER}` })).toBeEnabled();
  await settleWrites(page);
  // The same episode through a link the server says has no reply part (404): today's section, not the old box.
  await page.goto(linkTo('vectorvoice01'));
  await startFromBeginning(page);
  const fromPlain = page.getByRole('dialog', { name: EPISODE });
  await write(fromPlain, 'Through the plain link.');
  await expect(fromPlain.getByText(TODAY_CAPTION)).toBeVisible();
  await expect(fromPlain.getByRole('button', { name: /^Send to / })).toHaveCount(0);
  await settleWrites(page);
  await page.goto(`${STUB}/`);
  await page.reload();
  await page.getByRole('button', { name: new RegExp(EPISODE.replace(/[()]/g, '\\$&')) }).first().click();
  await nowTab(page);
  const again = page.getByRole('dialog', { name: EPISODE });
  await expect(again.getByText(TODAY_CAPTION)).toBeVisible();
  await expect(again.getByRole('button', { name: /^Send to / })).toHaveCount(0);
  await context.close();
});

/** Makes the stored Margin with these words a reply to a Margin from another packet (another link or file). */
async function replyToAnotherPacket(page: Page, words: string, digest: string): Promise<void> {
  await page.evaluate(
    ({ words, digest }) =>
      new Promise<void>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const tx = open.result.transaction('margins', 'readwrite');
          const all = tx.objectStore('margins').getAll() as IDBRequest<Array<{ text?: string }>>;
          all.onsuccess = () => {
            const row = all.result.find((m) => m.text === words);
            if (!row) return reject(new Error(`no Margin "${words}"`));
            tx.objectStore('margins').put({ ...row, replyToId: `packet:${digest}:interjection-1` });
          };
          tx.oncomplete = () => resolve();
          tx.onerror = () => reject(tx.error);
        };
        open.onerror = () => reject(open.error);
      }),
    { words, digest },
  );
}

test('a reply to another packet’s Margin never goes through the box, so the phone never drops the whole answer (#4675)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const before = (await postsIn(page, 'replyvoice01')).length;
  await openAndAnswer(page, 'replyvoice01', 'A reply elsewhere.');
  await replyToAnotherPacket(page, 'A reply elsewhere.', 'b'.repeat(64));

  await page.goto(linkTo('replyvoice01'));
  await startFromBeginning(page);
  const playing = page.getByRole('dialog', { name: EPISODE });
  await write(playing, 'My answer.');
  const elsewhere = playing.locator('.reply-back li').filter({ hasText: 'A reply elsewhere.' });
  await expect(elsewhere.locator('.tag', { hasText: 'File only' })).toBeVisible();
  await elsewhere.getByRole('checkbox').check();
  const status = playing.locator('#share-why-not');
  await expect(status).toContainText('Replies to Margins from another link or file can’t go through this link. Send those as a file.');

  const send = playing.getByRole('button', { name: `Send to ${SENDER}` });
  await send.click();
  await expect(status).toContainText(SENT);
  const posts = await postsIn(page, 'replyvoice01');
  expect(posts.length).toBe(before + 1);
  const answer = await readPacket(posts[posts.length - 1]);
  expect(answer.margins.map((m) => m.text)).toEqual(['My answer.']);
  // Only what went is marked Sent; the reply elsewhere stays ticked for the file, and Send has nothing left to take.
  await expect(elsewhere.locator('.tag', { hasText: 'Sent' })).toHaveCount(0);
  await expect(elsewhere.getByRole('checkbox')).toBeChecked();
  await expect(send).toBeDisabled();
  await expect(playing.getByRole('button', { name: FILE_BUTTON })).toBeEnabled();
  await context.close();
});

const ERROR_ROWS: Array<[string, string, 'ended' | 'too-big' | 'retry']> = [
  ['replyclosed1', '410 expired_or_removed', 'ended'],
  ['replyfull409', '409 club_full', 'ended'],
  ['replygone404', '404 not_found', 'ended'],
  ['replyfull503', '503 full', 'ended'],
  ['replyoff0503', '503 disabled', 'ended'],
  ['replybig0413', '413 too_large', 'too-big'],
  ['replyrate429', '429 rate_limited', 'retry'],
  ['replybusy503', '503 busy', 'retry'],
];

for (const [id, answer, row] of ERROR_ROWS) {
  test(`a box that answers ${answer}: its line, and the file button still works (#4675)`, async ({ browser }) => {
    const context = await newContext(browser);
    const page = await friendPage(context);
    const playing = await openAndAnswer(page, id);
    await playing.getByRole('button', { name: `Send to ${SENDER}` }).click();
    const status = playing.locator('#share-why-not');
    const file = playing.getByRole('button', { name: FILE_BUTTON });
    if (row === 'ended') {
      await expect(status).toHaveText(ENDED);
      await expect(playing.getByRole('button', { name: `Send to ${SENDER}` })).toHaveCount(0);
      await expect(file).toHaveClass(/button-primary/);
      await expect(file).toBeFocused();
    } else if (row === 'too-big') {
      await expect(status).toHaveText(TOO_BIG);
      await expect(playing.getByRole('button', { name: `Send to ${SENDER}` })).toBeEnabled();
      await expect(file).not.toHaveClass(/button-primary/);
    } else {
      await expect(status).toHaveText(RETRY);
      await expect(playing.getByRole('button', { name: 'Try again' })).toBeEnabled();
    }
    // The friend's Margin is still here, still ticked, and the file button writes the file.
    await expect(playing.locator('.reply-back li').filter({ hasText: 'My answer.' }).getByRole('checkbox')).toBeChecked();
    await expect(playing.locator('.reply-back .tag', { hasText: 'Sent' })).toHaveCount(0);
    await expect(file).toBeEnabled();
    const downloading = page.waitForEvent('download');
    await file.click();
    expect((await downloading).suggestedFilename()).toMatch(/\.spokenmargins$/);
    await context.close();
  });
}

test('offline at Send says "Couldn’t send", and Try again goes once the network is back (#4675)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const playing = await openAndAnswer(page, 'replyretry01');
  // The first try never reaches the server.
  await page.route(`${STUB}/api/v1/clubs/**`, (route) => route.abort('internetdisconnected'));
  await playing.getByRole('button', { name: `Send to ${SENDER}` }).click();
  await expect(playing.locator('#share-why-not')).toHaveText(RETRY);
  await page.unroute(`${STUB}/api/v1/clubs/**`);
  // The second meets the box's one 429, which reads the same; the third goes.
  await playing.getByRole('button', { name: 'Try again' }).click();
  await expect(playing.locator('#share-why-not')).toHaveText(RETRY);
  await playing.getByRole('button', { name: 'Try again' }).click();
  await expect(playing.locator('#share-why-not')).toContainText(SENT);
  expect((await postsIn(page, 'replyretry01')).length).toBe(1);
  await context.close();
});

test('a link with no reply part keeps today’s Share section, word for word (#4675)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const asked: string[] = [];
  page.on('request', (request) => asked.push(new URL(request.url()).pathname));
  const playing = await openAndAnswer(page, 'vectorvoice01');
  await expect(playing.getByText(TODAY_CAPTION)).toBeVisible();
  await expect(playing.getByRole('button', { name: 'Save as a file', exact: true })).toBeEnabled();
  await expect(playing.getByRole('button', { name: /^Send to / })).toHaveCount(0);
  await expect(playing.getByText(CAPTION)).toHaveCount(0);
  await expect(playing.getByTestId('margin-cue')).toContainText(`Your Margin is saved. Share sends it to ${SENDER}. You pick which of your Margins go.`);
  // It asked for the reply part, got none, and posted nothing.
  expect(asked).toContain('/l/vectorvoice01/reply');
  expect(asked.some((path) => path.startsWith('/api/'))).toBe(false);
  await context.close();
});

test('the first play doesn’t wait for a slow reply fetch, and after 5 seconds the section is today’s (#4675)', async ({ browser }) => {
  const context = await newContext(browser);
  const page = await friendPage(context);
  const opened = Date.now();
  await page.goto(linkTo('replyslow001'));
  await startFromBeginning(page);
  const playing = page.getByRole('dialog', { name: EPISODE });
  // The episode plays while the stub is still holding the reply part (it answers after 8 seconds).
  await expect
    .poll(() => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime), { timeout: 10_000 })
    .toBeGreaterThan(0.3);
  // While the fetch is out, the Share section waits rather than drawing one that changes under the friend.
  await expect(playing.getByRole('button', { name: 'Save as a file', exact: true })).toHaveCount(0);
  expect(Date.now() - opened).toBeLessThan(5_000);
  // At the 5-second ceiling it counts as no reply part: today's section.
  await write(playing, 'My answer.');
  await expect(playing.getByText(TODAY_CAPTION)).toBeVisible({ timeout: 8_000 });
  await expect(playing.getByRole('button', { name: 'Save as a file', exact: true })).toBeEnabled();
  await expect(playing.getByRole('button', { name: /^Send to / })).toHaveCount(0);
  await context.close();
});
