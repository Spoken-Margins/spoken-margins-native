// The web Library holds what you add (#4425): Following adds nothing, the show screen's Add and a play do, a friend's
// file comes back in, and a store from before the change moves its untouched episodes out once, with a notice that
// puts them back. Phone size, against the repo's feed fixture. Captures go to artifacts/ (fixtures only).
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const SHOW = 'Spoken Margins Test Show';
const EP3 = 'Episode 3: No link, GUID and audio';
const EP2 = 'Episode 2: No link, no GUID, audio only';
const WEB_VOICE = fileURLToPath(new URL('../../Contracts/fixtures/web-packets/web-voice.spokenmargins', import.meta.url));
const MIRROR_KEY = 'sm.positions.v1';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Runs at phone size (390×844).');
  await serveFixtures(page);
});

const tab = (page: Page, name: string) => page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
const libraryTitles = (page: Page) => page.getByRole('list', { name: 'Episodes, newest first' }).locator('.row-title');
const notice = (page: Page) => page.getByRole('region', { name: 'What moved out of your Library' });

async function followFixture(page: Page): Promise<void> {
  await tab(page, 'Following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await sheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await sheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(`Following ${SHOW}. Open it to pick episodes for your Library.`)).toBeVisible();
}

async function openShow(page: Page, title = SHOW): Promise<void> {
  await tab(page, 'Following');
  await page.getByRole('button', { name: `Open ${title}` }).click();
  await expect(page.getByRole('heading', { name: title })).toBeVisible();
}

const addButton = (page: Page, title: string) => page.getByRole('button', { name: `Add ${title} to your Library`, exact: true });

/** The Library as an older web app left it: every episode in it, no membership setting. Written over what the first load stored. */
async function seedOlderStore(page: Page, seed: { shows: unknown[]; episodes: unknown[]; margins: unknown[]; positions?: unknown[]; mirror?: unknown[] }): Promise<void> {
  await page.goto('./');
  // The first load has finished its own move (the empty Library is drawn only once `data` is set), so it can't write over the seed.
  await expect(page.getByText('Episodes you add from the shows you follow, and the ones friends send you, appear here.')).toBeVisible();
  await page.evaluate(
    ({ shows, episodes, margins, mirror, key }) =>
      new Promise<void>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const tx = open.result.transaction(['shows', 'episodes', 'margins', 'settings'], 'readwrite');
          for (const row of shows) tx.objectStore('shows').put(row);
          for (const row of episodes) tx.objectStore('episodes').put(row);
          for (const row of margins) tx.objectStore('margins').put(row);
          // Over the first load's own value, so the next load runs the move again.
          tx.objectStore('settings').put({ key: 'libraryModel', value: '' });
          tx.oncomplete = () => {
            if (mirror.length > 0) localStorage.setItem(key, JSON.stringify(mirror));
            resolve();
          };
          tx.onerror = () => reject(tx.error);
        };
        open.onerror = () => reject(open.error);
      }),
    { shows: seed.shows, episodes: seed.episodes, margins: seed.margins, mirror: seed.mirror ?? [], key: MIRROR_KEY },
  );
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Library' })).toBeVisible();
}

const media = 'https://media.example.com/seeded.mp3';
const seededShow = { id: 'feed:seeded', kind: 'podcast', title: 'Seeded Show', feedUrl: `${FEED_ORIGIN}/seeded.rss`, followedAt: '2026-11-01T10:00:00Z' };
const friendsShow = { id: 'shared:sam', kind: 'podcast', title: 'Shared by Sam', feedUrl: '', followedAt: '2026-11-02T10:00:00Z' };
const episode = (id: string, showId: string, title: string, day: number) => ({ id, showId, title, audioUrl: media, audioOrigin: 'podcast-enclosure', durationSeconds: 600, publishedAt: `2026-11-${String(day).padStart(2, '0')}T08:00:00Z` });

