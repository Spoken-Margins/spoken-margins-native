// The web app's first journey (#2982): follow a fixture show, play an episode, add a written Margin, find
// it in the Margins tab and jump back to its moment, then reload and resume. Run at phone and laptop size.
import { expect, test, type Page } from '@playwright/test';
import { FEED_ORIGIN, seconds, serveFixtures, shot } from './fixtures.ts';

const FEED = `${FEED_ORIGIN}/enclosure-only-episodes.rss`;

async function tab(page: Page, name: string) {
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name }).click();
}

async function elapsed(page: Page): Promise<number> {
  return seconds((await page.getByTestId('elapsed').textContent()) ?? '0:00');
}

test.beforeEach(async ({ page }) => {
  await serveFixtures(page);
});

test('follow a show, play, write a Margin, find it in Margins, and resume after a reload', async ({ page }, info) => {
  await page.goto('./');
  await expect(page.getByRole('heading', { name: 'Library' })).toBeVisible();
  await shot(page, info, '01-empty-library');

  // Follow the fixture feed by its address.
  await page.getByRole('button', { name: 'Find a show to follow' }).click();
  const sheet = page.getByRole('dialog', { name: 'Follow a show' });
  await sheet.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await shot(page, info, '02-follow-sheet');
  await sheet.getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByText('Following Spoken Margins Test Show. 3 episodes added to your Library.')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Following' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open Spoken Margins Test Show' })).toContainText('3 new');
  await shot(page, info, '03-following');

  // The Library lists the three playable episodes, newest first. The show note and the video trailer
  // have no audio, so they aren't there.
  await tab(page, 'Library');
  const titles = page.getByRole('list', { name: 'Episodes, newest first' }).locator('.row-title');
  await expect(titles).toHaveText(['Episode 3: No link, GUID and audio', 'Episode 2: No link, no GUID, audio only', 'Episode 1: Has a link']);
  await shot(page, info, '04-library');

  // Play the newest episode; the clock must actually move.
  await page.getByRole('button', { name: /Episode 3: No link, GUID and audio/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: 'Episode 3: No link, GUID and audio' });
  await expect(nowPlaying).toBeVisible();
  await expect(nowPlaying.getByRole('button', { name: 'Pause' })).toBeVisible();
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(2);

  // Skip forward 15 seconds.
  const beforeSkip = await elapsed(page);
  await nowPlaying.getByRole('button', { name: 'Forward 15 seconds' }).click();
  await expect.poll(() => elapsed(page)).toBeGreaterThanOrEqual(beforeSkip + 14);

  // Speed cycles 1× to 1.25×.
  await nowPlaying.getByRole('button', { name: /Speed 1 times/ }).click();
  await expect(nowPlaying.getByRole('button', { name: /Speed 1.25 times/ })).toBeVisible();
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.playbackRate)).toBe(1.25);

  // Write a Margin. It is anchored where the listener tapped, not where they finished typing.
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  const label = await nowPlaying.locator('label[for="margin-text"]').textContent();
  const anchor = seconds(label?.replace('Your Margin at ', '') ?? '0:00');
  expect(anchor).toBeGreaterThanOrEqual(17);
  await nowPlaying.getByLabel(/Your Margin at/).fill('The guest’s point about tides is the one to send Sam.');
  await shot(page, info, '05-writing-margin');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Margin saved at/)).toBeVisible();
  const tick = nowPlaying.getByRole('button', { name: /^Margin at .*tides/ });
  await expect(tick).toBeVisible();
  await shot(page, info, '06-margin-on-timeline');

  // Tapping the tick seeks to the Margin's moment.
  await nowPlaying.getByRole('button', { name: 'Forward 15 seconds' }).click();
  await nowPlaying.getByRole('button', { name: 'Pause' }).click();
  await tick.click();
  await expect.poll(() => elapsed(page)).toBe(anchor);

  // The Margins tab shows it in the newest group, and tapping it plays from its moment.
  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Margins');
  await expect(page.getByRole('heading', { name: /Episode 3: No link, GUID and audio/ })).toBeVisible();
  await expect(page.locator('.margin-group').first().getByText('Newest').first()).toBeVisible();
  await expect(page.getByText('The guest’s point about tides is the one to send Sam.')).toBeVisible();
  await shot(page, info, '07-margins-tab');
  await page.getByRole('button', { name: /Play from .*tides/ }).click();
  await expect(page.getByRole('dialog', { name: 'Episode 3: No link, GUID and audio' })).toBeVisible();
  await expect.poll(() => elapsed(page)).toBeGreaterThanOrEqual(anchor);
  await expect.poll(() => elapsed(page)).toBeLessThan(anchor + 5);

  // Pause, reload: the Library offers to resume, and reopening resumes there.
  await page.getByRole('button', { name: 'Pause' }).click();
  const pausedAt = await elapsed(page);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Margins', exact: true })).toBeVisible();
  await tab(page, 'Library');
  const resume = page.getByRole('button', { name: /Episode 3/ }).getByText(/Resume at/);
  await expect(resume).toBeVisible();
  expect(Math.abs(seconds((await resume.textContent())!.replace('Resume at ', '')) - pausedAt)).toBeLessThanOrEqual(1);
  await shot(page, info, '08-library-resume');
  await page.getByRole('button', { name: /Episode 3/ }).click();
  // The audio itself, not just the clock label, must start from the saved place and play on from it.
  const audioTime = () => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
  await expect.poll(audioTime, { timeout: 10_000 }).toBeGreaterThanOrEqual(pausedAt + 1);
  expect(await audioTime()).toBeLessThan(pausedAt + 6);
  await expect(page.getByRole('button', { name: 'Pause' })).toBeVisible();
  await shot(page, info, '09-now-playing');
});

