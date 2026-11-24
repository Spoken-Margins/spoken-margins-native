// The Following search box (#4427 PR 3): a Shows section and an Episodes section, a way into the Follow sheet when
// nothing matches, a query that ends when something new comes in, and a search that works offline. Phone size, against
// the repo's feed fixture. Queries hold no dots, or the Follow sheet would take them for an address.
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

const SHOW = 'Spoken Margins Test Show';
const WEB_VOICE = fileURLToPath(new URL('../../Contracts/fixtures/web-packets/web-voice.spokenmargins', import.meta.url));
const tab = (page: Page, name: string) => page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name });

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Runs at phone size (390×844).');
  await serveFixtures(page);
});

async function followFeed(page: Page): Promise<void> {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(`${FEED_ORIGIN}/enclosure-only-episodes.rss`);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following .*Open it to pick episodes/)).toBeVisible();
}

test('Following search lists matching shows and episodes, and opening either returns to the same results', async ({ page }, info) => {
  await followFeed(page);
  const search = page.getByRole('searchbox', { name: 'Search the shows you follow' });
  await shot(page, info, 'following-search-1-empty');

  // A show's name lists the show, not its episodes.
  await search.fill('test show');
  const shows = page.getByRole('list', { name: 'Shows that match' });
  await expect(shows.getByRole('listitem')).toHaveCount(1);
  await expect(shows).toContainText(SHOW);
  await expect(page.getByRole('heading', { name: 'Episodes' })).toHaveCount(0);
  await expect(page.getByRole('status').filter({ hasText: 'match' })).toHaveText('1 show matches.');

  // An episode's title lists the episode, with its show above it.
  await search.fill('no guid');
  await expect(page.getByRole('heading', { name: 'Shows' })).toHaveCount(0);
  const episodes = page.getByRole('list', { name: 'Episodes that match, newest first' });
  await expect(episodes.getByRole('listitem')).toHaveCount(1);
  await expect(episodes).toContainText('Episode 2: No link, no GUID, audio only');
  await expect(episodes.locator('.row-kicker')).toHaveText(SHOW);
  await shot(page, info, 'following-search-2-episode');

  await episodes.locator('.episode-row').click();
  await expect(page.getByRole('button', { name: 'Close Now Playing' })).toBeVisible();
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(search).toHaveValue('no guid');
  await expect(episodes.getByRole('listitem')).toHaveCount(1);

  // Opening the show from the results and coming back finds them again.
  await search.fill('test show');
  await page.getByRole('button', { name: new RegExp(`^Open ${SHOW}`) }).click();
  await page.locator('.back-button').click();
  await expect(search).toHaveValue('test show');
  await expect(shows.getByRole('listitem')).toHaveCount(1);
  await expect(page.getByRole('button', { name: new RegExp(`^Open ${SHOW}`) })).toBeFocused();

  await page.getByRole('button', { name: 'Clear search' }).click();
  await expect(page.getByRole('list', { name: 'Shows you follow, newest episode first' })).toBeVisible();
});

test('a Following search that finds nothing offers to look for the name in the Follow sheet', async ({ page }, info) => {
  await followFeed(page);
  await page.route('https://itunes.apple.com/search*', (route) => route.fulfill({ json: { resultCount: 0, results: [] } }));
  await page.getByRole('searchbox', { name: 'Search the shows you follow' }).fill('zzzz');
  await expect(page.getByRole('status').filter({ hasText: 'Nothing in the shows you follow matches' })).toHaveText('Nothing in the shows you follow matches “zzzz”.');
  await shot(page, info, 'following-search-3-no-match');

  await page.getByRole('button', { name: 'Look for “zzzz” to follow' }).click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await expect(sheet.getByLabel('Show name, or a feed or Substack address')).toHaveValue('zzzz');
  await expect(sheet.getByText('No shows found for “zzzz”')).toBeVisible();

  // Closing the sheet forgets the name: the next time it opens, its field is empty.
  await sheet.getByRole('button', { name: 'Close' }).click();
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await expect(page.getByLabel('Show name, or a feed or Substack address')).toHaveValue('');
});

test('a name that looks like an address is filled into the Follow sheet and not followed', async ({ page }) => {
  await followFeed(page);
  await page.getByRole('searchbox', { name: 'Search the shows you follow' }).fill('nothing.example/feed');
  await page.getByRole('button', { name: 'Look for “nothing.example/feed” to follow' }).click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await expect(sheet.getByLabel('Show name, or a feed or Substack address')).toHaveValue('nothing.example/feed');
  await expect(sheet.getByRole('button', { name: 'Follow', exact: true })).toBeVisible();
  await expect(sheet.getByText(/No shows found/)).toHaveCount(0);
});

test('opening a friend’s file clears the Following search, and their Shared by show is found', async ({ page }) => {
  await followFeed(page);
  const search = page.getByRole('searchbox', { name: 'Search the shows you follow' });
  await search.fill('test show');
  await expect(search).toHaveValue('test show');

  await tab(page, 'Library').click();
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Open a Margin file' }).click();
  await (await choosing).setFiles(WEB_VOICE);
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(page.getByRole('button', { name: 'Close Now Playing' })).toHaveCount(0);

  await tab(page, 'Following').click();
  await expect(search).toHaveValue('');
  await search.fill('shared by');
  const shows = page.getByRole('list', { name: 'Shows that match' });
  await expect(shows.getByRole('listitem')).toHaveCount(1);
  await expect(shows).toContainText('Shared by');
});

test('Following search still filters offline', async ({ page, context }) => {
  await followFeed(page);
  await context.setOffline(true);
  const search = page.getByRole('searchbox', { name: 'Search the shows you follow' });
  await search.fill('episode 1');
  const episodes = page.getByRole('list', { name: 'Episodes that match, newest first' });
  await expect(episodes.getByRole('listitem')).toHaveCount(1);
  await expect(episodes).toContainText('Episode 1: Has a link');
  await search.fill('zzzz');
  await expect(page.getByRole('button', { name: 'Look for “zzzz” to follow' })).toBeVisible();
});
