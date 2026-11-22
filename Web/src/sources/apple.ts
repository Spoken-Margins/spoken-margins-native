// An Apple Podcasts episode page to its audio (#4783). A share link for an episode saved from Apple Podcasts can carry
// that page and no audio address (#4767). The iPhone app resolves such a page through the same public iTunes lookup
// (`PublicPodcastLinkResolver.resolveAppleLookup`), and this does the same in a browser: the lookup allows browser
// requests (CORS), so no server or relay is involved, and it is read only when the listener taps the episode.
//
// The match is exact: the episode whose Apple id is the page's `?i=`. An episode Apple's lookup doesn't list (it lists a show's
// newest 200) is then looked for in the show's own feed, and found only when exactly one feed item has the packet's title
// (apple-feed.ts); otherwise it is "not found", never a near match.
import type { AudioOrigin } from '../shared/model.ts';
import { episodeInFeed } from './apple-feed.ts';
import { FeedParseError } from './feed.ts';
import { pickReadTransport } from './native-http.ts';
import { NeedsRelayConsent, readFeed, ReadTooLarge } from './read.ts';
import type { ReadOptions } from './read.ts';
import type { FetchLike } from './search.ts';

/** The ids an Apple Podcasts episode page names: the show in the path (`/id1445582279`), the episode in `?i=`. */
export interface AppleEpisodeRef {
  showId: string;
  episodeId: string;
}

const APPLE_HOSTS = new Set(['podcasts.apple.com', 'itunes.apple.com']);
const ID = /^[0-9]{1,19}$/;

/** The show and episode ids of an Apple Podcasts episode page, or undefined for any other address (or a show page with no `?i=`). */
export function appleEpisodeRef(pageUrl: string): AppleEpisodeRef | undefined {
  let url: URL;
  try {
    url = new URL(pageUrl);
  } catch {
    return undefined;
  }
  if (url.protocol !== 'https:' || !APPLE_HOSTS.has(url.hostname.toLowerCase())) return undefined;
  const shows = url.pathname
    .split('/')
    .map((segment) => /^id([0-9]{1,19})$/.exec(segment)?.[1])
    .filter((id): id is string => id !== undefined);
  const episodes = url.searchParams.getAll('i');
  const episodeId = episodes[0];
  // Exactly one show id and one episode id: a page that names two of either is not read as either.
  if (shows.length !== 1 || episodes.length !== 1 || episodeId === undefined || !ID.test(episodeId)) return undefined;
  return { showId: withoutLeadingZeros(shows[0] as string), episodeId: withoutLeadingZeros(episodeId) };
}

/** `0123` and `123` name one Apple id; the lookup's `trackId` is a number, so the ids are compared without padding. */
function withoutLeadingZeros(id: string): string {
  return id.replace(/^0+(?=[0-9])/, '');
}

/** What the lookup found for an episode that is listed with audio. */
export interface AppleEpisodeAudio {
  audioUrl: string;
  audioOrigin: AudioOrigin;
  durationSeconds?: number;
  guid?: string;
}

/** The lookup couldn't be asked or answered: offline, a refusal, or something that is not JSON. */
export class AppleLookupError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AppleLookupError';
  }
}

export interface AppleLookupOptions {
  /** Injected in tests. Defaults to native HTTP inside the Android app and the browser's `fetch` elsewhere. */
  fetch?: FetchLike;
  /** Injected in tests; the lookup's own limit otherwise (`LOOKUP_TIMEOUT_MS`). */
  timeoutMs?: number;
  /**
   * When Apple's lookup doesn't list the episode, look for it in the show's own feed, by this title (the packet's). Apple lists
   * a show's newest 200 episodes, so an older episode is found only there (#4783). Without it, the feed is never read.
   * `consent`, `relayBase`, `fetch` and `transport` are the read path's, as for any feed: the browser's own read first, the
   * server's relay only with the listener's OK (`NeedsRelayConsent` otherwise).
   */
  feed?: { title: string } & Pick<ReadOptions, 'consent' | 'relayBase' | 'transport' | 'fetch'>;
}

/** The most items of a show's feed read to find one episode: far past the newest 500 a followed show keeps. */
const FEED_ITEMS_SEARCHED = 5_000;

/** How long the lookup may take. The friend's card waits on it, so a lookup that never answers must end. */
export const LOOKUP_TIMEOUT_MS = 8_000;

/** A signal that aborts after `ms`. `AbortSignal.timeout` is missing from older Safari, where the lookup would always fail. */
function deadline(ms: number): AbortSignal {
  if (typeof AbortSignal.timeout === 'function') return AbortSignal.timeout(ms);
  const controller = new AbortController();
  setTimeout(() => controller.abort(), ms);
  return controller.signal;
}

/**
 * `run`, but rejected after `ms` whatever `run` does. The Android app's native read ignores the abort signal, so the
 * signal alone would leave the listener's card waiting on a lookup that never answers.
 */
