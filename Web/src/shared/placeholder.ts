// Placeholder words for a voice Margin the listener left without words (#3025). Every iPhone packet reader back to
// Build 29 rejects a Margin whose transcript is empty (SharedMarginTextRequirement.swift, #304), and on-device
// transcription is opt-in, so a word-less voice Margin travels with these instead: what it is, where, and when.
// Owner, 2026-10-30: "can it just be the title of the item they're listening to and the timestamp and the date?"
//
// The words say plainly that they are a stand-in ("Voice Margin at …"), so a friend never reads them as the
// sender's own. They go in the existing transcript field; the packet gains no key.

import { formatClock } from './clock.ts';

/** The longest item title the placeholder quotes, in user-perceived characters, ellipsis included. */
export const PLACEHOLDER_TITLE_CHARACTERS = 80;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function graphemes(text: string): string[] {
  if (typeof Intl !== 'undefined' && 'Segmenter' in Intl) {
    return [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)].map((s) => s.segment);
  }
  return Array.from(text);
}

/** The title on one line, cut at a whole character with "…" when it is longer than `max`. */
export function placeholderTitle(title: string | undefined, max = PLACEHOLDER_TITLE_CHARACTERS): string {
  const line = (title ?? '').normalize('NFC').replace(/\s+/gu, ' ').trim();
  const parts = graphemes(line);
  if (parts.length <= max) return line;
  return `${parts.slice(0, max - 1).join('').trimEnd()}…`;
}

/** "30 Oct 2026": day, English month abbreviation, year, in the listener's own calendar day. No numeric order to misread. */
export function placeholderDate(date: Date): string {
  return `${date.getDate()} ${MONTHS[date.getMonth()]} ${date.getFullYear()}`;
}

/**
 * `Voice Margin at 12:34 in “Title”, recorded 30 Oct 2026`. Without a title the "in" part is left out; with an
 * unreadable date, the "recorded" part.
 */
export function voicePlaceholder(margin: { atSeconds: number; title?: string; recordedAt: Date }): string {
  const title = placeholderTitle(margin.title);
  const when = Number.isNaN(margin.recordedAt.getTime()) ? '' : `, recorded ${placeholderDate(margin.recordedAt)}`;
  return `Voice Margin at ${formatClock(margin.atSeconds)}${title ? ` in “${title}”` : ''}${when}`;
}
