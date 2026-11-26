// Margins grouped under their media title, each group a button that folds its Margins away (#4423). Four groups, so
// a long list opens on the newest group only; a tap on another title opens it, and a tap on the open one folds it.
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Runs at phone size (390×844).');
  await serveFixtures(page);
});

/** One written Margin on each stored episode (the feed fixture has three) and one on an episode no longer in the Library: four groups, the newest first. */
async function marginOnFourEpisodes(page: Page): Promise<void> {
  await page.evaluate(
    () =>
      new Promise<void>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const read = open.result.transaction('episodes').objectStore('episodes').getAll() as IDBRequest<Array<{ id: string }>>;
          read.onsuccess = () => {
            const tx = open.result.transaction('margins', 'readwrite');
            [...read.result.slice(0, 3).map((e) => e.id), 'gone'].forEach((episodeId, i) => {
              tx.objectStore('margins').put({ id: `m${i}`, episodeId, atSeconds: 10, createdAt: `2026-11-1${4 - i}T10:00:00Z`, text: `Margin number ${i}` });
            });
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
          };
        };
        open.onerror = () => reject(open.error);
      }),
  );
}

test('a long Margins list opens on the newest group, and a group’s title opens and folds it', async ({ page }, info) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(`${FEED_ORIGIN}/enclosure-only-episodes.rss`);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following .*episode/)).toBeVisible();
  await marginOnFourEpisodes(page);
  await page.reload();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' }).click();

  const toggles = page.locator('.margin-group-toggle');
  await expect(toggles).toHaveCount(4);
  await expect(toggles.first()).toHaveAttribute('aria-expanded', 'true');
  await expect(toggles.first()).toContainText('1 Margin');
  await expect(toggles.nth(1)).toHaveAttribute('aria-expanded', 'false');
  await expect(page.getByText('Margin number 0')).toBeVisible();
  await expect(page.getByText('Margin number 1')).toBeHidden();
  await shot(page, info, '4423-margins-collapsed');

  await toggles.nth(1).click();
  await expect(toggles.nth(1)).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByText('Margin number 1')).toBeVisible();
  await shot(page, info, '4423-margins-opened');

  await toggles.first().click();
  await expect(page.getByText('Margin number 0')).toBeHidden();
  await expect(page.getByText('Margin number 1')).toBeVisible();
});
