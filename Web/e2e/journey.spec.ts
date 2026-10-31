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

  // Skip forward 15 seconds, then back 15. Bounded both ways, so a skip of the wrong size or direction fails.
  const audioTime = () => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
  const beforeSkip = await audioTime();
  await nowPlaying.getByRole('button', { name: 'Forward 15 seconds' }).click();
  const afterSkip = await audioTime();
  expect(afterSkip - beforeSkip).toBeGreaterThanOrEqual(14);
  expect(afterSkip - beforeSkip).toBeLessThanOrEqual(16);
  await nowPlaying.getByRole('button', { name: 'Back 15 seconds' }).click();
  const afterBack = await audioTime();
  expect(afterSkip - afterBack).toBeGreaterThanOrEqual(14);
  expect(afterSkip - afterBack).toBeLessThanOrEqual(16);
  await nowPlaying.getByRole('button', { name: 'Forward 15 seconds' }).click();

  // Speed cycles 1× to 1.25×.
  await nowPlaying.getByRole('button', { name: /Speed 1 times/ }).click();
  await expect(nowPlaying.getByRole('button', { name: /Speed 1.25 times/ })).toBeVisible();
  expect(await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.playbackRate)).toBe(1.25);

  // Write a Margin. It is anchored where the listener tapped, not where they finished typing.
  await nowPlaying.getByRole('button', { name: 'Write a Margin' }).click();
  const label = await nowPlaying.locator('label[for="margin-text"]').textContent();
  const anchor = seconds(label?.replace('Your Margin at ', '') ?? '0:00');
  expect(anchor).toBeGreaterThanOrEqual(17);
  // Playback runs on while the listener types. Save only once it is well past the tap, so a Margin
  // anchored at save time instead of tap time lands somewhere else and fails below.
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(anchor + 3);
  await nowPlaying.getByLabel(/Your Margin at/).fill('The guest’s point about tides is the one to send Sam.');
  await shot(page, info, '05-writing-margin');
  await nowPlaying.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.getByText(/Margin saved at/)).toBeVisible();
  await expect(nowPlaying.getByRole('button', { name: /^Play from .*tides/ })).toHaveAccessibleName(new RegExp(`^Play from ${label?.replace('Your Margin at ', '')}:`));
  // The timeline post: out of the screen reader's path (the list above names it), but there to tap.
  const tick = nowPlaying.locator('.tick[title*="tides"]');
  await expect(tick).toBeVisible();
  expect(Math.floor(Number(await tick.getAttribute('data-at')))).toBe(anchor);
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
  // Let it play on, so the place saved when the listener pauses differs from the one saved at the seek.
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(anchor + 3);

  // Pause, reload: the Library offers to resume, and reopening resumes there.
  await page.getByRole('button', { name: 'Pause' }).click();
  // The audio's own clock, not the shown one: the label is whole seconds and trails timeupdate, so it can sit more
  // than a second behind the exact place the pause saves, which made this check fail about half the time.
  await expect.poll(() => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.paused)).toBe(true);
  const pausedAt = await page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
  // The pause itself saved the place: wait for that stored row, not for a timer.
  const stored = () =>
    page.evaluate(
      () =>
        new Promise<number>((resolve, reject) => {
          const open = indexedDB.open('spoken-margins');
          open.onsuccess = () => {
            const get = open.result.transaction('positions').objectStore('positions').getAll();
            get.onsuccess = () => resolve((get.result as Array<{ seconds: number }>)[0]?.seconds ?? -1);
            get.onerror = () => reject(get.error);
          };
        }),
    );
  await expect.poll(async () => Math.abs((await stored()) - pausedAt)).toBeLessThanOrEqual(1);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Margins', exact: true })).toBeVisible();
  // The written Margin came back from storage, not from memory.
  await expect(page.getByText('The guest’s point about tides is the one to send Sam.')).toBeVisible();
  await tab(page, 'Library');
  const resume = page.getByRole('button', { name: /Episode 3/ }).getByText(/Resume at/);
  await expect(resume).toBeVisible();
  expect(Math.abs(seconds((await resume.textContent())!.replace('Resume at ', '')) - pausedAt)).toBeLessThanOrEqual(1);
  await shot(page, info, '08-library-resume');
  await page.getByRole('button', { name: /Episode 3/ }).click();
  // The audio itself, not just the clock label, must start from the saved place and play on from it.
  await expect.poll(audioTime, { timeout: 10_000 }).toBeGreaterThanOrEqual(pausedAt + 1);
  expect(await audioTime()).toBeLessThan(pausedAt + 6);
  await expect(page.getByRole('button', { name: 'Pause' })).toBeVisible();
  await shot(page, info, '09-now-playing');

  // Unfollowing keeps the Margins, and the episode they belong to.
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Following');
  await page.getByRole('button', { name: /^Open Spoken Margins Test Show/ }).click();
  await page.getByRole('button', { name: 'Unfollow' }).click();
  await expect(page.getByText('No episodes yet').or(page.getByText('Follow a podcast or a Substack'))).toBeVisible();
  await tab(page, 'Margins');
  await expect(page.getByText('The guest’s point about tides is the one to send Sam.')).toBeVisible();
  await expect(page.getByRole('heading', { name: /Episode 3: No link, GUID and audio/ })).toBeVisible();
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
  await expect(nowPlaying.getByRole('status').filter({ hasText: 'Recording' })).toBeVisible();
  const anchorText = (await nowPlaying.getByText(/Your Margin goes at/).textContent()) ?? '';
  const anchor = seconds(/at (\d+:\d+)/.exec(anchorText)?.[1] ?? '0:00');
  expect(anchor).toBeGreaterThanOrEqual(1);
  // The episode pauses while the listener speaks.
  await expect(nowPlaying.getByRole('button', { name: 'Play', exact: true })).toBeVisible();
  await shot(page, info, '10-recording');
  await page.waitForTimeout(1200);
  await nowPlaying.getByRole('button', { name: 'Stop and save' }).click();
  // Words are optional: the box starts with placeholder words, marked as such, which the Margin shares with (#3025).
  const words = nowPlaying.getByLabel(/Words to go with your voice Margin at/);
  await expect(words).toHaveValue(/^Voice Margin at \d+:\d\d in “.+”, recorded \d{1,2} [A-Z][a-z]{2} \d{4}$/);
  await expect(words).toHaveAttribute('data-placeholder', 'true');
  await expect(nowPlaying.getByText('Replace with your own words.', { exact: false })).toBeVisible();
  // Stop saved it (#3038): no Save step, and the episode carries on.
  await expect(nowPlaying.getByTestId('voice-saved')).toHaveText(/^Saved Voice Margin at \d+:\d\d\.$/);
  await expect(nowPlaying.getByRole('button', { name: /Hear this voice Margin/ })).toBeVisible();
  await expect(nowPlaying.getByRole('button', { name: 'Pause' })).toBeVisible();
  await shot(page, info, '10b-voice-placeholder');
  await nowPlaying.getByRole('button', { name: 'Done' }).click();

  await nowPlaying.getByRole('button', { name: 'Close Now Playing' }).click();
  await tab(page, 'Margins');
  await expect(page.getByRole('button', { name: /Hear this voice Margin/ })).toBeVisible();
  // What was stored: at the moment the listener tapped, about as long as they spoke, and real audio that
  // decodes (a few junk bytes would pass a size check).
  const recorded = await page.evaluate(
    () =>
      new Promise<{ type: string; at: number; duration: number; decoded: number }>((resolve, reject) => {
        const open = indexedDB.open('spoken-margins');
        open.onsuccess = () => {
          const get = open.result.transaction('margins').objectStore('margins').getAll();
          get.onsuccess = async () => {
            const margin = get.result.find((m: { voice?: unknown }) => m.voice) as
              | { atSeconds: number; voice: { data: ArrayBuffer; mimeType: string; durationSeconds: number } }
              | undefined;
            if (!margin) return reject(new Error('no voice Margin stored'));
            try {
              const audio = await new AudioContext().decodeAudioData(margin.voice.data);
              resolve({ type: margin.voice.mimeType, at: margin.atSeconds, duration: margin.voice.durationSeconds, decoded: audio.duration });
            } catch (error) {
              reject(error);
            }
          };
          get.onerror = () => reject(get.error);
        };
      }),
  );
  expect(Math.floor(recorded.at)).toBe(anchor);
  expect(recorded.duration).toBeGreaterThan(0.8);
  expect(recorded.decoded).toBeGreaterThan(0.5);
  // The real recorder (#2984) keeps only AAC in .m4a, the one voice format a packet carries.
  expect(recorded.type).toBe('audio/mp4');
  info.annotations.push({ type: 'recorded-format', description: recorded.type });

  // Hearing a voice Margin pauses the episode, so the two never talk over each other.
  await expect(page.locator('.mini-player').getByRole('button', { name: 'Pause' })).toBeVisible();
  await page.getByRole('button', { name: /Hear this voice Margin/ }).click();
  await expect(page.locator('.mini-player').getByRole('button', { name: 'Play', exact: true })).toBeVisible();
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

  // Asked once: trying again doesn't ask a second time, and says where to turn it on.
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByRole('alert')).toContainText('off in Settings');
  await expect(ask).toHaveCount(0);

  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Close' }).click();
  await tab(page, 'Settings');
  const relaySwitch = page.getByRole('switch', { name: /Use the server for feeds that need it/ });
  await expect(relaySwitch).not.toBeChecked();
  await expect(page.getByText('Off', { exact: true })).toBeVisible();
  await shot(page, info, '13-settings');
});

