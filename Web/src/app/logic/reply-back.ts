// Sending replies back to the friend who shared (#2168 phase 2, after the iPhone app's #3221). The rules mirror
// Packages/SessionKit/Sources/SessionKit/ReplyBack.swift (`ReplyBackOffer`): Share on an episode that holds a friend's
// Margins offers "Send replies to <friend>", the listener's replies pre-picked and their other new Margins offered
// unpicked, and nothing the friend sent goes back. Plain TypeScript with no DOM, so `npm run test:web` covers it.
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
import { senderName } from './arrival.ts';

export interface ReplyBackOffer {
  /** The listener's replies to a friend's Margins: picked at the start. */
  replies: Margin[];
  /** The listener's other Margins made since the friend's: offered, not picked. */
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

/** The Margins the listener starts with picked: the replies (Swift :19 `isPreselected`). */
export function preselected(offer: ReplyBackOffer): Set<string> {
  return new Set(offer.replies.map((m) => m.id));
}

/**
 * The Margins to write for the picked ids, in the order they were made. Nothing outside the offer can go: a friend's
 * Margin never travels back, whatever ids are passed.
 */
export function pickedMargins(offer: ReplyBackOffer, picked: ReadonlySet<string>): Margin[] {
  return offer.candidates.filter((m) => picked.has(m.id));
}
