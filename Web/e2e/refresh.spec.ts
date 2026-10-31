// Followed shows refresh (#2977 audit, rough edge 1): the Following tab's Refresh control, the 30-minute limit on
// automatic reads, merging without duplicates, and a feed that needs the server skipped quietly with one line.
import { expect, test, type Page, type Request } from '@playwright/test';
import { FEED_ORIGIN, feedFixture, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/refreshing.rss`;
const RELAY = 'https://relay.test';
const NEW_ITEM = `<item>
      <title>Episode 4: Fresh this morning</title>
      <guid isPermaLink="false">sm-test-show-ep4</guid>
      <pubDate>Sat, 27 Sep 2026 10:00:00 +0000</pubDate>
      <enclosure url="https://media.example.com/show/ep4.mp3" length="1234567" type="audio/mpeg"/>
    </item>
    <item>`;

/** The fixture feed, and the same feed once a new episode is out (the new item first, as feeds list them). */
const before = feedFixture('enclosure-only-episodes.rss').toString('utf8');
const after = before.replace('<item>', NEW_ITEM);

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'The refresh journeys run at phone size (390×844).');
  await serveFixtures(page);
});

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

/** Serves `FEED` with whatever `feed.body` holds at the time, and counts the reads. */
async function serveChangingFeed(page: Page) {
  const feed = { body: before, reads: 0 };
  await page.route(FEED, (route) => {
    feed.reads += 1;
    return route.fulfill({ status: 200, body: feed.body, headers: { 'content-type': 'application/rss+xml', 'access-control-allow-origin': '*' } });
  });
  return feed;
}

async function follow(page: Page, address: string) {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(address);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
}

test('the Refresh control adds a new episode once, and opening the app again within 30 minutes reads nothing', async ({ page }, info) => {
  const feed = await serveChangingFeed(page);
  await follow(page, FEED);
  await expect(page.getByText('Following Spoken Margins Test Show. 3 episodes added to your Library.')).toBeVisible();
  expect(feed.reads).toBe(1);
  await expect(page.getByTestId('refresh-status')).toHaveText('Checked just now');

  // Opening the app again (and coming back to it) leaves a feed read moments ago alone.
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Following' })).toBeVisible();
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await page.waitForTimeout(500);
  expect(feed.reads).toBe(1);

  // A new episode is out. The Refresh control reads now, whatever the time since the last read.
  feed.body = after;
  await page.getByRole('button', { name: 'Check for new episodes' }).click();
  await expect(page.getByText('1 new episode.')).toBeVisible();
  expect(feed.reads).toBe(2);
  await expect(page.getByRole('button', { name: /^Open Spoken Margins Test Show, 4 new, latest .*: Episode 4: Fresh this morning$/ })).toBeVisible();
  await expect(page.getByTestId('refresh-status')).toHaveText('Checked just now');
  await shot(page, info, '50-following-refreshed');

  // Again: the feed is the same, so nothing is added twice.
  await page.getByRole('button', { name: 'Check for new episodes' }).click();
  await expect(page.getByText('No new episodes.')).toBeVisible();
  await tab(page, 'Library');
  await expect(page.getByRole('button', { name: /Episode 4: Fresh this morning/ })).toHaveCount(1);
  await expect(page.getByRole('button', { name: /Episode 3: No link, GUID and audio/ })).toHaveCount(1);
  await expect(page.getByRole('button', { name: /Episode 2: No link, no GUID, audio only/ })).toHaveCount(1);
});

test('a feed that needs the server is skipped quietly once that is off, with one line and the way to say yes', async ({ page }, info) => {
  const relayCalls: Request[] = [];
  page.on('request', (request) => {
    if (request.url().startsWith(RELAY)) relayCalls.push(request);
  });
  let relayBody = before;
  await page.route(`${RELAY}/**`, (route) =>
    route.fulfill({ status: 200, body: relayBody, headers: { 'content-type': 'application/rss+xml', 'access-control-allow-origin': '*' } }),
  );

  // Followed through the server, then the server turned off in Settings.
  await follow(page, 'https://blocked.test/feed.rss');
  await page.getByRole('dialog', { name: 'Read this feed through our server?' }).getByRole('button', { name: 'Use the server' }).click();
  await expect(page.getByText(/Following Spoken Margins Test Show\./)).toBeVisible();
  expect(relayCalls).toHaveLength(1);
  await tab(page, 'Settings');
  await page.getByRole('switch', { name: /Use the server for feeds that need it/ }).click();
  await expect(page.getByRole('switch', { name: /Use the server for feeds that need it/ })).not.toBeChecked();

  // A refresh skips it without asking or calling the server, and says so in one line.
  relayBody = after;
  await tab(page, 'Following');
  await page.getByRole('button', { name: 'Check for new episodes' }).click();
  const line = page.getByTestId('refresh-needs-relay');
  await expect(line).toContainText('1 show needs the Spoken Margins server to refresh.');
  await expect(page.getByRole('dialog', { name: 'Read this feed through our server?' })).toHaveCount(0);
  expect(relayCalls).toHaveLength(1);
  await shot(page, info, '51-following-needs-server');

  // The consent action asks, and a yes reads the skipped feed through the server at once.
  await line.getByRole('button', { name: 'Use the server' }).click();
  await page.getByRole('dialog', { name: 'Read this feed through our server?' }).getByRole('button', { name: 'Use the server' }).click();
  await expect(page.getByText('1 new episode.')).toBeVisible();
  expect(relayCalls).toHaveLength(2);
  await expect(line).toHaveCount(0);
  await expect(page.getByRole('button', { name: /latest .*: Episode 4: Fresh this morning$/ })).toBeVisible();
});
