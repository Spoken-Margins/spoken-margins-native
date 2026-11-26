// "Send to <sender>" in the Share section when the link carried a reply part (#4675, Screen B of
// docs/design/reply-mailbox.md): its words, and the `sentThrough` mark that says which of the listener's Margins went
// back through a link. Plain TypeScript with no DOM, so `npm run test:web` covers it (reply-send.test.ts).
//
// "<sender>" is the link's sender as the packet names them; with no name the words say "your friend" or "the person who
// sent it", never a placeholder.
import type { Margin } from '../../shared/model.ts';
import type { ReplyFailure } from './reply-box.ts';

/** Which of today's file buttons stands in as the secondary one: the share sheet, a download, or the Android app's sheet. */
export type FileFallback = 'send' | 'save' | 'native';

export const REPLY_SEND_WORDS = Object.freeze({
  sending: 'Sending…',
  sentTag: 'Sent',
  allSent: 'Everything here has been sent.',
  tooBig: 'These are too big to send through the link. Untick a long recording, or send them as a file.',
  retry: 'Couldn’t send. Check your connection, then try again.',
  tryAgain: 'Try again',
  fileOnlyTag: 'File only',
  otherPacket: 'Replies to Margins from another link or file can’t go through this link. Send those as a file.',
});

const PACKET_PARENT = /^packet:([0-9a-f]{64}):/;

/**
 * Whether a Margin can go back through the reply box of the link whose packet had `linkDigest` (#4675). The sender's
 * phone keeps an answer only when every reply in it answers a Margin from that packet (SessionKit `ReplyBoxRecord.check`,
 * `other_parent`), so a reply to a Margin from another link or file would drop the whole answer while this page said
 * Sent. A Margin that answers nothing travels; a reply travels only when its parent came in through this link's packet.
 */
export function sendsThroughLink(margin: Margin, linkDigest: string): boolean {
  const parent = margin.replyToId ? PACKET_PARENT.exec(margin.replyToId)?.[1] : undefined;
  return parent === undefined || parent === linkDigest;
}

/** The picked Margins split into those the link's box takes and those that can only go as a file. */
export function splitForLink(margins: readonly Margin[], linkDigest: string): { through: Margin[]; fileOnly: Margin[] } {
  const through: Margin[] = [];
  const fileOnly: Margin[] = [];
  for (const margin of margins) (sendsThroughLink(margin, linkDigest) ? through : fileOnly).push(margin);
  return { through, fileOnly };
}

/** The caption that replaces "Share them as a file. …". */
export function replyCaption(sender: string | undefined): string {
  return sender
    ? `They go back through this link. Only ${sender} can hear them.`
    : 'They go back through this link. Only the person who sent it can hear them.';
}

/** The primary button. */
export function sendToLabel(sender: string | undefined): string {
  return `Send to ${sender ?? 'your friend'}`;
}

/** The secondary, text-style button: today's file button under its "instead" name. */
export function fileInsteadLabel(fallback: FileFallback): string {
  switch (fallback) {
    case 'send': return 'Send as a file instead';
    case 'save': return 'Save as a file instead';
    case 'native': return 'Save or send instead';
  }
}

/** The status line after a box send. "Sent" means it reached the box, never that the sender heard it (#3902). */
export function sentLine(sender: string | undefined): string {
  return sender
    ? `Sent to ${sender}. They’ll get it the next time they open Spoken Margins.`
    : 'Sent. Your friend gets it the next time they open Spoken Margins.';
}

/** The line in `#share-why-not` for each error row. The friend's Margins stay in the browser in every one. */
export function failureLine(failure: ReplyFailure, sender: string | undefined): string {
  switch (failure) {
    case 'ended': return `This link can’t take answers any more. Send them to ${sender ?? 'your friend'} as a file instead.`;
    case 'too-big': return REPLY_SEND_WORDS.tooBig;
    case 'retry': return REPLY_SEND_WORDS.retry;
  }
}

/** The saved card on an item whose link carried a reply part (replaces "Share sends it to …"). */
export function savedCardWithBox(sender: string | undefined): string {
  return `Your Margin is saved. ${sendToLabel(sender)} sends it back. You pick which of your Margins go.`;
}

/** Whether a Margin has gone back through a link's reply box. */
export function isSent(margin: Margin): boolean {
  return typeof margin.sentThrough === 'string' && margin.sentThrough !== '';
}

/**
 * A rewritten Margin keeps the stored `sentThrough` (the same rule as `keepingSharedAs`): the voice composer's older copy,
 * written again when the words arrive, must not make a sent Margin read as unsent.
 */
export function keepingSentThrough(margin: Margin, stored: Margin | undefined): Margin {
  return stored && isSent(stored) && !isSent(margin) ? { ...margin, sentThrough: stored.sentThrough } : margin;
}

/**
 * The Margins to store again with `sentThrough: linkId`, built from the Margins as stored now. An id that isn't stored
 * (deleted meanwhile), or a Margin already marked with this link, is left out.
 */
export function withSentThrough(marginIds: readonly string[], linkId: string, margins: readonly Margin[]): Margin[] {
  const byId = new Map(margins.map((m) => [m.id, m]));
  const out: Margin[] = [];
  for (const id of new Set(marginIds)) {
    const margin = byId.get(id);
    if (margin && margin.sentThrough !== linkId) out.push({ ...margin, sentThrough: linkId });
  }
  return out;
}

/** The starting ticks with every sent Margin taken out: a sent row starts unticked; a later Margin starts ticked as usual. */
export function withoutSent(starting: ReadonlySet<string>, candidates: readonly Margin[]): Set<string> {
  const sent = new Set(candidates.filter(isSent).map((m) => m.id));
  return new Set([...starting].filter((id) => !sent.has(id)));
}

/** Whether every listed Margin has been sent. False for an empty list. */
export function everythingSent(candidates: readonly Margin[]): boolean {
  return candidates.length > 0 && candidates.every(isSent);
}

/** The listener's changes with the just-sent Margins' ticks dropped, so they fall back to their (unticked) start. */
export function forgetTicks(changed: Readonly<Record<string, boolean>>, sentIds: readonly string[]): Record<string, boolean> {
  const out = { ...changed };
  for (const id of sentIds) delete out[id];
  return out;
}
