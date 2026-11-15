// Where a reply sits on the Margins screen, and the first line that says what it answers (#4174, Design 2026-11-13, PR 3).
// A reply is listed right after the Margin it answers, indented one step. The Margin it answers is found two ways: by id
// (a friend's imported Margin carries the id its packet gave it), or by `sharedAs` (the link a packet gave one of the
// listener's own Margins when she shared it, which is what a friend's reply to it carries). A reply that matches nothing
// stays at its own time and says so. Plain TypeScript with no DOM, covered by margin-threads.test.ts.
import type { Margin } from '../../shared/model.ts';
import { replyMarginName } from './reply-words.ts';
import { formatClock } from '../../shared/clock.ts';

/** What the reply's link led to. */
export type ThreadParent =
  | { readonly kind: 'mine'; readonly margin: Margin }
  | { readonly kind: 'friends'; readonly margin: Margin }
  | { readonly kind: 'lost' };

/** One row of a group: the Margin, how it sits, and, for a friend's reply, the line over it. */
export interface ThreadedRow {
  readonly margin: Margin;
  /** True when the row sits under the Margin it answers. */
  readonly indented: boolean;
  /** The first line of a friend's reply; undefined for the listener's own Margins (their line is `rowLine`'s) and for Margins that answer nothing. */
  readonly line: string | undefined;
}

/** The words for a Margin whose reply link matches nothing among the listener's Margins. */
export const LOST_PARENT_LINE = 'Reply to a Margin this browser can’t find';

/** The Margin `margin`'s `replyToId` leads to among `margins`, never `margin` itself: by id first, then by `sharedAs`. */
export function findParent(margin: Margin, margins: readonly Margin[]): ThreadParent | undefined {
  const link = margin.replyToId;
  if (link === undefined) return undefined;
  const others = margins.filter((m) => m !== margin && m.id !== margin.id);
  const byId = others.find((m) => m.id === link);
  if (byId) return byId.author === undefined ? { kind: 'mine', margin: byId } : { kind: 'friends', margin: byId };
  const shared = others.find((m) => m.sharedAs?.includes(link));
  if (shared) return { kind: 'mine', margin: shared };
  return { kind: 'lost' };
}

/** "Reply to your Margin at 12:34", "Reply to Sam’s Margin at 12:34", or the words for a link that leads nowhere. */
export function threadLine(parent: ThreadParent): string {
  if (parent.kind === 'lost') return LOST_PARENT_LINE;
  if (parent.kind === 'mine') return `Reply to your Margin at ${formatClock(parent.margin.atSeconds)}`;
  return replyMarginName(parent.margin);
}

const byTime = (a: Margin, b: Margin) => a.atSeconds - b.atSeconds || (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0);

/**
 * One episode's Margins in the order the Margins screen lists them: each Margin in time order, and after it the Margins
 * that answer it (each followed by its own), in their own time order. A Margin that answers nothing, or whose link leads
 * nowhere, stands at its own time. Links that loop back on themselves can't stack: the Margins in the loop are listed at
 * their own times, none lost. Every Margin appears exactly once.
 */
export function threadedRows(margins: readonly Margin[]): ThreadedRow[] {
  const sorted = [...margins].sort(byTime);
  const parents = new Map<Margin, ThreadParent>();
  const children = new Map<Margin, Margin[]>();
  for (const margin of sorted) {
    const parent = findParent(margin, sorted);
    if (!parent) continue;
    parents.set(margin, parent);
    if (parent.kind !== 'lost') children.set(parent.margin, [...(children.get(parent.margin) ?? []), margin]);
  }
  const rows: ThreadedRow[] = [];
  const placed = new Set<Margin>();
  const add = (margin: Margin, indented: boolean) => {
    placed.add(margin);
    const parent = parents.get(margin);
    rows.push({ margin, indented, line: margin.author !== undefined && parent ? threadLine(parent) : undefined });
  };
  const place = (margin: Margin, indented: boolean) => {
    if (placed.has(margin)) return;
    add(margin, indented);
    for (const reply of children.get(margin) ?? []) place(reply, true);
  };
  // Standing Margins first, in time order; they bring their replies with them.
  for (const margin of sorted) {
    const parent = parents.get(margin);
    if (!parent || parent.kind === 'lost') place(margin, false);
  }
  // Whatever is left answers another in a loop; list each at its own time, not indented, without its replies.
  for (const margin of sorted) {
    if (!placed.has(margin)) add(margin, false);
  }
  return rows;
}
