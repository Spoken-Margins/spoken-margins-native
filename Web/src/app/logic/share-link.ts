// Share links in the web app (#3003, phase 1 of #2168). Opening: a `/l/<id>#<key>` link, loaded or pasted, fetches
// the sealed packet from `/l/<id>/packet` and opens it here with the key from the `#` part, which the browser never
// sends to a server (#805). The importer then places the Margins as it does a file. The web app is receive-only for
// links: it cannot make one (owner, 2026-11-05, #3542). Plain TypeScript, so the node tests cover it.
import { DAMAGED_MESSAGE, PART, keyFromFragment, openPart } from '../../packet/share-link.ts';

/** What the listener reads. Expired and server match the share page and the app's ShareLinkPacketDownloader. */
export const LINK_MESSAGES = Object.freeze({
  damaged: DAMAGED_MESSAGE,
  expired: 'This link has expired. Ask your friend to share it again.',
  offline: 'You’re offline. Reconnect, then open the link again.',
  server: 'The server had a problem. Try again in a minute.',
  notALink: 'That isn’t a Spoken Margins link. A link looks like https://…/l/… with a # part.',
  off: 'Links are switched off for now. Ask your friend to send the Margins as a file.',
});

/** Why a link didn't open, for a screen that words it its own way (the arrival page). */
export type ShareLinkFailure = 'damaged' | 'expired' | 'offline' | 'server' | 'off' | 'other';

export class ShareLinkError extends Error {
  readonly reason: ShareLinkFailure;
  constructor(message: string, reason: ShareLinkFailure = 'other') {
    super(message);
    this.name = 'ShareLinkError';
    this.reason = reason;
  }
}

export interface ShareLinkRef {
  /** The link server's origin, e.g. `https://spokenmargins.com`. */
  origin: string;
  id: string;
  key: Uint8Array;
}

/**
 * A damaged link still names its link when the path matched (#3355), so a friend whose link was cut off can reach the
 * report form. Never the key: it is missing or malformed, and nothing here may carry any part of it.
 */
export type DamagedLink = { kind: 'damaged'; reportable?: Pick<ShareLinkRef, 'origin' | 'id'> };

export type ParsedLink = { kind: 'link'; link: ShareLinkRef } | DamagedLink | { kind: 'none' };

// The server's ids are 32 hex characters; the id is any URL-safe text here, within reason.
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
  if (!key) return { kind: 'damaged', reportable: { origin: url.origin, id: match[1] } };
  return { kind: 'link', link: { origin: url.origin, id: match[1], key } };
}

/**
 * Fetches and opens a link's sealed packet. Throws ShareLinkError with the listener's message: expired for 404 and
 * 410, offline when nothing answers, damaged when the bytes don't open under the key.
 */
export async function openSharedPacket(link: ShareLinkRef, fetchImpl: typeof fetch = fetch): Promise<Uint8Array> {
  return (await openSharedPacketWithExpiry(link, fetchImpl)).bytes;
}

/** The header the link server sends with the packet: the UTC day the link stops working, `YYYY-MM-DD` (#2168). */
export const LINK_EXPIRES_HEADER = 'X-SM-Link-Expires';

/** What the footer says when no usable expiry day reached the page (an older server, a missing or odd header). */
export const LINK_FOOTER_DEFAULT = 'This link works for 30 days.';

/**
 * The footer sentence for a link. With a valid expiry day: "This link works until 6 December." in the browser's
 * locale, with the year only when it isn't this year. Anything else keeps the old 30-day wording.
 */
export function linkFooterText(expires: string | undefined, now: Date = new Date(), locale?: string | string[]): string {
  const match = expires === undefined ? null : /^(\d{4})-(\d{2})-(\d{2})$/.exec(expires);
  if (!match) return LINK_FOOTER_DEFAULT;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const date = new Date(Date.UTC(year, month - 1, day, 12));
  // Reject a day that rolled over (2026-02-31) rather than word a date nobody meant.
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return LINK_FOOTER_DEFAULT;
  try {
    const words = new Intl.DateTimeFormat(locale, {
      day: 'numeric',
      month: 'long',
      ...(year === now.getUTCFullYear() ? {} : { year: 'numeric' as const }),
      timeZone: 'UTC',
    }).format(date);
    return `This link works until ${words}.`;
  } catch {
    return LINK_FOOTER_DEFAULT;
  }
}

/** As openSharedPacket, and the expiry day the server sent with it, if it sent one. Only the day, never a time. */
export async function openSharedPacketWithExpiry(
  link: ShareLinkRef,
  fetchImpl: typeof fetch = fetch,
): Promise<{ bytes: Uint8Array; expires: string | undefined }> {
  let response: Response;
  try {
    response = await fetchImpl(`${link.origin}/l/${link.id}/packet`, {
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      referrerPolicy: 'no-referrer',
    });
  } catch {
    throw new ShareLinkError(LINK_MESSAGES.offline, 'offline');
  }
  if (response.status === 404 || response.status === 410) throw new ShareLinkError(LINK_MESSAGES.expired, 'expired');
  // The server answers 503 while links are switched off: nothing will change in a minute, so it isn't "try again".
  if (response.status === 503) throw new ShareLinkError(LINK_MESSAGES.off, 'off');
  if (response.status !== 200) throw new ShareLinkError(LINK_MESSAGES.server, 'server');
  let sealed: Uint8Array;
  try {
    sealed = new Uint8Array(await response.arrayBuffer());
  } catch {
    throw new ShareLinkError(LINK_MESSAGES.offline, 'offline');
  }
  try {
    const bytes = await openPart(sealed, PART.packet, link.key);
    return { bytes, expires: response.headers.get(LINK_EXPIRES_HEADER) ?? undefined };
  } catch {
    throw new ShareLinkError(LINK_MESSAGES.damaged, 'damaged');
  }
}
