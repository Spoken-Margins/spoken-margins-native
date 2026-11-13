// Sending replies back to the friend who shared (#2168 phase 2, after the iPhone app's #3221). The rules mirror
// Packages/SessionKit/Sources/SessionKit/ReplyBack.swift (`ReplyBackOffer`): Share on an episode that holds a friend's
// Margins offers "Send replies to <friend>", the listener's replies pre-picked and their other new Margins offered
// unpicked, and nothing the friend sent goes back. Plain TypeScript with no DOM, so `npm run test:web` covers it.
// One more difference (#3784): the web records no reply link, so it also starts the listener's Margins made since the
// page opened picked (`preselected`).
//
// What the web does differently from the app, because its store is smaller:
// - The app compares a Margin's `createdAt` with the layer's `importedAt` ("since you opened your friend's", Swift
//   :43-44, :56). The web stores no moment of opening. The closest equivalent is the earliest `createdAt` among the
//   friend's Margins on the episode, which is when the friend made them, so it is never later than the real opening.
//   A Margin the listener made after the friend's first one but before opening it can therefore be offered (unpicked).
// - The app finds the friend by the packet digest of a live imported layer (Swift :37-38, :52). The web has no layers;
//   a friend's Margin id is `packet:<digest>:<id>` (packet/read.ts packetMarginId), so the digests in those ids stand
//   for the layers, and a layer's label is its Margins' `author`.
// - The app skips deleted or non-item Margins (Swift :36, :50); every web Margin is live and anchored in time.
import type { Margin } from '../../shared/model.ts';
import { LIMITS } from '../../packet/format.ts';
import { TOO_MANY_MARGINS } from '../../packet/write.ts';
import { senderName, type MarginCue } from './arrival.ts';

export interface ReplyBackOffer {
  /** The listener's replies to a friend's Margins. */
  replies: Margin[];
  /** The listener's other Margins made since the friend's: offered; picked at the start only if made since the page opened. */
  others: Margin[];
  /** Whose Margins the replies answer; with no replies, every friend on the episode. */
  friendLabels: string[];
  /** "Send replies to Ana" (Swift :16, :20). */
  title: string;
  /** Every Margin the list shows, in the order they were made (Swift :18). */
  candidates: Margin[];
}

const PACKET_ID = /^packet:([0-9a-f]{64}):/;

const digestOf = (id: string): string | undefined => PACKET_ID.exec(id)?.[1];

const time = (margin: Margin): number => {
  const ms = Date.parse(margin.createdAt);
  return Number.isNaN(ms) ? 0 : ms;
};

