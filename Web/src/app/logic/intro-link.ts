// Whether an opened link is an introduction link (#4784, Design 2026-11-21, slices 1 and 2). The mark is `answers: "none"`
// in the link's sealed preview, put there by `make-share-link --intro`. It is a decision on what the page shows, never a
// permission: an unknown value, a wrong type, or a preview that can't be read all count as no mark, so the page shows
// today's words for a conversation link. The mark is never written into a packet. Plain TypeScript with no DOM.
import type { Margin } from '../../shared/model.ts';
import { PART, openPart } from '../../packet/share-link.ts';
import { withCeiling, type ReplyFetchOutcome } from './reply-box.ts';
import type { ShareLinkRef } from './share-link.ts';
import { canStar } from './star.ts';

/** True only for a preview whose `answers` is exactly the string `"none"`. */
export function isIntroPreview(preview: unknown): boolean {
  return typeof preview === 'object' && preview !== null && !Array.isArray(preview)
    && (preview as { answers?: unknown }).answers === 'none';
}

/** A preview fetch that hasn't answered in this long counts as no mark (Default taken 7), as the reply fetch does. */
export const INTRO_FETCH_CEILING_MS = 5_000;

/** Opens a sealed preview under the link key and reads the mark. False when it doesn't open or isn't JSON. */
export async function openIntroMark(sealed: Uint8Array, linkKey: Uint8Array): Promise<boolean> {
  try {
    const plain = await openPart(sealed, PART.preview, linkKey);
    return isIntroPreview(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plain)));
  } catch {
    return false;
  }
}

/**
 * Fetches a link's sealed preview (`GET <origin>/l/<id>/preview`, which the link server already answers to the web
 * listener) and reads the introduction mark. False for every failure (offline, expired, an older server, damage) and for
 * no answer within `ceilingMs`. Never throws, and nothing waits on it to play.
 */
export function fetchIntroMark(
  link: ShareLinkRef,
  fetchImpl: typeof fetch = fetch,
  ceilingMs: number = INTRO_FETCH_CEILING_MS,
): Promise<boolean> {
  return withCeiling(
    async (signal) => {
      const response = await fetchImpl(`${link.origin}/l/${link.id}/preview`, {
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
        referrerPolicy: 'no-referrer',
        signal,
      });
      if (response.status !== 200) return false;
      return openIntroMark(new Uint8Array(await response.arrayBuffer()), link.key);
    },
    ceilingMs,
    false,
  );
}

/**
 * The friend's Margins among `marginIds` to store again with `fromIntro: true`, built from the Margins as stored now. The
 * listener's own Margins (a copy of theirs that came back in the packet) are never marked, and a Margin already marked or
 * no longer stored is left out.
 */
export function withFromIntro(marginIds: readonly string[], margins: readonly Margin[]): Margin[] {
  const byId = new Map(margins.map((m) => [m.id, m]));
  const out: Margin[] = [];
  for (const id of new Set(marginIds)) {
    const margin = byId.get(id);
    if (margin && !canStar(margin) && margin.fromIntro !== true) out.push({ ...margin, fromIntro: true });
  }
  return out;
}

/** A rewrite of a Margin keeps a stored introduction mark: opening the same packet again by file never loses it. */
export function keepingFromIntro(margin: Margin, stored: Margin | undefined): Margin {
  return stored?.fromIntro === true && margin.fromIntro !== true && !canStar(margin) ? { ...margin, fromIntro: true } : margin;
}

/**
 * What the Share section reads for a link (#4784 with #4675, #5419): the reply fetch's outcome, unless the link is an
 * introduction link. Waits for both fetches (each settles within its 5-second ceiling). On an introduction link it first
 * marks the link's Margins (`mark`, which waits for them to be stored), so the section never draws a conversation's words
 * and then changes, and the reply part is dropped as `gone`: an introduction mark wins over a reply part (Default taken
 * 4), and an older link's box kept for the same episode no longer applies. A mark that isn't kept is logged; the words
 * still follow the mark for this page. A reply fetch that rejects counts as `unreachable`, as its own ceiling does.
 */
export async function linkShareFetch(
  reply: Promise<ReplyFetchOutcome>,
  intro: Promise<boolean>,
  mark: () => Promise<void>,
): Promise<ReplyFetchOutcome> {
  const [outcome, isIntro] = await Promise.all([
    reply.catch((): ReplyFetchOutcome => ({ kind: 'unreachable' })),
    intro.catch(() => false),
  ]);
  if (!isIntro) return outcome;
  try {
    await mark();
  } catch (error) {
    console.warn('Could not keep that these Margins came through an introduction link.', error);
  }
  return { kind: 'gone' };
}
