// RSS 2.0 to the web app's `Show` and `Episode[]`. Handles podcast feeds (audio enclosures) and Substack feeds
// (posts whose voice is found later, from the post page, only when the listener taps that post).

import type { Episode, Show } from '../shared/model.ts';
import { child, childText, childrenNamed, parseXml } from './xml.ts';
import type { XmlElement } from './xml.ts';

export class FeedParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FeedParseError';
  }
}

export interface ParseFeedOptions {
  /** Where the feed was read from. Required for `Show.feedUrl`, and relative links resolve against it. */
  feedUrl: string;
  /** Where the read ended after redirects, when that differs: relative links resolve against it instead. */
  baseUrl?: string;
  /** Stop after this many items. Default 500: a feed's newest items come first, and the rest is rarely wanted. */
  maxItems?: number;
  /** Stamped on `Show.followedAt`. Default is the current time. */
  followedAt?: string;
}

export interface ParsedFeed {
  show: Show;
  episodes: Episode[];
  /** True when the feed had more items than `maxItems` and the rest were left unread. */
  truncated: boolean;
}

export const DEFAULT_MAX_ITEMS = 500;

/**
 * `itunes:duration` in any common form, as seconds: `3723`, `3723.5`, `62:03` (mm:ss), `1:02:03` (h:mm:ss),
 * with an optional fraction on the last part. Anything else is undefined, never a guess.
 */
export function parseDuration(raw: string | undefined): number | undefined {
  const text = raw?.trim();
  if (!text) return undefined;
  const parts = text.split(':');
  if (parts.length > 3) return undefined;
  let total = 0;
  for (let i = 0; i < parts.length; i += 1) {
    const part = (parts[i] as string).trim();
    const isLast = i === parts.length - 1;
    if (!(isLast ? /^\d+(\.\d+)?$/ : /^\d+$/).test(part)) return undefined;
    total = total * 60 + Number(part);
  }
  return Number.isFinite(total) ? total : undefined;
}

/** `pubDate` (RFC 822) as ISO 8601, or undefined when it doesn't parse. */
export function parsePubDate(raw: string | undefined): string | undefined {
  const text = raw?.trim();
  if (!text) return undefined;
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? undefined : new Date(ms).toISOString();
}

/** An http(s) URL resolved against `base`, or undefined for anything else (`javascript:`, `data:`, junk). */
export function resolveWebUrl(raw: string | undefined, base: string): string | undefined {
  const text = raw?.trim();
  if (!text) return undefined;
  try {
    const url = new URL(text, base);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : undefined;
  } catch {
    return undefined;
  }
}

const FEED_LINK_TYPES = new Set(['application/rss+xml', 'application/x-rss+xml']);

