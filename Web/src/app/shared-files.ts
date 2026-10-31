// `.spokenmargins` files shared to the installed app on Android arrive through the service worker
// (`pwa/service-worker.js`), which parks them in a cache and opens `./?shared=1`. This hook picks them up,
// opens each like a picked file, and removes them from the cache whatever the outcome.
import { useEffect, useRef } from 'react';
import { useData } from './data.tsx';
import { openFiles, type OpenMarginFile } from './import.tsx';
import { consumeLaunchQueue } from './logic/launch-files.ts';

const SHARED_CACHE = 'sm-shared-files';

export function useSharedFiles(open: OpenMarginFile): void {
  const data = useData();
  const handled = useRef(false);

  useEffect(() => {
    if (handled.current || !data.ready) return;
    const params = new URLSearchParams(window.location.search);
    if (!params.has('shared') || !('caches' in window)) return;
    handled.current = true;
    const url = new URL(window.location.href);
    url.searchParams.delete('shared');
    window.history.replaceState(null, '', url.href);

    void (async () => {
      const cache = await caches.open(SHARED_CACHE);
      for (const request of await cache.keys()) {
        const response = await cache.match(request);
        await cache.delete(request);
        if (!response) continue;
        const name = decodeURIComponent(response.headers.get('x-file-name') ?? '') || undefined;
        await open(new Uint8Array(await response.arrayBuffer()), name);
      }
    })();
  }, [data.ready, open]);
}

/**
 * Files the installed app is opened with: on desktop Chrome and Edge, a `.spokenmargins` file double-clicked or
 * opened with Spoken Margins (the manifest's `file_handlers`, #3039). The browser holds them until a consumer is set,
 * so it is set once storage is ready and an episode already in the Library is matched.
 */
export function useLaunchedFiles(open: OpenMarginFile): void {
  const data = useData();
  const openRef = useRef(open);
  openRef.current = open;
  const set = useRef(false);

  useEffect(() => {
    if (set.current || !data.ready) return;
    set.current = true;
    consumeLaunchQueue(window, (files) => void openFiles(files, (bytes, name) => openRef.current(bytes, name)));
  }, [data.ready]);
}
