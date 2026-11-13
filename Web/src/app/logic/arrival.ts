// What a friend reads and does when a share link opens in a browser (#2168, slice 4 of #3247). The words come from
// the owner-approved "friend's words" page: the sender's name leads, "Margin" is the only noun for what the sender
// left, a failure says what happened and one thing the friend can do. Plain TypeScript with no DOM, so
// `npm run test:web` covers it.
import { formatClock } from '../../shared/clock.ts';
import type { Episode, Margin, PlaybackPosition } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import { findEpisode } from './import.ts';
import { listenState } from './library.ts';
import { senderNameOrNone } from './reply-words.ts';
import { firesByItself } from './margin-autoplay.ts';

/** How far before a Margin the first Skip lands, so the friend hears the episode's own lead-in (2026-10-31 call). */
export const LEAD_IN_SECONDS = 20;
/** A written Margin counts this long toward "about N min": the time to hear a tone and a short line read aloud. */
const WRITTEN_SECONDS = 8;

/**
 * Whether the browser's voice reads this Margin aloud. A voice Margin plays its own audio; a written one is read unless
 * the sender asked that it not be (`readAloud: false`, #3445). The words show on screen either way.
 */
export function readsAloud(margin: Margin): boolean {
  return !margin.voice && margin.readAloud !== false;
}

/**
 * Whether a friend's Margin makes playback wait for it: a voice Margin plays its clip, a written one is read aloud.
 * One the sender asked not to be read aloud shows its words and is passed, as Skim passes it on the iPhone (#3445).
 */
export function stopsPlayback(margin: Margin): boolean {
  return margin.voice !== undefined || readsAloud(margin);
}

/**
 * The sender's name as the friend sees it. The packet's name is the sender's own claim, so it is only ever text. A label
 * that stands in for a missing name ("Your friend", "Someone", "Unsigned sender", "Imported collection", in any case) is
 * "your friend", so the countdown, the Share title and the reply row never name a sender two ways (reply-words.ts).
 */
export function senderName(sender: string | undefined): string {
  return senderNameOrNone(sender) ?? 'your friend';
}

/** A Margin's own author, or the packet's sender when the author is blank or only stands in for a missing name (#4107). */
function namedAuthor(author: string | undefined, sender: string | undefined): string | undefined {
  return senderNameOrNone(author) ?? sender;
}

/** A name at the start of a sentence: "your friend" becomes "Your friend"; a name is left as the sender wrote it. */
export function leading(name: string): string {
  return name.startsWith('your friend') ? `Y${name.slice(1)}` : name;
}

/** The name with its possessive: "Cole’s", "your friend’s". */
export function possessive(name: string): string {
  return `${name}’s`;
}

/** The first letter for the avatar circle. */
export function senderInitial(sender: string | undefined): string {
  const first = Array.from(sender?.trim() ?? '')[0];
  return first ? first.toUpperCase() : '•';
}

export interface ArrivalFacts {
  who: string;
  initial: string;
  /** "3 Margins · about 2 min". */
  countLine: string;
  /** The one-time explanation of "Margin", in the version that is true for these Margins (2026-11-02 call). */
  explanation: string;
  /** Whether any Margin is spoken, for the Play line. */
  anySpoken: boolean;
}

function lengthWords(seconds: number): string {
  if (seconds < 45) return 'under a minute';
  return `about ${Math.max(1, Math.round(seconds / 60))} min`;
}

/** How long the sender's Margins take to hear, in seconds: each voice Margin's length, a written one's reading time. */
export function marginsSeconds(margins: readonly Margin[]): number {
  return margins.reduce((sum, m) => sum + (m.voice ? m.voice.durationSeconds : readsAloud(m) ? WRITTEN_SECONDS : 0), 0);
}

export function arrivalFacts(sender: string | undefined, margins: readonly Margin[]): ArrivalFacts {
  const who = senderName(sender);
  const anyWritten = margins.some((m) => !m.voice);
  const count = margins.length === 1 ? '1 Margin' : `${margins.length} Margins`;
  return {
    who,
    initial: senderInitial(sender),
    countLine: `${count} · ${lengthWords(marginsSeconds(margins))}`,
    explanation: anyWritten
      ? `A Margin is a note ${who} left at a moment in this episode. You’ll hear each one there.`
      : `A Margin is a voice note ${who} left at a moment in this episode.`,
    anySpoken: margins.some((m) => m.voice !== undefined),
  };
}