test('first run: Following adds nothing, Add and a play put episodes in the Library, unfollow says how many leave', async ({ page }, info) => {
  await page.goto('./');
  // 1. Empty, follows no show.
  await expect(page.getByText('Episodes you add from the shows you follow, and the ones friends send you, appear here.')).toBeVisible();
  await expect(notice(page)).toHaveCount(0);
  await shot(page, info, '4425-1-library-first-run');
  await page.getByRole('button', { name: 'Find a show to follow' }).click();

  // 2 and 3. Follow: the toast says to open the show, and Following has the row.
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await sheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await sheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(`Following ${SHOW}. Open it to pick episodes for your Library.`)).toBeVisible();
  await expect(page.getByRole('button', { name: `Open ${SHOW}` })).toContainText('3 new');

  // 4. The Library is empty, and says so for a listener who follows a show.
  await tab(page, 'Library');
  await expect(page.getByText('Nothing in your Library yet. Open a show on Following and tap Add, or play an episode, and it appears here.')).toBeVisible();
  await shot(page, info, '4425-2-library-follows-a-show');
  await page.getByRole('button', { name: 'Go to Following' }).click();
  await expect(page.getByRole('heading', { name: 'Following' })).toBeVisible();

  // 5. Add one episode on the show's screen.
  await page.getByRole('button', { name: `Open ${SHOW}` }).click();
  await addButton(page, EP3).click();
  await expect(page.getByText(`Added “${EP3}” to your Library.`)).toBeVisible();
  await expect(addButton(page, EP3)).toHaveCount(0);
  await expect(page.getByText('In Library', { exact: true })).toHaveCount(1);
  await expect(page.getByRole('button', { name: /^Add .* to your Library$/ })).toHaveCount(2);
  await shot(page, info, '4425-3-show-one-added');

  // 6. Tap another row: it plays, and is in the Library too.
  await page.getByRole('button', { name: /^Episode 2:/ }).click();
  await expect(page.getByRole('dialog', { name: EP2 })).toBeVisible();
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(page.getByText('In Library', { exact: true })).toHaveCount(2);
  await expect(addButton(page, EP2)).toHaveCount(0);

  // 7. The Library lists both, newest first.
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveText([EP3, EP2]);
  await shot(page, info, '4425-4-library-two-added');

  // The Library keeps what was added across a reload.
  await page.reload();
  await expect(libraryTitles(page)).toHaveText([EP3, EP2]);

  // Unfollowing keeps what was added (#4426), and says so.
  await openShow(page);
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(page.getByText(`Unfollowed ${SHOW}. What you added to your Library stays there.`)).toBeVisible();
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveText([EP3, EP2]);
});

test('a store from before: A, B and D stay, C moves out, and the notice offers it back', async ({ page }, info) => {
  await seedOlderStore(page, {
    shows: [seededShow, friendsShow],
    episodes: [
      episode('ep-a', seededShow.id, 'Episode A, with a Margin', 10),
      episode('ep-b', seededShow.id, 'Episode B, place at 40 seconds', 9),
      episode('ep-c', seededShow.id, 'Episode C, untouched', 8),
      episode('ep-d', friendsShow.id, 'Episode D, from a friend', 7),
    ],
    margins: [
      { id: 'm-a', episodeId: 'ep-a', atSeconds: 12, createdAt: '2026-11-11T10:00:00Z', text: 'My own note.' },
      { id: 'm-d', episodeId: 'ep-d', atSeconds: 30, createdAt: '2026-11-11T11:00:00Z', text: 'Sam’s note.', author: 'Sam' },
    ],
    // B's place reached only the localStorage copy (the page went mid-write).
    mirror: [{ episodeId: 'ep-b', seconds: 40, updatedAt: '2026-11-11T12:00:00Z' }],
  });

  await expect(libraryTitles(page)).toHaveText(['Episode A, with a Margin', 'Episode B, place at 40 seconds', 'Episode D, from a friend']);
  await expect(notice(page)).toContainText('Your Library now holds only what you add, play or get from a friend. 1 episode you hadn’t started is still on Following, under its show.');
  await shot(page, info, '4425-5-library-with-notice');

  // C is on its show's screen with Add; the others say In Library.
  await openShow(page, 'Seeded Show');
  await expect(addButton(page, 'Episode C, untouched')).toBeVisible();
  await expect(page.getByText('In Library', { exact: true })).toHaveCount(2);

  // Put them back returns C, and the notice goes.
  await tab(page, 'Library');
  await notice(page).getByRole('button', { name: 'Put them back' }).click();
  await expect(page.getByText('Put 1 episode back in your Library.')).toBeVisible();
  await expect(notice(page)).toHaveCount(0);
  await expect(libraryTitles(page)).toHaveText(['Episode A, with a Margin', 'Episode B, place at 40 seconds', 'Episode C, untouched', 'Episode D, from a friend']);
  await page.reload();
  await expect(libraryTitles(page)).toHaveCount(4);
  await expect(notice(page)).toHaveCount(0);
});

