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

function serviceWorker(): Plugin {
  const source = fileURLToPath(new URL('./src/app/pwa/service-worker.js', import.meta.url));
  return {
    name: 'spoken-margins-service-worker',
    apply: 'build',
    generateBundle(_options, bundle) {
      const files = Object.keys(bundle).filter((name) => !name.endsWith('.map'));
      const shell = ['./', ...files.map((name) => `./${name}`), './manifest.webmanifest', './icons/icon.svg', './icons/icon-192.png', './icons/icon-512.png'];
      const version = createHash('sha256').update(files.sort().join('\n')).digest('hex').slice(0, 12);
      const code = readFileSync(source, 'utf8')
        .replace('__SM_SHELL__', JSON.stringify(shell))
        .replace('__SM_VERSION__', JSON.stringify(version));
      this.emitFile({ type: 'asset', fileName: 'sw.js', source: code });
    },
  };
}

export default defineConfig({
  base: './',
  plugins: [react(), serviceWorker()],
  build: { target: 'es2022', sourcemap: false },
  preview: { port: 4173, strictPort: true },
});
