// Share links in the web app (#3003, phase 1 of #2168). Opening: a `/l/<id>#<key>` link, loaded or pasted, fetches
// the sealed packet from `/l/<id>/packet` and opens it here with the key from the `#` part, which the browser never
// sends to a server (#805). The importer then places the Margins as it does a file. Making a link is the other half,
// and only a build with SHARE_LINKS_ENABLED offers it. Plain TypeScript, so `npm run test:web` covers it.
import type { Episode, Margin, Show } from '../../shared/model.ts';
import { shareableLink } from '../../packet/links.ts';
import {
  DAMAGED_MESSAGE,
  type LinkPreview,
  PART,
  ShareLinkUploadError,
  ShareLinksOffError,
  keyFromFragment,
  openPart,
} from '../../packet/share-link.ts';

/** What the listener reads. Expired and server match the share page and the app's ShareLinkPacketDownloader. */
export const LINK_MESSAGES = Object.freeze({
  damaged: DAMAGED_MESSAGE,
  expired: 'This link has expired. Ask your friend to share it again.',
  offline: 'You’re offline. Reconnect, then open the link again.',
  server: 'The server had a problem. Try again in a minute.',
  notALink: 'That isn’t a Spoken Margins link. A link looks like https://…/l/… with a # part.',
  nothingToLink: 'None of these Margins have words, so there is nothing to put in a link. A voice Margin travels with its words.',
  tooLarge: 'These Margins are too large for a link. Save them as a file instead.',
  refused: 'The server didn’t accept these Margins. Save them as a file instead.',
  tooMany: 'Too many links were made from here just now. Try again later.',
  noServer: 'This copy of the web app has no link server.',
});

export class ShareLinkError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ShareLinkError';
  }
}

export interface ShareLinkRef {
  /** The link server's origin, e.g. `https://spokenmargins.com`. */
  origin: string;
  id: string;
  key: Uint8Array;
}

export type ParsedLink = { kind: 'link'; link: ShareLinkRef } | { kind: 'damaged' } | { kind: 'none' };

// The server's ids are 32 hex characters; uploadLink accepts any URL-safe id, so this does too, within reason.
const LINK_PATH = /\/l\/([A-Za-z0-9_-]{1,64})\/?$/;
const LOOPBACK = ['localhost', '127.0.0.1', '[::1]'];

/**
 * Reads a share link. `none` when the text isn't one at all (so a caller can ignore it); `damaged` when it is a
 * link whose key is missing or malformed, which nothing can open. http is accepted only for this machine.
 */
export function parseShareLink(text: string, base?: string): ParsedLink {
  const trimmed = text.trim();
  if (!trimmed) return { kind: 'none' };
  let url: URL;
  try {
    url = base === undefined ? new URL(trimmed) : new URL(trimmed, base);
  } catch {
    return { kind: 'none' };
  }
  const secure = url.protocol === 'https:' || (url.protocol === 'http:' && LOOPBACK.includes(url.hostname));
  if (!secure || url.username || url.password || url.search) return { kind: 'none' };
  const match = LINK_PATH.exec(url.pathname);
  if (!match) return { kind: 'none' };
  const key = keyFromFragment(url.hash);
  if (!key) return { kind: 'damaged' };
  return { kind: 'link', link: { origin: url.origin, id: match[1], key } };
}

/**
 * Fetches and opens a link's sealed packet. Throws ShareLinkError with the listener's message: expired for 404 and
 * 410, offline when nothing answers, damaged when the bytes don't open under the key.
 */
export async function openSharedPacket(link: ShareLinkRef, fetchImpl: typeof fetch = fetch): Promise<Uint8Array> {
  let response: Response;
  try {
    response = await fetchImpl(`${link.origin}/l/${link.id}/packet`, {
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      referrerPolicy: 'no-referrer',
    });
  } catch {
    throw new ShareLinkError(LINK_MESSAGES.offline);
  }
  if (response.status === 404 || response.status === 410) throw new ShareLinkError(LINK_MESSAGES.expired);
  if (response.status !== 200) throw new ShareLinkError(LINK_MESSAGES.server);
  let sealed: Uint8Array;
  try {
    sealed = new Uint8Array(await response.arrayBuffer());
  } catch {
    throw new ShareLinkError(LINK_MESSAGES.offline);
  }
  try {
    return await openPart(sealed, PART.packet, link.key);
  } catch {
    throw new ShareLinkError(LINK_MESSAGES.damaged);
  }
}

/**
 * The preview sealed next to the packet: the episode, its show, and the words of the Margins the packet carries.
 * A podcast Margin carries no source text, so there are no excerpts. The page link goes in only when it holds no
 * access secret. Throws when no Margin has words, since the share page needs at least one.
 */
export function linkPreview(episode: Episode, show: Show | undefined, margins: readonly Margin[], included: readonly string[]): LinkPreview {
  const chosen = new Set(included);
  const words = margins.filter((m) => chosen.has(m.id) && m.text?.trim()).map((m) => ({ text: (m.text ?? '').trim() }));
  if (words.length === 0) throw new ShareLinkError(LINK_MESSAGES.nothingToLink);
  const url = shareableLink(episode.pageUrl);
  return {
    schema: 'spokenmargins.link-preview.v1',
    source: { title: episode.title, ...(show?.title && { show: show.title }), ...(url && { url }) },
    margins: words,
  };
}

/** The listener's words for a failed upload. */
export function linkUploadMessage(error: unknown): string {
  if (error instanceof ShareLinkError || error instanceof ShareLinksOffError) return error.message;
  if (error instanceof ShareLinkUploadError) {
    if (error.status === 413) return LINK_MESSAGES.tooLarge;
    if (error.status === 429) return LINK_MESSAGES.tooMany;
    if (error.status === 400) return LINK_MESSAGES.refused;
    return LINK_MESSAGES.server;
  }
  if (error instanceof TypeError) return LINK_MESSAGES.offline;
  return LINK_MESSAGES.server;
}
