// Opened marks on the link arrival (#5275), against the local link stub. The stub answers like a server from before
// #5275; these tests add its `X-SM-Link-Opened: 1` header to the packet answer and catch `POST /l/<id>/opened` in the
// page, so nothing reaches a real server. What a friend sees: one line under "From …" with Don't tell, and the first
// start control sends exactly the opened-token, once.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { serveAudio, serveFixtures } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const LINK = `${STUB}/l/vectorvoice01#${vector.keyFragment as string}`;
const NOTICE = 'When you open these Margins, Web fixture can see that you did.';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'One size is enough for one line and one request.');
});

/** The page, with the packet answering as a server that keeps marks (or not), and every opened post recorded. */
async function friend(page: Page, offers: boolean): Promise<string[]> {
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  const posts: string[] = [];
  await page.context().route('**/l/*/packet', async (route) => {
    const response = await route.fetch();
    await route.fulfill({ response, headers: { ...response.headers(), ...(offers ? { 'x-sm-link-opened': '1' } : {}) } });
  });
  await page.context().route('**/l/*/opened', async (route) => {
    posts.push(`${route.request().method()} ${route.request().postData() ?? ''}`);
    await route.fulfill({ status: 204 });
  });
  return posts;
}

test('the first start control sends the token once, and the notice goes', async ({ page }) => {
  const posts = await friend(page, true);
  await page.goto(LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByTestId('arrival-opened')).toHaveText(`${NOTICE} Don’t tell Web fixture`);
  await arrival.getByRole('button', { name: 'Start from the beginning', exact: true }).click();
  await expect.poll(() => posts.length).toBe(1);
  expect(posts[0]).toMatch(/^POST [0-9a-f]{64}$/);
  // Once the page has stored the link as signalled, opening it again shows no notice and sends nothing.
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          new Promise<boolean>((resolve) => {
            const open = indexedDB.open('spoken-margins');
            open.onsuccess = () => {
              const get = open.result.transaction('settings').objectStore('settings').get('openedSignalled');
              get.onsuccess = () => resolve(Object.hasOwn(get.result?.value ?? {}, 'vectorvoice01'));
              get.onerror = () => resolve(false);
            };
            open.onerror = () => resolve(false);
          }),
      ),
    )
    .toBe(true);
  const again = await page.context().newPage();
  await serveFixtures(again);
  await serveAudio(again, 'https://example.com/podcast/**');
  await again.goto(LINK);
  await expect(again.getByTestId('arrival').getByRole('heading', { level: 1 })).toBeVisible();
  await expect(again.getByTestId('arrival-opened')).toHaveCount(0);
  await again.getByTestId('arrival').getByRole('button', { name: 'Start from the beginning', exact: true }).click();
  await again.locator('.now-playing').waitFor();
  expect(posts.length, 'a link this browser already signalled is not signalled again').toBe(1);
});

test('Don’t tell turns the switch off and swaps the notice; nothing is sent', async ({ page }) => {
  const posts = await friend(page, true);
  await page.goto(LINK);
  const arrival = page.getByTestId('arrival');
  await arrival.getByRole('button', { name: 'Don’t tell Web fixture' }).click();
  await expect(arrival.getByTestId('arrival-opened')).toHaveText('Web fixture won’t be told. Change this in Settings.');
  await arrival.getByRole('button', { name: 'Start from the beginning', exact: true }).click();
  await page.locator('.now-playing').waitFor();
  expect(posts).toEqual([]);
});

test('a server that keeps no marks shows no notice and gets no post', async ({ page }) => {
  const posts = await friend(page, false);
  await page.goto(LINK);
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(arrival.getByTestId('arrival-opened')).toHaveCount(0);
  await arrival.getByRole('button', { name: 'Start from the beginning', exact: true }).click();
  await page.locator('.now-playing').waitFor();
  expect(posts).toEqual([]);
});

test('on the listen-here card (an article link), the notice shows and Hear sends the token (#5351)', async ({ page }) => {
  const posts = await friend(page, true);
  await page.goto(`${STUB}/l/vectorarticle1#${vector.keyFragment as string}`);
  const card = page.getByTestId('arrival-listen');
  await expect(card.getByTestId('arrival-opened')).toHaveText(`${NOTICE} Don’t tell Web fixture`);
  await card.getByRole('button', { name: 'Hear Web fixture’s Margins' }).click();
  await expect.poll(() => posts.length).toBe(1);
  expect(posts[0]).toMatch(/^POST [0-9a-f]{64}$/);
  await expect(card.getByTestId('arrival-opened')).toHaveCount(0);
});
