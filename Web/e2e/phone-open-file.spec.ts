// The owner's phone feedback (#3039, 2026-10-31): "I didn't see a way to import margins... if someone handed me a
// .margins file, I don't know how I would listen to it in this website." A friend's `.spokenmargins` file opens from
// the Library, where a listener looks first, lands on the first Margin in Now Playing, and offers to play from there
// when the browser won't start the audio by itself. Runs at iPhone size in Chrome and WebKit (`phone-*` projects).
import { expect, test, type Page } from '@playwright/test';
import type { Episode, Margin } from '../src/shared/model.ts';
import { writePacket } from '../src/packet/write.ts';
import { BROWSER_PACKET_ACCEPT } from '../src/app/logic/native-packets.ts';
import { serveFixtures, shot } from './fixtures.ts';

const TITLE = 'The tide tables, explained';
const episode: Episode = {
  id: 'sam-episode',
  showId: 'sam-show',
  title: TITLE,
  guid: 'sam-episode-guid',
  audioUrl: 'https://media.example.com/tide-tables.mp3',
  audioOrigin: 'podcast-enclosure',
  durationSeconds: 180,
};
const FIRST_AT = 42;
const margins: Margin[] = [
  { id: 'm2', episodeId: episode.id, atSeconds: 95, createdAt: '2026-10-31T10:05:00Z', text: 'And this is why.' },
  { id: 'm1', episodeId: episode.id, atSeconds: FIRST_AT, createdAt: '2026-10-31T10:00:00Z', text: 'Listen to the tide bit.' },
];

async function packet(): Promise<{ name: string; buffer: Buffer }> {
  const written = await writePacket(episode, margins, { sender: 'Sam' });
  return { name: written.fileName, buffer: Buffer.from(written.bytes) };
}

/**
 * The browser refuses to start the audio by itself the first time, as Safari on an iPhone does when a file finishes
 * opening with no tap to play. Later calls, from a tap, play.
 */
async function refuseFirstAutoplay(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const play = HTMLMediaElement.prototype.play;
    let refused = false;
    HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
      if (!refused) {
        refused = true;
        return Promise.reject(new DOMException('play() needs a tap', 'NotAllowedError'));
      }
      return play.call(this);
    };
  });
}

const audioTime = (page: Page) => page.getByTestId('audio').evaluate((a: HTMLAudioElement) => a.currentTime);

test.beforeEach(async ({ page }) => {
  await serveFixtures(page);
});

test('a Margin file opens from the Library and offers to play from the first Margin', async ({ page, browserName }, info) => {
  await refuseFirstAutoplay(page);
  await page.goto('./');
  const open = page.getByRole('button', { name: 'Open a Margin file' });
  await expect(open).toBeVisible();
  await expect(page.getByText(/Got a \.spokenmargins file from a friend\?/)).toBeVisible();
  // On an iPhone the picker filters nothing, so a file iOS has no type for isn't greyed out.
  const picker = page.getByTestId('margin-file');
  if (browserName === 'webkit') expect(await picker.getAttribute('accept')).toBeNull();
  else expect(await picker.getAttribute('accept')).toBe(BROWSER_PACKET_ACCEPT);
  await shot(page, info, '3039-library-empty');

  // The button opens the picker.
  const choosing = page.waitForEvent('filechooser');
  await open.click();
  const chooser = await choosing;
  await chooser.setFiles(await packet());

  await expect(page.getByText(`Opened 2 Margins from Sam on “${TITLE}”.`)).toBeVisible();
  const nowPlaying = page.getByRole('dialog', { name: TITLE });
  await expect(nowPlaying).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(FIRST_AT - 0.5);
  const offer = nowPlaying.getByRole('button', { name: 'Play from the first Margin, at 0:42' });
  await expect(offer).toBeVisible();
  await shot(page, info, '3039-landed');

  await offer.click();
  await expect(nowPlaying.getByRole('button', { name: 'Pause' })).toBeVisible();
  await expect(offer).toBeHidden();
  const at = await audioTime(page);
  expect(at).toBeGreaterThanOrEqual(FIRST_AT - 0.5);
  expect(at).toBeLessThan(FIRST_AT + 5);
});

test('a Margin file the installed app is opened with lands the same way', async ({ page }) => {
  // Desktop Chrome and Edge hand the file over through `window.launchQueue` (the manifest's `file_handlers`). The
  // stand-in queue gives the app one launch, as the browser does once the app sets its consumer.
  const { name, buffer } = await packet();
  await page.addInitScript(
    ({ fileName, base64 }) => {
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      const handle = { kind: 'file', getFile: async () => new File([bytes], fileName) };
      Object.defineProperty(window, 'launchQueue', {
        configurable: true,
        value: { setConsumer: (consumer: (params: unknown) => void) => consumer({ files: [handle] }) },
      });
    },
    { fileName: name, base64: buffer.toString('base64') },
  );
  await page.goto('./');
  await expect(page.getByText(`Opened 2 Margins from Sam on “${TITLE}”.`)).toBeVisible();
  await expect(page.getByRole('dialog', { name: TITLE })).toBeVisible();
  await expect.poll(() => audioTime(page), { timeout: 10_000 }).toBeGreaterThanOrEqual(FIRST_AT - 0.5);
});