/**
 * Every visible control: a name, a hit area of at least 44 px, and nothing else on top of its centre.
 * A control inside a <label> may use the label as its hit area (a tap on the label works the control).
 * Controls hidden from screen readers on purpose (the timeline posts) need no name, but still 44 px.
 */
function checkControls(page: Page) {
  return page.evaluate(() => {
    const problems: string[] = [];
    // With a modal open, only its controls can be reached.
    const modals = Array.from(document.querySelectorAll('dialog')).filter((d) => d.matches(':modal'));
    const scope: ParentNode = modals.at(-1) ?? document;
    for (const el of Array.from(scope.querySelectorAll<HTMLElement>('button, input, textarea, select, summary, a[href]'))) {
      if (el.closest('[inert]')) continue;
      const target = (el.closest('label') as HTMLElement | null) ?? el;
      const box = target.getBoundingClientRect();
      if (box.width === 0 && box.height === 0) continue;
      const style = getComputedStyle(el);
      if (style.visibility === 'hidden' || style.display === 'none') continue;
      const hidden = Boolean(el.closest('[aria-hidden="true"]'));
      const labelledBy = el.getAttribute('aria-labelledby');
      const name =
        (el.getAttribute('aria-label') ?? '').trim() ||
        (labelledBy ? labelledBy.split(' ').map((id) => document.getElementById(id)?.textContent ?? '').join(' ').trim() : '') ||
        (el.id ? document.querySelector(`label[for="${el.id}"]`)?.textContent?.trim() : '') ||
        (el.closest('label')?.textContent ?? '').trim() ||
        (el.textContent ?? '').trim();
      const what = name || el.outerHTML.slice(0, 60);
      if (!name && !hidden) problems.push(`no name: ${el.outerHTML.slice(0, 80)}`);
      if (Math.min(box.width, box.height) < 44 - 0.5) problems.push(`small (${Math.round(box.width)}x${Math.round(box.height)}): ${what}`);
      // Something else on top of the control's centre takes the tap instead.
      const cx = box.left + box.width / 2;
      const cy = box.top + box.height / 2;
      if (cx >= 0 && cy >= 0 && cx < innerWidth && cy < innerHeight) {
        const top = document.elementFromPoint(cx, cy);
        // Content scrolls under the fixed tab bar and mini player; that is scrolling, not a covered control.
        const chrome = top?.closest('.tabbar, .mini-player') && !target.closest('.tabbar, .mini-player');
        if (top && !chrome && !target.contains(top) && !top.contains(target)) problems.push(`covered by ${top.className || top.tagName}: ${what}`);
      }
    }
    return problems;
  });
}

