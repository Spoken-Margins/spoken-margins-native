// Whether the Margin being recorded or written answers a friend's, and the words that say so (#4107, B4; the iPhone
// app's reply composer, #473). The player's reply memory (reply-memory.ts) suggests the friend's Margin when the listener
// begins one; this is what the composer does with it: it names whom the Margin answers, lets the listener make it
// independent and back, and says what id goes on the saved Margin. Plain TypeScript with no DOM, so `npm run test:web`
// covers it.
import type { Margin } from '../../shared/model.ts';
import { replyingCaption, replyTo, STOP_REPLYING, NOT_A_REPLY } from './reply-words.ts';

/** The friend's Margin a new Margin was begun against, and whether the listener still means it as an answer. */
export interface ReplyChoice {
  readonly parent: Margin;
  readonly replying: boolean;
}

/** A composer begun against `parent` starts as a reply; with no parent there is no choice to make and no row. */
export function choiceFor(parent: Margin | undefined): ReplyChoice | undefined {
  return parent ? { parent, replying: true } : undefined;
}

/** The × and "Reply to Cole" are one control. Each tap flips it, so a double tap ends where it began and the words show the result. */
export function toggleReplying(choice: ReplyChoice | undefined): ReplyChoice | undefined {
  return choice ? { parent: choice.parent, replying: !choice.replying } : undefined;
}

/**
 * The Margin with its reply link set from the composer's choice, nothing else changed: answering puts the friend's id on
 * `replyToId`; "Stop replying" keeps it on `formerReplyToId` so "Reply to Cole" can put it back; no choice carries neither.
 * Only `replyToId` is ever written to a packet.
 */
export function withReplyChoice(margin: Margin, choice: ReplyChoice | undefined): Margin {
  const { replyToId: _answers, formerReplyToId: _answered, ...rest } = margin;
  if (!choice) return rest;
  return choice.replying ? { ...rest, replyToId: choice.parent.id } : { ...rest, formerReplyToId: choice.parent.id };
}

/** Whether the Margin already carries the link `withReplyChoice` would give it, so a write that changes nothing is skipped. */
export function hasReplyChoice(margin: Margin, choice: ReplyChoice | undefined): boolean {
  const wanted = withReplyChoice(margin, choice);
  return wanted.replyToId === margin.replyToId && wanted.formerReplyToId === margin.formerReplyToId;
}

/** A saved reply, made independent: the link moves to `formerReplyToId`. A Margin that answers nothing is returned as it is. */
export function stopReplying(margin: Margin): Margin {
  if (margin.replyToId === undefined) return margin;
  const { replyToId, ...rest } = margin;
  return { ...rest, formerReplyToId: replyToId };
}

/** "Reply to Cole" on a stopped reply: the link moves back to `replyToId`. A Margin with no former link is returned as it is. */
export function resumeReplying(margin: Margin): Margin {
  if (margin.formerReplyToId === undefined) return margin;
  const { formerReplyToId, ...rest } = margin;
  return { ...rest, replyToId: formerReplyToId };
}

/** The Margin an own Margin answers, or answered before "Stop replying", found among `margins`; undefined when it isn't there. */
export function parentOf(margin: Margin, margins: readonly Margin[]): Margin | undefined {
  const id = margin.replyToId ?? margin.formerReplyToId;
  return id === undefined ? undefined : margins.find((m) => m.id === id);
}

/** The row at the top of a composer: while replying, the caption and the × (`stop`); after ×, "Not a reply" and the button that puts it back (`resume`). */
export type ReplyRow =
  | { readonly replying: true; readonly caption: string; readonly stop: string }
  | { readonly replying: false; readonly line: string; readonly resume: string };

export function replyRow(choice: ReplyChoice): ReplyRow {
  const { parent } = choice;
  if (choice.replying) {
    return { replying: true, caption: replyingCaption(parent.author, parent.text ?? '', parent.atSeconds), stop: STOP_REPLYING };
  }
  return { replying: false, line: NOT_A_REPLY, resume: replyTo(parent.author) };
}
