// The sender's background check (#4454): the iPhone app loads the exact share link in a hidden web view and this page
// answers "would a friend's browser play this?" with one message, without playing anything.
//
// Probe mode is on only when the web view has the `smPlayCheck` message handler the app injects. No ordinary browser has
// one, and a link can't switch it on: `parseShareLink` refuses any query string. So for a friend nothing here runs.
//
// The check reads nothing the page doesn't already read to draw the arrival card: the packet. It never starts the
// player, never reads a publisher's page or audio, and never uses the relay. A post whose voice would have to be looked
// up is reported `unverified`, because settling it takes a publisher read that waits on the owner's call (#4454, PR 1b).
//
// The messages, all posted to `window.webkit.messageHandlers.smPlayCheck`:
//   { type: 'started' }                                          the page is running the check; sent once
//   { type: 'verdict', verdict: 'plays' }
//   { type: 'verdict', verdict: 'cannot', reason: CannotPlayReason }
//   { type: 'verdict', verdict: 'unverified', why: 'post-voice' }
//   { type: 'failed', reason: 'link-broken' | 'links-off' | 'offline' | 'server' }   the link did not open
import type { PacketRead } from './ports.ts';
import { playability, type CannotPlayReason } from './logic/playability.ts';
import { ShareLinkError } from './logic/share-link.ts';

export type PlayCheckFailure = 'link-broken' | 'links-off' | 'offline' | 'server';

export type PlayCheckMessage =
  | { type: 'started' }
  | { type: 'verdict'; verdict: 'plays' }
  | { type: 'verdict'; verdict: 'cannot'; reason: CannotPlayReason }
  | { type: 'verdict'; verdict: 'unverified'; why: 'post-voice' }
  | { type: 'failed'; reason: PlayCheckFailure };

export interface PlayCheckHandler {
  postMessage(message: PlayCheckMessage): void;
}

/** The handler the app injects into its hidden web view, or undefined in any other browser. */
export function playCheckHandler(host: unknown = globalThis): PlayCheckHandler | undefined {
  const handler = (host as { webkit?: { messageHandlers?: { smPlayCheck?: Partial<PlayCheckHandler> } } } | null | undefined)?.webkit?.messageHandlers?.smPlayCheck;
  return handler && typeof handler.postMessage === 'function' ? (handler as PlayCheckHandler) : undefined;
}

/** What the check says about an opened packet: the same verdict the arrival page draws its card from. */
export function messageForOpened(read: Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>): PlayCheckMessage {
  const result = playability(read);
  if (result.verdict === 'plays') return { type: 'verdict', verdict: 'plays' };
  if (result.verdict === 'cannot') return { type: 'verdict', verdict: 'cannot', reason: result.reason };
  return { type: 'verdict', verdict: 'unverified', why: 'post-voice' };
}

/**
 * What the check says when the link did not open. A link that is cut off, expired or removed, or a packet that can't be
 * read, is a link a friend can't open (`link-broken`); the app's server being off, offline or in trouble is not the
 * link's fault, and the app words those as "not checked".
 */
export function messageForFailure(error: unknown): PlayCheckMessage {
  if (error instanceof ShareLinkError) {
    switch (error.reason) {
      case 'off':
        return { type: 'failed', reason: 'links-off' };
      case 'offline':
        return { type: 'failed', reason: 'offline' };
      case 'damaged':
      case 'expired':
        return { type: 'failed', reason: 'link-broken' };
      default:
        return { type: 'failed', reason: 'server' };
    }
  }
  return { type: 'failed', reason: 'link-broken' };
}

/** Posts one message when this page runs inside the app's check; otherwise does nothing. Never throws. */
export function reportPlayCheck(message: PlayCheckMessage, host: unknown = globalThis): void {
  try {
    playCheckHandler(host)?.postMessage(message);
  } catch {
    // The check is a courtesy: a web view that refuses a message must not break the page a friend would see.
  }
}