test('every control has a name and a target of at least 44 px, in every state', async ({ page }) => {
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  expect(await checkControls(page), 'Follow sheet').toEqual([]);
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByRole('heading', { name: 'Following' })).toBeVisible();
  await page.getByRole('button', { name: /^Open Spoken Margins Test Show/ }).click();
  expect(await checkControls(page), 'Show screen').toEqual([]);
  await page.locator('.back-button').click();

  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
  await page.getByRole('button', { name: 'Write a Margin' }).click();
  await page.getByLabel(/Your Margin at/).fill('A note.');
  expect(await checkControls(page), 'Now Playing, writing').toEqual([]);
  await page.getByRole('button', { name: 'Save Margin' }).click();
  // Measure only once the Margin is saved and its post is on the timeline.
  await expect(page.locator('.tick')).toHaveCount(1);
  expect(await checkControls(page), 'Now Playing').toEqual([]);
  await page.getByRole('button', { name: 'Record a Margin' }).click();
  await expect(page.getByRole('button', { name: 'Stop and save' })).toBeEnabled();
  expect(await checkControls(page), 'Now Playing, recording').toEqual([]);
  await page.getByRole('button', { name: 'Stop and save' }).click();
  await page.getByLabel(/Words to go with your voice Margin at/).fill('A spoken note.');
  expect(await checkControls(page), 'Now Playing, voice words').toEqual([]);
  await page.getByRole('button', { name: 'Done' }).click();
  await expect(page.getByRole('button', { name: /Hear this voice Margin/ })).toBeVisible();
  expect(await checkControls(page), 'Now Playing, voice Margin').toEqual([]);

  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  for (const name of ['Library', 'Following', 'Margins', 'Settings']) {
    await tab(page, name);
    expect(await checkControls(page), name).toEqual([]);
  }
  await page.getByText('How this works').click();
  expect(await checkControls(page), 'Settings, opened').toEqual([]);

  await tab(page, 'Following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill('https://blocked.test/feed.rss');
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await expect(page.getByRole('dialog', { name: 'Read this feed through our server?' })).toBeVisible();
  expect(await checkControls(page), 'Relay question').toEqual([]);
});

