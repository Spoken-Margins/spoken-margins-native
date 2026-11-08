// Quick add (#3610): from a fresh browser, a new listener taps one suggested show and it is followed, with its
// episodes in the Library and playable. Fixture feeds only: the four publishers' hosts answer from a fixture, and the
// browser is shown to touch none of them, and no third-party host, before that tap.
import { expect, test, type Page, type Request } from '@playwright/test';
import { SUGGESTED_SHOWS } from '../src/app/logic/suggestions.ts';
import { feedFixture, seconds, serveFixtures, shot } from './fixtures.ts';

const RELAY = 'https://relay.test';
const CONSENT = 'Read this feed through our server?';

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

/** Every request the page makes, by host. */
function watchHosts(page: Page): Request[] {
  const seen: Request[] = [];
  page.on('request', (request) => seen.push(request));
  return seen;
}

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone' && info.project.name !== 'laptop', 'Runs at phone and laptop size.');
  await serveFixtures(page);
  // Substack's feeds send no CORS header, so a browser can't read them: the refusal, as a failed fetch. The relay
  // reads them for the listener once they say yes.
  for (const show of SUGGESTED_SHOWS) await page.route(`${new URL(show.feedUrl).origin}/**`, (route) => route.abort('failed'));
  await page.route(`${RELAY}/**`, (route) =>
    route.fulfill({
      status: 200,
      body: feedFixture('enclosure-only-episodes.rss'),
      headers: { 'content-type': 'application/rss+xml', 'access-control-allow-origin': '*' },
    }),
  );
});

test('a new listener follows a suggested show in one tap, and its episodes play', async ({ page, baseURL }, info) => {
  const requests = watchHosts(page);
  await page.goto('./#following');
  const list = page.getByRole('list', { name: 'Suggested shows' });
  await expect(list.locator('.row-title')).toHaveText(SUGGESTED_SHOWS.map((s) => s.title));
  await expect(page.getByText(/your first tap may ask to use our server/)).toBeVisible();
  await shot(page, info, '60-suggested-empty-following');

  // Showing the list reached no publisher, no relay and no third-party host.
  const appHost = new URL(baseURL ?? 'http://127.0.0.1:4173').host;
  const foreign = requests.map((r) => new URL(r.url())).filter((u) => u.protocol.startsWith('http') && u.host !== appHost);
  expect(foreign.map((u) => u.host), 'hosts contacted before any tap').toEqual([]);

  // One tap. The feed can't be read by the browser, so the listener is asked once, in the same words as anywhere else.
  await list.getByRole('button', { name: 'Add Dwarkesh Podcast' }).click();
  const consent = page.getByRole('dialog', { name: CONSENT });
  await expect(consent).toBeVisible();
  await shot(page, info, '61-suggested-consent');
  await consent.getByRole('button', { name: 'Use the server' }).click();

  await expect(page.getByText('Following Spoken Margins Test Show. 3 episodes added to your Library.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open Spoken Margins Test Show' })).toContainText('3 new');
  // Only the tapped feed was asked for: the other three publishers were never contacted.
  // (The browser tries the feed itself before the server reads it, so that one host is asked more than once.)
  const publishers = SUGGESTED_SHOWS.map((s) => new URL(s.feedUrl).host);
  const reached = new Set(requests.map((r) => new URL(r.url()).host).filter((host) => publishers.includes(host)));
  expect([...reached]).toEqual([publishers[0]]);

  // Its episodes are in the Library and play, and the clock moves.
  await tab(page, 'Library');
  await page.getByRole('button', { name: /Episode 3: No link, GUID and audio/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: 'Episode 3: No link, GUID and audio' });
  await expect(nowPlaying.getByRole('button', { name: 'Pause' })).toBeVisible();
  await expect
    .poll(async () => seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00'), { timeout: 10_000 })
    .toBeGreaterThanOrEqual(2);
  await shot(page, info, '62-suggested-playing');
});

test('Not now keeps the suggestions and follows nothing, and the Follow sheet lists them too', async ({ page }, info) => {
  await page.goto('./#following');
  const list = page.getByRole('list', { name: 'Suggested shows' });
  await list.getByRole('button', { name: 'Add The Pragmatic Engineer' }).click();
  await page.getByRole('dialog', { name: CONSENT }).getByRole('button', { name: 'Not now' }).click();
  await expect(page.getByRole('alert')).toContainText('Not followed');
  await expect(list.locator('.row-title')).toHaveCount(SUGGESTED_SHOWS.length);
  await shot(page, info, '63-suggested-not-now');

  // Reaching the list from the Follow sheet (the Library's empty state opens it too), and following from there.
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await expect(sheet.getByRole('list', { name: 'Suggested shows' }).locator('.row-title')).toHaveCount(SUGGESTED_SHOWS.length);
  await sheet.getByRole('button', { name: 'Add Lenny’s Newsletter' }).click();
  // "Not now" was remembered, so the server is not asked about again, and the follow says why.
  await expect(sheet.getByRole('alert')).toContainText('Reading feeds through the server is off in Settings');
});
