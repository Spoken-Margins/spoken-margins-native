// The read path for feeds and pages (owner, 2026-10-30): the browser's own `fetch` first. Only when that fails
// because the site doesn't allow browser reads (CORS) or the network refuses, ask the listener once and then
// read through the Spoken Margins server's relay, which keeps nothing.
//
// A Substack post page is read only when the listener taps that post (owner, 2026-10-21), so `readUrl` refuses a
// post page unless the caller passes `reason: 'listener-tap'`.

import { parseFeed } from './feed.ts';
import type { ParseFeedOptions, ParsedFeed } from './feed.ts';
import type { FetchLike } from './search.ts';
import { findSubstackVoice, isSubstackPostUrl } from './substack.ts';
import type { SubstackVoice } from './substack.ts';

/** Why the page is being read. Only an explicit tap may read a Substack post page. */
export type ReadReason = 'listener-tap' | 'feed-refresh' | 'search';

/** The direct read failed and the relay needs the listener's consent first. Ask once, then retry with `consent: true`. */
export class NeedsRelayConsent extends Error {
  readonly url: string;
  constructor(url: string) {
    super('This site does not allow reading from a browser. Reading it through the Spoken Margins server needs your OK.');
    this.name = 'NeedsRelayConsent';
    this.url = url;
  }
}

/** A Substack post page was asked for without a listener tap. */
export class PostPageReadRefused extends Error {
  readonly url: string;
  constructor(url: string) {
    super('A Substack post page is read only when the listener taps that post.');
    this.name = 'PostPageReadRefused';
    this.url = url;
  }
}

/** The site or the relay answered, with an error status. */
export class ReadHttpError extends Error {
  readonly status: number;
  readonly via: 'direct' | 'relay';
  constructor(status: number, via: 'direct' | 'relay') {
    super(`Reading failed with status ${status}${via === 'relay' ? ' (through the server)' : ''}.`);
    this.name = 'ReadHttpError';
    this.status = status;
    this.via = via;
  }
}

/** The body was larger than the cap. */
export class ReadTooLarge extends Error {
  constructor(limit: number) {
    super(`The page is larger than ${limit} bytes.`);
    this.name = 'ReadTooLarge';
  }
}

/** The relay was needed and consented to, but no relay address was configured. */
export class RelayNotConfigured extends Error {
  constructor() {
    super('No Spoken Margins server address is configured for the relay.');
    this.name = 'RelayNotConfigured';
  }
}

export interface ReadOptions {
  /** Injected in tests. Defaults to the global `fetch`. */
  fetch?: FetchLike;
  /** True once the listener agreed to read through the server. Without it a blocked direct read throws `NeedsRelayConsent`. */
  consent?: boolean;
  /** The share-link server's base address, such as `https://example.org`. The relay is `GET <base>/api/v1/relay?url=…`. */
  relayBase?: string;
  /** Required to be `'listener-tap'` for a Substack post page. */
  reason?: ReadReason;
  /** Largest body to accept. Default 4 MiB for a page, like the iPhone app. */
  maxBytes?: number;
}

export interface ReadResult {
  body: string;
  via: 'direct' | 'relay';
  /**
   * Where the read ended after redirects: `Response.url` on a direct read, the relay's `X-Final-URL` through the
   * relay (#2979). Unset only when a relay doesn't send a usable one.
   */
  finalUrl?: string;
}

/** The header the relay names the address after redirects in (`research/B4/server/internal/relay`, #2979). */
export const RELAY_FINAL_URL_HEADER = 'x-final-url';

/** An http(s) address the relay reported, or undefined for a missing or unusable one. */
function relayFinalUrl(response: Response): string | undefined {
  const raw = response.headers.get(RELAY_FINAL_URL_HEADER)?.trim();
  if (!raw) return undefined;
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : undefined;
  } catch {
    return undefined;
  }
}

export const DEFAULT_MAX_BYTES = 4 * 1024 * 1024;

export function relayUrl(relayBase: string, target: string): string {
  return `${relayBase.replace(/\/+$/, '')}/api/v1/relay?url=${encodeURIComponent(target)}`;
}

async function readBody(response: Response, maxBytes: number): Promise<string> {
  const declared = Number(response.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > maxBytes) throw new ReadTooLarge(maxBytes);
  const body = await response.text();
  if (new TextEncoder().encode(body).length > maxBytes) throw new ReadTooLarge(maxBytes);
  return body;
}

/**
 * Reads a URL as text. Direct first; a thrown `fetch` (what a CORS block or a network failure looks like in a
 * browser) means the relay, and the relay needs consent. An HTTP error status is the site's answer, so it is
 * reported as `ReadHttpError` and never retried through the relay.
 */
export async function readUrl(url: string, options: ReadOptions = {}): Promise<ReadResult> {
  if (isSubstackPostUrl(url) && options.reason !== 'listener-tap') throw new PostPageReadRefused(url);
  const doFetch: FetchLike = options.fetch ?? ((input, init) => fetch(input, init));
  const maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES;

  let direct: Response | undefined;
  try {
    direct = await doFetch(url, { credentials: 'omit' });
  } catch {
    direct = undefined;
  }
  if (direct) {
    if (!direct.ok) throw new ReadHttpError(direct.status, 'direct');
    const finalUrl = direct.url || url;
    // A redirect can land on a post page the listener never tapped.
    if (finalUrl !== url && isSubstackPostUrl(finalUrl) && options.reason !== 'listener-tap') throw new PostPageReadRefused(finalUrl);
    return { body: await readBody(direct, maxBytes), via: 'direct', finalUrl };
  }

  if (!options.consent) throw new NeedsRelayConsent(url);
  if (!options.relayBase) throw new RelayNotConfigured();
  const relayed = await doFetch(relayUrl(options.relayBase, url), { credentials: 'omit' });
  if (!relayed.ok) throw new ReadHttpError(relayed.status, 'relay');
  const finalUrl = relayFinalUrl(relayed);
  // The same rule as a direct read: a redirect can land on a post page the listener never tapped.
  if (finalUrl && finalUrl !== url && isSubstackPostUrl(finalUrl) && options.reason !== 'listener-tap') throw new PostPageReadRefused(finalUrl);
  const body = await readBody(relayed, maxBytes);
  return finalUrl ? { body, via: 'relay', finalUrl } : { body, via: 'relay' };
}

/**
 * Reads a feed and parses it. The show keeps the address asked for (`feedUrl`, what the listener follows); relative
 * links resolve against where the read ended after redirects.
 */
export async function readFeed(
  url: string,
  options: ReadOptions & Pick<ParseFeedOptions, 'maxItems' | 'followedAt'> = {},
): Promise<ParsedFeed> {
  const { body, finalUrl } = await readUrl(url, options);
  return parseFeed(body, { feedUrl: url, baseUrl: finalUrl, maxItems: options.maxItems, followedAt: options.followedAt });
}

/**
 * Reads one Substack post page and finds its voice, for a post the listener just tapped. Always passes
 * `reason: 'listener-tap'`, so call it only from that tap. Null when the post has no playable voice.
 */
export async function readSubstackVoice(postUrl: string, options: Omit<ReadOptions, 'reason'> = {}): Promise<SubstackVoice | null> {
  const result = await readUrl(postUrl, { ...options, reason: 'listener-tap' });
  return findSubstackVoice(result.body, result.finalUrl === undefined ? {} : { finalUrl: result.finalUrl });
}
