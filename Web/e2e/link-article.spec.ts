// A share link for a Substack post (#4421): the iPhone app anchors a Margin on an article to the article's words and
// how far through it the sender was, with no time. A friend in a browser taps Play, the player finds the post's own voice
// (reading the page only then), and the Margins land at their share of that audio's length and play there. Against the
// local link stub (e2e/link-stub-server.ts), as link-arrival.spec.ts is.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { feedFixture, serveAudio, serveFixtures, startFromBeginning } from './fixtures.ts';

const STUB = 'http://127.0.0.1:4174';
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const LINK = `${STUB}/l/vectorpost01#${vector.keyFragment as string}`;
const POST = 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory';
const TITLE = 'Leaked Anthropic Draft AI Regulatory Bill Is Unacceptable and Troubling';
/** The stub's audio is 180 seconds: 20% is 36 s, 60% is 108 s. */
const FIRST_AT = 36;

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'The link stub is one server; this runs once, at a phone size.');
});

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);

test('a share link for a Substack post plays its voice and puts the sender’s Margins at their place in it', async ({ page }) => {
  const pageReads: string[] = [];
  await serveFixtures(page);
  await page.route(`${POST}*`, (route) => {
    pageReads.push(route.request().url());
    return route.fulfill({
      status: 200,
      body: feedFixture('substack-preloads-json-generated-voice-page.html'),
      headers: { 'access-control-allow-origin': '*', 'content-type': 'text/html' },
    });
  });
  await serveAudio(page, 'https://substack-video.s3.amazonaws.com/**');

  await page.goto(LINK);

  // 1. Not the text-only card: a Play button, the count of Margins, and nothing read from the publisher yet.
  const arrival = page.getByTestId('arrival');
  await expect(arrival.getByRole('heading', { name: TITLE })).toBeVisible();
  await expect(arrival.getByText('2 Margins', { exact: false })).toBeVisible();
  await expect(arrival.getByText('which the browser can’t play yet')).toHaveCount(0);
  // The article stays one tap away, for a post whose voice turns out not to be there.
  await expect(arrival.getByRole('link', { name: 'Open the article' })).toHaveAttribute('href', POST);
  expect(pageReads).toHaveLength(0);

  // 2. Play finds the post's voice (the one page read) and plays it from the beginning.
  await startFromBeginning(page, 'Play');
  const playing = page.getByRole('dialog', { name: TITLE });
  await expect(playing).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThan(0.3);
  expect(pageReads).toHaveLength(1);
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentSrc)).toContain('substack-video.s3.amazonaws.com');

  // 3. The countdown points at the first Margin, a fifth of the way through the audio; Skip goes there.
  const cue = playing.getByTestId('margin-cue');
  await expect(cue).toContainText('Web fixture’s first Margin in');
  await cue.getByRole('button', { name: 'Skip to just before Web fixture' }).click();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(FIRST_AT - 20.5);
  expect(await audioTime(page)).toBeLessThan(FIRST_AT);
  await cue.getByRole('button', { name: 'Skip to Web fixture now' }).click();

  // 4. The Margin plays in place, with its words.
  const arrived = playing.getByTestId('arrived-margin');
  await expect(arrived).toContainText('Web fixture wrote this');
  await expect(arrived).toContainText('1 of 2');
  await expect(arrived).toContainText('A written Margin from the web, 1:05 in.');
  expect(await audioTime(page)).toBeGreaterThanOrEqual(FIRST_AT - 1);
  expect(await audioTime(page)).toBeLessThan(FIRST_AT + 5);

  // 5. Both Margins were kept, the second at 60% of the audio, and are in the Margins tab for later.
  await playing.getByRole('button', { name: 'Close Now Playing' }).click();
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Margins' }).click();
  await expect(page.getByText('A written Margin from the web, 1:05 in.')).toBeVisible();
  await expect(page.getByText('Another at ten minutes.')).toBeVisible();
});
