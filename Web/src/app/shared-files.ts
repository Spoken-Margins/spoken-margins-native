// `.spokenmargins` files shared to the installed app on Android arrive through the service worker
// (`pwa/service-worker.js`), which parks them in a cache and opens `./?shared=1`. This hook picks them up,
// opens each like a picked file, and removes them from the cache whatever the outcome.
import { useEffect, useRef } from 'react';
import { useData } from './data.tsx';
import type { OpenMarginFile } from './import.tsx';

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
