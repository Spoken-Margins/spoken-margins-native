// The owner's phone feedback (#3037, 2026-10-31): "the speed control should be on the right side, not the left
// side, because it gets covered by the iPhone's volume." On an iPhone the volume indicator slides in at the left
// edge, beside the volume buttons, in roughly the top half of the screen. Nothing on Now Playing that a listener
// taps may sit there. Runs at iPhone size in Chrome and WebKit (`phone-*` projects).
import { expect, test } from '@playwright/test';
import { FEED_ORIGIN, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;

/**
 * Where the volume indicator can cover the page, in CSS pixels from the viewport's top-left. It is a narrow pill
 * against the left edge beside the volume buttons; this is generous both ways, so a control just outside it is
 * still clear of the indicator's shadow and of a thumb reaching past it.
 */
const VOLUME_BAND = { left: 0, right: 56, top: 60, bottom: 420 };

test.beforeEach(async ({ page }) => {
  await serveFixtures(page);
});

test('on Now Playing, speed is on the right and nothing to tap sits under the volume indicator', async ({ page }, info) => {
  await page.goto('./');
  await page.getByRole('button', { name: 'Find a show to follow' }).click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await sheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await sheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following Spoken Margins Test Show/)).toBeVisible();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click();
  await page.getByRole('button', { name: /Episode 3: No link, GUID and audio/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: 'Episode 3: No link, GUID and audio' });
  await expect(nowPlaying.getByRole('button', { name: /Speed 1 times/ })).toBeVisible();
  await shot(page, info, '3037-now-playing');

  const viewport = page.viewportSize();
  if (!viewport) throw new Error('no viewport');
  const speed = await nowPlaying.getByRole('button', { name: /Speed 1 times/ }).boundingBox();
  if (!speed) throw new Error('speed button has no box');
  expect(speed.x, 'the speed button starts on the right half').toBeGreaterThan(viewport.width / 2);

  // Play stays centred between the skips.
  const play = await nowPlaying.getByRole('button', { name: /^(Play|Pause)$/ }).boundingBox();
  if (!play) throw new Error('play button has no box');
  expect(Math.abs(play.x + play.width / 2 - viewport.width / 2)).toBeLessThanOrEqual(4);

  // Every button in Now Playing, by name and box. The timeline's Margin posts are left out: they are pointer
  // shortcuts for rows in "Margins in this episode", which stay reachable. The scrubber is a track the full width.
  const covered = await nowPlaying.locator('button:visible, [role="button"]:visible').evaluateAll(
    (elements, band) =>
      elements
        .filter((el) => !el.classList.contains('tick'))
        .map((el) => {
          const box = el.getBoundingClientRect();
          return { name: el.getAttribute('aria-label') ?? el.textContent?.trim() ?? '', box };
        })
        .filter(({ box }) => box.width > 0 && box.left < band.right && box.right > band.left && box.top < band.bottom && box.bottom > band.top)
        // A button wider than the band reaches past the indicator, so it can still be tapped beside it.
        .filter(({ box }) => box.right - band.right < 44)
        .map(({ name }) => name),
    VOLUME_BAND,
  );
  expect(covered, 'buttons under the left-edge volume indicator').toEqual([]);
});
