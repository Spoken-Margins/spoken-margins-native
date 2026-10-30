// Spoken Margins service worker. The build (vite.config.ts) copies this file to `sw.js` and fills in
// SHELL (the files the app needs to open offline) and VERSION.
//
// What it does, and nothing more:
// 1. Keeps the app shell, so the app opens with no network. Navigations try the network first and fall
//    back to the cached page; the hashed build files are served from the cache.
// 2. Receives `.spokenmargins` files shared to the installed app on Android (the manifest's
//    `share_target`), parks them in a cache, and opens the app, which imports them.
// Feeds, audio and anything from another origin pass straight through: nothing a listener plays or
// follows is stored here.

const SHELL = __SM_SHELL__;
const VERSION = __SM_VERSION__;
const SHELL_CACHE = `sm-shell-${VERSION}`;
const SHARED_CACHE = 'sm-shared-files';

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key.startsWith('sm-shell-') && key !== SHELL_CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

async function receiveShare(request) {
  const form = await request.formData();
  const files = form.getAll('packet').filter((value) => typeof value !== 'string');
  const cache = await caches.open(SHARED_CACHE);
  let index = 0;
  for (const file of files) {
    const name = file.name || `shared-${index}.spokenmargins`;
    await cache.put(new Request(`./shared/${Date.now()}-${index}`), new Response(file, { headers: { 'x-file-name': encodeURIComponent(name) } }));
    index += 1;
  }
  return Response.redirect(new URL('./?shared=1', self.registration.scope).href, 303);
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.method === 'POST' && url.pathname.endsWith('/share-target')) {
    event.respondWith(receiveShare(request));
    return;
  }
  if (request.method !== 'GET') return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).catch(() => caches.match('./', { ignoreSearch: true }).then((cached) => cached || Response.error())),
    );
    return;
  }

  // ignoreVary: module scripts are requested with an Origin header that the shell's install requests
  // lacked, and a server that answers `Vary: Origin` would otherwise make every cached file miss offline.
  event.respondWith(caches.match(request, { ignoreVary: true }).then((cached) => cached || fetch(request)));
});
