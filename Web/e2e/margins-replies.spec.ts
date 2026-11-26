// A friend's reply sits under the Margin it answers on the Margins screen (#4174, Design 2026-11-13, PR 3). Her packet
// is written by the real writer, so the reply names her Margin the way a real reply does; the Margins she shared are
// stored with `sharedAs`, as the share path stores them.
import { expect, test, type Page } from '@playwright/test';
import type { Episode, Margin } from '../src/shared/model.ts';
import { writePacket } from '../src/packet/write.ts';
import { packetMarginId } from '../src/packet/read.ts';
import { withSharedAs } from '../src/app/logic/shared-as.ts';
import { serveFixtures, shot } from './fixtures.ts';

const TITLE = 'The tide tables, explained';
const episode: Episode = {
  id: 'her-episode',
  showId: 'her-show',
  title: TITLE,
  guid: 'tide-guid',
  audioUrl: 'https://media.example.com/tide-tables.mp3',
  audioOrigin: 'podcast-enclosure',
  durationSeconds: 180,
};
const hers: Margin[] = [
  { id: 'her-a', episodeId: episode.id, atSeconds: 30, createdAt: '2026-11-12T10:00:00Z', text: 'The tide bit.' },
  { id: 'her-b', episodeId: episode.id, atSeconds: 60, createdAt: '2026-11-12T10:01:00Z', text: 'And the moon.' },
];

/** Cole's reply to her second Margin, as a file; and her Margins stamped as the share path stamps them. */
async function replyAndStamped(): Promise<{ file: { name: string; buffer: Buffer }; stamped: Margin[] }> {
  const sent = await writePacket(episode, hers, { sender: 'Her' });
  const stamped = withSharedAs(sent, hers);
  const parent = packetMarginId(sent.contentDigest, 'margin-0002');
  const reply: Margin = { id: 'cole-1', episodeId: episode.id, atSeconds: 60, createdAt: '2026-11-13T09:00:00Z', text: 'Yes, the moon is why.', replyToId: parent };
  const written = await writePacket(episode, [reply], { sender: 'Cole' });
  return { file: { name: written.fileName, buffer: Buffer.from(written.bytes) }, stamped };
}

async function openFile(page: Page, file: { name: string; buffer: Buffer }): Promise<void> {
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Open a Margin file' }).click();
  await (await choosing).setFiles(file);
  await expect(page.getByRole('dialog', { name: TITLE })).toBeVisible();
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
}

async function storeMargins(page: Page, margins: Margin[]): Promise<void> {
  await page.evaluate(
    (rows) =>
      new Promise<void>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const episodeId = (open.result.transaction('episodes').objectStore('episodes').getAll() as IDBRequest<Array<{ id: string }>>);
          episodeId.onsuccess = () => {
            const id = episodeId.result[0].id;
            const tx = open.result.transaction('margins', 'readwrite');
            for (const row of rows) tx.objectStore('margins').put({ ...row, episodeId: id });
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
          };
        };
        open.onerror = () => reject(open.error);
      }),
    margins,
  );
}

const tab = (page: Page, name: string) => page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();

test.beforeEach(async ({ page }) => {
  await serveFixtures(page);
});

test('in the browser she shared from, Cole’s reply sits under her Margin and says which', async ({ page }, info) => {
  const { file, stamped } = await replyAndStamped();
  await page.goto('./');
  await tab(page, 'Margins');
  await openFile(page, file);
  await storeMargins(page, hers.map((m) => stamped.find((s) => s.id === m.id) ?? m));
  await page.reload();
  await tab(page, 'Margins');
  const rows = page.locator('.margin-list > li');
  await expect(rows).toHaveCount(3);
  await expect(rows.nth(0)).toContainText('The tide bit.');
  await expect(rows.nth(1)).toContainText('And the moon.');
  await expect(rows.nth(2)).toContainText('Reply to your Margin at 1:00');
  await expect(rows.nth(2)).toContainText('Yes, the moon is why.');
  await expect(rows.nth(2)).toHaveClass(/is-reply/);
  await expect(rows.nth(1)).not.toHaveClass(/is-reply/);
  await expect(page.getByRole('button', { name: /^Reply to your Margin at 1:00\. Play from 1:00/ })).toBeVisible();
  await shot(page, info, '4174-margins-threaded');
});

test('in a fresh browser, the same reply says this browser can’t find the Margin it answers', async ({ page }, info) => {
  const { file } = await replyAndStamped();
  await page.goto('./');
  await tab(page, 'Margins');
  await openFile(page, file);
  const rows = page.locator('.margin-list > li');
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Reply to a Margin this browser can’t find');
  await expect(rows.first()).not.toHaveClass(/is-reply/);
  await shot(page, info, '4174-margins-cant-find');
});
