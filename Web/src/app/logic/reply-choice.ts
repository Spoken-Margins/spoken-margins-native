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

/** The id that goes on the saved Margin as `replyToId`: the friend's Margin while replying, nothing once made independent. */
export function replyIdFor(choice: ReplyChoice | undefined): string | undefined {
  return choice?.replying ? choice.parent.id : undefined;
}

/** The × and "Reply to Cole" are one control. Each tap flips it, so a double tap ends where it began and the words show the result. */
export function toggleReplying(choice: ReplyChoice | undefined): ReplyChoice | undefined {
  return choice ? { parent: choice.parent, replying: !choice.replying } : undefined;
}

/** The Margin with `replyToId` set to `id`, or taken off when there is none. Nothing else on it changes. */
export function withReplyId(margin: Margin, id: string | undefined): Margin {
  const { replyToId: _dropped, ...rest } = margin;
  return id === undefined ? rest : { ...rest, replyToId: id };
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
