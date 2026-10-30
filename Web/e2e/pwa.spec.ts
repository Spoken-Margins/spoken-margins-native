// Installability: the manifest (with the `.spokenmargins` share target), and a service worker that opens
// the app shell with no network.
import { expect, test } from '@playwright/test';

test.use({ serviceWorkers: 'allow' });

test('the manifest makes the app installable and accepts shared Margin files', async ({ request }) => {
  const manifest = await (await request.get('./manifest.webmanifest')).json();
  expect(manifest.display).toBe('standalone');
  expect(manifest.start_url).toBe('./');
  const sizes = manifest.icons.map((i: { sizes: string }) => i.sizes);
  expect(sizes).toEqual(expect.arrayContaining(['192x192', '512x512']));
  expect(manifest.share_target.method).toBe('POST');
  expect(manifest.share_target.params.files[0].accept).toContain('.spokenmargins');
  for (const icon of manifest.icons) expect((await request.get(`./${icon.src}`)).ok()).toBe(true);
});

test('the app shell opens offline once the service worker has it', async ({ page, context }) => {
  await page.goto('./');
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload();
  await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);

  await context.setOffline(true);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Library' })).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' })).toBeVisible();
  await context.setOffline(false);
});
