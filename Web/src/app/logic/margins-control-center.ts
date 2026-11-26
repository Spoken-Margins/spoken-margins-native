// The Margins tab and the arrival preview (part of #3216): the web port of SessionKit's `MarginsControlCenter` and
// `NextMarginSkip` (Packages/SessionKit/Sources/SessionKit/MarginsControlCenter.swift). Both sides run the same cases,
// Contracts/fixtures/margins-control-center/cases.json, so the list, Next Margin and the arrival buttons follow one set of
// rules. Plain TypeScript with no DOM: margins-control-center.test.ts runs every case under `npm run test:web`.
//
// The constants and labels come from the cases file itself, so the words the screens show are the words SessionKit
// checks; nothing here retypes them. The build puts only those two parts of the file into the app
// (`__MARGINS_CONTROL_CENTER_WORDS__`, vite.config.ts), not its 100 KB of cases; the tests, which run without the
// build, hand the same two parts over on `globalThis.marginsControlCenterWords` before importing this module.
import type { Margin } from '../../shared/model.ts';
import { graphemes, isVoicePlaceholder } from '../../shared/placeholder.ts';
import { findParent } from './margin-threads.ts';

/** The cases file's `constants` and `labels` (Contracts/schemas/margins-control-center-cases.schema.json). */
export interface ControlCenterWords {
  constants: { leadInMs: number; startFromBeginningMs: number; leadInExcerptCharacters: number; missingParentNote: string; ownSender: string };
  labels: {
    rowStart: { arrival: string; playback: string };
    startWithUnheard: string;
    startFromBeginning: string;
    autoplayMenuTitle: string;
    autoplay: { unheard: string; all: string; none: string };
  };
}

declare const __MARGINS_CONTROL_CENTER_WORDS__: ControlCenterWords | undefined;
const WORDS: ControlCenterWords | undefined =
  typeof __MARGINS_CONTROL_CENTER_WORDS__ === 'undefined'
    ? (globalThis as { marginsControlCenterWords?: ControlCenterWords }).marginsControlCenterWords
    : __MARGINS_CONTROL_CENTER_WORDS__;
if (!WORDS) throw new Error('The Margins control center words were not built in (vite.config.ts) or handed over (globalThis.marginsControlCenterWords).');

export const CONSTANTS = Object.freeze(WORDS.constants);
export const LABELS = Object.freeze(WORDS.labels);

/** The lead-in before a Margin that a row's start control and Next Margin go to (owner, 2026-11-17: 20 s). */
export const LEAD_IN_MS = CONSTANTS.leadInMs;

export type Autoplay = 'unheard' | 'all' | 'none';
export const AUTOPLAY_CHOICES: readonly Autoplay[] = ['unheard', 'all', 'none'];
export const autoplayTitle = (autoplay: Autoplay): string => LABELS.autoplay[autoplay];
export const isAutoplay = (value: unknown): value is Autoplay => value === 'unheard' || value === 'all' || value === 'none';

export type Hearing = 'yours' | 'heard' | 'unheard';

/** One Margin as the rules see it: language-neutral, the shape the cases file gives. */
export interface CenterMargin {
  readonly id: string;
  /** Your own Margin, or a friend's (by name). */
  readonly own: boolean;
  readonly sender: string;
  /** The Margin this one answers: an id here, an id that isn't here (parent missing), or none. */
  readonly parentId: string | null;
  /** Where it sits in the listener's copy; null when it couldn't be placed. */
  readonly timeMs: number | null;
  /** The listener has listened to some of this friend's Margin. Ignored for your own. */
  readonly heard: boolean;
  readonly words: string | null;
  /** Starred to share. Ignored for a friend's. */
  readonly starred: boolean;
  readonly sourceTextBefore: string | null;
}

export interface Row {
  readonly id: string;
  readonly depth: number;
  readonly sender: string;
  readonly hearing: Hearing;
  /** The words to show; null while they are still to come (blank or placeholder words). */
  readonly words: string | null;
  readonly leadIn: string | null;
  readonly timeMs: number | null;
  /** Where the row's start control goes: the lead-in before the Margin, never before 0. */
  readonly startHereMs: number | null;
  readonly starred: boolean;
  readonly note: string | null;
  /** The id of the Margin this row answers when it is here, for "to Sam" on a deeper reply. */
  readonly parentId: string | null;
}

