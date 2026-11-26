// The card a friend's browser shows when it can't play the Margins on what they sit on (#5265): an article, a PDF, a
// book or a pasted text, or an episode or recording with no audio. It lists the sender's Margins with the source's words
// at each, plays them here one after another (the source's words first, in the browser's voice, then the Margin), and
// offers one next step: the iPhone app, which plays them in place and lets the friend answer. No line on it says what
// the browser can't do. Plain TypeScript with no DOM, so `npm run test:web` covers every word on it.
import { formatClock } from '../../shared/clock.ts';
import type { Margin } from '../../shared/model.ts';
import type { PacketRead } from '../ports.ts';
import { leading, marginSenderName, possessive, readsAloud, senderName } from './arrival.ts';
import { unnamedAuthorFor, type Arrival } from './import.ts';
import { graphemes, isVoicePlaceholder } from '../../shared/placeholder.ts';
import { itemKind, playability, type ItemKind } from './playability.ts';

/** How much of the source's words a Margin's context runs to: about 15 to 20 seconds read aloud (Default taken 2, #5265). */
export const CONTEXT_CHARACTERS = 300;

/** How the card reached the friend: a share link, or a `.spokenmargins` file opened in the web app. */
export type CardOrigin = Extract<Arrival, 'link' | 'file'>;

/** One Margin on the card, with what the row and the voice say about where it sits. */
export interface CardMargin {
  /** The Margin, with the packet's unnamed sender named ("Your friend"), so it never reads as the listener's own. */
  margin: Margin;
  /** The moment in seconds, for a Margin placed by time. */
  time?: number;
  /** How far through the text, 0 to 100, for a Margin on its words that says so. */
  percent?: number;
  /** The source's words the row shows and the voice reads first: the quote it sits on, or the words before it. */
  context?: string;
}

/** The nouns and sentences that change with what the Margins sit on (the Design's kinds table). */
export interface KindWords {
  kind: ItemKind;
  /** "article", "PDF", "book", "text", "episode", "recording". */
  noun: string;
  /** "place" on a text, "moment" in an episode or recording. */
  place: string;
  /** The source link's words, when the packet has a safe web address. */
  sourceLabel?: string;
  /** The next step's first sentence. */
  nextStep: string;
  /** The line after it: tap the link again, or open the file again, in the app. */
  again: string;
  /** Whether the source's words are named for the noun ("The article’s words …") or generically ("The words …"). */
  namedWords: boolean;
}

const NOUNS: Record<ItemKind, { noun: string; place: string; source: string; namedWords: boolean }> = {
  article: { noun: 'article', place: 'place', source: 'Open the article', namedWords: true },
  text: { noun: 'text', place: 'place', source: 'Open the page', namedWords: false },
  pdf: { noun: 'PDF', place: 'place', source: 'Open the PDF', namedWords: true },
  book: { noun: 'book', place: 'place', source: 'Open the book', namedWords: true },
  episode: { noun: 'episode', place: 'moment', source: 'Open the episode’s page', namedWords: true },
  recording: { noun: 'recording', place: 'moment', source: 'Open the page', namedWords: false },
};

/**
 * The card's words for this packet. `who` is the sender as the card names them; `hasAddress` is whether the packet has a
 * safe http(s) address to offer. A text with no address has no source link; an article always has one.
 */
export function kindWords(kind: ItemKind, who: string, origin: CardOrigin, hasAddress: boolean): KindWords {
  const n = NOUNS[kind];
  const sent = `${possessive(who)} ${origin}`;
  const own = kind === 'pdf' || kind === 'book' || kind === 'recording' ? `, with your own copy of the same ${n.noun}` : '';
  const inPlace = n.place === 'moment' ? `in the ${n.noun}` : `while the ${n.noun} is read aloud`;
  return {
    kind,
    noun: n.noun,
    place: n.place,
    ...(hasAddress && kind !== 'text' && { sourceLabel: n.source }),
    nextStep: `To hear them in place ${inPlace}, open ${sent} in Spoken Margins on iPhone${own}.`,
    again: origin === 'link' ? 'After installing, tap your friend’s link again to open it in the app.' : 'After installing, open the file again in the app.',
    namedWords: n.namedWords,
  };
}

/** The card's kind and words for a packet. */
export function cardWords(read: Pick<PacketRead, 'itemType' | 'episode' | 'margins'>, who: string, origin: CardOrigin, hasAddress: boolean): KindWords {
  return kindWords(itemKind(read), who, origin, hasAddress);
}

/** A run of text cut to `max` characters at a whole word, with "…" when cut. */
export function cutAtWord(text: string, max: number = CONTEXT_CHARACTERS): string {
  const collapsed = text.split(/\s+/u).filter(Boolean).join(' ');
  const parts = graphemes(collapsed);
  if (parts.length <= max) return collapsed;
  const head = parts.slice(0, max).join('');
  const space = head.lastIndexOf(' ');
  return `${(space > 0 ? head.slice(0, space) : head).replace(/[\s,;:.]+$/u, '')}…`;
}

