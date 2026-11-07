// The web app is receive-only for share links (owner, 2026-11-05, #3542): it opens and reports links and cannot make
// one, because link creation was removed, not switched off. This fails if code that seals or uploads a link comes back
// into the web build. Sealing and uploading live only in src/cli (the Mac's make-share-link command) and the tests.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const web = fileURLToPath(new URL('../../', import.meta.url));
const src = join(web, 'src');

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sources(path);
    return /\.(ts|tsx)$/.test(entry.name) && !/\.test\.ts$/.test(entry.name) ? [path] : [];
  });
}

// Everything the browser bundle can reach: all of src except the Mac command and the tests.
const bundled = sources(src).filter((path) => !relative(src, path).startsWith('cli/'));

const CREATION = /\/api\/v1\/links|from '[^']*cli\/link-sealing|sealPart|sealPacket|uploadForm|postSealedLink|uploadLink|SHARE_LINKS|__SM_SHARE_LINKS__|ShareLinksOffError/;

test('nothing the web bundle reaches seals or uploads a share link', () => {
  assert.ok(bundled.length > 20, 'the walk found the web sources');
  const hits = bundled.filter((path) => CREATION.test(readFileSync(path, 'utf8'))).map((path) => relative(web, path));
  assert.deepEqual(hits, []);
});

test('the web build has no link-creation switch or build mode left', () => {
  const config = readFileSync(join(web, 'vite.config.ts'), 'utf8');
  assert.doesNotMatch(config, /share-links-test|__SM_SHARE_LINKS__|SHARE_LINKS/);
  const playwright = readFileSync(join(web, 'e2e/playwright.config.ts'), 'utf8');
  assert.doesNotMatch(playwright, /share-links-test|dist-share-links/);
});