export const wordsComing = (row: Row): boolean => row.words === null;

/** The words to show: the Margin's own, trimmed, or null for blank or placeholder words. */
export function words(raw: string | null | undefined): string | null {
  const text = (raw ?? '').trim();
  if (text === '' || isVoicePlaceholder(text)) return null;
  return text;
}

/**
 * The last few words of the source text before a Margin, cut at a whole word and opened with "…" when cut. Whitespace is
 * collapsed to single spaces; characters are counted as a person sees them, as Swift counts a String.
 */
export function leadInExcerpt(prefix: string | null | undefined, maxCharacters: number = CONSTANTS.leadInExcerptCharacters): string | null {
  const collapsed = (prefix ?? '').split(/\s+/u).filter(Boolean).join(' ');
  if (collapsed === '') return null;
  const parts = graphemes(collapsed);
  if (parts.length <= maxCharacters) return collapsed;
  const tail = parts.slice(parts.length - maxCharacters).join('');
  const space = tail.indexOf(' ');
  const trimmed = space === -1 ? tail : tail.slice(space + 1);
  return `…${trimmed === '' ? tail : trimmed}`;
}

/**
 * Every Margin of the item in thread order (MarginThreadPresentation.rows): threads by the time of their first Margin,
 * unplaced last, ties in the order they were made (`margins` is oldest first); replies under the Margin they answer, in
 * the order they were made. A reply whose parent isn't here starts its own thread and says so. A loop of replies with no
 * root still lists every Margin once.
 */
export function rows(margins: readonly CenterMargin[]): Row[] {
  const order = new Map(margins.map((m, i) => [m.id, i]));
  const byId = new Map(margins.map((m) => [m.id, m]));
  const children = new Map<string, CenterMargin[]>();
  const roots: CenterMargin[] = [];
  const orphans = new Set<string>();
  for (const margin of margins) {
    if (margin.parentId === null) roots.push(margin);
    else if (byId.has(margin.parentId) && margin.parentId !== margin.id) children.set(margin.parentId, [...(children.get(margin.parentId) ?? []), margin]);
    else {
      roots.push(margin);
      orphans.add(margin.id);
    }
  }
  const created = (a: CenterMargin, b: CenterMargin) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0);
  const before = (a: CenterMargin, b: CenterMargin) => {
    if (a.timeMs !== null && b.timeMs !== null && a.timeMs !== b.timeMs) return a.timeMs - b.timeMs;
    if (a.timeMs !== null && b.timeMs === null) return -1;
    if (a.timeMs === null && b.timeMs !== null) return 1;
    return created(a, b);
  };
  const out: Row[] = [];
  const visited = new Set<string>();
  const walk = (margin: CenterMargin, depth: number) => {
    if (visited.has(margin.id)) return;
    visited.add(margin.id);
    const hearing: Hearing = margin.own ? 'yours' : margin.heard ? 'heard' : 'unheard';
    out.push({
      id: margin.id,
      depth,
      sender: margin.own ? CONSTANTS.ownSender : margin.sender,
      hearing,
      words: words(margin.words),
      leadIn: leadInExcerpt(margin.sourceTextBefore),
      timeMs: margin.timeMs,
      startHereMs: margin.timeMs === null ? null : Math.max(0, margin.timeMs - LEAD_IN_MS),
      starred: margin.own && margin.starred,
      note: orphans.has(margin.id) ? CONSTANTS.missingParentNote : null,
      parentId: depth > 0 ? margin.parentId : null,
    });
    for (const child of [...(children.get(margin.id) ?? [])].sort(created)) walk(child, depth + 1);
  };
  for (const root of [...roots].sort(before)) walk(root, 0);
  for (const margin of [...margins].sort(before)) walk(margin, 0);
  return out;
}

/** What reaching a Margin does: it plays by itself, or a tone marks it and the episode plays on. */
export type Arrival = 'plays' | 'tone';

/** With Unheard, only a friend's Margin the listener hasn't heard plays; All plays every Margin; Off plays a tone for each. */
export function arrival(row: Pick<Row, 'hearing'>, autoplay: Autoplay): Arrival {
  if (autoplay === 'all') return 'plays';
  if (autoplay === 'none') return 'tone';
  return row.hearing === 'unheard' ? 'plays' : 'tone';
}

