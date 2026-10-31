// Audio and text helpers for transcription, in plain TypeScript so `npm run test:web` checks them
// (segments.test.ts). The browser decodes the recording; these turn it into what the model takes and turn the
// model's pieces back into one line of words.

/** One mono track from any number of channels, by averaging. */
export function mixToMono(channels: readonly Float32Array[]): Float32Array {
  if (channels.length === 0) return new Float32Array(0);
  if (channels.length === 1) return channels[0] as Float32Array;
  const length = Math.min(...channels.map((c) => c.length));
  const mono = new Float32Array(length);
  for (const channel of channels) {
    for (let i = 0; i < length; i += 1) mono[i] = (mono[i] as number) + (channel[i] as number) / channels.length;
  }
  return mono;
}

/** The loudest sample's size, 0 to 1. */
export function peak(samples: Float32Array): number {
  let max = 0;
  for (const s of samples) {
    const a = Math.abs(s);
    if (a > max) max = a;
  }
  return max;
}

/** Below this peak a recording is treated as silence and not given to the model, which would invent words. */
export const SILENCE_PEAK = 0.01;

const FRAME_SECONDS = 0.1;

function frameEnergy(samples: Float32Array, from: number, length: number): number {
  let sum = 0;
  const end = Math.min(samples.length, from + length);
  for (let i = from; i < end; i += 1) sum += (samples[i] as number) * (samples[i] as number);
  return sum / Math.max(1, end - from);
}

/**
 * Splits a recording into pieces no longer than `maxSeconds`, cutting at the quietest tenth of a second in the
 * last 40% of each piece, so a cut falls between words rather than through one. A recording that fits is
 * returned whole. Pieces are views on the same samples, not copies.
 */
export function splitAtQuiet(samples: Float32Array, sampleRate: number, maxSeconds: number): Float32Array[] {
  const max = Math.floor(maxSeconds * sampleRate);
  if (max <= 0) throw new RangeError('maxSeconds must be positive');
  const frame = Math.max(1, Math.round(FRAME_SECONDS * sampleRate));
  const pieces: Float32Array[] = [];
  let start = 0;
  while (samples.length - start > max) {
    const searchFrom = start + Math.floor(max * 0.6);
    const searchTo = start + max - frame;
    let cut = start + max;
    let quietest = Number.POSITIVE_INFINITY;
    for (let at = searchFrom; at <= searchTo; at += frame) {
      const energy = frameEnergy(samples, at, frame);
      if (energy < quietest) {
        quietest = energy;
        cut = at + Math.floor(frame / 2);
      }
    }
    pieces.push(samples.subarray(start, cut));
    start = cut;
  }
  if (samples.length > start || pieces.length === 0) pieces.push(samples.subarray(start));
  return pieces;
}

/**
 * The words in what a model wrote, or '' when there are none: sound labels such as "[BLANK_AUDIO]",
 * "[Music]" or "(beeping)" are dropped, spaces are tidied, and a result with no letter or digit left is empty.
 */
export function cleanTranscript(text: string): string {
  const words = text
    .replace(/\[[^\]]*\]/g, ' ')
    .replace(/\((?:[^)]*)\)/g, (match) => (/^\((?:music|applause|laughter|laughs|beep|beeping|silence|noise|inaudible|blank_audio|static|tone|sighs|coughs|bell|ringing|buzzing|whistling)[^)]*\)$/i.test(match) ? ' ' : match))
    .replace(/\s+/g, ' ')
    .trim();
  return /[\p{L}\p{N}]/u.test(words) ? words : '';
}

/** Joins the words of consecutive pieces into one line. */
export function joinSegmentTexts(texts: readonly string[]): string {
  return cleanTranscript(texts.map((t) => cleanTranscript(t)).filter(Boolean).join(' '));
}
