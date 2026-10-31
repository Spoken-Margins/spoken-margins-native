// Podcast search through the iTunes Search API, which allows browser requests (CORS) so no server is involved.

import type { Show } from '../shared/model.ts';
import { pickReadTransport } from './native-http.ts';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface SearchOptions {
  /** Injected in tests. Defaults to native HTTP inside the Android app and the browser's `fetch` elsewhere. */
  fetch?: FetchLike;
  /** Results to ask for. Default 15, which is what the recorded fixtures use. */
  limit?: number;
}

export class SearchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SearchError';
  }
}

interface ItunesResult {
  kind?: unknown;
  collectionId?: unknown;
  collectionName?: unknown;
  trackName?: unknown;
  artistName?: unknown;
  feedUrl?: unknown;
  artworkUrl600?: unknown;
  artworkUrl100?: unknown;
}

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

function webUrl(value: unknown): string | undefined {
  const raw = text(value);
  if (!raw) return undefined;
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : undefined;
  } catch {
    return undefined;
  }
}

/** Maps one iTunes result to a `Show`, or undefined when it isn't a podcast with a feed. */
export function showFromItunesResult(result: ItunesResult): Show | undefined {
  if (result.kind !== undefined && result.kind !== 'podcast') return undefined;
  const feedUrl = webUrl(result.feedUrl);
  const title = text(result.collectionName) ?? text(result.trackName);
  if (!feedUrl || !title) return undefined;
  const id = typeof result.collectionId === 'number' ? result.collectionId : undefined;
  // `followedAt` stays empty: a search result is not followed until the listener follows it.
  const show: Show = { id: id === undefined ? `feed:${feedUrl}` : `itunes:${id}`, kind: 'podcast', title, feedUrl, followedAt: '' };
  const author = text(result.artistName);
  if (author) show.author = author;
  const artworkUrl = webUrl(result.artworkUrl600) ?? webUrl(result.artworkUrl100);
  if (artworkUrl) show.artworkUrl = artworkUrl;
  if (id !== undefined) show.itunesId = id;
  return show;
}

/** Searches podcasts by name. Results keep iTunes' order (its ranking is the relevance). */
export async function searchPodcasts(term: string, options: SearchOptions = {}): Promise<Show[]> {
  const query = term.trim();
  if (!query) return [];
  const doFetch: FetchLike = options.fetch ?? pickReadTransport().fetch;
  const url = `https://itunes.apple.com/search?media=podcast&term=${encodeURIComponent(query)}&limit=${options.limit ?? 15}`;
  const response = await doFetch(url, { credentials: 'omit' });
  if (!response.ok) throw new SearchError(`Podcast search failed with status ${response.status}.`);
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new SearchError('Podcast search returned something that is not JSON.');
  }
  const results = (body as { results?: unknown } | null)?.results;
  if (!Array.isArray(results)) return [];
  const shows: Show[] = [];
  const seen = new Set<string>();
  for (const result of results) {
    if (typeof result !== 'object' || result === null) continue;
    const show = showFromItunesResult(result as ItunesResult);
    if (!show || seen.has(show.id)) continue;
    seen.add(show.id);
    shows.push(show);
  }
  return shows;
}