/** The threads in `rows` (a row at depth 0 and every row under it), in list order. */
export function threads(list: readonly Row[]): Row[][] {
  const out: Row[][] = [];
  for (const row of list) {
    if (row.depth === 0 || out.length === 0) out.push([row]);
    else out[out.length - 1].push(row);
  }
  return out;
}

/** The Margin that plays first when playback lands on `thread`: its first unheard friend's Margin unless Autoplay is All, else its first. */
export function firstToPlay(thread: readonly Row[], autoplay: Autoplay): Row | undefined {
  if (autoplay !== 'all') {
    const unheard = thread.find((r) => r.hearing === 'unheard');
    if (unheard) return unheard;
  }
  return thread[0];
}

export const unheardCount = (list: readonly Row[]): number => list.filter((r) => r.hearing === 'unheard').length;

/** An item with a friend's Margin the listener hasn't heard opens on the Margins tab, not Now (owner, 2026-11-17). */
export const opensOnMarginsTab = (list: readonly Row[]): boolean => unheardCount(list) > 0;

/** Where "Start with unheard Margins" begins: the lead-in of the first thread holding an unheard friend's Margin. Null when all are heard. */
export function startWithUnheardMs(list: readonly Row[]): number | null {
  let root: Row | undefined;
  for (const row of list) {
    if (row.depth === 0) root = row;
    if (row.hearing === 'unheard') return (root ?? row).startHereMs;
  }
  return null;
}

