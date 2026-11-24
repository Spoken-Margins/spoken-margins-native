// Removing an item from the web Library, with Undo (#4424 PR 2). Nothing is deleted: removing writes an "out" membership
// row, Undo writes the old row back, the episode, its place and its Margins stay, and the item is still on its show's
// screen with Add. Phone size, against the repo's feed fixture. Captures go to artifacts/ (fixtures only).
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, followAndAdd, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const SHOW = 'Spoken Margins Test Show';
const EP3 = 'Episode 3: No link, GUID and audio';
const EP2 = 'Episode 2: No link, no GUID, audio only';
const EP1 = 'Episode 1: Has a link';
const WEB_VOICE = fileURLToPath(new URL('../../Contracts/fixtures/web-packets/web-voice.spokenmargins', import.meta.url));

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Runs at phone size (390×844).');
  await serveFixtures(page);
});

const tab = (page: Page, name: string) => page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
const libraryTitles = (page: Page) => page.getByRole('list', { name: 'Episodes, newest first' }).locator('.row-title');
const more = (page: Page, title: string) => page.getByRole('button', { name: `More for ${title}`, exact: true });
const addButton = (page: Page, title: string) => page.getByRole('button', { name: `Add ${title} to your Library`, exact: true });
const sheet = (page: Page, title: string) => page.getByRole('dialog', { name: title });

async function follow(page: Page): Promise<void> {
  await page.goto('./');
  await tab(page, 'Following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  const followSheet = page.getByRole('dialog', { name: 'Follow a show' });
  await followSheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await followSheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following .*Open it to pick episodes/)).toBeVisible();
}

/** Follows the fixture show and adds these episodes, then opens the Library. */
async function libraryWith(page: Page, titles: string[]): Promise<void> {
  await follow(page);
  await followAndAdd(page, SHOW, titles);
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveCount(titles.length);
}

async function removeFromRow(page: Page, title: string): Promise<void> {
  await more(page, title).click();
  await sheet(page, title).getByRole('button', { name: 'Remove from Library' }).click();
  await expect(sheet(page, title)).toHaveCount(0);
}

const removedToast = (title: string) => `Removed “${title}” from your Library.`;

test('1. Remove, then Undo: the row comes back in its place', async ({ page }, info) => {
  await libraryWith(page, [EP3, EP2, EP1]);
  await shot(page, info, '4424-1-library-more');
  await more(page, EP2).click();
  await expect(sheet(page, EP2).getByRole('button', { name: 'Remove from Library' })).toBeFocused();
  await shot(page, info, '4424-2-remove-sheet');

  // Cancel changes nothing and returns focus to the row's ⋯.
  await sheet(page, EP2).getByRole('button', { name: 'Cancel' }).click();
  await expect(sheet(page, EP2)).toHaveCount(0);
  await expect(libraryTitles(page)).toHaveText([EP3, EP2, EP1]);
  await expect(more(page, EP2)).toBeFocused();

  await removeFromRow(page, EP2);
  await expect(libraryTitles(page)).toHaveText([EP3, EP1]);
  await expect(page.getByText(removedToast(EP2), { exact: true })).toBeVisible();
  await shot(page, info, '4424-3-removed-toast');

  await page.getByRole('button', { name: 'Undo' }).click();
  await expect(page.getByText(`“${EP2}” is back in your Library.`)).toBeVisible();
  await expect(libraryTitles(page)).toHaveText([EP3, EP2, EP1]);
  await page.reload();
  await expect(libraryTitles(page)).toHaveText([EP3, EP2, EP1]);
});

test('2. Remove and let the toast go: still out after a reload, and on its show with Add', async ({ page }) => {
  await libraryWith(page, [EP3, EP2]);
  await removeFromRow(page, EP3);
  await expect(page.getByText(removedToast(EP3), { exact: true })).toBeVisible();
  // The pointer rests where Remove was tapped, which can sit over the toast, and a hovered toast waits.
  await page.mouse.move(0, 0);
  // An Undo toast stays ten seconds; the ceiling is only a limit.
  await expect(page.getByText(removedToast(EP3), { exact: true })).toHaveCount(0, { timeout: 20_000 });
  await page.reload();
  await expect(libraryTitles(page)).toHaveText([EP2]);
  await tab(page, 'Following');
  await page.getByRole('button', { name: `Open ${SHOW}` }).click();
  await expect(addButton(page, EP3)).toBeVisible();
});

