// Spoken Margins service worker. The build (vite.config.ts) copies this file to `sw.js` and fills in
// SHELL (the files the app needs to open offline), OPT_IN (build files only some listeners need) and VERSION.
//
// What it does, and nothing more:
// 1. Keeps the app shell, so the app opens with no network. Navigations try the network first and fall
//    back to the cached page; the hashed build files are served from the cache.
// 1a. Keeps the opt-in files (the transcription worker, #2977) only once this browser has loaded one, which
//    happens only after the listener turned transcription on. From then on they work offline, and a new
//    version of the app fetches its own copies when it installs.
// 2. Receives `.spokenmargins` files shared to the installed app on Android (the manifest's
//    `share_target`), parks them in a cache, and opens the app, which imports them.
// Feeds, audio and anything from another origin pass straight through: nothing a listener plays or
// follows is stored here.

const SHELL = __SM_SHELL__;
const OPT_IN = __SM_OPT_IN__;
const VERSION = __SM_VERSION__;
const SHELL_CACHE = `sm-shell-${VERSION}`;
const OPT_IN_CACHE = `sm-opt-in-${VERSION}`;
const SHARED_CACHE = 'sm-shared-files';

const OPT_IN_URLS = new Set(OPT_IN.map((path) => new URL(path, self.registration.scope).href));

/** Whether an earlier version kept opt-in files, meaning this listener turned transcription on. */
async function optedIn() {
  for (const key of await caches.keys()) {
    if (key.startsWith('sm-opt-in-') && key !== OPT_IN_CACHE && (await (await caches.open(key)).keys()).length > 0) return true;
  }
  return false;
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      .then((cache) => cache.addAll(SHELL))
      // Best effort: a listener who had transcription on gets this version's worker now, so it works offline
      // after an update too. Failing here never stops the update.
      .then(() => optedIn())
      .then((yes) => (yes && OPT_IN.length ? caches.open(OPT_IN_CACHE).then((cache) => cache.addAll(OPT_IN)).catch(() => undefined) : undefined))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  const stale = (key) => (key.startsWith('sm-shell-') && key !== SHELL_CACHE) || (key.startsWith('sm-opt-in-') && key !== OPT_IN_CACHE);
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter(stale).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

/** An opt-in file: from its cache, or fetched and then kept. */
async function optInFile(request) {
  const cache = await caches.open(OPT_IN_CACHE);
  const cached = await cache.match(request, { ignoreVary: true, ignoreSearch: true });
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok) await cache.put(request.url.split('?')[0], response.clone());
  return response;
}

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

  if (OPT_IN_URLS.has(url.origin + url.pathname)) {
    event.respondWith(optInFile(request));
    return;
  }

  // ignoreVary: module scripts are requested with an Origin header that the shell's install requests
  // lacked, and a server that answers `Vary: Origin` would otherwise make every cached file miss offline.
  event.respondWith(caches.match(request, { ignoreVary: true }).then((cached) => cached || fetch(request)));
});
