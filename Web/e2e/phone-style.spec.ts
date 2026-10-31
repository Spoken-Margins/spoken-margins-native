// The owner's phone feedback (#3040, 2026-10-31): the web app "doesn't look much like the app in terms of style."
// Each tab and Now Playing at iPhone size, light and dark, in Chrome and WebKit: the page wears the app's bone and
// evergreen, titles are the serif, lists are panels. Screenshots go to artifacts/web-2982/ for a look.
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const EPISODE = 'Episode 3: No link, GUID and audio';

const LOOK = {
  light: { page: 'rgb(247, 242, 227)', tint: 'rgb(20, 77, 54)', panel: 'rgb(255, 255, 255)' },
  dark: { page: 'rgb(20, 26, 23)', tint: 'rgb(122, 214, 158)', panel: 'rgb(33, 41, 36)' },
} as const;

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

const style = (page: Page, selector: string, property: string) =>
  page.locator(selector).first().evaluate((el, p) => getComputedStyle(el).getPropertyValue(p), property);

for (const scheme of ['light', 'dark'] as const) {
  test.describe(scheme, () => {
    test.use({ colorScheme: scheme });

    test(`every tab and Now Playing wear the app's ${scheme} look`, async ({ page }, info) => {
      await serveFixtures(page);
      await page.goto('./');
      await page.getByRole('button', { name: 'Find a show to follow' }).click();
      const sheet = page.getByRole('dialog', { name: 'Follow a show' });
      await sheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
      await sheet.getByRole('button', { name: 'Follow' }).click();
      await expect(page.getByText(/Following Spoken Margins Test Show/)).toBeVisible();

      await tab(page, 'Library');
      await expect(page.getByRole('list', { name: 'Episodes, newest first' })).toBeVisible();
      expect(await style(page, 'body', 'background-color')).toBe(LOOK[scheme].page);
      expect(await style(page, '.screen-header h1', 'font-family')).toMatch(/^ui-serif/);
      expect(await style(page, '.rows', 'background-color')).toBe(LOOK[scheme].panel);
      expect(await style(page, '.rows', 'border-top-left-radius')).toBe('18px');
      // The current tab: evergreen, bold, and a bar above it, so colour isn't alone.
      expect(await style(page, ".tab[aria-current='page']", 'color')).toBe(LOOK[scheme].tint);
      expect(await style(page, ".tab[aria-current='page']", 'font-weight')).toBe('700');
      await shot(page, info, `3040-${scheme}-library`);

      await tab(page, 'Following');
      await shot(page, info, `3040-${scheme}-following`);
      await tab(page, 'Margins');
      await shot(page, info, `3040-${scheme}-margins`);
      await tab(page, 'Settings');
      await shot(page, info, `3040-${scheme}-settings`);

      await tab(page, 'Library');
      await page.getByRole('button', { name: new RegExp(EPISODE) }).click();
      const nowPlaying = page.getByRole('dialog', { name: EPISODE });
      await expect(nowPlaying).toBeVisible();
      expect(await style(page, '.np-title', 'font-family')).toMatch(/^ui-serif/);
      expect(await style(page, '.play-button', 'background-color')).toBe(LOOK[scheme].tint);
      await shot(page, info, `3040-${scheme}-now-playing`);
    });
  });
}
