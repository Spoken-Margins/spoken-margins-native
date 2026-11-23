// The reads the sender's check makes (#4454, PR 1b) go through the iPhone app, never through this page's own `fetch`.
// A friend's browser can't read a publisher's page (CORS), and falling back to our relay would show our server the item's
// address right after a sealed upload, which sealed links exist to hide. So inside the check the page asks the app, which
// reads with its own network stack, no cookies and a size cap, and answers on the same call.
//
// The reads are the ones the owner agreed to (the Share link tap is his action), once per link and nothing else:
// - 2026-11-17: one read of a Substack post's page, and the first 1 KB of the episode's audio;
// - 2026-11-23 (#4783): for an Apple Podcasts episode page, Apple's public lookup for that show and, when Apple doesn't list
//   the episode, one read of the show's own feed (the address Apple's answer names), as the friend's page does.
//
// The app's handler is `window.webkit.messageHandlers.smPlayCheckRead`, a handler WebKit answers with a Promise:
//   { kind: 'page', url }          -> { status, url?, body? }          the page's text (the app caps it as `read.ts` does:
//                                                                      over the cap it answers `tooLarge: true` and no body)
//   { kind: 'apple-lookup', url }  -> { status, url?, body? }          Apple's lookup answer; the app reads only `appleLookupUrl`'s shape
//   { kind: 'feed', url }          -> { status, url?, body? }          the show's feed; the app reads only a feed Apple's answer named
//   { kind: 'audio-start', url }   -> { status, contentType? }         the first 1 KB of the audio, as a range read; no body comes back
// A read that can't reach the publisher rejects. A read the app won't make rejects with `READ_REFUSED` (an app built before
// a kind existed refuses it the same way). No page without the handler reads anything.
import type { ReadTransport } from '../sources/native-http.ts';
import { DEFAULT_MAX_BYTES, ReadTooLarge } from '../sources/read.ts';

/** The kinds of read that answer with a page's text. */
export type CheckTextReadKind = 'page' | 'apple-lookup' | 'feed';

export type CheckReadRequest = { kind: CheckTextReadKind; url: string } | { kind: 'audio-start'; url: string };

/** What the app answers for a read it won't make (`ShareLinkPlayCheckRunner`): WebKit rejects the call with this message. */
export const READ_REFUSED = 'This read is not allowed.';

/** Whether a rejected read was the app refusing it, not the network failing. */
export function isReadRefused(error: unknown): boolean {
  return error instanceof Error && error.message === READ_REFUSED;
}

export interface CheckReadReply {
  status: number;
  /** Where a page read ended after redirects. */
  url?: string;
  body?: string;
  contentType?: string;
  /** The body was over the app's cap (the same 4 MB a browser's read stops at), so none came back. */
  tooLarge?: boolean;
}

export interface CheckReadHandler {
  postMessage(request: CheckReadRequest): Promise<CheckReadReply>;
}

/** The handler the app injects for the check's reads, or undefined in any other browser. */
export function checkReadHandler(host: unknown = globalThis): CheckReadHandler | undefined {
  const handler = (host as { webkit?: { messageHandlers?: { smPlayCheckRead?: Partial<CheckReadHandler> } } } | null | undefined)?.webkit?.messageHandlers?.smPlayCheckRead;
  return handler && typeof handler.postMessage === 'function' ? (handler as CheckReadHandler) : undefined;
}

/** Statuses whose `Response` must have no body. */
const NULL_BODY = new Set([204, 205, 304]);

/**
 * A transport for `readUrl` whose every GET is asked of the app, as a read of `kind`. It is `native`, so a failed read is the
 * network's and never becomes a relay read; credentials are the app's to leave out. A feed named as `http://` is asked for
 * as `https://`: the app reads https only, as a friend's https page would.
 */
export function checkTransport(handler: CheckReadHandler, kind: CheckTextReadKind = 'page'): ReadTransport {
  return {
    kind: 'native',
    fetch: async (input, init) => {
      const method = (init?.method ?? 'GET').toUpperCase();
      if (method !== 'GET') throw new TypeError(`The check only reads; ${method} is not supported.`);
      let reply: CheckReadReply;
      try {
        const url = kind === 'feed' ? input.replace(/^http:/i, 'https:') : input;
        reply = await handler.postMessage({ kind, url });
      } catch (error) {
        throw new TypeError(`Network request failed: ${error instanceof Error ? error.message : String(error)}`);
      }
      // The app stopped at the size a browser's read stops at: the same answer `readUrl` gives a friend.
      if (reply?.tooLarge === true) throw new ReadTooLarge(DEFAULT_MAX_BYTES);
      const status = reply?.status;
      if (typeof status !== 'number' || !Number.isInteger(status) || status < 200 || status > 599) {
        throw new TypeError(`Network request failed: the app answered with status ${String(status)}.`);
      }
      const response = new Response(NULL_BODY.has(status) ? null : (reply.body ?? ''), { status });
      Object.defineProperty(response, 'url', { value: typeof reply.url === 'string' && reply.url ? reply.url : input });
      return response;
    },
  };
}

export type AudioVerdict = 'plays' | 'audio-refused' | 'audio-format' | 'unreachable';

/** Audio and video types Chrome, Firefox or Safari play, even where the sender's own WebKit says no. */
const PLAYS_IN_OTHER_BROWSERS = /^(audio|video)\/(mpeg|mp3|mp4|x-m4a|m4a|aac|x-aac|wav|x-wav|wave|ogg|opus|webm|flac|x-flac|3gpp|3gpp2)$/;

/**
 * What the start of an episode's audio says about whether a browser can play it. A warning is only for what is clear: a
 * 4xx (the server turned the request away), a page where audio should be, an audio or video type this browser says it
 * can't play. Anything unclear passes, since a false warning on a link a friend then plays is worse than none.
 * A 5xx, a 429, another 4xx (a host may turn the app away and serve a browser) or a redirect left over says only that
 * the check couldn't tell (`unreachable`).
 */
export function classifyAudioStart(reply: Pick<CheckReadReply, 'status' | 'contentType'>, canPlayType: (type: string) => string): AudioVerdict {
  const { status } = reply;
  if (status >= 500 || status === 429 || (status >= 300 && status < 400) || status < 200) return 'unreachable';
  // A host that turns the app's request away (401, 403, bot rules, hotlink rules) may serve a friend's browser: that is
  // "couldn't tell". Only a missing file is clear.
  if (status === 404 || status === 410) return 'audio-refused';
  if (status >= 400) return 'unreachable';
  const type = (reply.contentType ?? '').split(';')[0].trim().toLowerCase();
  if (!type) return 'plays';
  if (type.startsWith('text/') || type === 'application/json' || type.endsWith('+xml') || type === 'application/xml') return 'audio-refused';
  // This is the sender's WebKit asked about a friend's browser: formats other browsers play are never a warning.
  if (PLAYS_IN_OTHER_BROWSERS.test(type)) return 'plays';
  if ((type.startsWith('audio/') || type.startsWith('video/')) && canPlayType(type) === '') return 'audio-format';
  return 'plays';
}

/** WebKit's own answer for a media type, without loading anything. */
export function browserCanPlayType(type: string): string {
  try {
    return document.createElement('audio').canPlayType(type);
  } catch {
    // A page that can't ask says nothing against the audio.
    return 'maybe';
  }
}
