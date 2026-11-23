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
// the first 1 KB of the episode's audio. Since 2026-11-23 (#4783, the owner's yes) an Apple Podcasts episode with no audio
// address is looked up the way the friend's page looks it up (`findAppleEpisodeAudio`): Apple's public lookup, then the show's
// feed when Apple doesn't list it. So the #4433 case (a post with no voice), an Apple episode with no audio to find and an
// episode whose audio a browser can't play are caught before the friend meets them.
//
// The messages, all posted to `window.webkit.messageHandlers.smPlayCheck`:
//   { type: 'started' }                                          the page is running the check; sent once
//   { type: 'verdict', verdict: 'plays' }
//   { type: 'verdict', verdict: 'cannot', reason: CannotPlayReason | 'audio-refused' | 'audio-format' }
//   { type: 'verdict', verdict: 'unverified', why: 'post-voice' }
//   { type: 'failed', reason: 'link-broken' | 'links-off' | 'offline' | 'server' }   the link did not open
import { findAppleEpisodeAudio } from '../sources/apple.ts';
import { PaidPostNoVoice, readSubstackVoice } from '../sources/read.ts';
import { pageHoldsThisPost } from '../sources/substack.ts';
import type { PacketRead } from './ports.ts';
import { playability, type CannotPlayReason } from './logic/playability.ts';
import { ShareLinkError } from './logic/share-link.ts';
import { browserCanPlayType, checkReadHandler, checkTransport, classifyAudioStart, isReadRefused, type CheckReadHandler } from './play-check-reads.ts';

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
  // An Apple Podcasts episode page is looked up as the friend's page looks it up (#4783). Any other page is already `cannot` (#4767).
  if (first.verdict === 'needs-voice-lookup' && first.source === 'apple-episode') return appleEpisodeMessage(read, first.pageUrl, reads, canPlayType);
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
    return await audioStartMessage(audioUrl, reads, canPlayType);
  } catch (error) {
    if (error instanceof PaidPostNoVoice) return { type: 'verdict', verdict: 'cannot', reason: 'paid-post' };
    return { type: 'failed', reason: 'server' };
  }
}

/** The verdict the start of the audio gives, read once through the app. */
async function audioStartMessage(audioUrl: string, reads: CheckReadHandler, canPlayType: (type: string) => string): Promise<PlayCheckMessage> {
  const audio = classifyAudioStart(await reads.postMessage({ kind: 'audio-start', url: audioUrl }), canPlayType);
  if (audio === 'unreachable') return { type: 'failed', reason: 'server' };
  return audio === 'plays' ? { type: 'verdict', verdict: 'plays' } : { type: 'verdict', verdict: 'cannot', reason: audio };
}

/**
 * An Apple Podcasts episode with no audio address of its own (#4783): the same lookup the friend's page makes when they tap
 * Play (`findAppleEpisodeAudio`, Apple's lookup and then the show's feed matched by the packet's exact title), made through
 * the app's reads, then the audio's start. So the sender is told what the friend will meet:
 * - found, and its audio starts: `plays`; found, but the audio is refused or in a format browsers can't play: that `cannot`;
 * - Apple answered and neither it nor the feed holds the episode with audio (or the feed is over the 4 MB a browser reads
 *   too): `cannot` / `no-episode-audio`, the friend's card;
 * - a read failed (offline, Apple or the host in trouble): `failed`, which the app words "Not checked";
 * - the app refused a read (a build that predates these reads, or a second feed a page pointed to): `unverified`, as before.
 */
async function appleEpisodeMessage(
  read: Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>,
  pageUrl: string,
  reads: CheckReadHandler,
  canPlayType: (type: string) => string,
): Promise<PlayCheckMessage> {
  let refused = false;
  const watched: CheckReadHandler = {
    postMessage: async (request) => {
      try {
        return await reads.postMessage(request);
      } catch (error) {
        if (isReadRefused(error)) refused = true;
        throw error;
      }
    },
  };
  try {
    const found = await findAppleEpisodeAudio(pageUrl, {
      fetch: checkTransport(watched, 'apple-lookup').fetch,
      // `consent: false` and a native transport: a feed the app can't read is "couldn't tell", never a relay read.
      feed: { title: read.episode.title, transport: checkTransport(watched, 'feed'), consent: false },
    });
    if (!found) {
      const settled = playability(read, 'none');
      return settled.verdict === 'cannot' ? { type: 'verdict', verdict: 'cannot', reason: settled.reason } : messageForOpened(read);
    }
    return await audioStartMessage(found.audioUrl, watched, canPlayType);
  } catch {
    return refused ? messageForOpened(read) : { type: 'failed', reason: 'server' };
  }
}
