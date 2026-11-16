// The Library's search box (#4422): it filters as you type, matches by title, show and accents, says so when nothing
// matches, and clearing it brings every item back. Phone size, against the repo's feed fixture.
import { expect, test } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Runs at phone size (390×844).');
  await serveFixtures(page);
});

test('the Library search filters the list as you type, and clearing it brings everything back', async ({ page }, info) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(`${FEED_ORIGIN}/enclosure-only-episodes.rss`);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following .*episode/)).toBeVisible();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click();

  const list = page.getByRole('list', { name: 'Episodes, newest first' });
  // Nothing is said about matches before anyone searches.
  await expect(page.getByRole('status').filter({ hasText: 'matches' })).toHaveCount(0);
  const all = await list.getByRole('listitem').count();
  expect(all).toBeGreaterThan(1);

  const search = page.getByRole('searchbox', { name: 'Search the Library' });
  await shot(page, info, 'library-search-1-empty');
  await search.fill('EPISODE 3');
  await expect(list.getByRole('listitem')).toHaveCount(1);
  await expect(list).toContainText('Episode 3');
  await shot(page, info, 'library-search-2-filtered');

  await search.fill('no such episode');
  await expect(page.getByRole('status').filter({ hasText: 'Nothing in the Library matches' })).toBeVisible();

  await page.getByRole('button', { name: 'Clear search' }).click();
  await expect(search).toHaveValue('');
  await expect(search).toBeFocused();
  await expect(list.getByRole('listitem')).toHaveCount(all);
});
