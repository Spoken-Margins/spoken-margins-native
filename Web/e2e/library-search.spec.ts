// The Library's search box (#4422): it filters as you type, matches by title, show and accents, says so when nothing
// matches, and clearing it brings every item back. Phone size, against the repo's feed fixture.
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
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

// The one query rule (#4427 PR 2): a query lasts across tab switches, ends on a reload, and ends when something new
// comes in, a friend's file or a followed show, so the new thing is never hidden behind an old search.
const WEB_VOICE = fileURLToPath(new URL('../../Contracts/fixtures/web-packets/web-voice.spokenmargins', import.meta.url));
const tab = (page: Page, name: string) => page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name });

async function followFeed(page: Page): Promise<void> {
  await tab(page, 'Following').click();
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(`${FEED_ORIGIN}/enclosure-only-episodes.rss`);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following .*episode/)).toBeVisible();
}

/** Opens the friend's packet from the Library, then closes Now Playing. */
async function openFriendsFile(page: Page): Promise<void> {
  await tab(page, 'Library').click();
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Open a Margin file' }).click();
  await (await choosing).setFiles(WEB_VOICE);
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(page.getByRole('button', { name: 'Close Now Playing' })).toHaveCount(0);
}

test('the Library says how many episodes match once typing pauses, and a query is kept across tabs and ends on a reload', async ({ page }) => {
  await page.goto('./#library');
  await openFriendsFile(page);
  await followFeed(page);
  await tab(page, 'Library').click();

  const library = page.getByRole('searchbox', { name: 'Search the Library' });
  await library.fill('EPISODE 3');
  // `toHaveText` waits for the count, which is set a moment after the last letter.
  await expect(page.getByRole('status').filter({ hasText: 'match' })).toHaveText('1 episode matches.');

  await tab(page, 'Margins').click();
  const margins = page.getByRole('searchbox', { name: 'Search your Margins' });
  await margins.fill('zzzz');
  await tab(page, 'Library').click();
  await expect(library).toHaveValue('EPISODE 3');
  await expect(page.getByRole('list', { name: 'Episodes, newest first' }).getByRole('listitem')).toHaveCount(1);
  await tab(page, 'Margins').click();
  await expect(margins).toHaveValue('zzzz');

  await page.reload();
  await tab(page, 'Margins').click();
  await expect(margins).toHaveValue('');
  await tab(page, 'Library').click();
  await expect(library).toHaveValue('');
});

test('opening a friend’s file clears the Library search', async ({ page }) => {
  await page.goto('./#following');
  await followFeed(page);
  await tab(page, 'Library').click();
  const library = page.getByRole('searchbox', { name: 'Search the Library' });
  await library.fill('episode 3');
  await expect(library).toHaveValue('episode 3');
  await openFriendsFile(page);
  await expect(library).toHaveValue('');
});

test('following a show clears the Library search, and its episodes show', async ({ page }) => {
  await page.goto('./#library');
  await openFriendsFile(page);
  const library = page.getByRole('searchbox', { name: 'Search the Library' });
  await library.fill('zzzz');
  await expect(page.getByRole('status').filter({ hasText: 'Nothing in the Library matches' })).toBeVisible();
  await followFeed(page);
  await tab(page, 'Library').click();
  await expect(library).toHaveValue('');
  await expect(page.getByRole('list', { name: 'Episodes, newest first' })).toContainText('Episode 3');
});