test('record a voice Margin with the microphone', async ({ page }, info) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  const nowPlaying = page.getByRole('dialog', { name: /Episode 3/ });
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(1);

  await nowPlaying.getByRole('button', { name: 'Record a Margin' }).click();
  await expect(nowPlaying.getByText(/Recording your Margin at/)).toBeVisible();
  // The episode pauses while the listener speaks.
  await expect(nowPlaying.getByRole('button', { name: 'Play', exact: true })).toBeVisible();
  await shot(page, info, '10-recording');
  await page.waitForTimeout(1200);
  await nowPlaying.getByRole('button', { name: 'Stop and save' }).click();
  await expect(page.getByText(/Voice Margin saved at/)).toBeVisible();
  // And resumes afterwards.
  await expect(nowPlaying.getByRole('button', { name: 'Pause' })).toBeVisible();

  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Margins');
  await expect(page.getByRole('button', { name: /Hear this voice Margin/ })).toBeVisible();
  const recorded = await page.evaluate(
    () =>
      new Promise<{ type: string; size: number }>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const get = open.result.transaction('margins').objectStore('margins').getAll();
          get.onsuccess = () => {
            const voice = get.result.find((m: { voice?: { blob: Blob; mimeType: string } }) => m.voice)?.voice;
            resolve({ type: voice?.mimeType ?? '', size: voice?.blob.size ?? 0 });
          };
          get.onerror = () => reject(get.error);
        };
      }),
  );
  expect(recorded.size).toBeGreaterThan(0);
  info.annotations.push({ type: 'recorded-format', description: recorded.type });
  await shot(page, info, '11-voice-margin');
});

test('a feed the browser cannot read asks once before using the server', async ({ page }, info) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill('https://blocked.test/feed.rss');
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  const ask = page.getByRole('dialog', { name: 'Read this feed through our server?' });
  await expect(ask).toBeVisible();
  await expect(ask).toContainText('keeps nothing');
  await shot(page, info, '12-relay-question');
  await ask.getByRole('button', { name: 'Not now' }).click();
  await expect(page.getByRole('alert')).toContainText('can only be read through our server');

  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Close' }).click();
  await tab(page, 'Settings');
  const relaySwitch = page.getByRole('switch', { name: /Use the server for feeds that need it/ });
  await expect(relaySwitch).not.toBeChecked();
  await expect(page.getByText('Off', { exact: true })).toBeVisible();
  await shot(page, info, '13-settings');
});

test('every control has a name and a target of at least 44 px', async ({ page }) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  await page.getByRole('button', { name: 'Write a Margin' }).click();
  await page.getByLabel(/Your Margin at/).fill('A note.');
  await page.getByRole('button', { name: 'Save Margin' }).click();

  const check = () =>
    page.evaluate(() => {
      const problems: string[] = [];
      for (const el of Array.from(document.querySelectorAll<HTMLElement>('button, input, textarea, a[href]'))) {
        const target = (el.closest('label') as HTMLElement | null) ?? el;
        const box = target.getBoundingClientRect();
        if (box.width === 0 && box.height === 0) continue;
        const name = (el.getAttribute('aria-label') ?? el.textContent ?? '').trim() || (el.id && document.querySelector(`label[for="${el.id}"]`)?.textContent);
        if (!name && !el.closest('label')) problems.push(`no name: ${el.outerHTML.slice(0, 80)}`);
        if (Math.min(box.width, box.height) < 44 - 0.5) problems.push(`small (${Math.round(box.width)}x${Math.round(box.height)}): ${name || el.outerHTML.slice(0, 60)}`);
      }
      return problems;
    });

  expect(await check(), 'Now Playing').toEqual([]);
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  for (const name of ['Library', 'Following', 'Margins', 'Settings']) {
    await tab(page, name);
    expect(await check(), name).toEqual([]);
  }
});
