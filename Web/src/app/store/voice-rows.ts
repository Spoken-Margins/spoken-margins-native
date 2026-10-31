// How a voice Margin's audio sits in IndexedDB (#3043). Safari's private browsing, and Playwright's ephemeral
// WebKit, refuse to store a Blob in IndexedDB: the write aborts, and no voice Margin could be kept. Plain bytes
// store everywhere, so a stored row holds the audio as an ArrayBuffer and the app rebuilds the Blob on read.
// Plain TypeScript, so `npm run test:web` covers it (voice-rows.test.ts).
import type { Margin } from '../../shared/model.ts';

/** A Margin as stored: a voice Margin's audio is bytes (`data`), not a Blob. Rows saved before #3043 hold `blob`. */
export type MarginRow = Omit<Margin, 'voice'> & {
  voice?: { data?: ArrayBuffer; blob?: Blob; mimeType: string; durationSeconds: number };
};

/** The row to store for a Margin: the same fields, with the voice's Blob read out into bytes. */
export async function toRow(margin: Margin): Promise<MarginRow> {
  if (!margin.voice) return margin as MarginRow;
  const { blob, mimeType, durationSeconds } = margin.voice;
  return { ...margin, voice: { data: await blob.arrayBuffer(), mimeType, durationSeconds } };
}

/**
 * The Margin a stored row stands for. A row from before #3043 already holds a Blob and passes through; a row with
 * bytes gets its Blob back. A voice row with neither is returned as it is, never dropped: it may be a newer
 * copy's shape, and the Margins tab still lists it.
 */
export function fromRow(row: MarginRow): Margin {
  const voice = row.voice;
  if (!voice || voice.blob instanceof Blob || !(voice.data instanceof ArrayBuffer)) return row as unknown as Margin;
  const { data, mimeType, durationSeconds } = voice;
  return { ...row, voice: { blob: new Blob([data], { type: mimeType }), mimeType, durationSeconds } };
}
