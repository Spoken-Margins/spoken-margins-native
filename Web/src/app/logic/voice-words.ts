// Which words a voice Margin keeps (#3025). Plain TypeScript, so `npm run test:web` covers it (voice-words.test.ts).
//
// The words box after a recording starts with the placeholder (src/shared/placeholder.ts). In order of precedence:
// 1. The listener's own typed words always win: a transcript never replaces them, it is offered beside them.
// 2. A transcript, when transcription is on and succeeds, replaces the placeholder.
// 3. Otherwise the placeholder stands. It isn't stored as the Margin's words; the packet writer writes the same
//    placeholder at export, so the Margin stays "no words yet" here and every older word-less Margin shares too.
//
// Stop saves the Margin at once (#3038); the words then update the saved Margin as they arrive or change.
import type { Margin } from '../../shared/model.ts';
import { prefill, type Prefill } from '../../transcribe/state.ts';

/** Whether the box holds the placeholder (or nothing), rather than words of the listener's or a transcript's. */
export function isPlaceholder(words: string, placeholder: string): boolean {
  const text = words.trim();
  return text === '' || text === placeholder.trim();
}

/** What the box holds once a transcript arrives. The placeholder counts as an empty, untouched box. */
export function prefillOverPlaceholder(words: string, edited: boolean, transcript: string, placeholder: string): Prefill {
  if (!isPlaceholder(words, placeholder)) return prefill(words, edited, transcript);
  const result = prefill('', false, transcript);
  return result.words ? result : { words };
}

/** The words to store with the Margin: undefined when the box holds only the placeholder or nothing. */
export function wordsToSave(words: string, placeholder: string): string | undefined {
  return isPlaceholder(words, placeholder) ? undefined : words.trim();
}

/**
 * The voice Margin that Stop saves straight away (#3038, owner 2026-10-31: "kind of discombobulating to need to stop
 * the margin and then save it"). It has no words of its own yet, so until a transcript or the listener's words
 * arrive it shares with the placeholder. `createdAt` is when the recording stopped, the day the placeholder names.
 */
export function voiceMarginOnStop(fields: {
  id: string;
  episodeId: string;
  atSeconds: number;
  recordedAt: Date;
  voice: NonNullable<Margin['voice']>;
}): Margin {
  return { id: fields.id, episodeId: fields.episodeId, atSeconds: fields.atSeconds, createdAt: fields.recordedAt.toISOString(), voice: fields.voice };
}

/**
 * The saved Margin carrying the box's words, or undefined when they change nothing, so nothing is written. Going
 * back to the placeholder, or to an empty box, takes the words off again.
 */
export function withWords(margin: Margin, words: string, placeholder: string): Margin | undefined {
  const text = wordsToSave(words, placeholder);
  if (text === margin.text) return undefined;
  if (text === undefined) {
    const { text: _dropped, ...rest } = margin;
    return rest;
  }
  return { ...margin, text };
}
