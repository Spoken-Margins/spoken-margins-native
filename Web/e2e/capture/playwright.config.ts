// The recipient capture (#3247): photographs what a first-time friend sees from a share link or a Margin file, in
// WebKit at iPhone size, before and after each slice of the rebuild. It asserts only that each screen was reached;
// it is a camera, not a test, so it never runs in the e2e suite or in CI (its files end in `.capture.ts`).
// Run: cd Web && npx playwright test -c e2e/capture/playwright.config.ts
// Screenshots go to `artifacts/recipient-capture/web/` at the repo root (git-ignored), or SM_CAPTURE_DIR.
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: /\.capture\.ts$/,
  outputDir: '../../../artifacts/recipient-capture/test-results',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  timeout: 45_000,
  use: { serviceWorkers: 'block' },
  projects: [{ name: 'iphone-webkit', use: { ...devices['iPhone 15 Pro'] } }],
  webServer: [
    {
      // The web player, as the share-link journeys serve it (see e2e/playwright.config.ts).
      command:
        'npx vite build --mode share-links-test --outDir dist-share-links --emptyOutDir --logLevel warn && node e2e/link-stub-server.ts',
      env: { VITE_RELAY_ORIGIN: 'http://127.0.0.1:4174' },
      cwd: '../..',
      url: 'http://127.0.0.1:4174/',
      reuseExistingServer: false,
      timeout: 120_000,
    },
    {
      // The link server's own page, with one seeded link (needs Go).
      command: 'node e2e/capture/landing-server.ts',
      cwd: '../..',
      url: `http://127.0.0.1:${process.env.SM_LANDING_PORT ?? 8899}/api/v1/health`,
      reuseExistingServer: false,
      timeout: 120_000,
    },
  ],
});