test('Got it hides the notice through a reload, and leaves the moved episode on its show', async ({ page }) => {
  await seedOlderStore(page, {
    shows: [seededShow],
    episodes: [episode('ep-a', seededShow.id, 'Episode A, with a Margin', 10), episode('ep-c', seededShow.id, 'Episode C, untouched', 8)],
    margins: [{ id: 'm-a', episodeId: 'ep-a', atSeconds: 12, createdAt: '2026-11-11T10:00:00Z', text: 'My own note.' }],
  });
  await expect(notice(page)).toBeVisible();
  await notice(page).getByRole('button', { name: 'Got it' }).click();
  await expect(notice(page)).toHaveCount(0);
  await page.reload();
  await expect(libraryTitles(page)).toHaveText(['Episode A, with a Margin']);
  await expect(notice(page)).toHaveCount(0);
  await openShow(page, 'Seeded Show');
  await expect(addButton(page, 'Episode C, untouched')).toBeVisible();
});

test('a store where nothing was started: everything moves out, and the notice sits above the "follows a show" empty state', async ({ page }) => {
  await seedOlderStore(page, {
    shows: [seededShow],
    episodes: [episode('ep-c', seededShow.id, 'Episode C, untouched', 8), episode('ep-e', seededShow.id, 'Episode E, untouched', 7)],
    margins: [],
  });
  await expect(notice(page)).toContainText('2 episodes you hadn’t started are still on Following, under their shows.');
  await expect(page.getByText('Nothing in your Library yet. Open a show on Following and tap Add, or play an episode, and it appears here.')).toBeVisible();
  await expect(page.getByRole('list', { name: 'Episodes, newest first' })).toHaveCount(0);
  await expect(page.getByRole('searchbox', { name: 'Search the Library' })).toHaveCount(0);
  // The notice comes first on the page.
  const order = await page.evaluate(() => {
    const card = document.querySelector('.library-notice');
    const empty = document.querySelector('.empty');
    return Boolean(card && empty && card.compareDocumentPosition(empty) & Node.DOCUMENT_POSITION_FOLLOWING);
  });
  expect(order).toBe(true);
});

test('Add on a show while another episode plays leaves the player alone', async ({ page }) => {
  await page.goto('./');
  await followFixture(page);
  await openShow(page);
  await page.getByRole('button', { name: /^Episode 3:/ }).click();
  await expect(page.getByRole('dialog', { name: EP3 })).toBeVisible();
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await expect(page.locator('.mini-player')).toContainText(EP3);

  await addButton(page, EP2).click();
  await expect(page.getByText(`Added “${EP2}” to your Library.`)).toBeVisible();
  await expect(page.locator('.mini-player')).toContainText(EP3);
  await expect(page.locator('.mini-player')).not.toContainText(EP2);
});

