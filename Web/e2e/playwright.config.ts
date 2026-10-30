// Playwright builds the app into `dist-e2e/` and serves it through `vite preview` (see webServer), in Chromium only,
// at a phone size (390×844) and a laptop size (1280×800). Screenshots go to `artifacts/web-2982/` at the repo
// root, which git ignores.
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  outputDir: '../../artifacts/web-2982/test-results',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  timeout: 45_000,
  use: {
    baseURL: 'http://127.0.0.1:4173/',
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
  ],
  webServer: {
    // Its own build in `dist-e2e/` (git-ignored, never deployed), with a relay origin only the tests' routes
    // answer, so the consent journey can count relay calls.
    command:
      'npx vite build --outDir dist-e2e --emptyOutDir --logLevel warn && npx vite preview --outDir dist-e2e --host 127.0.0.1 --port 4173 --strictPort',
    env: { VITE_RELAY_ORIGIN: 'https://relay.test' },
    cwd: '..',
    url: 'http://127.0.0.1:4173/',
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
