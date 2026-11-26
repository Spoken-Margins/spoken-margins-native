// Unfollow a show and dismiss an episode on the web, each with Undo (#4426, Design of 2026-11-22). Neither deletes
// anything: Unfollow marks the show record, Dismiss writes a `dismissed:` settings row, and what the listener added to
// the Library stays there with its place. Phone size, against the repo's feed fixture. Captures go to artifacts/
// (fixtures only).
import { expect, test, type Page } from '@playwright/test';
import type { Episode, Margin } from '../src/shared/model.ts';
import { writePacket } from '../src/packet/write.ts';
import { FEED_ORIGIN, followAndAdd, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const SHOW = 'Spoken Margins Test Show';
const EP3 = 'Episode 3: No link, GUID and audio';
const EP2 = 'Episode 2: No link, no GUID, audio only';
const EP1 = 'Episode 1: Has a link';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Runs at phone size (390×844).');
  await serveFixtures(page);
});

/** Before the app loads: an IndexedDB whose put() throws for whichever store `window.__failStore` names (storage.spec.ts). */
async function rigStorage(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const w = window as unknown as { __failStore?: string };
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (this: IDBObjectStore, ...args: Parameters<IDBObjectStore['put']>) {
      if (w.__failStore === this.name) throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');
      return put.apply(this, args);
    };
  });
}
const failStore = (page: Page, store: string | undefined) =>
  page.evaluate((s) => {
    (window as unknown as { __failStore?: string }).__failStore = s;
  }, store);

const tab = (page: Page, name: string) => page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
const libraryTitles = (page: Page) => page.getByRole('list', { name: 'Episodes, newest first' }).locator('.row-title');
const showList = (page: Page) => page.getByRole('list', { name: `Episodes of ${SHOW}` });
const showTitles = (page: Page) => showList(page).locator('.row-title');
const more = (page: Page, title: string) => page.getByRole('button', { name: `More for ${title}`, exact: true });
const sheet = (page: Page, title: string) => page.getByRole('dialog', { name: title });
const openShowButton = (page: Page) => page.getByRole('button', { name: new RegExp(`^Open ${SHOW}`) });
// A toast with Undo keeps its words in their own span, so they match exactly; a plain toast's paragraph starts with its mark.
const toastText = (page: Page, text: string) => page.getByText(text, { exact: true });
const plainToast = (page: Page, text: string) => page.locator('.toast').filter({ hasText: text });

async function follow(page: Page): Promise<void> {
  await tab(page, 'Following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  const followSheet = page.getByRole('dialog', { name: 'Follow a show' });
  await followSheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await followSheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following .*Open it to pick episodes/)).toBeVisible();
}

async function openShow(page: Page): Promise<void> {
  await tab(page, 'Following');
  await openShowButton(page).click();
  await expect(page.getByRole('heading', { name: SHOW, level: 1 })).toBeVisible();
}

/** Runs one request on the app's own IndexedDB. */
async function idb<T>(page: Page, body: string): Promise<T> {
  return page.evaluate(
    (code) =>
      new Promise<T>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onerror = () => reject(open.error);
        open.onsuccess = () => {
          // eslint-disable-next-line no-new-func
          const run = new Function('db', 'resolve', 'reject', code) as (db: IDBDatabase, ok: (v: T) => void, no: (e: unknown) => void) => void;
          run(open.result, resolve, reject);
        };
      }),
    body,
  );
}

async function episodeId(page: Page, title: string): Promise<string> {
  return idb<string>(
    page,
    `const r = db.transaction('episodes').objectStore('episodes').getAll();
     r.onsuccess = () => resolve(r.result.find((e) => e.title === ${JSON.stringify(title)}).id);
     r.onerror = () => reject(r.error);`,
  );
}

async function storedShow(page: Page): Promise<{ unfollowedAt?: string } | undefined> {
  return idb(
    page,
    `const r = db.transaction('shows').objectStore('shows').getAll();
     r.onsuccess = () => resolve(r.result.find((s) => s.title === ${JSON.stringify(SHOW)}));
     r.onerror = () => reject(r.error);`,
  );
}