/** The pill's `m:ss` countdown, rounded up so it never promises an early arrival; minutes keep counting past an hour. */
export function countdown(ms: number): string {
  const seconds = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

export interface NextMargin {
  /** The thread's first Margin, which the lead-in and countdown are measured to. */
  readonly marginTimeMs: number;
  readonly leadInStartMs: number;
  readonly msUntilMargin: number;
  /** Before the lead-in: seek forward to it. Inside it: go straight into the Margin. */
  readonly action: 'seekToLeadIn' | 'playMargin';
  /** Where the press puts the playhead. Never behind it. */
  readonly destinationMs: number;
  readonly countdown: string;
  /** The Margin that plays first in the thread the press lands on. */
  readonly firstToPlayId: string;
  /** The thread the press lands on. */
  readonly thread: readonly Row[];
}

/**
 * Next Margin (NextMarginSkip.next): it stops only at a thread's first Margin, never at a reply. Under Unheard it goes to
 * the next thread holding an unheard friend's Margin, or the next thread when none is ahead. It only ever moves forward,
 * and never past that Margin. Nothing here moves the player.
 */
export function nextMargin(playheadMs: number, list: readonly Row[], autoplay: Autoplay, leadInMs: number = LEAD_IN_MS): NextMargin | null {
  const ahead = threads(list).filter((t) => t[0]?.timeMs !== null && t[0].timeMs >= 0 && t[0].timeMs > playheadMs);
  const preferred = autoplay === 'unheard' ? ahead.find((t) => t.some((r) => r.hearing === 'unheard')) : undefined;
  const thread = preferred ?? ahead[0];
  const target = thread?.[0]?.timeMs;
  if (!thread || target === null || target === undefined) return null;
  const leadInStartMs = Math.max(0, target - leadInMs);
  const action = playheadMs >= leadInStartMs ? 'playMargin' : 'seekToLeadIn';
  const msUntilMargin = target - playheadMs;
  return {
    marginTimeMs: target,
    leadInStartMs,
    msUntilMargin,
    action,
    destinationMs: action === 'playMargin' ? target : leadInStartMs,
    countdown: countdown(msUntilMargin),
    firstToPlayId: firstToPlay(thread, autoplay)?.id ?? '',
    thread,
  };
}

/**
 * The Margins to play, in order, when the listener starts at `chosen` in its thread (a row's start control, or Next
 * Margin's first-to-play): the chosen one, then the rest of the thread after it that Autoplay would play. The chosen one
 * always plays: the listener asked for it.
 */
export function playQueue(list: readonly Row[], chosenId: string, autoplay: Autoplay): string[] {
  const thread = threadOf(list, chosenId) ?? [];
  const at = thread.findIndex((r) => r.id === chosenId);
  if (at === -1) return [];
  return [chosenId, ...thread.slice(at + 1).filter((r) => arrival(r, autoplay) === 'plays').map((r) => r.id)];
}

/** The thread holding `id`. */
export const threadOf = (list: readonly Row[], id: string): Row[] | undefined => threads(list).find((t) => t.some((r) => r.id === id));

// ---------- The web's Margins in the rules' shape ----------

/** The listener's own Margin has no author. */
const ownMargin = (margin: Margin) => margin.author === undefined || margin.author === '';
const createdTime = (margin: Margin) => {
  const t = Date.parse(margin.createdAt);
  return Number.isNaN(t) ? 0 : t;
};

/**
 * One episode's Margins (`margins`) as the rules take them, oldest first. A reply's link is followed the way the Margins
 * screen follows it (findParent: by id, then by `sharedAs`); a link that leads nowhere is a parent missing from this
 * browser. A web Margin always has a time.
 */
export function centerMargins(margins: readonly Margin[]): CenterMargin[] {
  return [...margins]
    .map((margin, index) => ({ margin, index }))
    .sort((a, b) => createdTime(a.margin) - createdTime(b.margin) || a.index - b.index)
    .map(({ margin }) => {
      const parent = findParent(margin, margins);
      const parentId = parent === undefined ? null : parent.kind === 'lost' ? `missing:${margin.replyToId ?? ''}` : parent.margin.id;
      return {
        id: margin.id,
        own: ownMargin(margin),
        sender: margin.author ?? CONSTANTS.ownSender,
        parentId,
        timeMs: Number.isFinite(margin.atSeconds) ? Math.max(0, Math.round(margin.atSeconds * 1000)) : null,
        heard: margin.heard === true,
        words: margin.text ?? null,
        starred: margin.starred === true,
        sourceTextBefore: margin.leadIn ?? null,
      };
    });
}

/** How the rules see one web Margin: your own, or a friend's heard or not. */
export const hearingOf = (margin: Margin): Hearing => (ownMargin(margin) ? 'yours' : margin.heard === true ? 'heard' : 'unheard');

/** How far past a started Margin's moment playback may be and still play it: one time update's worth (margin-autoplay.ts). */
export const PENDING_GRACE_SECONDS = 3;

/**
 * A start the listener tapped (a row's start control, Next Margin, an arrival button) waits for playback to reach the
 * Margin's moment, then plays. It is dropped when playback is already well past it: the listener moved on, and the
 * player never plays a Margin they left behind.
 */
export function pendingStart(atSeconds: number, time: number): 'wait' | 'play' | 'drop' {
  if (time < atSeconds - 0.05) return 'wait';
  return time <= atSeconds + PENDING_GRACE_SECONDS ? 'play' : 'drop';
}

/** How far from a start's own landing a seek may report and still be that landing (a browser rounds currentTime). */
export const START_LANDING_SLACK_SECONDS = 0.5;

/**
 * Whether a start the listener tapped, which moved to `seekTo`, still stands after a seek that landed at `landedAt`. Only
 * its own seek keeps it: a scrub away leaves the tap behind, so its Margins never play minutes later against Autoplay.
 */
export function startSurvivesSeek(seekTo: number, landedAt: number): boolean {
  return Math.abs(landedAt - seekTo) <= START_LANDING_SLACK_SECONDS;
}

/**
 * Where a start control goes and what it plays: a row's own lead-in, or straight into the Margin when the playhead is
 * already inside that lead-in (never backwards inside it). `queue` is what plays when playback reaches it.
 */
export function startFor(row: Row, list: readonly Row[], autoplay: Autoplay, playheadMs: number): { seekToMs: number; atMs: number; queue: string[] } | null {
  if (row.timeMs === null || row.startHereMs === null) return null;
  const inside = playheadMs >= row.startHereMs && playheadMs < row.timeMs;
  return { seekToMs: inside ? row.timeMs : row.startHereMs, atMs: row.timeMs, queue: playQueue(list, row.id, autoplay) };
}

/** The Margins tab's rows for one episode's Margins. */
export const marginRows = (margins: readonly Margin[]): Row[] => rows(centerMargins(margins));
