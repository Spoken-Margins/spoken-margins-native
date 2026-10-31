// Vite builds the web app into `dist/`. `base: './'` keeps every URL relative, so the build works from
// whatever path it is hosted at (where it lives is still the owner's call, #2977).
//
// The service worker is written by hand (`src/app/pwa/service-worker.js`) instead of pulled in from a
// plugin. The small plugin below copies it into the build as `sw.js` and fills in the list of files the
// app shell needs offline, plus a version that changes whenever any of them does.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

/** Build files only a listener who turns transcription on needs: the transcription worker and its chunks. */
const OPT_IN_DIR = 'assets/opt-in/';

function serviceWorker(): Plugin {
  const source = fileURLToPath(new URL('./src/app/pwa/service-worker.js', import.meta.url));
  return {
    name: 'spoken-margins-service-worker',
    apply: 'build',
    generateBundle(_options, bundle) {
      // The speech engine (onnxruntime-web, about 27 MB) stays out of the shell: only a listener who turns
      // transcription on downloads it, and transformers.js then keeps it with the model (src/transcribe/).
      const files = Object.keys(bundle).filter((name) => !name.endsWith('.map') && !/(^|\/)ort-wasm[^/]*$/.test(name));
      // The transcription worker (about 546 KB) is opt-in too (#2977): the service worker keeps it only once a
      // listener who turned transcription on has loaded it, so it still works offline after that.
      const optIn = files.filter((name) => name.startsWith(OPT_IN_DIR));
      const shellFiles = files.filter((name) => !name.startsWith(OPT_IN_DIR));
      const shell = ['./', ...shellFiles.map((name) => `./${name}`), './manifest.webmanifest', './icons/icon.svg', './icons/icon-192.png', './icons/icon-512.png'];
      const version = createHash('sha256').update(files.sort().join('\n')).digest('hex').slice(0, 12);
      const code = readFileSync(source, 'utf8')
        .replace('__SM_SHELL__', JSON.stringify(shell))
        .replace('__SM_OPT_IN__', JSON.stringify(optIn.map((name) => `./${name}`)))
        .replace('__SM_VERSION__', JSON.stringify(version));
      this.emitFile({ type: 'asset', fileName: 'sw.js', source: code });
    },
  };
}

// The share-link switch (#3003), fixed at build time (owner, 2026-10-17: a build setting, never a server switch).
// Only the Playwright build turns it on, with `--mode share-links-test` into the git-ignored `dist-share-links/`;
// every other build, including `npm run build`, leaves link creation out. Turning it on for listeners waits for
// the DMCA designated agent (owner, 2026-10-20) and is a change to this line in a reviewed PR.
export const SHARE_LINKS_TEST_MODE = 'share-links-test';

export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [react(), serviceWorker()],
  define: { __SM_SHARE_LINKS__: JSON.stringify(mode === SHARE_LINKS_TEST_MODE) },
  build: { target: 'es2022', sourcemap: false },
  // The transcription worker (src/transcribe/worker.ts) loads transformers.js, which splits into chunks. They are
  // written under OPT_IN_DIR, so the service worker leaves them out of the shell everyone downloads.
  worker: {
    format: 'es',
    rolldownOptions: { output: { entryFileNames: `${OPT_IN_DIR}[name]-[hash].js`, chunkFileNames: `${OPT_IN_DIR}[name]-[hash].js` } },
  },
  preview: { port: 4173, strictPort: true },
}));
