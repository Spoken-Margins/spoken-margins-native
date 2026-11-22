// A tap on a Substack post whose page is a podcast episode plays that episode, and a tap on a post that has nothing to
// play leaves the page usable (#4433: a friend's shared Substack podcast link said "no voice", and after Close nothing on
// the page could be tapped). Phone size only; every network answer is served from the repo's fixtures.
import { expect, test, type Page } from '@playwright/test';
import { feedFixture, seconds, serveAudio, serveFixtures } from './fixtures.ts';

const POST = 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory';
const TITLE = 'Leaked Anthropic Draft AI Regulatory Bill Is Unacceptable and Troubling';
const cors = { 'access-control-allow-origin': '*' };

test.beforeEach(async ({ page }, info) => {
  test.skip(info.project.name !== 'phone', 'These journeys run at phone size (390×844).');
  await serveFixtures(page);
  await page.route('https://thezvi.substack.com/feed', (route) =>
    route.fulfill({ status: 200, body: feedFixture('substack-zvi-generated-voice.rss'), headers: { ...cors, 'content-type': 'application/rss+xml' } }),
  );
});

const preloads = (post: Record<string, unknown>) =>
  `<script>window._preloads = JSON.parse(${JSON.stringify(JSON.stringify({ post: { id: 1, canonical_url: POST, audience: 'everyone', ...post } }))});</script>`;

async function servePostPage(page: Page, html: string) {
  await page.route(`${POST}*`, (route) => route.fulfill({ status: 200, body: html, headers: { ...cors, 'content-type': 'text/html' } }));
}

async function followAndOpenLibrary(page: Page) {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill('https://thezvi.substack.com/feed');
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText(/Following /)).toBeVisible();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click();
}

test('a Substack post that is a podcast episode plays the episode itself (#4433)', async ({ page }) => {
  await servePostPage(page, preloads({ type: 'podcast', podcast_url: 'https://audio.example/episode.mp3', podcast_duration: 3600, audio_items: [] }));
  await serveAudio(page, 'https://audio.example/**');
  await followAndOpenLibrary(page);

  await page.getByRole('button', { name: new RegExp(TITLE) }).click();
  const nowPlaying = page.getByRole('dialog', { name: TITLE });
  await expect(nowPlaying).toBeVisible();
  await expect(page.getByText(/has no voice to play/)).toHaveCount(0);
  await expect.poll(async () => seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00'), { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentSrc)).toBe('https://audio.example/episode.mp3');
});

// Every way a tap on a post can end with nothing to play. Each used to leave Now Playing "open" with nothing drawn, which
// made the tabs and the list inert: Close on the notice cleared the notice and nothing else.
const NOTHING_TO_PLAY: Array<[string, () => string, RegExp]> = [
  ['a podcast post with no episode audio on its page', () => preloads({ type: 'podcast', podcast_url: null, audio_items: [] }), /has no voice to play/],
  ['a newsletter post with no voice', () => preloads({ type: 'newsletter', podcast_url: null, audio_items: [] }), /has no voice to play/],
  ['a paid post', () => feedFixture('substack-paid-post-page.html').toString().replace('https://captured.example/p/paid-post', POST), /for paid subscribers/],
];

for (const [name, html, notice] of NOTHING_TO_PLAY) {
  test(`${name}: the notice appears, and after Close the page still works (#4433)`, async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (error) => errors.push(String(error)));
    await servePostPage(page, html());
    await followAndOpenLibrary(page);

    await page.getByRole('button', { name: new RegExp(TITLE) }).click();
    await expect(page.getByText(notice)).toBeVisible();
    await page.getByRole('button', { name: 'Close' }).click();
    await expect(page.getByText(notice)).toHaveCount(0);

    // Nothing is covering or disabling the page: the tabs take a tap, and so does the same post again.
    await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Settings' }).click({ timeout: 3000 });
    await expect(page.getByRole('heading', { name: 'Settings' }).first()).toBeVisible();
    await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Library' }).click({ timeout: 3000 });
    await page.getByRole('button', { name: new RegExp(TITLE) }).click({ timeout: 3000 });
    await expect(page.getByText(notice)).toBeVisible();
    expect(errors).toEqual([]);
  });
}