/**
 * The last `max` characters of the words before a Margin, cut at a whole word and opened with "…" when cut: the Margins
 * tab's `leadInExcerpt` rule, kept here so this module needs none of that module's built-in words.
 */
export function wordsBefore(prefix: string | undefined, max: number = CONTEXT_CHARACTERS): string | undefined {
  const collapsed = (prefix ?? '').split(/\s+/u).filter(Boolean).join(' ');
  if (collapsed === '') return undefined;
  const parts = graphemes(collapsed);
  if (parts.length <= max) return collapsed;
  const tail = parts.slice(parts.length - max).join('');
  const space = tail.indexOf(' ');
  const trimmed = space === -1 ? tail : tail.slice(space + 1);
  return `…${trimmed === '' ? tail : trimmed}`;
}

/** The source's words for a Margin: the quote it sits on, cut at 300 characters, else the words before it. */
export function contextText(quote: string | undefined, leadIn: string | undefined): string | undefined {
  if (quote && quote.trim()) return cutAtWord(quote);
  return wordsBefore(leadIn);
}

/**
 * The card's Margins, in the card's order: those placed by time, by time; then those on the words with a percent, lowest
 * first; then the rest in the packet's order. Each gets the packet's unnamed sender named for how it came (#4226).
 */
export function cardMargins(read: Pick<PacketRead, 'margins' | 'pageMargins'>, origin: CardOrigin): CardMargin[] {
  const unnamed = unnamedAuthorFor(origin);
  const named = (m: Margin): Margin => (unnamed && !m.author?.trim() ? { ...m, author: unnamed } : m);
  const timed = [...read.margins]
    .sort((a, b) => a.atSeconds - b.atSeconds)
    .map((m): CardMargin => ({ margin: named(m), time: m.atSeconds, ...optional('context', contextText(undefined, m.leadIn)) }));
  const page = read.pageMargins.map((p, index) => ({ p, index }));
  const withPercent = page.filter(({ p }) => p.percent !== undefined).sort((a, b) => (a.p.percent as number) - (b.p.percent as number) || a.index - b.index);
  const without = page.filter(({ p }) => p.percent === undefined);
  const text = [...withPercent, ...without].map(({ p }): CardMargin => ({
    margin: named(p.margin),
    ...(p.percent !== undefined && { percent: p.percent }),
    ...optional('context', contextText(p.quote, p.margin.leadIn)),
  }));
  return [...timed, ...text];
}

function optional<K extends string>(key: K, value: string | undefined): { [P in K]?: string } {
  return (value === undefined ? {} : { [key]: value }) as { [P in K]?: string };
}

/** Where a row sits: "12:34" for a Margin placed by time, "About 37% in" for one with a percent, nothing otherwise. */
export function rowPlace(card: CardMargin): string {
  if (card.time !== undefined) return formatClock(card.time);
  if (card.percent !== undefined) return `About ${Math.round(Math.min(100, Math.max(0, card.percent)))}% in`;
  return '';
}

/** A row's words: the Margin's own, and for a voice Margin its length ("Voice Margin · 0:42" when it has no words). */
export function rowWords(margin: Margin): { words: string | null; voiceLine?: string } {
  const raw = (margin.text ?? '').trim();
  const own = raw === '' || isVoicePlaceholder(raw) ? null : raw;
  if (!margin.voice) return { words: own };
  const length = formatClock(Math.round(margin.voice.durationSeconds));
  return own === null ? { words: null, voiceLine: `Voice Margin · ${length}` } : { words: own, voiceLine: `Voice · ${length}` };
}

/** The name a row and the voice credit a Margin to. */
export function cardName(card: CardMargin, sender: string | undefined): string {
  return marginSenderName(card.margin, sender);
}

/** The row header's accessible name for its button: "Hear Cole’s Margin About 37% in". */
export function hearOneLabel(card: CardMargin, sender: string | undefined): string {
  const place = rowPlace(card);
  return `Hear ${possessive(cardName(card, sender))} Margin${place ? ` ${place}` : ''}`;
}

/**
 * What the browser's voice says before a Margin, or undefined for nothing: the source's words when the packet has them,
 * else where the Margin sits ("Cole’s Margin is about 37% of the way through “Title”."), else nothing. Nothing before a
 * written Margin the sender asked not to be read aloud. Never a tone: the tone means the Margin itself.
 */
export function contextLine(card: CardMargin, words: Pick<KindWords, 'noun' | 'namedWords'>, title: string, sender: string | undefined): string | undefined {
  const margin = card.margin;
  if (!margin.voice && !readsAloud(margin)) return undefined;
  const name = cardName(card, sender);
  if (card.context) {
    const whose = words.namedWords ? `the ${words.noun}’s words` : 'the words';
    return `Here are ${whose} just before ${possessive(name)} Margin: ${card.context}`;
  }
  if (card.time !== undefined) return `${leading(possessive(name))} Margin is at ${formatClock(card.time)} in “${title}”.`;
  if (card.percent !== undefined) return `${leading(possessive(name))} Margin is about ${Math.round(card.percent)}% of the way through “${title}”.`;
  return undefined;
}