test('nothing scrolls sideways at 320 px wide, even with text at 200%', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 640 });
  const overflow = () =>
    page.evaluate(() =>
      [document.documentElement, ...Array.from(document.querySelectorAll<HTMLElement>('.now-playing, dialog[open]'))]
        .filter((el) => el.scrollWidth > el.clientWidth + 1)
        .map((el) => `${el.className || el.tagName} ${el.scrollWidth}>${el.clientWidth}`),
    );
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  expect(await overflow(), 'Follow sheet').toEqual([]);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  await page.getByRole('button', { name: 'Write a Margin' }).click();
  await page.getByLabel(/Your Margin at/).fill('A note.');
  await page.getByRole('button', { name: 'Save Margin' }).click();
  await expect(page.locator('.tick')).toHaveCount(1);
  for (const zoom of ['100%', '200%']) {
    await page.evaluate((size) => (document.documentElement.style.fontSize = size), zoom);
    expect(await overflow(), `Now Playing at ${zoom}`).toEqual([]);
  }
  await page.getByRole('button', { name: 'Close Now Playing' }).click();
  for (const zoom of ['100%', '200%']) {
    await page.evaluate((size) => (document.documentElement.style.fontSize = size), zoom);
    for (const name of ['Library', 'Following', 'Margins', 'Settings']) {
      await tab(page, name);
      expect(await overflow(), `${name} at ${zoom}`).toEqual([]);
    }
  }
});

