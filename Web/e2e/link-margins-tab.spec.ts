// The Margins tab redesign on the web (owner's prototype v3, part of #3216), driven at an iPhone-sized 375×812 window
// against the local link stub and the shared test vector, so the Margins are fixtures, never a real Library. The arrival
// preview lists the friend's Margins before anything plays; a start opens Now Playing on its Margins tab; Next Margin
// counts down and, inside the lead-in, goes straight into the Margin; the list marks heard, unheard, a reply and a star.
// Screenshots go to artifacts/web-margins-tab/ (git-ignored). Audio is muted by the config and the silence script.
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { nowTab, seconds, serveAudio, serveFixtures } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const LINK = `${STUB}/l/vectorvoice01#${vector.keyFragment as string}`;
const EPISODE = 'Episode 1 (example episode)';
const SHOTS = fileURLToPath(new URL('../../artifacts/web-margins-tab/', import.meta.url));

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'One journey, in its own 375×812 context.');
});

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
async function shot(page: Page, name: string): Promise<void> {
  mkdirSync(SHOTS, { recursive: true });
  await page.screenshot({ path: `${SHOTS}${name}.png` });
}

test('arrival preview, Margins tab, Next Margin and Autoplay at 375×812 (part of #3216)', async ({ browser }) => {
  test.setTimeout(90_000);
  const context = await browser.newContext({ viewport: { width: 375, height: 812 }, hasTouch: true, serviceWorkers: 'block' });
  const page = await context.newPage();
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  await page.goto(LINK);

  // 1. The preview: welcome, the two Margins with "Start with this Margin", the two pinned starts, and no player.
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByText('Welcome. Web fixture left these Margins for you.')).toBeVisible();
  await expect(arrival.getByTestId('mc-row')).toHaveCount(2);
  await expect(arrival.getByRole('button', { name: 'Start with this Margin' })).toHaveCount(2);
  const unheardStart = page.getByRole('button', { name: 'Start with unheard Margins' });
  const fromStart = page.getByRole('button', { name: 'Start from the beginning' });
  await expect(unheardStart).toBeVisible();
  await expect(fromStart).toBeVisible();
  // Pinned: both starts sit at the bottom of the window.
  const bar = await page.locator('.arrival-starts').boundingBox();
  expect((bar?.y ?? 0) + (bar?.height ?? 0)).toBeGreaterThanOrEqual(811);
  await expect(page.locator('.np-dock')).toHaveCount(0);
  expect(await arrival.evaluate((el) => el.scrollWidth - el.clientWidth)).toBeLessThanOrEqual(1);
  await expect(page.getByTestId('next-margin')).toHaveCount(0);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);
  await shot(page, '1-arrival-preview');

  // 2. Start with unheard Margins: the lead-in of the first (0:30 − 20 s = 0:10), on the Margins tab.
  await unheardStart.click();
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing).toBeVisible();
  await expect(playing.getByRole('tab', { name: /Margins/ })).toHaveAttribute('aria-selected', 'true');
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(10.2);
  expect(await audioTime(page)).toBeLessThan(20);

  // 3. The Next Margin pill counts down, and the clock moves.
  const pill = page.getByTestId('next-margin');
  await expect(pill).toBeVisible();
  const first = (await pill.locator('.mc-next-clock').textContent()) ?? '';
  const elapsedFirst = seconds((await page.getByTestId('elapsed').textContent())?.split('/')[0] ?? '0:00');
  await expect.poll(async () => pill.locator('.mc-next-clock').textContent(), { timeout: 5_000 }).not.toBe(first);
  const second = (await pill.locator('.mc-next-clock').textContent()) ?? '';
  expect(seconds(second)).toBeLessThan(seconds(first));
  await expect.poll(async () => seconds((await page.getByTestId('elapsed').textContent())?.split('/')[0] ?? '0:00')).toBeGreaterThan(elapsedFirst);
  test.info().annotations.push({ type: 'countdown', description: `${first} then ${second}` });
  await shot(page, '2-next-margin-pill');

  // 4. Inside the lead-in, Next Margin goes straight into the Margin (forward only): the written one at 0:30 plays.
  const before = await audioTime(page);
  await pill.click();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(29.5);
  expect(await audioTime(page)).toBeGreaterThan(before);
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture wrote this');
  await expect(arrived).toContainText('A written Margin at half a minute.');
  await expect(playing.locator('.mc-playing')).toContainText('Playing');
  await shot(page, '3-margin-playing');

  // 5. A reply of the listener's own while it shows (Write is on Now), then back to Margins.
  await nowTab(page);
  await playing.getByRole('button', { name: 'Write a Margin' }).click();
  await expect(playing.locator('.reply-row')).toContainText('Replying to Web fixture');
  await playing.getByLabel(/Your Margin at/).fill('Agreed. The part about reaction times is the bit I keep coming back to, and I would like to hear more about how they measured it.');
  await playing.getByRole('button', { name: 'Save Margin' }).click();
  await playing.getByRole('tab', { name: /Margins/ }).click();
  // Let the friend's written Margin finish, so its row reads Heard rather than Playing.
  await expect(playing.getByTestId('arrived-margin')).toHaveCount(0, { timeout: 20_000 });

  // 6. The rows: the written Margin heard (check and "Heard"), the voice Margin unheard (bar, dot, spoken "Unheard"),
  // the reply indented under it, starred.
  const rows = playing.getByTestId('mc-row');
  await expect(rows).toHaveCount(3);
  const heard = playing.locator('.mc-heard');
  await expect(heard).toHaveCount(1);
  await expect(heard).toContainText('Heard');
  const unheard = playing.locator('.mc-unheard');
  await expect(unheard).toHaveCount(1);
  await expect(unheard.locator('.mc-dot')).toHaveCount(1);
  await expect(unheard.getByText('Unheard')).toHaveCount(1);
  const reply = playing.locator('.mc-replies .mc-row');
  await expect(reply).toContainText('You');
  const star = reply.getByRole('button', { name: 'Star for sharing' });
  await star.click();
  await expect(star).toHaveAttribute('aria-pressed', 'true');
  await expect(reply.getByRole('button', { name: 'See more' })).toBeVisible();
  // Unheard is never bolder or bigger than heard words in the same list.
  const weight = async (row: ReturnType<Page['locator']>) => row.locator('.mc-text').evaluate((el) => getComputedStyle(el).fontWeight);
  expect(await weight(unheard)).toBe(await weight(reply));
  await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.pause());
  // Nothing scrolls sideways at 375 wide: the filters, Autoplay and the star fit.
  expect(await page.locator('.now-playing').evaluate((el) => el.scrollWidth - el.clientWidth)).toBeLessThanOrEqual(1);
  await playing.locator('.mc-list').scrollIntoViewIfNeeded();
  await shot(page, '4-margins-tab-rows');

  // 7. The Autoplay menu: "Play Margins by themselves" with three choices, Unheard checked.
  await playing.getByRole('button', { name: /^Autoplay:/ }).click();
  const menu = playing.getByRole('menu', { name: 'Play Margins by themselves' });
  await expect(menu.getByRole('menuitemradio')).toHaveText(['Unheard Margins', 'All Margins', 'Off']);
  await expect(menu.getByRole('menuitemradio', { name: 'Unheard Margins' })).toHaveAttribute('aria-checked', 'true');
  await shot(page, '5-autoplay-menu');
  await menu.getByRole('menuitemradio', { name: 'All Margins' }).click();
  await expect(playing.getByRole('button', { name: 'Autoplay: All Margins' })).toBeVisible();
  await context.close();
});
