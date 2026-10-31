// Files the installed web app is opened with (#3039). The manifest's `file_handlers` make it an opener for
// `.spokenmargins` files on desktop Chrome and Edge; the browser then hands each file over through
// `window.launchQueue`. Plain TypeScript with no DOM types, so `npm run test:web` checks it with stand-ins
// (launch-files.test.ts). Safari and Firefox have no launch queue, and nothing here runs there.

/** The part of a file handle this needs. */
export interface LaunchedHandle {
  kind?: string;
  getFile(): Promise<File>;
}

/** The part of the browser's LaunchParams this needs. */
export interface LaunchParamsLike {
  files?: ReadonlyArray<LaunchedHandle>;
}

interface LaunchQueueLike {
  setConsumer(consumer: (params: LaunchParamsLike) => void): void;
}

/** The files a launch carries, in order. A folder, or a file that can no longer be read, is left out. */
export async function launchedFiles(params: LaunchParamsLike): Promise<File[]> {
  const files: File[] = [];
  for (const handle of params.files ?? []) {
    if (handle.kind !== undefined && handle.kind !== 'file') continue;
    try {
      files.push(await handle.getFile());
    } catch {
      // Moved or deleted between the launch and now: the other files still open.
    }
  }
  return files;
}

/**
 * Hands every launch's files to `onFiles`, once they can be read. Returns false where the browser has no launch
 * queue, so a caller knows nothing will ever arrive this way.
 */
export function consumeLaunchQueue(host: unknown, onFiles: (files: File[]) => void): boolean {
  const queue = (host as { launchQueue?: LaunchQueueLike } | undefined)?.launchQueue;
  if (!queue || typeof queue.setConsumer !== 'function') return false;
  queue.setConsumer((params) => {
    void launchedFiles(params).then((files) => {
      if (files.length) onFiles(files);
    });
  });
  return true;
}
