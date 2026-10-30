// Stand-in for `src/sources/` (#2983) until it merges. It uses the browser's own DOMParser, which the real
// module can't (it runs in Node tests too), and it is deliberately small: enough to follow a feed, list its
// episodes and search by name. Wave 2 (#2979) replaces it in `services.ts`.
import type { Episode, Show } from '../../shared/model.ts';
import { stableId } from '../logic/library.ts';
import { NeedsRelayConsent, type FeedRead, type SourcesPort } from '../ports.ts';

/** The relay's origin, set at build time once the server route exists (#2985). Empty means no relay. */
const RELAY_ORIGIN: string = (import.meta.env.VITE_RELAY_ORIGIN as string | undefined) ?? '';

async function fetchText(url: string, relayAllowed: boolean): Promise<string> {
  let direct: Response;
  try {
    direct = await fetch(url, { credentials: 'omit' });
  } catch {
    // A CORS refusal and a dropped network look the same from here: both need the relay.
    if (!relayAllowed) throw new NeedsRelayConsent(url);
    if (!RELAY_ORIGIN) throw new Error('This build has no server route for feeds yet, so this feed can’t be read here.');
    const relayed = await fetch(`${RELAY_ORIGIN}/api/v1/relay?url=${encodeURIComponent(url)}`, { credentials: 'omit' });
    if (!relayed.ok) throw new Error(`The server couldn’t read that feed (status ${relayed.status}).`);
    return relayed.text();
  }
  if (!direct.ok) throw new Error(`That address answered with status ${direct.status}.`);
  return direct.text();
}

function text(parent: Element, tag: string): string | undefined {
  for (const child of Array.from(parent.children)) {
    if (child.tagName === tag || child.localName === tag) {
      const value = child.textContent?.trim();
      if (value) return value;
    }
  }
  return undefined;
}

function parseDuration(raw: string | undefined): number | undefined {
  if (!raw) return undefined;
  const parts = raw.split(':').map(Number);
  if (parts.some((n) => !Number.isFinite(n))) return undefined;
  return parts.reduce((total, n) => total * 60 + n, 0) || undefined;
}

function isoDate(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  const t = Date.parse(raw);
  return Number.isNaN(t) ? undefined : new Date(t).toISOString();
}

function absolute(href: string | undefined, base: string): string | undefined {
  if (!href) return undefined;
  try {
    return new URL(href, base).href;
  } catch {
    return undefined;
  }
}

export function parseFeedInBrowser(xml: string, feedUrl: string): FeedRead {
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  const channel = doc.querySelector('channel');
  if (!channel || doc.querySelector('parsererror')) throw new Error('That address isn’t a podcast or Substack feed.');
  const siteUrl = absolute(text(channel, 'link'), feedUrl);
  const isSubstack = /substack\.com/i.test(feedUrl) || /substack/i.test(text(channel, 'generator') ?? '');
  const showId = stableId(feedUrl);
  const image = channel.getElementsByTagName('itunes:image')[0]?.getAttribute('href') ?? channel.querySelector('image > url')?.textContent?.trim();
  const show: Show = {
    id: showId,
    kind: isSubstack ? 'substack' : 'podcast',
    title: text(channel, 'title') ?? feedUrl,
    author: text(channel, 'itunes:author') ?? text(channel, 'author'),
    feedUrl,
    siteUrl,
    artworkUrl: absolute(image ?? undefined, feedUrl),
    followedAt: new Date().toISOString(),
  };
  const episodes: Episode[] = [];
  for (const item of Array.from(channel.getElementsByTagName('item'))) {
    const enclosure = item.getElementsByTagName('enclosure')[0];
    const type = enclosure?.getAttribute('type') ?? '';
    const audioUrl = enclosure && (type.startsWith('audio/') || (!type && /\.(mp3|m4a|aac|ogg|opus|wav)(\?|$)/i.test(enclosure.getAttribute('url') ?? '')))
      ? absolute(enclosure.getAttribute('url') ?? undefined, feedUrl)
      : undefined;
    const pageUrl = absolute(text(item, 'link'), feedUrl);
    // A podcast item with no audio has nothing to play. A Substack post may still have a voice on its page.
    if (!audioUrl && !(isSubstack && pageUrl)) continue;
    const guid = text(item, 'guid');
    const title = text(item, 'title') ?? 'Untitled';
    episodes.push({
      id: stableId(`${showId}|${guid ?? audioUrl ?? pageUrl ?? title}`),
      showId,
      title,
      guid,
      pageUrl,
      audioUrl,
      audioOrigin: audioUrl ? (isSubstack ? 'substack-voiceover' : 'podcast-enclosure') : undefined,
      durationSeconds: parseDuration(text(item, 'itunes:duration')),
      publishedAt: isoDate(text(item, 'pubDate')),
    });
  }
  return { show, episodes };
}

export const stubSources: SourcesPort = {
  async searchPodcasts(term) {
    const url = `https://itunes.apple.com/search?media=podcast&entity=podcast&limit=20&term=${encodeURIComponent(term)}`;
    const response = await fetch(url, { credentials: 'omit' });
    if (!response.ok) throw new Error(`Search answered with status ${response.status}.`);
    const body = (await response.json()) as { results?: Array<Record<string, unknown>> };
    return (body.results ?? [])
      .filter((r) => typeof r.feedUrl === 'string')
      .map((r) => ({
        id: stableId(String(r.feedUrl)),
        kind: 'podcast' as const,
        title: String(r.collectionName ?? r.trackName ?? 'Untitled'),
        author: typeof r.artistName === 'string' ? r.artistName : undefined,
        feedUrl: String(r.feedUrl),
        artworkUrl: typeof r.artworkUrl600 === 'string' ? r.artworkUrl600 : undefined,
        itunesId: typeof r.collectionId === 'number' ? r.collectionId : undefined,
        followedAt: new Date().toISOString(),
      }));
  },
  async readFeed(feedUrl, { relayAllowed }) {
    return parseFeedInBrowser(await fetchText(feedUrl, relayAllowed), feedUrl);
  },
  async findPostVoice() {
    // Substack voice detection is #2983's job; until it lands, a post without audio in its feed has none.
    return null;
  },
};
