// A share link opened at the REAL link server's page (#3355), not the stub: research/B4/server is built with `go build`
// and started with `-links-web-url` pointing at this run's web build, one link is sealed under the test vector's key,
// and the browser opens `/l/<id>` as a friend's does. A link with its key cut off or missing must land on the web app's
// "This link is cut off." screen (the old server page said "incomplete or damaged" with the report form open), the full
// link must arrive at "From ...", and `?report` must stay on the server page with the form open. Needs `go` on the PATH.
import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, test, type Page } from '@playwright/test';
import { keyFromFragment, PART } from '../src/packet/share-link.ts';
import { sealPart } from '../src/cli/link-sealing.ts';
import { serveAudio, serveFixtures } from './fixtures.ts';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const SERVER_PORT = Number(process.env.SM_LINK_SERVER_PAGE_PORT ?? 8898);
const SERVER = `http://127.0.0.1:${SERVER_PORT}`;
const WEB = `http://127.0.0.1:${Number(process.env.SM_E2E_PORT ?? 4173)}`;
// The web build in dist-e2e is made for this relay origin; the tests answer it from the real server.
const RELAY = 'https://relay.test';

const vector = JSON.parse(readFileSync(join(repo, 'research/B4/contracts/fixtures/share-link-sealing-vector.json'), 'utf8'));
const KEY: string = vector.keyFragment;

let work = '';
let server: ChildProcess | undefined;
let id = '';

test.beforeEach(async ({}, info) => {
  test.skip(info.project.name !== 'phone', 'One browser size is enough: this checks which page a link lands on.');
});

test.beforeAll(async () => {
  work = mkdtempSync(join(tmpdir(), 'sm-link-server-page-'));
  const binary = join(work, 'smserver');
  // No skip when Go is missing: every test blocks, so a machine without it fails here, loudly.
  execFileSync('go', ['build', '-o', binary, './cmd/smserver'], { cwd: join(repo, 'research/B4/server'), stdio: 'inherit' });
  execFileSync(binary, ['switch', '-public', join(work, 'public'), 'links', 'on'], { stdio: 'inherit' });
  server = spawn(
    binary,
    ['serve', '-listen', `127.0.0.1:${SERVER_PORT}`, '-state', join(work, 'state'), '-public', join(work, 'public'),
      '-links-install-url', 'https://testflight.apple.com/join/EXAMPLE', '-links-web-url', WEB],
    { stdio: 'inherit' },
  );
  for (let tries = 0; ; tries += 1) {
    try {
      if ((await fetch(`${SERVER}/api/v1/health`)).ok) break;
    } catch {
      if (tries > 100) throw new Error('the link server did not start');
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  const key = keyFromFragment(KEY) as Uint8Array;
  const preview = { schema: 'spokenmargins.link-preview.v1', source: { title: 'Episode 1 (example episode)' }, margins: [{ text: 'A Margin.' }] };
  const packet = new Uint8Array(readFileSync(join(repo, 'Contracts/fixtures/web-packets/web-voice.spokenmargins')));
  const form = new FormData();
  form.append('preview', new Blob([await sealPart(new TextEncoder().encode(JSON.stringify(preview)), PART.preview, key)]), 'preview');
  form.append('packet', new Blob([await sealPart(packet, PART.packet, key)]), 'packet');
  const made = await fetch(`${SERVER}/api/v1/links`, { method: 'POST', body: form });
  if (made.status !== 201) throw new Error(`seeding the link answered ${made.status}`);
  id = ((await made.json()).path as string).replace('/l/', '');
});

test.afterAll(() => {
  server?.kill();
  if (work) rmSync(work, { recursive: true, force: true });
});

/** The host the app is served from adds `<base href="/">` at `/l/<id>`, as the stub server does; and relay.test is the real server. */
async function wire(page: Page): Promise<void> {
  await serveFixtures(page);
  await serveAudio(page, 'https://example.com/podcast/**');
  await page.context().route(
    (url) => url.origin === WEB && /^\/l\/[^/]+\/?$/.test(url.pathname),
    async (route) => {
      const home = await route.fetch({ url: `${WEB}/` });
      const html = (await home.text()).replace('<head>', '<head>\n    <base href="/" />');
      await route.fulfill({ response: home, body: html });
    },
  );
  await page.context().route(`${RELAY}/**`, async (route) => {
    const url = new URL(route.request().url());
    const answer = await route.fetch({ url: `${SERVER}${url.pathname}${url.search}` });
    await route.fulfill({ response: answer, headers: { ...answer.headers(), 'access-control-allow-origin': '*' } });
  });
}

const report = (page: Page) => page.locator('details#report');

for (const [name, hash] of [
  ['its key cut to 20 characters', `#${KEY.slice(0, 20)}`],
  ['no key', ''],
  ['an empty # part', '#'],
  ['a trailing dot', `#${KEY}.`],
] as const) {
  test(`${name}: the real server page hands over to the web app's cut-off screen, with no report form open`, async ({ page }) => {
    await wire(page);
    await page.goto(`${SERVER}/l/${id}${hash}`);
    const failed = page.getByTestId('arrival-failed');
    await expect(failed.getByRole('heading', { name: 'This link is cut off.' })).toBeVisible();
    await expect(failed.getByText('Copy the whole link from the message and open it again.')).toBeVisible();
    expect(new URL(page.url()).origin).toBe(WEB);
    await expect(page.getByText('incomplete or damaged')).toHaveCount(0);
    await expect(report(page)).toHaveCount(0);
    // The cut-off screen still reaches the report form, on the link server, and the address has no key in it.
    const link = failed.getByRole('link', { name: 'Report this link' });
    const href = (await link.getAttribute('href')) ?? '';
    expect(href).toBe(`${RELAY}/l/${id}?report`);
    expect(href).not.toContain(KEY.slice(0, 12));
  });
}

test('the full link arrives at who sent it, through the real server page', async ({ page }) => {
  await wire(page);
  await page.goto(`${SERVER}/l/${id}#${KEY}`);
  await expect(page.getByTestId('arrival').getByText('From Web fixture')).toBeVisible();
  expect(new URL(page.url()).origin).toBe(WEB);
});

test('?report stays on the server page with the form open and no failure sentence', async ({ page }) => {
  await wire(page);
  await page.goto(`${SERVER}/l/${id}?report`);
  await expect(report(page)).toHaveAttribute('open', '');
  await expect(page.locator('#category')).toBeVisible();
  await expect(page.locator('#status')).toHaveText('');
  expect(new URL(page.url()).origin).toBe(SERVER);
});

test("the cut-off screen's Report this link reaches the open form with no failure sentence", async ({ page }) => {
  await wire(page);
  await page.goto(`${SERVER}/l/${id}#${KEY.slice(0, 20)}`);
  const popup = page.waitForEvent('popup');
  await page.getByTestId('arrival-failed').getByRole('link', { name: 'Report this link' }).click();
  const reporter = await popup;
  await expect(reporter.locator('details#report')).toHaveAttribute('open', '');
  await expect(reporter.locator('#status')).toHaveText('');
});

test('the report form is closed on the server page, and works with no key and no script', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  const page = await context.newPage();
  await page.goto(`${SERVER}/l/${id}`);
  await expect(report(page)).not.toHaveAttribute('open', '');
  await expect(page.locator('#category')).toBeHidden();
  await page.getByText('Report this link', { exact: true }).first().click();
  await expect(page.locator('#category')).toBeVisible();
  await context.close();
});
