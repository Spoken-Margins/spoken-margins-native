// What the voice Margin composer shows about transcription, and when the model may be downloaded. Plain
// TypeScript with no browser, so `npm run test:web` checks every rule (state.test.ts).
//
// The rules:
// 1. Opt-in. Nothing downloads until the listener turns transcription on in Settings, or taps "Write out my
//    words" after a recording. Until they have answered once, the composer offers it, with the size.
// 2. Prefill, not replace. The transcript fills the words box only while the listener hasn't typed in it. If they
//    have, it is offered beside the box instead, and their words stay.
// 3. Failure changes nothing. If the model can't load or run, the words box works as it always has.

/** The listener's answer: '' before they have been asked, then 'on' or 'off'. */
export type TranscriptionSetting = '' | 'on' | 'off';

export type Phase =
  /** Off, unsupported, or declined: the composer is the plain words box. */
  | { kind: 'off' }
  /** Never asked: the composer offers to write out the words, naming the download size. */
  | { kind: 'offer' }
  /** The model is loading; `total` is 0 until the size is known, and `loaded` is bytes so far. */
  | { kind: 'loading'; loaded: number; total: number }
  | { kind: 'transcribing' }
  /** Done. `text` is '' when no words were heard. */
  | { kind: 'done'; text: string }
  | { kind: 'failed'; message: string };

export type PhaseEvent =
  | { type: 'accept' }
  | { type: 'decline' }
  | { type: 'progress'; loaded: number; total: number }
  | { type: 'loaded' }
  | { type: 'result'; text: string }
  | { type: 'error'; message: string };

/** What the composer shows the moment a recording stops. */
export function initialPhase(setting: TranscriptionSetting, supported: boolean): Phase {
  if (!supported || setting === 'off') return { kind: 'off' };
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
