// The sender's background check (#4454): the iPhone app loads the exact share link in a hidden web view and this page
// answers "would a friend's browser play this?" with one message, without playing anything.
//
// Probe mode is on only when the web view has the `smPlayCheck` message handler the app injects. No ordinary browser has
// one, and a link can't switch it on: `parseShareLink` refuses any query string. So for a friend nothing here runs.
//
// With no `smPlayCheckRead` handler (play-check-reads.ts) the check reads nothing the page doesn't already read to draw
// the arrival card: the packet. It never starts the player and never uses the relay. A post whose voice would have to be
// looked up is then reported `unverified`.
//
// With the handler, the app lets the check settle what only the publisher can say, through the app's own network stack
// (the owner agreed on 2026-11-17 that the Share link tap covers it): one read of a Substack post's page for its voice, and
// the first 1 KB of the episode's audio. So the #4433 case (a post with no voice) and an episode whose audio a browser
// can't play are caught before the friend meets them.
//
// The messages, all posted to `window.webkit.messageHandlers.smPlayCheck`:
//   { type: 'started' }                                          the page is running the check; sent once
//   { type: 'verdict', verdict: 'plays' }
//   { type: 'verdict', verdict: 'cannot', reason: CannotPlayReason | 'audio-refused' | 'audio-format' }
//   { type: 'verdict', verdict: 'unverified', why: 'post-voice' }
//   { type: 'failed', reason: 'link-broken' | 'links-off' | 'offline' | 'server' }   the link did not open
import { PaidPostNoVoice, readSubstackVoice } from '../sources/read.ts';
import { pageHoldsThisPost } from '../sources/substack.ts';
import type { PacketRead } from './ports.ts';
import { playability, type CannotPlayReason } from './logic/playability.ts';
import { ShareLinkError } from './logic/share-link.ts';
import { browserCanPlayType, checkReadHandler, checkTransport, classifyAudioStart } from './play-check-reads.ts';

export type PlayCheckFailure = 'link-broken' | 'links-off' | 'offline' | 'server';

/** Why an episode's audio can't be played, which only a read of the audio can say. */
export type AudioReason = 'audio-refused' | 'audio-format';

export type PlayCheckMessage =
  | { type: 'started' }
  | { type: 'verdict'; verdict: 'plays' }
  | { type: 'verdict'; verdict: 'cannot'; reason: CannotPlayReason | AudioReason }
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

/**
 * What the check says about an opened packet. With the app's read handler it settles the post's voice and the audio's
 * start; without it, it is `messageForOpened`. Never throws, and a read that fails says `failed`, never a warning: the
 * app words it "Not checked".
 */
export async function messageForOpenedSettled(
  read: Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>,
  host: unknown = globalThis,
  canPlayType: (type: string) => string = browserCanPlayType,
): Promise<PlayCheckMessage> {
  // The reads need both of the app's handlers: with only one of them nobody would hear the verdict.
  const reads = playCheckHandler(host) ? checkReadHandler(host) : undefined;
  const first = playability(read);
  if (!reads || first.verdict === 'cannot') return messageForOpened(read);
  // Only a Substack post's page is read (the agreed read). An Apple Podcasts episode page needs Apple's lookup, which the
  // hidden web view can't make (it loads nothing but the link) and the app's reads don't cover, so it stays `unverified`:
  // the friend's page asks Apple itself when the link is opened (#4783). Any other page is already `cannot` (#4767).
  if (first.verdict === 'needs-voice-lookup' && first.source !== 'substack-post') return messageForOpened(read);
  try {
    let audioUrl = read.episode.audioUrl;
    if (first.verdict === 'needs-voice-lookup') {
      const page: { body?: string; url?: string } = {};
      const transport = checkTransport(reads);
      const recording: typeof transport = {
        ...transport,
        fetch: async (input, init) => {
          const response = await transport.fetch(input, init);
          page.url = response.url;
          page.body = await response.clone().text();
          return response;
        },
      };
      const voice = await readSubstackVoice(first.pageUrl, { transport: recording, reason: 'sender-share-check' });
      // "No voice" is said only when the page held this very post; anything else is "couldn't tell" (`unverified`).
      if (!voice && !(page.body !== undefined && page.url !== undefined && pageHoldsThisPost(page.body, page.url))) {
        return { type: 'verdict', verdict: 'unverified', why: 'post-voice' };
      }
      const settled = playability(read, voice ? 'found' : 'none');
      if (settled.verdict === 'cannot') return { type: 'verdict', verdict: 'cannot', reason: settled.reason };
      audioUrl = voice?.audioUrl;
    }
    if (!audioUrl) return messageForOpened(read);
    const audio = classifyAudioStart(await reads.postMessage({ kind: 'audio-start', url: audioUrl }), canPlayType);
    if (audio === 'unreachable') return { type: 'failed', reason: 'server' };
    return audio === 'plays' ? { type: 'verdict', verdict: 'plays' } : { type: 'verdict', verdict: 'cannot', reason: audio };
  } catch (error) {
    if (error instanceof PaidPostNoVoice) return { type: 'verdict', verdict: 'cannot', reason: 'paid-post' };
    return { type: 'failed', reason: 'server' };
  }
}
