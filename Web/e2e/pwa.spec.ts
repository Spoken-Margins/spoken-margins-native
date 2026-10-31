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

test('a file shared to the installed app reaches the app through the service worker', async ({ page, request }) => {
  // Post the way Android does, to the manifest's own action and field name, so the manifest and the
  // service worker have to agree.
  const { share_target: share } = await (await request.get('./manifest.webmanifest')).json();
  await page.goto('./');
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload();
  await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);

  const landed = await page.evaluate(
    async ({ action, field }) => {
      const form = new FormData();
      form.append(field, new File([new Uint8Array([80, 75, 3, 4])], 'from-a-friend.spokenmargins'));
      const response = await fetch(action, { method: 'POST', body: form });
      const keys = await (await caches.open('sm-shared-files')).keys();
      return { url: response.url, parked: keys.length };
    },
    { action: share.action as string, field: share.params.files[0].name as string },
  );
  // The worker answered with its redirect to `?shared=1` (a redirect made by a service worker doesn't
  // set `response.redirected`, so the landing address is the check).
  expect(new URL(landed.url).searchParams.has('shared')).toBe(true);
  expect(landed.parked).toBe(1);

  // Opening the app there hands the file to the packet reader and empties the parking cache. Until the
  // packet reader lands (#2984), the reader refuses it, which shows as a problem naming the file.
  await page.goto(landed.url);
  await expect(page.getByRole('alert')).toContainText('from-a-friend.spokenmargins');
  await expect.poll(() => page.evaluate(async () => (await (await caches.open('sm-shared-files')).keys()).length)).toBe(0);
});