/** The Design's `returning` seed: A (Episode 1) added with a place of 40 s, B (Episode 3) with a Margin, D (Episode 2) dismissed. */
async function returningSeed(page: Page): Promise<void> {
  await page.goto('./');
  await follow(page);
  await followAndAdd(page, SHOW, [EP1]);
  const a = await episodeId(page, EP1);
  const b = await episodeId(page, EP3);
  const d = await episodeId(page, EP2);
  await idb<void>(
    page,
    `const tx = db.transaction(['positions', 'margins', 'settings'], 'readwrite');
     tx.objectStore('positions').put({ episodeId: ${JSON.stringify(a)}, seconds: 40, updatedAt: '2026-11-25T10:00:00Z' });
     tx.objectStore('margins').put({ id: 'seed-margin', episodeId: ${JSON.stringify(b)}, atSeconds: 12, createdAt: '2026-11-25T10:00:00Z', text: 'A seeded Margin.' });
     tx.objectStore('settings').put({ key: 'dismissed:' + ${JSON.stringify(d)}, value: { dismissed: true, at: '2026-11-25T10:00:00Z' } });
     tx.oncomplete = () => resolve();
     tx.onerror = () => reject(tx.error);`,
  );
  await page.reload();
}

test('1. Returning: Unfollow keeps the Library and its place; following again brings back the row, places and dismissals', async ({ page }, info) => {
  await returningSeed(page);
  await openShow(page);
  await shot(page, info, '4426-1-show-add-and-more');
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(toastText(page, `Unfollowed ${SHOW}. What you added to your Library stays there.`)).toBeVisible();
  await shot(page, info, '4426-3-unfollow-toast');
  await expect(page.locator('#following-title')).toBeFocused();
  await expect(openShowButton(page)).toHaveCount(0);

  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveText([EP3, EP1]);
  await expect(page.getByRole('list', { name: 'Episodes, newest first' }).getByText('Resume at 0:40')).toBeVisible();

  // The Follow sheet's search offers Follow again (#646), not the "Following" tag.
  await page.route('https://itunes.apple.com/**', (route) =>
    route.fulfill({
      status: 200,
      headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*' },
      body: JSON.stringify({ resultCount: 1, results: [{ collectionId: 1, collectionName: SHOW, artistName: 'Test', feedUrl: FEED }] }),
    }),
  );
  await tab(page, 'Following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  const followSheet = page.getByRole('dialog', { name: 'Follow a show' });
  await followSheet.getByLabel('Show name, or a feed or Substack address').fill('Spoken Margins');
  await followSheet.getByRole('button', { name: 'Search' }).click();
  const results = followSheet.getByRole('list', { name: 'Search results' });
  await expect(results.getByText('Following', { exact: true })).toHaveCount(0);

  await page.reload();
  await expect(openShowButton(page)).toHaveCount(0);
  await follow(page);
  await openShow(page);
  await expect(showList(page).getByText('In Library', { exact: true })).toHaveCount(2);
  await expect(showTitles(page)).toHaveText([EP3, EP1]);
  await page.getByRole('button', { name: 'Dismissed episodes (1)' }).click();
  await expect(page.getByRole('list', { name: `Dismissed episodes of ${SHOW}` }).locator('.row-title')).toHaveText([EP2]);
  await shot(page, info, '4426-4-dismissed-open');
  await tab(page, 'Library');
  await expect(page.getByRole('list', { name: 'Episodes, newest first' }).getByText('Resume at 0:40')).toBeVisible();
});

test('2–3. Unfollow, then Undo: the row and its focus come back; the last show shows the empty state', async ({ page }) => {
  await page.goto('./');
  await follow(page);
  await openShow(page);
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(toastText(page, `Unfollowed ${SHOW}.`)).toBeVisible();
  await expect(page.getByText('Follow a podcast or a Substack.', { exact: false })).toBeVisible();
  await page.getByRole('button', { name: 'Undo' }).click();
  await expect(plainToast(page, `Following ${SHOW} again.`)).toBeVisible();
  await expect(openShowButton(page)).toBeFocused();
  await page.reload();
  await tab(page, 'Following');
  await expect(openShowButton(page)).toBeVisible();
  expect(await storedShow(page)).not.toHaveProperty('unfollowedAt');
});

test('4–5. Unfollow while its episode plays: it keeps playing; Check for new episodes skips the feed', async ({ page }) => {
  await page.goto('./');
  await follow(page);
  await openShow(page);
  await showList(page).getByRole('button', { name: new RegExp(`^${EP3.slice(0, 9)}`) }).click();
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  const mini = page.locator('.mini-player');
  await expect(mini).toContainText(EP3);
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(mini).toContainText(EP3);
  await expect(mini.getByRole('button', { name: 'Pause' })).toBeVisible();

  // The load's automatic refresh would read every followed feed; the unfollowed one must not be read.
  const feedRequests: string[] = [];
  page.on('request', (request) => {
    if (request.url().startsWith(FEED)) feedRequests.push(request.url());
  });
  await page.reload();
  await expect.poll(() => storedShow(page).then((s) => typeof s?.unfollowedAt)).toBe('string');
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toContainText([EP3]);
  expect(feedRequests).toEqual([]);
});

test('6. Dismiss, then Undo; Dismiss and let it go: gone after a reload, "N new" one lower, and Bring back returns it', async ({ page }, info) => {
  await page.goto('./');
  await follow(page);
  await openShow(page);
  await expect(showTitles(page)).toHaveText([EP3, EP2, EP1]);
  await more(page, EP2).click();
  await expect(sheet(page, EP2).getByRole('button', { name: 'Dismiss' })).toBeFocused();
  await expect(sheet(page, EP2).getByText('It leaves this list and the new count. Nothing is deleted.')).toBeVisible();
  await shot(page, info, '4426-2-dismiss-sheet');
  await sheet(page, EP2).getByRole('button', { name: 'Cancel' }).click();
  await expect(more(page, EP2)).toBeFocused();

  await more(page, EP2).click();
  await sheet(page, EP2).getByRole('button', { name: 'Dismiss' }).click();
  await expect(showTitles(page)).toHaveText([EP3, EP1]);
  await expect(toastText(page, `Dismissed “${EP2}”.`)).toBeVisible();
  await expect(more(page, EP1)).toBeFocused();
  await page.getByRole('button', { name: 'Undo' }).click();
  await expect(plainToast(page, `“${EP2}” is back in the list.`)).toBeVisible();
  await expect(showTitles(page)).toHaveText([EP3, EP2, EP1]);
  await expect(more(page, EP2)).toBeFocused();

  await page.locator('.back-button').click();
  const newBefore = await openShowButton(page).getAttribute('aria-label');
  await openShowButton(page).click();
  await more(page, EP2).click();
  await sheet(page, EP2).getByRole('button', { name: 'Dismiss' }).click();
  await expect(toastText(page, `Dismissed “${EP2}”.`)).toBeVisible();
  await page.reload();
  await tab(page, 'Following');
  const newAfter = await openShowButton(page).getAttribute('aria-label');
  const count = (label: string | null) => Number(/(\d+) new/.exec(label ?? '')?.[1] ?? 0);
  expect(count(newAfter)).toBe(count(newBefore) - 1);
  await openShowButton(page).click();
  await expect(showTitles(page)).toHaveText([EP3, EP1]);
  await page.getByRole('button', { name: 'Dismissed episodes (1)' }).click();
  await page.getByRole('button', { name: `Bring back ${EP2}` }).click();
  await expect(plainToast(page, `“${EP2}” is back in the list.`)).toBeVisible();
  await expect(showTitles(page)).toHaveText([EP3, EP2, EP1]);
  await expect(page.getByRole('button', { name: /Dismissed episodes/ })).toHaveCount(0);
});

test('7–8. Keyboard only: dismiss every episode; the screen and the Following row say so', async ({ page }) => {
  await page.goto('./');
  await follow(page);
  await openShow(page);
  const titles = await showTitles(page).allTextContents();
  // Keyboard: focus the first ⋯, Enter opens the sheet, Enter dismisses, focus lands on the next row's ⋯.
  await more(page, titles[0]!).focus();
  await page.keyboard.press('Enter');
  await expect(sheet(page, titles[0]!).getByRole('button', { name: 'Dismiss' })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(more(page, titles[1]!)).toBeFocused();
  for (const title of titles.slice(1)) {
    await more(page, title).click();
    await sheet(page, title).getByRole('button', { name: 'Dismiss' }).click();
    await expect(sheet(page, title)).toHaveCount(0);
  }
  await expect(page.getByText('You’ve dismissed every episode here.')).toBeVisible();
  await expect(page.getByRole('button', { name: `Dismissed episodes (${titles.length})` })).toBeFocused();
  await page.locator('.back-button').click();
  await expect(openShowButton(page)).toContainText('Every episode dismissed');
  await expect(page.getByRole('button', { name: new RegExp(`Play the newest episode of ${SHOW}`) })).toHaveCount(0);
});

test('9. Offline: Unfollow and Dismiss still write', async ({ page, context }) => {
  await page.goto('./');
  await follow(page);
  await openShow(page);
  await context.setOffline(true);
  await more(page, EP1).click();
  await sheet(page, EP1).getByRole('button', { name: 'Dismiss' }).click();
  await expect(toastText(page, `Dismissed “${EP1}”.`)).toBeVisible();
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(toastText(page, `Unfollowed ${SHOW}.`)).toBeVisible();
  await context.setOffline(false);
  await expect.poll(() => storedShow(page).then((s) => typeof s?.unfollowedAt)).toBe('string');
});

test('10–11. A friend’s file for an episode of an unfollowed show lands in the Library; Remove then says how to find it', async ({ page }) => {
  await page.goto('./');
  await follow(page);
  await openShow(page);
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(openShowButton(page)).toHaveCount(0);

  const friendEpisode: Episode = { id: 'f', showId: 'f-show', title: EP3, guid: 'sm-test-show-ep3', audioUrl: 'https://media.example.com/show/ep3.mp3', audioOrigin: 'podcast-enclosure', durationSeconds: 180 };
  const margins: Margin[] = [{ id: 'fm', episodeId: 'f', atSeconds: 20, createdAt: '2026-11-25T10:00:00Z', text: 'Listen here.' }];
  const written = await writePacket(friendEpisode, margins, { sender: 'Sam' });
  await tab(page, 'Library');
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Open a Margin file' }).click();
  await (await choosing).setFiles({ name: written.fileName, mimeType: 'application/octet-stream', buffer: Buffer.from(written.bytes) });
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveText([EP3]);
  await tab(page, 'Following');
  await expect(openShowButton(page)).toHaveCount(0);

  // Remove from the Library: the friend's Margin wins the toast. Delete the Margin first to see the unfollowed sentence.
  await idb<void>(page, `const tx = db.transaction('margins', 'readwrite'); tx.objectStore('margins').clear(); tx.oncomplete = () => resolve(); tx.onerror = () => reject(tx.error);`);
  await page.reload();
  await tab(page, 'Library');
  await more(page, EP3).click();
  await sheet(page, EP3).getByRole('button', { name: 'Remove from Library' }).click();
  await expect(toastText(page, `Removed “${EP3}” from your Library. Follow ${SHOW} again to find it.`)).toBeVisible();
});

test('12. A refused write: Unfollow and Dismiss change nothing, name the problem, and offer no Undo', async ({ page }) => {
  await rigStorage(page);
  await page.goto('./');
  await follow(page);
  await openShow(page);

  await failStore(page, 'shows');
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(page.getByText(`Unfollowing ${SHOW} wasn’t saved.`, { exact: false })).toBeVisible();
  await expect(page.getByRole('heading', { name: SHOW, level: 1 })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Unfollow' })).toBeEnabled();
  await expect(page.getByRole('button', { name: 'Undo' })).toHaveCount(0);

  await failStore(page, 'settings');
  await more(page, EP1).click();
  await sheet(page, EP1).getByRole('button', { name: 'Dismiss' }).click();
  await expect(page.getByText(`Dismissing “${EP1}” wasn’t saved.`, { exact: false })).toBeVisible();
  await expect(sheet(page, EP1)).toHaveCount(0);
  await expect(showTitles(page)).toContainText([EP1]);
  await expect(more(page, EP1)).toBeFocused();
  await expect(page.getByRole('button', { name: 'Undo' })).toHaveCount(0);
  await failStore(page, undefined);
  await page.reload();
  expect(await storedShow(page)).not.toHaveProperty('unfollowedAt');
});