/** Swift :71-73 `madeBefore`: by creation time, then id. */
const madeBefore = (a: Margin, b: Margin): number => time(a) - time(b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

/**
 * Swift :76-83 `names`: none is "your friend", one is the name, two are "A and B", more are "A, B and 2 others".
 * The web's `senderName` is the app's `SharedPacketArrival.senderName` (a blank name reads "your friend").
 */
export function friendNames(labels: readonly string[]): string {
  switch (labels.length) {
    case 0: return 'your friend';
    case 1: return labels[0];
    case 2: return `${labels[0]} and ${labels[1]}`;
    default: return `${labels[0]}, ${labels[1]} and ${labels.length - 2} other${labels.length === 3 ? '' : 's'}`;
  }
}

/** The friend's Margins fire by themselves and carry an author; the listener's own never do (arrival.ts friendMargins). */
const isFriends = (margin: Margin): boolean => margin.author !== undefined && margin.author !== '';

/**
 * The offer for an episode's Margins, or undefined when the listener has made no Margin since the friend's (Swift
 * :30-32, :61). `margins` are all of the episode's Margins, the friend's included; the friend's are never offered
 * (Swift :27-29).
 */
export function replyBackOffer(margins: readonly Margin[]): ReplyBackOffer | undefined {
  const friends = margins.filter(isFriends);
  if (friends.length === 0) return undefined;
  const firstOpen = Math.min(...friends.map(time));

  // One layer per packet; a friend's Margin whose id names no packet stands alone.
  const layers = new Map<string, string>();
  for (const friend of [...friends].sort(madeBefore)) {
    const key = digestOf(friend.id) ?? friend.id;
    if (!layers.has(key)) layers.set(key, friend.author as string);
  }

  const replies: Margin[] = [];
  const others: Margin[] = [];
  const answered: string[] = [];
  for (const margin of margins.filter((m) => !isFriends(m)).sort(madeBefore)) {
    const parent = margin.replyToId ? digestOf(margin.replyToId) : undefined;
    if (parent !== undefined && layers.has(parent)) {
      // Swift :52-54: a reply stays on offer, and the layer it answers is named once, in the order replies come.
      replies.push(margin);
      if (!answered.includes(parent)) answered.push(parent);
    } else if (time(margin) >= firstOpen) {
      others.push(margin);
    }
  }
  if (replies.length === 0 && others.length === 0) return undefined;

  // Swift :58-65: a friend with no name is "your friend", never a label.
  const ordered = answered.length > 0 ? answered : [...layers.keys()];
  const friendLabels: string[] = [];
  for (const key of ordered) {
    const name = senderName(layers.get(key));
    if (name !== 'your friend' && !friendLabels.includes(name)) friendLabels.push(name);
  }
  return {
    replies,
    others,
    friendLabels,
    title: `Send replies to ${friendNames(friendLabels)}`,
    candidates: [...replies, ...others].sort(madeBefore),
  };
}

/**
 * The Margins the listener starts with picked: the replies (Swift :19 `isPreselected`), and the other new Margins made
 * at or after `since`, the moment this page was opened. The app knows which friend's Margin each Margin answers; the web
 * never records that (no Margin it makes carries `replyToId`), so with replies only every box started unticked and Send
 * was greyed out with no reason (#3784). A Margin made since the page opened was made while listening to the friend's, so
 * it starts picked. An older note, which `others` can hold because the web stores no moment of opening, stays unpicked,
 * so a private note is never ticked for the listener.
 */
export function preselected(offer: ReplyBackOffer, since: number = Number.POSITIVE_INFINITY): Set<string> {
  const picked = new Set(offer.replies.map((m) => m.id));
  for (const margin of offer.others) if (time(margin) >= since) picked.add(margin.id);
  return picked;
}

/** Why Send and Save are greyed, in words. Undefined when something is picked. */
export function nothingPickedReason(offer: ReplyBackOffer | undefined, toWriteCount: number): string | undefined {
  if (toWriteCount > 0) return undefined;
  return offer ? 'Tick at least one Margin above to send it.' : 'There is nothing to share yet.';
}

/** The words on the button above the reply list: what the next tap does (#4093). */
export type SelectAllLabel = 'Select all' | 'Select none';

/** Whether every listed Margin is ticked. False for an empty list, which has no button. */
export function allPicked(candidates: readonly Margin[], picked: ReadonlySet<string>): boolean {
  return candidates.length > 0 && candidates.every((m) => picked.has(m.id));
}

/** "Select none" when everything listed is ticked, else "Select all": the label always says what the next tap does. */
export function selectAllLabel(everyPicked: boolean): SelectAllLabel {
  return everyPicked ? 'Select none' : 'Select all';
}

/**
 * The ticks the "Select all" / "Select none" button sets: every listed Margin to `value`, and nothing else. Only the
 * offer's candidates are passed, and the friend's own Margins are never among them (`replyBackOffer`).
 */
export function pickAll(candidates: readonly Margin[], value: boolean): Record<string, boolean> {
  return Object.fromEntries(candidates.map((m) => [m.id, value]));
}

/** The writer's limit, said before the tap: undefined up to `LIMITS.margins` ticked. */
export function tooManyReason(pickedCount: number): string | undefined {
  return pickedCount > LIMITS.margins ? TOO_MANY_MARGINS : undefined;
}

/**
 * Why Send and Save are greyed, in words: nothing ticked, or too many ticked. The too-many sentence is said only where
 * a list lets the listener untick (an offer); with no list the writer's own error toast stays the only notice.
 */
export function whyNotShared(offer: ReplyBackOffer | undefined, toWriteCount: number): string | undefined {
  return nothingPickedReason(offer, toWriteCount) ?? (offer ? tooManyReason(toWriteCount) : undefined);
}

/**
 * What to say after the file is saved, when it is saved and not handed to a share sheet: the file goes nowhere until
 * the listener sends it. With a friend's Margins on the episode it names them (#3784). Nothing else is promised: the
 * sharer is never told when the file arrives.
 */
export function savedFileNextStep(offer: ReplyBackOffer): string {
  return `Send this file to ${friendNames(offer.friendLabels)} in a message.`;
}

/** One row of the reply list: the Margin's words, or "Voice Margin" with its length only when it has one. */
export function candidateLabel(margin: Margin, clock: (seconds: number) => string): string {
  if (margin.text) return margin.text;
  const seconds = margin.voice?.durationSeconds ?? 0;
  return seconds > 0 ? `Voice Margin, ${clock(seconds)}` : 'Voice Margin';
}

/**
 * The Margins to write for the picked ids, in the order they were made. Nothing outside the offer can go: a friend's
 * Margin never travels back, whatever ids are passed.
 */
export function pickedMargins(offer: ReplyBackOffer, picked: ReadonlySet<string>): Margin[] {
  return offer.candidates.filter((m) => picked.has(m.id));
}

/**
 * The card after the listener saves a Margin on an item a friend sent: what Share will do with it. The owner approved
 * the words on 2026-11-06: "Your Margin is saved. Share sends it to {sender}. You pick which of your Margins go."
 * It shows only where there is a reply-back offer (a friend's Margins and one of the listener's), so an item of the
 * listener's own gets nothing. It replaces the "That was X's last Margin" card but never the countdown (`nowCard`), until
 * a friend's Margin plays (the screen clears it then); an episode that can't play keeps its own card. No button: Share is on the screen.
 */
export function savedMarginCard(margins: readonly Margin[], cue: MarginCue | undefined): { sentence: string } | undefined {
  if (cue && (cue.kind === 'unplayable' || cue.kind === 'unplayable-done')) return undefined;
  const offer = replyBackOffer(margins);
  if (!offer) return undefined;
  return { sentence: `Your Margin is saved. Share sends it to ${friendNames(offer.friendLabels)}. You pick which of your Margins go.` };
}

/**
 * What the Now Playing card shows (#4092). After a save, the saved sentence sits on top of the countdown instead of
 * replacing it, so Skip does not go missing until a friend's Margin plays: the web has no transport Next button, the
 * card's Skip is its only jump. The sentence still replaces "That was X's last Margin" (nothing is left to skip to), and
 * an episode that can't play keeps its own card alone.
 */
export function nowCard(
  margins: readonly Margin[], cue: MarginCue | undefined, saved: boolean,
): { saved?: string; cue?: MarginCue } {
  const sentence = saved ? savedMarginCard(margins, cue)?.sentence : undefined;
  if (sentence === undefined) return { cue };
  if (cue?.kind === 'countdown') return { saved: sentence, cue };
  return { saved: sentence };
}
