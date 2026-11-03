// What a first-time friend sees from a share link or a Margin file (#3247), photographed screen by screen: first
// the link server's own page, which every friend meets until links open the app, then the web player. Each shot
// is saved twice, the visible screen and the whole scrolled page. Configuration and how to run: playwright.config.ts.
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { serveAudio } from '../fixtures.ts';

const OUT = process.env.SM_CAPTURE_DIR ?? fileURLToPath(new URL('../../../artifacts/recipient-capture/web', import.meta.url));
const vector = JSON.parse(
  readFileSync(fileURLToPath(new URL('../../../research/B4/contracts/fixtures/share-link-sealing-vector.json', import.meta.url)), 'utf8'),
);
const KEY: string = vector.keyFragment;
const STUB = 'http://127.0.0.1:4174';
const EPISODE = 'Episode 1 (example episode)';
const FILE = fileURLToPath(new URL('../../../Contracts/fixtures/web-packets/web-voice.spokenmargins', import.meta.url));

test.beforeEach(async ({ page }) => {
  mkdirSync(OUT, { recursive: true });
  await serveAudio(page, 'https://example.com/podcast/**');
});

async function snap(page: Page, name: string) {
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${OUT}/${name}.png` });
  await page.screenshot({ path: `${OUT}/${name}-full.png`, fullPage: true });
}

test('the link server page, which a friend meets first', async ({ page }) => {
  // The server answers its health check a moment before landing-server.ts has seeded the link.
  const seeded = join(tmpdir(), 'sm-landing-seeded-link.txt');
  await expect.poll(() => existsSync(seeded), { timeout: 10_000 }).toBe(true);
  const link = readFileSync(seeded, 'utf8').trim();
  await page.goto(link);
  await expect(page.getByRole('heading', { name: 'Shared Margins' })).toBeVisible();
  await snap(page, '01-landing');
  const { origin, pathname } = new URL(link);
  await page.goto(`${origin}${pathname}`);
  await snap(page, '02-landing-no-key');
  await page.goto(`${origin}/l/ffffffffffffffffffffffffffffffff#${KEY}`);
  await snap(page, '03-landing-unknown-link');
});

test('the web player, opened at a link', async ({ page }) => {
  await page.goto(`${STUB}/l/vectorvoice01#${KEY}`);
  const playing = page.getByRole('dialog', { name: EPISODE });
  await expect(playing).toBeVisible();
  await snap(page, '10-player-link-landed');
  await page.waitForTimeout(4000);
  await snap(page, '11-player-after-4s');
  await playing.getByRole('button', { name: 'Close Now Playing' }).click();
  await snap(page, '12-player-library-after-close');
  await page.goto(`${STUB}/l/expired00001#${KEY}`);
  await snap(page, '13-player-expired');
});

test('the web player, for a newcomer with nothing yet', async ({ page }) => {
  await page.goto(`${STUB}/`);
  await snap(page, '20-player-first-visit');
  await page.goto(`${STUB}/#margins`);
  await snap(page, '21-player-margins-tab');
  await page.getByRole('button', { name: 'Open a link' }).click();
  await snap(page, '22-player-open-a-link');
});

test('the web player, opening a Margin file', async ({ page }) => {
  await page.goto(`${STUB}/#margins`);
  const choosing = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: /Open a Margin file/ }).click();
  await (await choosing).setFiles(FILE);
  await expect(page.getByRole('dialog', { name: EPISODE })).toBeVisible();
  await snap(page, '30-player-file-opened');
});
