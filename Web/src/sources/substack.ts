// Finds a Substack post's playable voice from its page. A port of `PublisherNarrationEvidence` and
// `PublisherAudioDetector` in Packages/SessionKit/Sources/SessionKitFeeds (#810, #2024).
//
// The page is read as data: its `_preloads` JSON is decoded and no page script ever runs. The author's own
// voiceover wins; Substack's automatic narration (`tts`) is the fallback (owner, 2026-10-14). Paid posts, posts
// still processing, podcast posts and pages that aren't posts give nothing.

import type { AudioOrigin } from '../shared/model.ts';

export interface SubstackVoice {
  origin: Extract<AudioOrigin, 'substack-voiceover' | 'substack-generated-voice'>;
  audioUrl: string;
  /** Unset when the page gives no usable duration. */
  durationSeconds?: number;
  /** The post the page is about, from `post.canonical_url`. */
  canonicalUrl: string;
}

export interface FindVoiceOptions {
  /**
   * Where the page ended up after redirects. When given, the voice counts only if it belongs to this address
   * (same scheme, host and path; query, fragment, case of host and trailing slashes ignored), so a page for
   * another post never lends its voice. A shared `open.substack.com/pub/<name>/p/<slug>` link redirects to the
   * post's own address, so pass the address after redirects, not the one asked for.
   */
  finalUrl?: string;
}

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * `window._preloads` as data. Substack has served it two ways: a string literal,
 * `window._preloads = JSON.parse("...")`, and, since October 2026, a JSON script tag,
 * `<script type="application/json" id="preloads-json">{...}</script>`, that an inline script parses.
 */
function preloads(html: string): Json | undefined {
  let json: string | undefined;
  const literal = /window\._preloads\s*=\s*JSON\.parse\(("(?:\\.|[^"\\])*")\)/i.exec(html);
  if (literal) {
    try {
      const decoded: unknown = JSON.parse(literal[1] as string);
      if (typeof decoded === 'string') json = decoded;
    } catch {
      json = undefined;
    }
  }
  if (json === undefined) {
    const tag = /<script\b[^>]*\bid\s*=\s*(["']?)preloads-json\1(?=[\s/>])[^>]*>([\s\S]*?)<\/script\s*>/i.exec(html);
    if (tag) json = tag[2];
  }
  if (json === undefined) return undefined;
  try {
    const parsed: unknown = JSON.parse(json);
    return isObject(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

function completedRecording(post: Json, type: 'voiceover' | 'tts', requiresVoiceoverFlag: boolean): SubstackVoice | undefined {
  if (post.type !== 'newsletter') return undefined;
  if (requiresVoiceoverFlag && post.has_voiceover !== true) return undefined;
  const canonicalUrl = post.canonical_url;
  const postId = post.id;
  const items = post.audio_items;
  if (typeof canonicalUrl !== 'string' || typeof postId !== 'number' || !Array.isArray(items)) return undefined;
  const recording = items.find(
    (item): item is Json => isObject(item) && item.type === type && item.status === 'completed' && item.post_id === postId,
  );
  const audio = recording?.audio_url;
  if (!recording || typeof audio !== 'string') return undefined;
  try {
    const url = new URL(audio);
    if (url.protocol !== 'https:' || !url.hostname) return undefined;
  } catch {
    return undefined;
  }
  const voice: SubstackVoice = {
    origin: type === 'voiceover' ? 'substack-voiceover' : 'substack-generated-voice',
    audioUrl: audio,
    canonicalUrl,
  };
  const seconds = recording.duration;
  if (typeof seconds === 'number' && Number.isFinite(seconds) && seconds >= 0) voice.durationSeconds = seconds;
  return voice;
}

/** Same scheme, host and path, ignoring host case, trailing slashes, the query and the fragment. */
export function samePage(a: string, b: string): boolean {
  function key(raw: string): string | undefined {
    try {
      const url = new URL(raw);
      return `${url.protocol}//${url.host.toLowerCase()}${url.pathname.replace(/\/+$/, '')}`;
    } catch {
      return undefined;
    }
  }
  const left = key(a);
  return left !== undefined && left === key(b);
}

/**
 * The post's playable voice: the author's completed voiceover, else Substack's completed automatic narration,
 * else null.
 */
export function findSubstackVoice(html: string, options: FindVoiceOptions = {}): SubstackVoice | null {
  return inspectSubstackPost(html, options).voice;
}

/** What a post page says about its voice. */
export interface SubstackPostVoice {
  voice: SubstackVoice | null;
  /**
   * True when the post is for paid subscribers and its page, read without anyone's sign-in, holds no playable
   * voice: Substack marks the audio `paywalled`, or the post's audience is paid only. Then "no voice" would be the
   * wrong thing to tell the listener: the writer or Substack may well offer one, behind the paywall.
   */
  paidOnly: boolean;
}

const PAID_AUDIENCES = new Set(['only_paid', 'founding']);

/** `findSubstackVoice`, and whether a missing voice is because the post is for paid subscribers. */
export function inspectSubstackPost(html: string, options: FindVoiceOptions = {}): SubstackPostVoice {
  const root = preloads(html);
  const post = root?.post;
  if (!isObject(post)) return { voice: null, paidOnly: false };
  // A page for another post (a redirect elsewhere) lends neither its voice nor its paywall.
  if (options.finalUrl !== undefined && (typeof post.canonical_url !== 'string' || !samePage(post.canonical_url, options.finalUrl))) {
    return { voice: null, paidOnly: false };
  }
  const voice = completedRecording(post, 'voiceover', true) ?? completedRecording(post, 'tts', false);
  if (voice) return { voice, paidOnly: false };
  const items = Array.isArray(post.audio_items) ? post.audio_items : [];
  const paywalled = items.some((item) => isObject(item) && item.status === 'paywalled');
  const paidAudience = typeof post.audience === 'string' && PAID_AUDIENCES.has(post.audience);
  return { voice: null, paidOnly: paywalled || paidAudience };
}

/** `/p/<slug>`, with an optional trailing slash: Substack's post path on every publication's domain. */
function isPostPath(path: string): boolean {
  const segments = path.split('/');
  if (segments[segments.length - 1] === '') segments.pop();
  return segments.length === 3 && segments[0] === '' && segments[1] === 'p' && (segments[2] as string).length > 0;
}

/**
 * Whether a link is a Substack post page: an https `/p/<slug>` address on any host (publications on their own
 * domain keep Substack's post path), or a `substack.com` or `<name>.substack.com` address with `/p/<slug>` in its
 * path, such as a shared `open.substack.com/pub/<name>/p/<slug>`. A feed (`/feed`) is not a post page. Such a page is
 * read only when the listener taps that post (owner, 2026-10-21).
 */
export function isSubstackPostUrl(raw: string): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.protocol !== 'https:' || !url.hostname) return false;
  const host = url.hostname.toLowerCase();
  const onSubstack = host === 'substack.com' || host.endsWith('.substack.com');
  return isPostPath(url.pathname) || (onSubstack && /\/p\/[^/]/.test(url.pathname));
}