/** What is sounding in the card's run. */
export type CardPhase = 'context' | 'voice' | 'written' | 'shown';

/** " · 1 of 3", or nothing when there is one Margin: "1 of 1" is never shown. */
function position(index: number, total: number): string {
  return total > 1 ? ` · ${index + 1} of ${total}` : '';
}

/** The status line while the card plays: who is speaking, and which of how many (the Design's 2b). */
export function statusLine(phase: CardPhase, card: CardMargin, index: number, total: number, words: Pick<KindWords, 'noun' | 'namedWords'>, sender: string | undefined): string {
  const name = cardName(card, sender);
  const at = position(index, total);
  switch (phase) {
    case 'context':
      return `${contextTitle(name, words)}${at}`;
    case 'voice':
      return `${leading(name)} is speaking${at}`;
    default:
      return `${leading(name)} wrote this${at}`;
  }
}

/** The pinned card's title while the voice reads the episode's words before a Margin (Now Playing, episode failed). */
export function contextTitle(name: string, words: Pick<KindWords, 'noun' | 'namedWords'>): string {
  return `${words.namedWords ? `The ${words.noun}’s words` : 'The words'} before ${possessive(name)} Margin`;
}

/** The line once a row's own "Hear this one" ends: "That was 2 of 3.", or the last-Margin line for a card of one. */
export function oneDoneLine(index: number, total: number, last: CardMargin, sender: string | undefined, iphoneStep: boolean): string {
  return total > 1 ? `That was ${index + 1} of ${total}.` : finishedLine(last, sender, iphoneStep);
}

/** The line once the run has played the last Margin, naming its sender, and how to answer when the app is the next step. */
export function finishedLine(last: CardMargin, sender: string | undefined, iphoneStep: boolean): string {
  const name = cardName(last, sender);
  const answer = iphoneStep ? ` To answer ${name}, add a Margin of your own in Spoken Margins on iPhone.` : '';
  return `That was ${possessive(name)} last Margin.${answer}`;
}

/** The line while the run waits on a clip the browser refused to start without a new tap. */
export const waitingLine = (who: string): string => `Tap Hear ${possessive(who)} Margins to go on.`;

/** The line before anything plays: how the run goes. */
export function hintLine(cards: readonly CardMargin[]): string {
  return cards.some((c) => c.context) ? 'Each Margin plays after the words just before it.' : 'They play one after another.';
}

/** In place of the list, when the packet holds no Margins at all. */
export const noMarginsLine = (origin: CardOrigin): string => `This ${origin} has no Margins in it. Ask your friend to share it again.`;

/** The line on a row whose clip couldn't load or decode in this browser. */
export const CLIP_FAILED = 'This Margin couldn’t play in this browser.';

/** The primary button's words: start, stop, or start again once all were heard. */
export function hearButton(who: string, state: 'ready' | 'playing' | 'finished'): string {
  if (state === 'playing') return 'Stop';
  if (state === 'finished') return 'Hear them again';
  return `Hear ${possessive(who)} Margins`;
}

/** The card's heading under the title. */
export const welcomeLine = (who: string): string => `Welcome. ${leading(who)} left these Margins for you.`;

/** The next step block's heading. */
export const NEXT_STEP_HEADING = 'Hear them in place';

/**
 * Whether the card offers the iPhone app. Not inside the Android app (the Capacitor bridge) or on an Android browser:
 * the iPhone app's join page turns them away, so the source link is their next step when there is one.
 */
export function showIphoneStep(insideAndroidApp: boolean, userAgent: string): boolean {
  return !insideAndroidApp && !/android/i.test(userAgent);
}

/** The steps the card's run plays: each Margin, with the line the voice says first. */
export function runSteps(cards: readonly CardMargin[], words: Pick<KindWords, 'noun' | 'namedWords'>, title: string, sender: string | undefined): { context?: string; margin: Margin }[] {
  return cards.map((card) => {
    const context = contextLine(card, words, title, sender);
    return { margin: card.margin, ...(context !== undefined && { context }) };
  });
}

/** The sender as the card names them: the packet's name, or "your friend". */
export const cardSender = (sender: string | undefined): string => senderName(sender);

/**
 * Whether an opened file shows the listen-here card instead of being stored (#5265): one packet opened on its own as a
 * file (not a backup, not one of several at once) whose Margins sit on a text the web app can't play. Every other file
 * keeps today's import, so a restore never stacks cards and an episode with no audio is stored as before.
 */
export function opensListenCard(read: Pick<PacketRead, 'episode' | 'margins' | 'percentMargins'>, arrival: Arrival, alone: boolean): boolean {
  if (arrival !== 'file' || !alone) return false;
  const verdict = playability(read);
  return verdict.verdict === 'cannot' && verdict.reason === 'article';
}

/** The noun for what a packet's Margins sit on: "article", "PDF", "book", "text", "episode", "recording". */
export function kindNoun(read: Pick<PacketRead, 'itemType' | 'episode' | 'margins'>): string {
  return NOUNS[itemKind(read)].noun;
}