test('3. An item with a Margin: the toast says the Margins stay, and the Margins tab still has them', async ({ page }) => {
  await follow(page);
  await tab(page, 'Library');
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Open a Margin file' }).click();
  await (await choosing).setFiles(WEB_VOICE);
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(page.getByRole('button', { name: 'Close Now Playing' })).toHaveCount(0);
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveCount(1);
  const title = (await libraryTitles(page).first().textContent()) ?? '';
  await tab(page, 'Margins');
  const margins = page.locator('main');
  const before = await margins.innerText();

  await tab(page, 'Library');
  await removeFromRow(page, title);
  await expect(page.getByText(`${removedToast(title)} Its Margins stay in the Margins tab.`, { exact: true })).toBeVisible();
  await expect(libraryTitles(page)).toHaveCount(0);
  await tab(page, 'Margins');
  expect(await margins.innerText()).toBe(before);
});

test('4. Removing the playing item keeps it playing, and tapping its show row puts it back', async ({ page }) => {
  await libraryWith(page, [EP3, EP2]);
  await page.locator('.episode-row', { hasText: EP3 }).click();
  await expect(page.getByRole('dialog', { name: EP3 })).toBeVisible();
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(page.locator('.mini-player')).toContainText(EP3);

  await removeFromRow(page, EP3);
  await expect(libraryTitles(page)).toHaveText([EP2]);
  await expect(page.locator('.mini-player')).toContainText(EP3);
  await expect(page.locator('.mini-player').getByRole('button', { name: 'Pause' })).toBeVisible();

  await tab(page, 'Following');
  await page.getByRole('button', { name: `Open ${SHOW}` }).click();
  await page.getByRole('button', { name: /^Episode 3:/ }).click();
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveText([EP3, EP2]);
});

test('5. Two removes, then Undo: the second comes back', async ({ page }) => {
  await libraryWith(page, [EP3, EP2, EP1]);
  await removeFromRow(page, EP3);
  await removeFromRow(page, EP2);
  await expect(libraryTitles(page)).toHaveText([EP1]);
  // Only the newest toast shows.
  await expect(page.getByRole('button', { name: 'Undo' })).toHaveCount(1);
  await page.getByRole('button', { name: 'Undo' }).click();
  await expect(libraryTitles(page)).toHaveText([EP2, EP1]);
});

test('6. Keyboard only: ⋯, Enter, Remove, Enter, and focus lands on the next row’s ⋯', async ({ page }) => {
  await libraryWith(page, [EP3, EP2, EP1]);
  await page.locator('.episode-row', { hasText: EP3 }).focus();
  await page.keyboard.press('Tab');
  await expect(more(page, EP3)).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(sheet(page, EP3).getByRole('button', { name: 'Remove from Library' })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(libraryTitles(page)).toHaveText([EP2, EP1]);
  await expect(more(page, EP2)).toBeFocused();

  // Escape closes the sheet with no change.
  await page.keyboard.press('Enter');
  await expect(sheet(page, EP2)).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(sheet(page, EP2)).toHaveCount(0);
  await expect(libraryTitles(page)).toHaveText([EP2, EP1]);
  await expect(more(page, EP2)).toBeFocused();
});

test('7. Removing the only search match moves focus to the search field', async ({ page }) => {
  await libraryWith(page, [EP3, EP2, EP1]);
  const search = page.getByRole('searchbox', { name: 'Search the Library' });
  await search.fill('Episode 2');
  await expect(libraryTitles(page)).toHaveText([EP2]);
  await removeFromRow(page, EP2);
  await expect(search).toBeFocused();
  await expect(search).toHaveValue('Episode 2');

  // Removing the last item in the Library clears the query, so Undo brings the row back to a visible list.
  await search.fill('');
  await removeFromRow(page, EP3);
  await removeFromRow(page, EP1);
  await expect(page.getByText(/Nothing in your Library yet/)).toBeVisible();
  await expect(page.getByRole('button', { name: 'Go to Following' })).toBeFocused();
  await page.getByRole('button', { name: 'Undo' }).click();
  await expect(libraryTitles(page)).toHaveText([EP1]);
});

test('8. A write the browser refuses: the row stays and the problem is named', async ({ page }) => {
  await page.addInitScript(() => {
    const w = window as unknown as { __failStore?: string };
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (this: IDBObjectStore, ...args: Parameters<IDBObjectStore['put']>) {
      if (w.__failStore === this.name) throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');
      return put.apply(this, args);
    };
  });
  await libraryWith(page, [EP3, EP2]);
  await page.evaluate(() => {
    (window as unknown as { __failStore?: string }).__failStore = 'settings';
  });
  await more(page, EP3).click();
  await sheet(page, EP3).getByRole('button', { name: 'Remove from Library' }).click();
  await expect(page.getByText(new RegExp(`^Removing “${EP3}” from your Library wasn’t saved\\.`))).toBeVisible();
  await expect(libraryTitles(page)).toHaveText([EP3, EP2]);
  await expect(page.getByRole('button', { name: 'Undo' })).toHaveCount(0);
});