/**
 * Where Play starts: the listener's own saved place in this episode, when they have started it (the Library row says
 * "Resume at" for the same place), else the beginning (#3798). `undefined` means the beginning. A finished episode
 * starts over, as the Library's own play does.
 */
export function arrivalResumeAt(
  read: PacketRead,
  episodes: readonly Episode[],
  positions: readonly PlaybackPosition[],
): number | undefined {
  const own = findEpisode(read, episodes);
  if (!own) return undefined;
  const position = positions.find((p) => p.episodeId === own.id);
  return listenState(own, position) === 'started' ? position?.seconds : undefined;
}

/** The line under the Play button, saying what Play does: one place, the same one Play then goes to. */
export const playHint = (who: string, resumeAt?: number): string =>
  `${resumeAt === undefined ? 'Starts at the beginning.' : `Picks up at ${formatClock(resumeAt)}.`} ${leading(possessive(who))} Margins play when the episode reaches them.`;

/** Every way a link can fail to open, in the words a friend reads. Expired, removed and unknown all read the same. */
export const ARRIVAL_WORDS = Object.freeze({
  expired: 'This link has expired. Ask your friend to share it again.',
  cutOff: 'This link is cut off. Copy the whole link from the message and open it again.',
  off: 'Links are switched off for now. Ask your friend to send the Margins as a file.',
  offline: 'You’re offline. Reconnect, then open the link again.',
  server: 'The server had a problem. Try again in a minute.',
  unreadable: 'This file couldn’t be opened. It may have been damaged on the way. Ask your friend to send it again.',
  article: (who: string) => `${leading(possessive(who))} Margins are on an article’s text, which the browser can’t play yet.`,
  noEpisodeAudio: (who: string) => `This episode has no audio the browser can play. ${leading(possessive(who))} Margins are saved in your Library.`,
  // The episode has an address but it failed to load (#3356): say so once, and offer the Margins on their own.
  episodeCantPlay: (who: string) => `This episode can’t play here, but you can still hear ${possessive(who)} Margins.`,
  hearMargins: (who: string) => `Hear ${possessive(who)} Margins`,
  episodeCantPlayDone: (who: string) => `That was ${possessive(who)} last Margin, and the episode can’t play here.`,
});

/** The one app link on the arrival page's foot (#3783): the join guide, not TestFlight, since the guide explains the "tap the link again" step TestFlight strands people on. */
export const GET_APP_LINK = Object.freeze({
  text: 'Get Spoken Margins for iPhone',
  href: 'https://spokenmargins.com/join',
});

/** The Margins that come from a friend, in the order they come. Only these fire by themselves and get a countdown. */
export function friendMargins(margins: readonly Margin[]): Margin[] {
  return margins.filter(firesByItself).sort((a, b) => a.atSeconds - b.atSeconds);
}

/** "11 min" while far off, then "0:20" in the last minute. */
export function countdownClock(secondsAway: number): string {
  const s = Math.max(0, Math.ceil(secondsAway));
  return s >= 60 ? `${Math.ceil(s / 60)} min` : formatClock(s);
}

/** What a screen reader hears for the countdown: coarse, so it isn't read out every second. */
export function countdownSpoken(secondsAway: number): string {
  const s = Math.max(0, Math.ceil(secondsAway));
  if (s < 60) return 'less than a minute';
  const m = Math.ceil(s / 60);
  return m === 1 ? '1 minute' : `${m} minutes`;
}

