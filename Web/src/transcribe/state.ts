// What the voice Margin composer shows about transcription, and when the model may be downloaded. Plain
// TypeScript with no browser, so `npm run test:web` checks every rule (state.test.ts).
//
// The rules:
// 1. Opt-in. Nothing downloads until the listener turns transcription on in Settings, or taps "Write out my
//    words" after a recording. Until they have answered once, the composer offers it, with the size.
// 2. Prefill, not replace. The transcript fills the words box only while the listener hasn't typed in it. If they
//    have, it is offered beside the box instead, and their words stay.
// 3. Failure changes nothing. If the model can't load or run, the words box works as it always has, and the composer
//    says so in a plain line (the recording is kept) rather than leaving a spinner or nothing at all (#4169).
// 4. Nothing spins forever. A load or a run that makes no progress for long enough is called stuck (`watch`).

/** The listener's answer: '' before they have been asked, then 'on' or 'off'. */
export type TranscriptionSetting = '' | 'on' | 'off';

export type Phase =
  /** Off or declined: the composer is the plain words box. */
  | { kind: 'off' }
  /** Turned on, but this browser can't run the model: the plain words box, with a line saying why. */
  | { kind: 'unsupported' }
  /** Never asked: the composer offers to write out the words, naming the download size. */
  | { kind: 'offer' }
  /** The model is loading; `total` is 0 until the size is known, and `loaded` is bytes so far. */
  | { kind: 'loading'; loaded: number; total: number }
  /** `done` of `total` segments are written out, once the first is. */
  | { kind: 'transcribing'; done?: number; total?: number }
  /** Done. `text` is '' when no words were heard. */
  | { kind: 'done'; text: string }
  | { kind: 'failed'; message: string };

export type PhaseEvent =
  | { type: 'accept' }
  | { type: 'decline' }
  | { type: 'progress'; loaded: number; total: number }
  | { type: 'loaded' }
  | { type: 'segment'; done: number; total: number }
  | { type: 'result'; text: string }
  | { type: 'error'; message: string };

/** What the composer shows the moment a recording stops. */
export function initialPhase(setting: TranscriptionSetting, supported: boolean): Phase {
  if (setting === 'off') return { kind: 'off' };
  // Said yes earlier, but this browser can't do it now: say so. Never asked: stay quiet, nothing was promised.
  if (!supported) return setting === 'on' ? { kind: 'unsupported' } : { kind: 'off' };
  if (setting === 'on') return { kind: 'loading', loaded: 0, total: 0 };
  return { kind: 'offer' };
}

/** Whether the model may be fetched or run in this phase. Only after the listener said yes. */
export function mayRun(phase: Phase): boolean {
  return phase.kind === 'loading' || phase.kind === 'transcribing';
}

export function nextPhase(phase: Phase, event: PhaseEvent): Phase {
  switch (event.type) {
    case 'accept':
      return phase.kind === 'offer' || phase.kind === 'failed' ? { kind: 'loading', loaded: 0, total: 0 } : phase;
    case 'decline':
      return phase.kind === 'offer' ? { kind: 'off' } : phase;
    case 'progress':
      return phase.kind === 'loading' ? { kind: 'loading', loaded: event.loaded, total: event.total } : phase;
    case 'loaded':
      return phase.kind === 'loading' ? { kind: 'transcribing' } : phase;
    case 'segment':
      return phase.kind === 'transcribing' ? { kind: 'transcribing', done: event.done, total: event.total } : phase;
    case 'result':
      return mayRun(phase) ? { kind: 'done', text: event.text } : phase;
    case 'error':
      return mayRun(phase) ? { kind: 'failed', message: event.message } : phase;
  }
}

/** The setting a composer answer stores: yes turns transcription on for every later Margin, no turns it off. */
export function settingAfter(event: PhaseEvent, setting: TranscriptionSetting): TranscriptionSetting {
  if (event.type === 'accept') return 'on';
  if (event.type === 'decline') return 'off';
  return setting;
}

export interface Prefill {
  /** What the words box holds after the transcript arrives. */
  words: string;
  /** The transcript, offered beside the box, when it didn't go in because the listener had typed. */
  suggestion?: string;
}

/**
 * Puts a transcript in the words box, unless the listener has typed there since the recording stopped: then their
 * words stay and the transcript is offered. An empty transcript changes nothing.
 */
export function prefill(words: string, edited: boolean, transcript: string): Prefill {
  const text = transcript.trim();
  if (!text) return { words };
  if (!edited || words.trim() === '') return { words: text };
  if (words.trim() === text) return { words };
  return { words, suggestion: text };
}

/** "Downloading the speech model, 12 of 32 MB", or the plain line before the size is known. */
export function loadingLine(phase: Phase, sizeLabel: string): string {
  if (phase.kind !== 'loading') return '';
  if (phase.total <= 0 || phase.loaded <= 0) return `Getting the speech model ready (${sizeLabel} the first time)…`;
  const mb = (bytes: number) => Math.round(bytes / 1_000_000);
  if (phase.loaded >= phase.total) return 'Getting the speech model ready…';
  return `Downloading the speech model, ${mb(phase.loaded)} of ${mb(phase.total)} MB…`;
}

/** How long a load or a run may make no progress before the composer says it is taking a while. */
export const SLOW_AFTER_MS = 20_000;
/** Then how long before it is called stuck. A load reports download progress, so quiet for two minutes is stuck. */
export const LOAD_GIVES_UP_MS = 120_000;
/** A run reports each segment (about 20 s of speech) as it ends, so quiet for two minutes is stuck however long the Margin. */
export const RUN_GIVES_UP_MS = 120_000;

export const STUCK_MESSAGE = 'It took too long, so it was stopped.';

export type Watch = 'working' | 'slow' | 'stuck';

/** What to tell the listener about a phase that has made no progress for `quietMs`. */
export function watch(phase: Phase, quietMs: number): Watch {
  if (!mayRun(phase)) return 'working';
  const giveUp = phase.kind === 'loading' ? LOAD_GIVES_UP_MS : RUN_GIVES_UP_MS;
  if (quietMs >= giveUp) return 'stuck';
  return quietMs >= SLOW_AFTER_MS ? 'slow' : 'working';
}

/** The line under the words box once a load or a run is slow: still working, and the recording is safe. */
export function slowLine(phase: Phase): string {
  if (phase.kind === 'loading') {
    return 'Still getting the speech model ready. This can take a while on a slow connection. Your recording is kept, and you can type the words instead.';
  }
  return 'Still writing out your words. This can take a while on a phone. Your recording is kept, and you can type the words instead.';
}

/** Why the words weren't written out, in one plain line that says the recording is kept. */
export const FAILED_LINE = 'Your words couldn’t be written out here. Your recording is kept, so type them if you like.';
/** For a browser that can't run the speech model at all. */
export const UNSUPPORTED_LINE = 'This browser can’t write out your words. Your recording is kept, so type them if you like.';
