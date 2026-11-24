// The Margins search box (#4427 PR 2): it finds a Margin by its text or author, opens every group that matches, keeps
// the taps made while searching apart from the listener's own folding, and says so when nothing matches. Phone size,
// against the repo's feed fixture, with five groups so the ones after the first start folded.
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Runs at phone size (390×844).');
  await serveFixtures(page);
});

/**
 * Five groups, newest first: Episode 1 (one Margin), Episode 2 (three Margins: "turnip soup", one by "Sam Example", a plain
 * one), Episode 3, and two on episodes no longer in the Library. No group title holds "turnip" or "Sam".
 */
async function seedFiveGroups(page: Page): Promise<void> {
  await page.evaluate(
    () =>
      new Promise<void>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const read = open.result.transaction('episodes').objectStore('episodes').getAll() as IDBRequest<Array<{ id: string; title: string }>>;
          read.onsuccess = () => {
            const idOf = (prefix: string) => read.result.find((e) => e.title.startsWith(prefix))!.id;
            const margin = (id: string, episodeId: string, at: number, day: number, text: string, author?: string) => ({
              id,
              episodeId,
              atSeconds: at,
              createdAt: `2026-11-${day}T10:00:00Z`,
              text,
              ...(author ? { author } : {}),
            });
            const ep2 = idOf('Episode 2');
            const all = [
              margin('a0', idOf('Episode 1'), 10, 14, 'Margin number 0'),
              margin('b0', ep2, 10, 13, 'Add a turnip soup here'),
              margin('b1', ep2, 20, 13, 'A pause worth keeping', 'Sam Example'),
              margin('b2', ep2, 30, 13, 'Nothing special'),
              margin('c0', idOf('Episode 3'), 10, 12, 'Margin number 3'),
              margin('d0', 'gone-1', 10, 11, 'Margin number 4'),
              margin('e0', 'gone-2', 10, 10, 'Margin number 5'),
            ];
            const tx = open.result.transaction('margins', 'readwrite');
            for (const m of all) tx.objectStore('margins').put(m);
            tx.oncomplete = () => resolve();
            tx.onerror = () => reject(tx.error);
          };
        };
        open.onerror = () => reject(open.error);
      }),
  );
}

test('a Margins search opens the groups that match, keeps its own folds apart, and clearing restores the earlier ones', async ({ page }, info) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(`${FEED_ORIGIN}/enclosure-only-episodes.rss`);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following .*episode/)).toBeVisible();
  await seedFiveGroups(page);
  await page.reload();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' }).click();

  const toggles = page.locator('.margin-group-toggle');
  await expect(toggles).toHaveCount(5);
  const search = page.getByRole('searchbox', { name: 'Search your Margins' });
  // Nothing is said about matches before anyone searches.
  await expect(page.getByRole('status').filter({ hasText: 'match' })).toHaveCount(0);
  await shot(page, info, '4427-margins-search-1-empty');

  // 1. The listener's own folding: group 2 open, group 1 shut.
  await toggles.nth(1).click();
  await toggles.first().click();
  await expect(toggles.nth(1)).toHaveAttribute('aria-expanded', 'true');
  await expect(toggles.first()).toHaveAttribute('aria-expanded', 'false');

  // 2. A search by text: only that group, open, "1 of 3 Margins".
  await search.fill('TURNIP');
  await expect(toggles).toHaveCount(1);
  await expect(toggles.first()).toContainText('1 of 3 Margins');
  await expect(toggles.first()).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByText('Add a turnip soup here')).toBeVisible();
  await expect(page.getByText('A pause worth keeping')).toHaveCount(0);
  await expect(page.getByRole('status').filter({ hasText: 'match' })).toHaveText('1 Margin matches.');
  await shot(page, info, '4427-margins-search-2-filtered');

  // 3. A tap while searching folds the group.
  await toggles.first().click();
  await expect(toggles.first()).toHaveAttribute('aria-expanded', 'false');

  // 4. Another search keeps that tap (it lasts until the query is cleared): the author's Margin is there once opened.
  await search.fill('sam example');
  await expect(toggles).toHaveCount(1);
  await expect(toggles.first()).toContainText('1 of 3 Margins');
  await expect(toggles.first()).toHaveAttribute('aria-expanded', 'false');
  await toggles.first().click();
  await expect(page.getByText('A pause worth keeping')).toBeVisible();
  await expect(page.getByText('Add a turnip soup here')).toHaveCount(0);

  // 5. A group's episode title shows all its Margins.
  await search.fill('episode 2');
  await expect(toggles).toHaveCount(1);
  await expect(toggles.first()).toContainText('3 Margins');
  await expect(toggles.first()).not.toContainText(' of ');
  await expect(page.getByText('Nothing special')).toBeVisible();

  // 6. Nothing matches: said at once.
  await search.fill('zzzz');
  await expect(page.getByRole('status').filter({ hasText: 'Nothing in your Margins matches' })).toHaveText('Nothing in your Margins matches “zzzz”.');
  await expect(toggles).toHaveCount(0);
  await shot(page, info, '4427-margins-search-3-no-match');

  // 7. Clearing brings back the folding from step 1; the fold in step 3 didn't leak.
  await page.getByRole('button', { name: 'Clear search' }).click();
  await expect(toggles).toHaveCount(5);
  await expect(toggles.nth(1)).toHaveAttribute('aria-expanded', 'true');
  await expect(toggles.first()).toHaveAttribute('aria-expanded', 'false');
  await expect(page.getByText('Nothing special')).toBeVisible();

  // 8. Offline, a search still filters: it runs on what the browser holds.
  await page.context().setOffline(true);
  await search.fill('turnip');
  await expect(toggles).toHaveCount(1);
  await page.context().setOffline(false);
});