function within<T>(ms: number, run: () => Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timed out')), ms);
    run().then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

/** The lookup address for a show's newest 200 episodes, the one the iPhone app asks. */
export function appleLookupUrl(showId: string): string {
  return `https://itunes.apple.com/lookup?id=${showId}&entity=podcastEpisode&limit=200`;
}

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

/**
 * The audio address of a lookup result, as a page on https can load it. Apple lists some enclosures as `http://`; a
 * browser would upgrade or block them as mixed content, so the https address is the one used. Anything that is not an
 * http(s) address is no audio.
 */
export function playableAudioAddress(value: unknown): string | undefined {
  const raw = text(value);
  if (!raw) return undefined;
  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return undefined;
    url.protocol = 'https:';
    return url.href;
  } catch {
    return undefined;
  }
}

/**
 * Finds the audio of the Apple Podcasts episode a page names. Null when the lookup answered but doesn't list that
 * episode, or lists it with no audio. Throws `AppleLookupError` when the lookup couldn't be asked or answered, so
 * "no audio" and "couldn't ask" are never the same message.
 */
export async function findAppleEpisodeAudio(pageUrl: string, options: AppleLookupOptions = {}): Promise<AppleEpisodeAudio | null> {
  const ref = appleEpisodeRef(pageUrl);
  if (!ref) return null;
  const doFetch: FetchLike = options.fetch ?? pickReadTransport().fetch;
  let response: Response;
  try {
    const limit = options.timeoutMs ?? LOOKUP_TIMEOUT_MS;
    response = await within(limit, () => doFetch(appleLookupUrl(ref.showId), { credentials: 'omit', signal: deadline(limit) }));
  } catch {
    throw new AppleLookupError('Apple Podcasts didn’t answer. Check your connection and try again.');
  }
  if (!response.ok) throw new AppleLookupError('Apple Podcasts can’t look this episode up right now. Try again in a minute.');
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new AppleLookupError('Apple Podcasts can’t look this episode up right now. Try again in a minute.');
  }
  const results = (body as { results?: unknown } | null)?.results;
  if (!Array.isArray(results)) return null;
  const fromApple = appleListedAudio(results, ref);
  if (fromApple || !options.feed) return fromApple;
  // Apple answered but doesn't list the episode with audio: it may be older than the 200 it lists, so ask the show's feed.
  const feedUrl = showFeedUrl(results);
  return feedUrl ? findInShowFeed(feedUrl, options.feed) : null;
}

/** The address of the show's feed in Apple's answer (the show's own row names it), as http(s) only. */
function showFeedUrl(results: unknown[]): string | undefined {
  for (const result of results) {
    const raw = typeof result === 'object' && result !== null ? text((result as Record<string, unknown>).feedUrl) : undefined;
    if (!raw) continue;
    try {
      const url = new URL(raw);
      if (url.protocol === 'https:' || url.protocol === 'http:') return url.href;
    } catch {
      // not an address: try the next row
    }
  }
  return undefined;
}

/**
 * The episode in the show's feed that the packet's title names, with the audio address the feed gives. Null when no item, or
 * more than one, has that title. Throws `NeedsRelayConsent` when the browser can't read the feed and the listener hasn't
 * agreed to the server's relay, and `AppleLookupError` when the feed couldn't be read for another reason that may pass.
 */
async function findInShowFeed(feedUrl: string, options: NonNullable<AppleLookupOptions['feed']>): Promise<AppleEpisodeAudio | null> {
  const { title, ...read } = options;
  let episodes;
  try {
    episodes = (await readFeed(feedUrl, { ...read, reason: 'feed-refresh', maxItems: FEED_ITEMS_SEARCHED })).episodes;
  } catch (error) {
    if (error instanceof NeedsRelayConsent) throw error;
    // A page that is not a feed, or one too large to read, will not read any better tomorrow: no audio to find.
    if (error instanceof FeedParseError || error instanceof ReadTooLarge) return null;
    throw new AppleLookupError('This show’s feed can’t be read right now. Try again in a minute.');
  }
  const match = episodeInFeed(episodes, title);
  const audioUrl = playableAudioAddress(match?.audioUrl);
  if (!match || !audioUrl) return null;
  return {
    audioUrl,
    audioOrigin: 'podcast-enclosure',
    ...(match.durationSeconds !== undefined && { durationSeconds: match.durationSeconds }),
    ...(match.guid && { guid: match.guid }),
  };
}

/** The audio of the episode with the page's own Apple id, when Apple's answer lists it with audio. */
function appleListedAudio(results: unknown[], ref: AppleEpisodeRef): AppleEpisodeAudio | null {
  const episode = results.find((result): result is Record<string, unknown> => {
    if (typeof result !== 'object' || result === null) return false;
    const r = result as Record<string, unknown>;
    const isEpisode = r.wrapperType === 'podcastEpisode' || r.kind === 'podcast-episode';
    return isEpisode && String(r.trackId) === ref.episodeId;
  });
  if (!episode) return null;
  const audioUrl = playableAudioAddress(episode.episodeUrl);
  if (!audioUrl) return null;
  const millis = episode.trackTimeMillis;
  const guid = text(episode.episodeGuid);
  return {
    audioUrl,
    audioOrigin: 'podcast-enclosure',
    ...(typeof millis === 'number' && Number.isFinite(millis) && millis > 0 && { durationSeconds: millis / 1000 }),
    ...(guid && { guid }),
  };
}
