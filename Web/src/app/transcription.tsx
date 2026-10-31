// Writing out a voice Margin's words on this device, in the composer after a recording stops. The rules (opt-in,
// prefill not replace, failure changes nothing) are in `src/transcribe/state.ts`; this file only wires them to the
// worker and draws them.
import { useCallback, useEffect, useRef, useState } from 'react';
import { initialPhase, loadingLine, nextPhase, settingAfter, type Phase, type PhaseEvent } from '../transcribe/state.ts';
import { useData } from './data.tsx';
import { plainError } from './logic/messages.ts';
import { services } from './services.ts';

export interface Transcription {
  phase: Phase;
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
    const step = (event: PhaseEvent) => {
      if (!gone.current) setPhase((current) => nextPhase(current, event));
    };
    services.transcriber
      .prepare((loaded, total) => step({ type: 'progress', loaded, total }))
      .then(() => {
        step({ type: 'loaded' });
        return services.transcriber.transcribe(voice);
      })
      .then((result) => {
        if (gone.current) return;
        setDevice(result.device);
        step({ type: 'result', text: result.text });
        textRef.current(result.text);
      })
      .catch((error: unknown) => step({ type: 'error', message: plainError(error) }));
  }, [voice, phase.kind]);

  const answer = useCallback(
    (event: PhaseEvent) => {
      const setting = settingAfter(event, settingRef.current);
      if (setting !== settingRef.current) void data.setSetting('transcription', setting);
      started.current = undefined;
      setPhase((current) => nextPhase(current, event));
    },
    [data],
  );

  return { phase, ...(device && { device }), accept: () => answer({ type: 'accept' }), decline: () => answer({ type: 'decline' }) };
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
          {phase.kind === 'loading' ? loadingLine(phase, size) : 'Writing out your words…'}
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
          {prefilled ? 'Written out from your recording, on this device. Check the words before you save.' : 'Written out from your recording.'}
        </p>
      );
    case 'failed':
      return (
        <div className="transcribe-note" role="status" data-testid="transcribe-status">
          <p>Your words couldn’t be written out here, so type them if you like. {phase.message}</p>
          <button type="button" className="button" onClick={accept}>
            Try again
          </button>
        </div>
      );
  }
}
