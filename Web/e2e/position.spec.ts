// Where the listener left off survives a refresh (#4096): scrub then refresh, with and without a pause in between.
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, seconds, serveFixtures } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;
const TITLE = 'Episode 3: No link, GUID and audio';

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'Run at phone size.');
  await serveFixtures(page);
});

async function open(page: Page) {
  await page.goto('./');
  await page.getByRole('button', { name: 'Find a show to follow' }).click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await sheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await sheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByRole('heading', { name: 'Following' })).toBeVisible();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click();
  await page.getByRole('button', { name: new RegExp(TITLE) }).click();
  const playing = page.getByRole('dialog', { name: TITLE });
  await expect(playing.getByRole('button', { name: 'Pause' })).toBeVisible();
  return playing;
}
const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
async function scrubTo(page: Page, to: number) {
  await page.getByRole('slider', { name: 'Position' }).evaluate((el: HTMLInputElement, v) => {
    const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!;
    set.call(el, String(v));
    el.dispatchEvent(new Event('input', { bubbles: true }));
  }, to);
}
async function reopenAndRead(page: Page) {
  await page.reload();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click();
  const resume = page.getByRole('button', { name: new RegExp(TITLE) }).getByText(/Resume at/);
  await expect(resume).toBeVisible();
  const shown = seconds((await resume.textContent())!.replace('Resume at ', ''));
  await page.getByRole('button', { name: new RegExp(TITLE) }).click();
  await expect(page.getByRole('dialog', { name: TITLE })).toBeVisible();
  // Past zero: the saved place is applied when the audio's metadata arrives, not when the dialog opens.
  await expect.poll(() => audioTime(page)).toBeGreaterThan(1);
  return { shown, at: await audioTime(page) };
}

test('play, scrub, pause, refresh: back at the scrub', async ({ page }) => {
  const playing = await open(page);
  await expect.poll(() => audioTime(page)).toBeGreaterThan(1);
  await scrubTo(page, 40);
  await playing.getByRole('button', { name: 'Pause' }).click();
  const at = await audioTime(page);
  const r = await reopenAndRead(page);
  expect(Math.abs(r.shown - at)).toBeLessThanOrEqual(1.5); // the Library's "Resume at"
  expect(Math.abs(r.at - at)).toBeLessThanOrEqual(1.5);
});
test('scrub while paused and refresh at once: back at the scrub', async ({ page }) => {
  const playing = await open(page);
  await expect.poll(() => audioTime(page)).toBeGreaterThan(1);
  await playing.getByRole('button', { name: 'Pause' }).click();
  await scrubTo(page, 70);
  const at = await audioTime(page);
  const r = await reopenAndRead(page);
  expect(Math.abs(r.shown - at)).toBeLessThanOrEqual(1.5); // the Library's "Resume at"
  expect(Math.abs(r.at - at)).toBeLessThanOrEqual(1.5);
});
test('play on after a scrub and refresh within seconds: back where it was, not at the scrub', async ({ page }) => {
  await open(page);
  await expect.poll(() => audioTime(page)).toBeGreaterThan(1);
  await scrubTo(page, 100);
  await expect.poll(() => audioTime(page)).toBeGreaterThan(103.5);
  // Four seconds on: IndexedDB last committed at the scrub (100 s), and the next timed save is a second away.
  const at = await audioTime(page);
  const r = await reopenAndRead(page);
  expect(Math.abs(r.shown - at)).toBeLessThanOrEqual(1.5); // the Library's "Resume at"
  expect(Math.abs(r.at - at)).toBeLessThanOrEqual(1.5);
});