test('the Library search sees only what was added', async ({ page }) => {
  await page.goto('./');
  await followFixture(page);
  await openShow(page);
  await addButton(page, EP3).click();
  await expect(addButton(page, EP3)).toHaveCount(0);
  await tab(page, 'Library');
  const search = page.getByRole('searchbox', { name: 'Search the Library' });
  await search.fill('Episode');
  await expect(libraryTitles(page)).toHaveText([EP3]);
  await search.fill('Episode 2');
  await expect(page.getByRole('status').filter({ hasText: 'Nothing in the Library matches' })).toBeVisible();
});

test('a friend’s file for an episode that was out of the Library brings it back, with its Margins as they were', async ({ page }) => {
  const importFile = async () => {
    await tab(page, 'Library');
    const choosing = page.waitForEvent('filechooser');
    await page.getByRole('button', { name: 'Open a Margin file' }).click();
    await (await choosing).setFiles(WEB_VOICE);
    await page.getByRole('button', { name: 'Close Now Playing' }).click();
    await expect(page.getByRole('button', { name: 'Close Now Playing' })).toHaveCount(0);
  };
  const stored = () =>
    page.evaluate(
      () =>
        new Promise<{ episodeId: string; margins: number }>((resolve, reject) => {
          const open = indexedDB.open('spoken-margins');
          open.onsuccess = () => {
            const tx = open.result.transaction(['episodes', 'margins']);
            const episodes = tx.objectStore('episodes').getAll() as IDBRequest<Array<{ id: string }>>;
            const margins = tx.objectStore('margins').count();
            tx.oncomplete = () => resolve({ episodeId: episodes.result[0]!.id, margins: margins.result });
            tx.onerror = () => reject(tx.error);
          };
          open.onerror = () => reject(open.error);
        }),
    );

  await page.goto('./#library');
  await importFile();
  await expect(libraryTitles(page)).toHaveCount(1);
  const before = await stored();

  // The listener took it out (#4424 writes this row): it is stored, and not in the Library.
  await page.evaluate(
    (id) =>
      new Promise<void>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const tx = open.result.transaction('settings', 'readwrite');
          tx.objectStore('settings').put({ key: `library:${id}`, value: { in: false, at: '2026-11-20T10:00:00Z' } });
          tx.oncomplete = () => resolve();
          tx.onerror = () => reject(tx.error);
        };
        open.onerror = () => reject(open.error);
      }),
    before.episodeId,
  );
  await page.reload();
  await expect(libraryTitles(page)).toHaveCount(0);

  await importFile();
  await expect(libraryTitles(page)).toHaveCount(1);
  expect(await stored()).toEqual(before);
});

test('a refused write leaves the Library showing every episode, says so, and a play says nothing more', async ({ page }) => {
  // Every write to the settings store fails, as when the browser is out of space for it.
  await page.addInitScript(() => {
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (this: IDBObjectStore, ...args: Parameters<IDBObjectStore['put']>) {
      if (this.name === 'settings') throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');
      return put.apply(this, args);
    };
  });
  await page.goto('./');
  await expect(page.getByText('Your Library couldn’t be updated in this browser, so it shows every episode for now.')).toBeVisible();
  await followFixture(page);

  // The old rule holds: every stored episode is in the Library, and the show screen has no Add.
  await tab(page, 'Library');
  await expect(libraryTitles(page)).toHaveCount(3);
  await openShow(page);
  await expect(page.getByRole('button', { name: /^Add .* to your Library$/ })).toHaveCount(0);

  // A play tries a quiet add, which fails too: logged, not toasted.
  await page.getByRole('button', { name: /^Episode 3:/ }).click();
  await expect(page.getByRole('dialog', { name: EP3 })).toBeVisible();
  await expect.poll(async () => (await page.getByTestId('elapsed').textContent()) ?? '0:00', { timeout: 10_000 }).not.toBe('0:00');
  await expect(page.getByText(/Adding “.*” to your Library wasn’t saved/)).toHaveCount(0);
});
