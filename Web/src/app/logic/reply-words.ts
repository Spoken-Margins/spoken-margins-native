// The words a listener reads when a Margin answers a friend's (#4107, B1; the iPhone app's MarginReplyWords.swift, #3890).
// Who is being answered, how a Margin with no words is named, and the two ends of the "stop replying" control.
// Plain TypeScript with no DOM, so `npm run test:web` covers it.
//
// What the web does differently from the app, on purpose (Design, 2026-11-13, default 3): a sender with no name is
// "your friend" here, as the web already says everywhere (`senderName`, `import.ts`), not the app's "a friend". The
// typography is the web's own: curly apostrophes and quotes and a one-character ellipsis.
import { graphemes, isVoicePlaceholder } from '../../shared/placeholder.ts';
import { formatClock } from '../../shared/clock.ts';

/** What a sender with no name is called mid-sentence on the web. */
export const UNNAMED_SENDER_WORDS = 'your friend';
export const STOP_REPLYING = 'Stop replying';
export const NOT_A_REPLY = 'Not a reply';

/** The longest excerpt of the answered Margin's words a caption quotes, in characters. */
export const EXCERPT_LIMIT = 90;

/** The labels that stand in for a missing name: stored by import, by older builds or by the app (folded, see `fold`). */
const STAND_INS = ['your friend', 'someone', 'unsigned sender', 'imported collection'].map((label) => fold(label));

/** Case, spacing and accents make no difference: "  SOMEONE ", "Unsigned  Sender", "Yoür friend". */
function fold(text: string): string {
  return text.normalize('NFD').replace(/\p{M}/gu, '').replace(/\s+/gu, ' ').trim().toLowerCase();
}

/** The sender's name as written, or undefined when the label stands in for a missing name: blank, "Your friend", "Someone", "Unsigned sender", "Imported collection". */
export function senderNameOrNone(label: string | undefined): string | undefined {
  const name = label?.trim();
  if (!name) return undefined;
  return STAND_INS.includes(fold(name)) ? undefined : name;
}

/** "Cole", or "your friend": for the middle of a line. */
export function replyName(label: string | undefined): string {
  return senderNameOrNone(label) ?? UNNAMED_SENDER_WORDS;
}

/** "Cole’s", or "your friend’s". */
export function replyPossessive(label: string | undefined): string {
  return `${replyName(label)}’s`;
}

/** The button that puts a stopped reply back: "Reply to Cole", "Reply to your friend". */
export function replyTo(label: string | undefined): string {
  return `Reply to ${replyName(label)}`;
}

/**
 * The words to quote on one line, or undefined when there are none worth quoting: blank, or the stand-in for a voice
 * Margin. Double quotes inside become single ones so the caption never nests them; cut at `EXCERPT_LIMIT` characters.
 */
export function excerpt(text: string): string | undefined {
  // Invisible format characters (zero-width space, BOM) count as nothing, like whitespace. The two joiners stay inside
  // the words, since a family emoji and several scripts are written with them, but words of only joiners are none.
  const visible = text.replace(/(?![\u200C\u200D])\p{Cf}/gu, '');
  const line = visible.split(/\s+/u).filter(Boolean).join(' ');
  if (!line.replace(/\p{Cf}/gu, '') || isVoicePlaceholder(line)) return undefined;
  const flattened = line.replace(/[“”"]/gu, (quote) => (quote === '“' ? '‘' : quote === '”' ? '’' : "'"));
  const characters = graphemes(flattened);
  if (characters.length <= EXCERPT_LIMIT) return flattened;
  return `${characters.slice(0, EXCERPT_LIMIT).join('').trimEnd()}…`;
}

/** " at 1:45", or nothing when the moment isn't known (a missing or negative time). */
function atClock(seconds: number | undefined): string {
  return seconds !== undefined && Number.isFinite(seconds) && seconds >= 0 ? ` at ${formatClock(seconds)}` : '';
}

/**
 * The line over a Margin being recorded or written that answers a friend's Margin whose words are `parentText`.
 * With words: `Replying to Cole: “first words…”`. With none (a voice Margin sent without a transcript, whose words are the
 * stand-in): `Replying to Cole’s Margin at 1:45`. Never the stand-in itself, and never a quote inside the quote.
 */
export function replyingCaption(senderLabel: string | undefined, parentText: string, parentSeconds: number | undefined): string {
  const quoted = excerpt(parentText);
  if (quoted === undefined) return `Replying to ${replyPossessive(senderLabel)} Margin${atClock(parentSeconds)}`;
  return `Replying to ${replyName(senderLabel)}: “${quoted}”`;
}

/** "Reply to Cole’s Margin at 1:45": a saved reply's line, and the spoken name of the Reply button on that Margin. */
export function replyMarginName(parent: { author?: string; atSeconds: number }): string {
  return `Reply to ${replyPossessive(parent.author)} Margin${atClock(parent.atSeconds)}`;
}

/**
 * The line on one of the listener's own Margins in a list, or undefined when it never was a reply. `parent` is the
 * Margin it answers, looked up by `replyToId ?? formerReplyToId`, and undefined when that Margin is no longer on the
 * episode.
 */
export function rowLine(
  own: { replyToId?: string; formerReplyToId?: string },
  parent: { author?: string; atSeconds: number } | undefined,
): string | undefined {
  if (own.replyToId === undefined && own.formerReplyToId === undefined) return undefined;
  if (own.replyToId === undefined) return NOT_A_REPLY;
  if (parent === undefined) return 'Reply to a Margin that isn’t here';
  return replyMarginName(parent);
}
