// Writing out a voice Margin's words on this device, in the composer after a recording stops. The rules (opt-in,
// prefill not replace, failure changes nothing) are in `src/transcribe/state.ts`; this file only wires them to the
// worker and draws them.
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  FAILED_LINE,
  LOAD_GIVES_UP_MS,
  RUN_GIVES_UP_MS,
  SLOW_AFTER_MS,
  STUCK_MESSAGE,
  UNSUPPORTED_LINE,
  initialPhase,
  loadingLine,
  mayRun,
  nextPhase,
  settingAfter,
  slowLine,
  type Phase,
  type PhaseEvent,
} from '../transcribe/state.ts';
import { useData } from './data.tsx';
import { plainError } from './logic/messages.ts';
import { services } from './services.ts';

export interface Transcription {
  phase: Phase;
  /** The load or run has made no progress for a while: say it is still working, and that the recording is kept. */
  slow: boolean;
  /** Where the last transcript ran, for tests and diagnostics: 'webgpu' or 'wasm'. */
  device?: string;
  accept(): void;
  decline(): void;
}

/**
 * Runs the transcriber for one recording, once the listener has said yes (now or earlier in Settings), and hands
 * the words to `onText`. Before that, and in a browser that can't run it, nothing is fetched or started.
 */
export function useTranscription(voice: Blob | undefined, onText: (text: string) => void): Transcription {
  const data = useData();
  const [phase, setPhase] = useState<Phase>({ kind: 'off' });
  const [device, setDevice] = useState<string>();
  const [slow, setSlow] = useState(false);
  /** Which attempt may still change the composer: a stopped or retried attempt must not touch a later one. */
  const attempt = useRef(0);
  const started = useRef<Blob | undefined>(undefined);
  const gone = useRef(false);
  const textRef = useRef(onText);
  textRef.current = onText;
  const settingRef = useRef(data.settings.transcription);
  settingRef.current = data.settings.transcription;

  useEffect(() => {
    gone.current = false;
    return () => {
      gone.current = true;
    };
  }, []);

  useEffect(() => {
    if (voice) setPhase(initialPhase(settingRef.current, services.transcriber.supported()));
  }, [voice]);

  useEffect(() => {
    if (!voice || phase.kind !== 'loading' || started.current === voice) return;
    started.current = voice;
    attempt.current += 1;
    const mine = attempt.current;
    const step = (event: PhaseEvent) => {
      if (!gone.current && attempt.current === mine) setPhase((current) => nextPhase(current, event));
    };
    services.transcriber
      .prepare((loaded, total) => step({ type: 'progress', loaded, total }))
      .then(() => {
        step({ type: 'loaded' });
        return services.transcriber.transcribe(voice, (done, total) => step({ type: 'segment', done, total }));
      })
      .then((result) => {
        if (gone.current || attempt.current !== mine) return;
        setDevice(result.device);
        step({ type: 'result', text: result.text });
        textRef.current(result.text);
      })
      .catch((error: unknown) => step({ type: 'error', message: plainError(error) }));
  }, [voice, phase.kind]);

  // A load or a run that goes quiet is first called slow, then stuck: the worker is stopped (the model stays
  // downloaded) and the composer says so, with Try again. Any progress, or a new phase, starts the count again.
  useEffect(() => {
    setSlow(false);
    if (!voice || !mayRun(phase)) return;
    const giveUp = phase.kind === 'loading' ? LOAD_GIVES_UP_MS : RUN_GIVES_UP_MS;
    const slowTimer = window.setTimeout(() => setSlow(true), SLOW_AFTER_MS);
    const stuckTimer = window.setTimeout(() => {
      services.transcriber.abandon();
      attempt.current += 1;
      setPhase((current) => nextPhase(current, { type: 'error', message: STUCK_MESSAGE }));
    }, giveUp);
    return () => {
      window.clearTimeout(slowTimer);
      window.clearTimeout(stuckTimer);
    };
  }, [voice, phase]);

  const answer = useCallback(
    (event: PhaseEvent) => {
      const setting = settingAfter(event, settingRef.current);
      if (setting !== settingRef.current) void data.setSetting('transcription', setting);
      started.current = undefined;
      attempt.current += 1;
      setPhase((current) => nextPhase(current, event));
    },
    [data],
  );

  return { phase, slow, ...(device && { device }), accept: () => answer({ type: 'accept' }), decline: () => answer({ type: 'decline' }) };
}

export function TranscriptionNote({
  transcription,
  prefilled,
  suggestion,
  onUseSuggestion,
}: {
  transcription: Transcription;
  /** The words box holds the transcript. */
  prefilled: boolean;
  /** The transcript, when it didn't go in because the listener had typed. */
  suggestion?: string;
  onUseSuggestion(): void;
}) {
  const { phase, accept, decline } = transcription;
  const size = services.transcriber.sizeLabel;
  switch (phase.kind) {
    case 'off':
      return null;
    case 'unsupported':
      return (
        <p className="transcribe-note" role="status" data-testid="transcribe-status">
          {UNSUPPORTED_LINE}
        </p>
      );
    case 'offer':
      return (
        <div className="transcribe-note" data-testid="transcribe-offer">
          <p>
            Write out your words on this device? It downloads a speech model once ({size}). Your recording never leaves this device.
          </p>
          <div className="transcribe-actions">
            <button type="button" className="button" onClick={decline}>
              No thanks
            </button>
            <button type="button" className="button" onClick={accept}>
              Write out my words
            </button>
          </div>
        </div>
      );
    case 'loading':
    case 'transcribing':
      return (
        <p className="transcribe-note transcribe-working" role="status" data-testid="transcribe-status">
          <span className="transcribe-spinner" aria-hidden="true" />
          {transcription.slow ? slowLine(phase) : phase.kind === 'loading' ? loadingLine(phase, size) : 'Writing out your words…'}
        </p>
      );
    case 'done':
      if (!phase.text) {
        return (
          <p className="transcribe-note" role="status" data-testid="transcribe-status" data-device={transcription.device}>
            No words were heard in the recording. You can type some.
          </p>
        );
      }
      if (suggestion) {
        return (
          <div className="transcribe-note" role="status" data-testid="transcribe-status" data-device={transcription.device}>
            <p>
              From your recording: <q>{suggestion}</q>
            </p>
            <button type="button" className="button" onClick={onUseSuggestion}>
              Use these words
            </button>
          </div>
        );
      }
      return (
        <p className="transcribe-note" role="status" data-testid="transcribe-status" data-device={transcription.device}>
          {prefilled ? 'Written out from your recording, on this device. Check the words.' : 'Written out from your recording.'}
        </p>
      );
    case 'failed':
      return (
        <div className="transcribe-note" role="status" data-testid="transcribe-status">
          <p>{FAILED_LINE}</p>
          <p data-testid="transcribe-detail">
            <small>What happened: {phase.message}</small>
          </p>
          <button type="button" className="button" onClick={accept}>
            Try again
          </button>
        </div>
      );
  }
}
