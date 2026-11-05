// The Vite plugin that makes the test-only web builds silent (#3375). With VITE_E2E_SILENT=1 set, it puts
// silence-script.js at the top of <head> of every HTML page in the build (there is one, index.html). Without it,
// it does nothing, so `vite build` as the deploy runs it carries no silence code. The Playwright configs set the
// variable on every web server that builds the app; Web/src/e2e-guard/ checks they all do.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Plugin } from 'vite';

export const SILENT_ENV = 'VITE_E2E_SILENT';
/** Marks the injected tag, so a test can strip it to compare a page with and without. */
export const SILENT_TAG_ID = 'sm-e2e-silent';

export function e2eSilence(): Plugin {
  const source = fileURLToPath(new URL('./silence-script.js', import.meta.url));
  return {
    name: 'spoken-margins-e2e-silence',
    transformIndexHtml: {
      order: 'pre',
      handler() {
        if (process.env[SILENT_ENV] !== '1') return undefined;
        return [{ tag: 'script', attrs: { id: SILENT_TAG_ID }, children: readFileSync(source, 'utf8'), injectTo: 'head-prepend' as const }];
      },
    },
  };
}