test('lock-screen and notification controls drive the player', async ({ page }) => {
  // Keep the handlers the app gives the Media Session, so the test can press them as Android would.
  await page.addInitScript(() => {
    const handlers: Record<string, (details: MediaSessionActionDetails) => void> = {};
    (window as unknown as { __media: typeof handlers }).__media = handlers;
    const original = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
    navigator.mediaSession.setActionHandler = (action, handler) => {
      if (handler) handlers[action] = handler;
      original(action, handler);
    };
  });
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();
  await page.getByRole('button', { name: /Play the newest episode/ }).click();
  await expect.poll(() => elapsed(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(1);
  expect(await page.evaluate(() => navigator.mediaSession.metadata?.title)).toBe('Episode 3: No link, GUID and audio');
  expect(await page.evaluate(() => navigator.mediaSession.playbackState)).toBe('playing');

  const audioTime = () => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);
  const press = (action: string, details: Record<string, number> = {}) =>
    page.evaluate(
      ([a, d]) => (window as unknown as { __media: Record<string, (x: unknown) => void> }).__media[a as string]?.({ action: a, ...(d as object) }),
      [action, details] as const,
    );
  const before = await audioTime();
  await press('seekforward');
  const after = await audioTime();
  expect(after - before).toBeGreaterThanOrEqual(14);
  expect(after - before).toBeLessThanOrEqual(16);
  await press('seekbackward');
  expect(after - (await audioTime())).toBeGreaterThanOrEqual(14);
  await press('seekto', { seekTime: 100 });
  expect(Math.round(await audioTime())).toBe(100);
  await press('pause');
  await expect(page.getByRole('button', { name: 'Play', exact: true })).toBeVisible();
  await expect.poll(() => page.evaluate(() => navigator.mediaSession.playbackState)).toBe('paused');
});

test('closing a layer puts focus back where the listener was', async ({ page }) => {
  const focused = () => page.evaluate(() => document.activeElement?.getAttribute('aria-label') ?? document.activeElement?.textContent?.trim() ?? '');
  await page.goto('./#following');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.keyboard.press('Escape');
  await expect.poll(focused).toBe('Follow a show');
  await page.getByRole('button', { name: 'Follow a show' }).first().click();
  await page.getByLabel('Show name, or a feed or Substack address').fill(FEED);
  await page.getByRole('dialog', { name: 'Follow a show' }).getByRole('button', { name: 'Follow' }).click();

  // A show's screen and back again.
  await page.getByRole('button', { name: /^Open Spoken Margins Test Show/ }).click();
  await expect.poll(focused).toBe('Spoken Margins Test Show');
  await page.locator('.back-button').click();
  await expect.poll(focused).toMatch(/^Open Spoken Margins Test Show/);

  // Now Playing, from a Library row: closing it returns to that row.
  await tab(page, 'Library');
  const row = page.getByRole('list', { name: 'Episodes, newest first' }).getByRole('button', { name: /Episode 2: No link, no GUID/ });
  await row.focus();
  await page.keyboard.press('Enter');
  await expect.poll(focused).toBe('Close Now Playing');
  // A composer that closes hands focus back to the button that opened it.
  await page.getByRole('button', { name: 'Write a Margin' }).click();
  await page.getByRole('button', { name: 'Cancel' }).click();
  await expect.poll(focused).toBe('Write a Margin');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog', { name: /Episode 2/ })).toHaveCount(0);
  await expect.poll(() => row.evaluate((el) => el === document.activeElement)).toBe(true);
});
