// What a listener reads when something fails (#2979, "every failure path a listener can hit shows a plain
// message"). The logic modules throw typed errors with technical detail; this turns each into one plain sentence
// that says what happened and what to do. Plain TypeScript, so `npm run test:web` covers it (messages.test.ts).
import { PacketError } from '../../packet/errors.ts';
import { NotAacError } from '../../packet/m4a.ts';
import { RecordingUnavailableError } from '../../packet/record.ts';
import { FeedParseError } from '../../sources/feed.ts';
import { PostPageReadRefused, ReadHttpError, ReadTooLarge, RelayNotConfigured } from '../../sources/read.ts';
import { SearchError } from '../../sources/search.ts';

export const MESSAGES = Object.freeze({
  feedGone: 'Nothing is at that feed address any more. Check the address, or search for the show by name.',
  feedRefused: 'That feed’s site refused to send it. Try again later, or search for the show by name.',
  feedSiteError: 'That feed’s site isn’t answering properly right now. Try again later.',
  notAFeed: 'That address isn’t a podcast or Substack feed. Feed addresses often end in /feed or .rss.',
  tooLarge: 'That feed is too large for the web app to read.',
  noRelay: 'This feed doesn’t let browsers read it, and this copy of the web app has no server to read it through.',
  relayBusy: 'Our server is busy reading other feeds. Try again in a minute.',
  relayLimit: 'Our server has read a lot of feeds for you this hour. Try again later.',
  relayOff: 'Reading feeds through our server isn’t available right now.',
  relayFailed: 'Our server couldn’t read that feed. Its site may be down, or the feed may not be a podcast or Substack feed.',
  offline: 'No connection. Check you’re online, then try again.',
  searchFailed: 'Search isn’t answering right now. Try again, or paste the show’s feed address.',
  micBlocked: 'The microphone is blocked for this site. Allow it in your browser’s site settings, then try again. Written Margins still work.',
  micMissing: 'No microphone was found. Connect one, then try again. Written Margins still work.',
  micBusy: 'Another app is using the microphone. Close it, then try again.',
  notAac: 'This browser recorded in a format the iPhone app can’t play, so the voice Margin wasn’t kept. Written Margins still work.',
  postNeedsTap: 'A post’s page is read only when you tap that post.',
});

function errorName(error: unknown): string | undefined {
  return typeof error === 'object' && error !== null && 'name' in error && typeof (error as { name: unknown }).name === 'string'
    ? (error as { name: string }).name
    : undefined;
}

function relayStatus(status: number): string {
  if (status === 429) return MESSAGES.relayLimit;
  if (status === 503) return MESSAGES.relayBusy;
  if (status === 403 || status === 404) return MESSAGES.relayOff;
  return MESSAGES.relayFailed;
}

/**
 * One plain sentence for any error a listener can meet. `microphone` says the error came from starting or stopping
 * a recording, where the browser's DOMException names (NotAllowedError and the rest) are about the microphone.
 */
export function plainError(error: unknown, context?: 'microphone'): string {
  if (error instanceof PacketError || error instanceof RecordingUnavailableError) return error.message;
  if (error instanceof NotAacError) return MESSAGES.notAac;
  if (error instanceof ReadHttpError) {
    if (error.via === 'relay') return relayStatus(error.status);
    if (error.status === 404 || error.status === 410) return MESSAGES.feedGone;
    if (error.status === 401 || error.status === 403) return MESSAGES.feedRefused;
    return MESSAGES.feedSiteError;
  }
  if (error instanceof FeedParseError) return MESSAGES.notAFeed;
  if (error instanceof ReadTooLarge) return MESSAGES.tooLarge;
  if (error instanceof RelayNotConfigured) return MESSAGES.noRelay;
  if (error instanceof PostPageReadRefused) return MESSAGES.postNeedsTap;
  if (error instanceof SearchError) return MESSAGES.searchFailed;
  const name = errorName(error);
  // What `fetch` throws with no network ("Failed to fetch" in Chrome, "Load failed" in Safari).
  if (name === 'TypeError' && /fetch|network|load failed/i.test(error instanceof Error ? error.message : '')) return MESSAGES.offline;
  if (context === 'microphone') {
    switch (name) {
      case 'NotAllowedError':
      case 'SecurityError':
      case 'PermissionDeniedError':
        return MESSAGES.micBlocked;
      case 'NotFoundError':
      case 'OverconstrainedError':
      case 'DevicesNotFoundError':
        return MESSAGES.micMissing;
      case 'NotReadableError':
      case 'TrackStartError':
        return MESSAGES.micBusy;
    }
  }
  return error instanceof Error ? error.message : String(error);
}
