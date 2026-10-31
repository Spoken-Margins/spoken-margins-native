// Playwright builds the app into `dist-e2e/` and serves it through `vite preview` (see webServer), in Chromium only,
// at a phone size (390×844) and a laptop size (1280×800). Screenshots go to `artifacts/web-2982/` at the repo
// root, which git ignores.
import { fileURLToPath } from 'node:url';
import { defineConfig, devices } from '@playwright/test';

// Threads run side by side on one Mac, so another worktree may hold the port: set SM_E2E_PORT to move.
const port = Number(process.env.SM_E2E_PORT ?? 4173);

export default defineConfig({
  testDir: '.',
  outputDir: '../../artifacts/web-e2e/test-results',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  timeout: 45_000,
  use: {
    baseURL: `http://127.0.0.1:${port}/`,
    serviceWorkers: 'block',
    trace: 'retain-on-failure',
    launchOptions: {
      // A fake microphone, so the voice Margin test records without a prompt or a device.
      args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
    },
  },
  projects: [
    {
      name: 'phone',
      use: { ...devices['Desktop Chrome'], viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: false },
    },
    {
      name: 'laptop',
      use: { ...devices['Desktop Chrome'], viewport: { width: 1280, height: 800 } },
    },
    {
      // On-device transcription (transcribe.spec.ts) in installed Google Chrome, the browser listeners use, rather
      // than the bundled Chromium. The fake microphone plays a spoken clip once (`%noloop`).
      name: 'chrome-transcribe',
      testMatch: /transcribe\.spec\.ts$/,
      timeout: 180_000,
      use: {
        ...devices['Desktop Chrome'],
        channel: 'chrome',
        viewport: { width: 390, height: 844 },
        hasTouch: true,
        launchOptions: {
          args: [
            '--use-fake-ui-for-media-stream',
            '--use-fake-device-for-media-stream',
            `--use-file-for-fake-audio-capture=${fileURLToPath(new URL('./audio/ask-not-16k.wav', import.meta.url))}%noloop`,
          ],
        },
      },
    },
  ],
  webServer: [
    {
      // Its own build in `dist-e2e/` (git-ignored, never deployed), with a relay origin only the tests' routes
      // answer, so the consent journey can count relay calls. Link creation is off here, as in every hosted build.
      command: `npx vite build --outDir dist-e2e --emptyOutDir --logLevel warn && npx vite preview --outDir dist-e2e --host 127.0.0.1 --port ${port} --strictPort`,
      env: { VITE_RELAY_ORIGIN: 'https://relay.test' },
      cwd: '..',
      url: `http://127.0.0.1:${port}/`,
      reuseExistingServer: false,
      timeout: 120_000,
    },
    {
      // The share-link journeys (#3003): the only build with link creation on (`--mode share-links-test`, into the
      // git-ignored `dist-share-links/`, never deployed), served with a stub link server on 4174.
      command:
        'npx vite build --mode share-links-test --outDir dist-share-links --emptyOutDir --logLevel warn && node e2e/link-stub-server.ts',
      env: { VITE_RELAY_ORIGIN: 'http://127.0.0.1:4174' },
      cwd: '..',
      url: 'http://127.0.0.1:4174/',
      reuseExistingServer: false,
      timeout: 120_000,
    },
  ],
});
