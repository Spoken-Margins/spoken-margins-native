// #3375: nothing a Playwright run plays or speaks may reach the Mac's speakers. The web servers build with the silence
// script (e2e/silence/silence-script.js); this proves it is in the page and does what it says, in every project. It
// plays only digital silence itself (all-128 8-bit WAV), so even a browser that ignored every setting here is quiet.
// An agent cannot hear: this proves the page's volume and speech calls, not what a speaker does.
import { expect, test, type Page } from '@playwright/test';
import { SILENT_TAG_ID } from './silence/silence-plugin.ts';

declare global {
  interface Window {
    __smSilent?: { spoken: string[]; speechCalls: string[]; realVolume(el: HTMLMediaElement): number };
  }
}

/** A page of the app, tapped once, as a listener's first tap grants the page its permission to play. */
async function tappedPage(page: Page): Promise<void> {
  await page.goto('./');
  await page.locator('body').click({ position: { x: 5, y: 5 } });
}

/** Makes a looping element on a blob of silence (digital silence, whatever the volume). Returns nothing; it is `window.__el`. */
const makeSilentElement = (page: Page) =>
  page.evaluate(() => {
    const rate = 8000;
    const bytes = new Uint8Array(44 + rate * 2).fill(128);
    const view = new DataView(bytes.buffer);
    const text = (at: number, s: string) => [...s].forEach((c, i) => view.setUint8(at + i, c.charCodeAt(0)));
    text(0, 'RIFF');
    view.setUint32(4, 36 + rate * 2, true);
    text(8, 'WAVEfmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, rate, true);
    view.setUint32(28, rate, true);
    view.setUint16(32, 1, true);
    view.setUint16(34, 8, true);
    text(36, 'data');
    view.setUint32(40, rate * 2, true);
    const element = document.createElement('audio');
    element.src = URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
    element.loop = true;
    (window as unknown as { __el: HTMLMediaElement }).__el = element;
  });

test('the silence script is in the page', async ({ page }) => {
  await page.goto('./');
  expect(await page.evaluate(() => typeof window.__smSilent?.realVolume)).toBe('function');
  // First thing in <head>, so it runs before any page script.
  expect(await page.evaluate((id) => document.head.firstElementChild?.id === id, SILENT_TAG_ID)).toBe(true);
});

test('play() after a tap keeps the logical volume at 1, holds the real volume at 0, and the clock still runs', async ({ page }) => {
  await tappedPage(page);
  await makeSilentElement(page);
  const result = await page.evaluate(async () => {
    const el = (window as unknown as { __el: HTMLMediaElement }).__el;
    const watch = window.__smSilent!;
    await el.play();
    const right = { logical: el.volume, real: watch.realVolume(el), muted: el.muted };
    el.volume = 0.25; // as the player turns the episode down while a Margin is read
    const ducked = { logical: el.volume, real: watch.realVolume(el) };
    el.volume = 1;
    return { right, ducked, back: { logical: el.volume, real: watch.realVolume(el) } };
  });
  expect(result.right).toEqual({ logical: 1, real: 0, muted: false });
  expect(result.ducked).toEqual({ logical: 0.25, real: 0 });
  expect(result.back).toEqual({ logical: 1, real: 0 });
  await expect.poll(() => page.evaluate(() => (window as unknown as { __el: HTMLMediaElement }).__el.currentTime), { timeout: 5000 }).toBeGreaterThan(0.3);
  // Pausing and playing again keeps it silent; an out-of-range volume still throws as a browser's does.
  const again = await page.evaluate(async () => {
    const el = (window as unknown as { __el: HTMLMediaElement }).__el;
    el.pause();
    await el.play();
    let thrown = '';
    try { el.volume = 2; } catch (error) { thrown = (error as Error).name; }
    return { real: window.__smSilent!.realVolume(el), logical: el.volume, thrown };
  });
  expect(again).toEqual({ real: 0, logical: 1, thrown: 'IndexSizeError' });
});

test('speak() records the words and fires start, then end; cancel() fires error "canceled"; nothing reaches the engine', async ({ page }) => {
  await page.goto('./');
  const result = await page.evaluate(async () => {
    const synth = speechSynthesis;
    const events: string[] = [];
    const first = new SpeechSynthesisUtterance('Cole wrote: hello');
    for (const type of ['start', 'end', 'error'] as const) first.addEventListener(type, (event) => events.push(type + ((event as SpeechSynthesisErrorEvent).error ? `:${(event as SpeechSynthesisErrorEvent).error}` : '')));
    const done = new Promise<void>((resolve) => first.addEventListener('end', () => resolve()));
    synth.speak(first);
    const flags = { speaking: synth.speaking, pending: synth.pending };
    await done;
    const afterEnd = { speaking: synth.speaking, pending: synth.pending };

    const second = new SpeechSynthesisUtterance('a long second reading that will be cut off');
    const cut = new Promise<string>((resolve) => second.addEventListener('error', (event) => resolve((event as SpeechSynthesisErrorEvent).error)));
    synth.speak(second);
    await new Promise((resolve) => setTimeout(resolve, 60));
    synth.cancel();
    return { events, flags, afterEnd, cut: await cut, spoken: window.__smSilent!.spoken, afterCancel: synth.speaking };
  });
  expect(result.events).toEqual(['start', 'end']);
  expect(result.flags.speaking || result.flags.pending).toBe(true);
  expect(result.afterEnd).toEqual({ speaking: false, pending: false });
  expect(result.cut).toBe('canceled');
  expect(result.afterCancel).toBe(false);
  expect(result.spoken).toEqual(['Cole wrote: hello', 'a long second reading that will be cut off']);
});

test('Web Audio output goes through a zero gain; captures and the connect() contract are untouched', async ({ page }) => {
  await page.goto('./');
  const result = await page.evaluate(() => {
    const context = new AudioContext();
    const tone = context.createOscillator();
    const gain = context.createGain();
    const returned = tone.connect(gain).connect(context.destination);
    const capture = context.createMediaStreamDestination(); // what a recording reads: not the speakers
    const toCapture = gain.connect(capture);
    let disconnected = true;
    try { gain.disconnect(context.destination); } catch { disconnected = false; }
    void context.close();
    return { returnsDestination: returned === context.destination, capturesUnchanged: toCapture === capture, disconnected };
  });
  expect(result).toEqual({ returnsDestination: true, capturesUnchanged: true, disconnected: true });
});

test('playing without a tap gets the same answer with the script as without it', async ({ page, browserName }, info) => {
  const attempt = async () => {
    await page.goto('./');
    await makeSilentElement(page);
    return page.evaluate(async () => {
      const el = (window as unknown as { __el: HTMLMediaElement }).__el;
      const outcome = async (prepare: () => void) => {
        el.pause();
        el.muted = false;
        el.volume = 1;
        prepare();
        try { await el.play(); return 'played'; } catch (error) { return (error as Error).name; }
      };
      // Audible first. The other two are what the browsers' rule relaxes, reported to show what the script avoids.
      const audible = await outcome(() => undefined);
      const volumeZero = await outcome(() => { el.volume = 0; });
      const muted = await outcome(() => { el.volume = 1; el.muted = true; });
      return { audible, volumeZero, muted };
    });
  };
  const withScript = await attempt();

  // The same page with the script's tag cut out of the document.
  await page.route('**/', async (route) => {
    if (route.request().resourceType() !== 'document') return route.fallback();
    const response = await route.fetch();
    const html = (await response.text()).replace(new RegExp(`<script id="${SILENT_TAG_ID}">[\\s\\S]*?</script>`), '');
    return route.fulfill({ response, body: html });
  });
  const withoutScript = await attempt();
  expect(await page.evaluate(() => window.__smSilent)).toBeUndefined();

  info.annotations.push({ type: 'autoplay', description: `${browserName}: with script ${JSON.stringify(withScript)}; without ${JSON.stringify(withoutScript)}` });
  console.log(`autoplay without a tap, ${info.project.name}: with script ${JSON.stringify(withScript)}; without ${JSON.stringify(withoutScript)}`);
  expect(withScript.audible).toBe(withoutScript.audible);
});