export type MarginCue =
  | {
      kind: 'countdown';
      /** "Cole’s first Margin in". */
      label: string;
      /** "11 min" or "0:20". */
      clock: string;
      /** Read by a screen reader. */
      spoken: string;
      /** The Skip button's words and where it goes. The first Skip lands before the lead-in, the second on the Margin. */
      skip: { label: string; to: number };
      /** Whether the friend is inside the lead-in (the second Skip). */
      leadIn: boolean;
      /** The share left in the lead-in, 0 to 1, for the draining bar. */
      leadInLeft: number;
    }
  | { kind: 'after-last'; who: string; /** The name at the start of a sentence. */ lead: string }
  /** The episode failed to load: no countdown, no Skip; one sentence and one button that plays the Margins without it. */
  | { kind: 'unplayable'; who: string; sentence: string; button: string }
  /** The Margins have been heard without the episode: what's left, simply. No countdown comes back. */
  | { kind: 'unplayable-done'; who: string; sentence: string };

/** What the player knows about the episode, for the card. */
export interface EpisodeState {
  /** The episode failed to load (the player's one failure state). */
  failed: boolean;
  /** The sender's Margins have all been heard without the episode. */
  heardWithoutEpisode: boolean;
}

/** Margins closer than this to the playhead are "now", not upcoming: the one just crossed has fired already. */
const PAST_SECONDS = 0.5;
/** Land a hair before a Margin, so playback crosses its moment and the Margin fires. */
const CROSS_MARGIN_SECONDS = 0.3;

/**
 * The countdown card for the playhead at `time`: how far the next friend Margin is and the Skip that goes toward
 * it. After the last Margin it points at the player's own Margin buttons, which are how the friend answers.
 */
export function cueFor(margins: readonly Margin[], time: number, sender: string | undefined, episode?: EpisodeState): MarginCue | undefined {
  // The countdown and its Skip lead to the Margins that play or are read; a silent written one is passed (#3445).
  const friends = friendMargins(margins).filter(stopsPlayback);
  if (friends.length === 0) return undefined;
  if (episode?.failed) {
    const who = senderName(namedAuthor(friends[0].author, sender));
    return episode.heardWithoutEpisode
      ? { kind: 'unplayable-done', who, sentence: ARRIVAL_WORDS.episodeCantPlayDone(who) }
      : { kind: 'unplayable', who, sentence: ARRIVAL_WORDS.episodeCantPlay(who), button: ARRIVAL_WORDS.hearMargins(who) };
  }
  const index = friends.findIndex((m) => m.atSeconds > time + PAST_SECONDS);
  if (index === -1) {
    const last = senderName(namedAuthor(friends[friends.length - 1].author, sender));
    return { kind: 'after-last', who: last, lead: leading(last) };
  }
  const next = friends[index];
  // Two friends can have Margins on one episode: the countdown names whose is next.
  const who = senderName(namedAuthor(next.author, sender));
  const away = next.atSeconds - time;
  const ordinal = friends.length === 1 ? '' : index === 0 ? 'first ' : index === friends.length - 1 ? 'last ' : 'next ';
  const leadIn = away <= LEAD_IN_SECONDS + 1;
  return {
    kind: 'countdown',
    label: `${leading(possessive(who))} ${ordinal}Margin in`,
    clock: countdownClock(away),
    spoken: `${leading(possessive(who))} ${ordinal}Margin in ${countdownSpoken(away)}`,
    skip: leadIn
      ? { label: `Skip to ${who} now`, to: Math.max(0, next.atSeconds - CROSS_MARGIN_SECONDS) }
      : { label: `Skip to just before ${who}`, to: Math.max(0, next.atSeconds - LEAD_IN_SECONDS) },
    leadIn,
    leadInLeft: leadIn ? Math.min(1, Math.max(0, away / LEAD_IN_SECONDS)) : 1,
  };
}

/** The card while a friend's Margin is heard or shown: who, and which of how many. */
export function speakingLine(margin: Margin, margins: readonly Margin[], sender: string | undefined): { title: string; position: string } {
  const friends = friendMargins(margins);
  const place = friends.findIndex((m) => m.id === margin.id) + 1;
  const who = leading(senderName(namedAuthor(margin.author, sender)));
  return {
    title: margin.voice ? `${who} is speaking` : `${who} wrote this`,
    position: place > 0 ? `${place} of ${friends.length}` : '',
  };
}

/** The line the on-device voice says before a written Margin's words, so a synthetic voice never passes for the sender. */
export function writtenIntro(author: string | undefined): string {
  return `${leading(senderName(author))} wrote:`;
}