/** A tag's attributes, names lower-cased, values with their quotes taken off and `&amp;` decoded. */
function tagAttributes(tag: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  for (const match of tag.matchAll(/([a-zA-Z_:][-\w:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g)) {
    const name = (match[1] as string).toLowerCase();
    if (!(name in attrs)) attrs[name] = (match[2] ?? match[3] ?? match[4] ?? '').replace(/&amp;/gi, '&');
  }
  return attrs;
}

/**
 * The RSS feed a web page names for itself (`<link rel="alternate" type="application/rss+xml" href="/feed">`, which
 * every Substack home page and most podcast sites carry), resolved against `pageUrl`. Undefined for a page that names
 * none, or only an Atom feed, which `parseFeed` doesn't read. The first RSS link wins, as browsers pick it.
 */
export function discoverFeedUrl(html: string, pageUrl: string): string | undefined {
  // Only the head: a feed link in a post's body is someone else's feed.
  const head = /<head\b[\s\S]*?(?:<\/head\s*>|<body\b)/i.exec(html)?.[0] ?? html.slice(0, 200_000);
  for (const match of head.matchAll(/<link\b[^>]*>/gi)) {
    const attrs = tagAttributes(match[0]);
    const rel = (attrs.rel ?? '').toLowerCase().split(/\s+/);
    const type = (attrs.type ?? '').trim().toLowerCase().split(';')[0] as string;
    if (!rel.includes('alternate') || !FEED_LINK_TYPES.has(type)) continue;
    const url = resolveWebUrl(attrs.href, pageUrl);
    if (url) return url;
  }
  return undefined;
}

function isSubstackFeed(channel: XmlElement, feedUrl: string): boolean {
  if (childText(channel, 'generator')?.toLowerCase() === 'substack') return true;
  try {
    const host = new URL(feedUrl).hostname.toLowerCase();
    return host === 'substack.com' || host.endsWith('.substack.com');
  } catch {
    return false;
  }
}

/** The item's audio: an enclosure that is audio by MIME type, or untyped with an audio file extension. */
function audioEnclosure(item: XmlElement, feedUrl: string): string | undefined {
  for (const enclosure of childrenNamed(item, 'enclosure')) {
    const type = (enclosure.attrs.type ?? '').trim().toLowerCase();
    const url = resolveWebUrl(enclosure.attrs.url, feedUrl);
    if (!url) continue;
    if (type.startsWith('audio/')) return url;
    if (!type && /\.(mp3|m4a|aac|ogg|oga|opus|wav)$/i.test(new URL(url).pathname)) return url;
  }
  return undefined;
}

function artworkOf(channel: XmlElement, feedUrl: string): string | undefined {
  const itunesImage = child(channel, 'itunes:image')?.attrs.href;
  const image = child(channel, 'image');
  const plainImage = image ? childText(image, 'url') : undefined;
  return resolveWebUrl(itunesImage, feedUrl) ?? resolveWebUrl(plainImage, feedUrl);
}

/**
 * Parses an RSS 2.0 feed. Throws `FeedParseError` when the document has no `<rss><channel>` (an HTML error page,
 * an Atom feed). An empty feed is fine: a show with no episodes.
 *
 * Podcast feeds keep only items with playable audio. Substack feeds keep every item, because a post's voice is
 * not in the feed: it is found from the post page when the listener taps the post (`findSubstackVoice`).
 */
export function parseFeed(xml: string, options: ParseFeedOptions): ParsedFeed {
  const maxItems = options.maxItems ?? DEFAULT_MAX_ITEMS;
  const document = parseXml(xml, { stopAfterClosing: { name: 'item', count: maxItems + 1 } });
  const rss = child(document, 'rss');
  const channel = rss ? child(rss, 'channel') : undefined;
  if (!channel) throw new FeedParseError('Not an RSS 2.0 feed: no <rss><channel> found.');

  const feedUrl = options.feedUrl;
  const base = options.baseUrl ?? feedUrl;
  const kind: Show['kind'] = isSubstackFeed(channel, feedUrl) ? 'substack' : 'podcast';
  const id = `feed:${feedUrl}`;
  const itemElements = childrenNamed(channel, 'item');
  const truncated = itemElements.length > maxItems;

  const siteUrl = resolveWebUrl(childText(channel, 'link'), base);
  const show: Show = {
    id,
    kind,
    title: childText(channel, 'title') ?? new URL(feedUrl).hostname,
    feedUrl,
    followedAt: options.followedAt ?? new Date().toISOString(),
  };
  const author = childText(channel, 'itunes:author');
  if (author) show.author = author;
  if (siteUrl) show.siteUrl = siteUrl;
  const artworkUrl = artworkOf(channel, base);
  if (artworkUrl) show.artworkUrl = artworkUrl;

  const episodes: Episode[] = [];
  for (const item of itemElements.slice(0, maxItems)) {
    const audioUrl = audioEnclosure(item, base);
    if (kind === 'podcast' && !audioUrl) continue;
    const pageUrl = resolveWebUrl(childText(item, 'link'), base);
    const guid = childText(item, 'guid');
    const title = childText(item, 'title') ?? pageUrl ?? audioUrl ?? 'Untitled';
    const episode: Episode = {
      id: `${id}#${guid ?? audioUrl ?? pageUrl ?? title}`,
      showId: id,
      title,
    };
    if (guid) episode.guid = guid;
    if (pageUrl) episode.pageUrl = pageUrl;
    if (audioUrl) {
      episode.audioUrl = audioUrl;
      episode.audioOrigin = 'podcast-enclosure';
    }
    const durationSeconds = parseDuration(childText(item, 'itunes:duration'));
    if (durationSeconds !== undefined) episode.durationSeconds = durationSeconds;
    const publishedAt = parsePubDate(childText(item, 'pubDate'));
    if (publishedAt) episode.publishedAt = publishedAt;
    episodes.push(episode);
  }
  return { show, episodes, truncated };
}
