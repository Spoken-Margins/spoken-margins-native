// The sounds of the card's run (#5265), for `runMargins` (logic/arrival-run.ts): a line in the browser's voice, and a
// Margin's tone and clip, or its words read aloud. The clips play in one element the card readies from the friend's tap
// (`prime`), because Safari, and every browser on an iPhone, lets page code start an element's sound later only once it
// has played from a tap (#4472). Nothing is fetched: clips are in the packet and the voice is the browser's own.
import type { Margin } from '../shared/model.ts';
import { readingIntro, readsAloud } from './logic/arrival.ts';
import type { MarginRunEffects, Stoppable } from './logic/arrival-run.ts';
import { clipRejection } from './logic/episode-failure.ts';
import { SILENCE_WAV } from './player.tsx';
import { primeSpeech, readWrittenMargin, speakLine, tone } from './speech.ts';

/** How long a written Margin stays up when nothing reads it: the player's own time for a shown Margin. */
export const WRITTEN_SHOWN_MS = 10_000;

function detach(element: HTMLAudioElement): void {
  element.onended = null;
  element.onerror = null;
  element.onplay = null;
}

export interface CardSounds extends MarginRunEffects {
  /** Inside the friend's tap: readies the clip element and the voice, so the run's later sounds may start. */
  prime(): void;
}

export function cardSounds(element: HTMLAudioElement): CardSounds {
  return {
    prime() {
      primeSpeech();
      try {
        detach(element);
        element.src = SILENCE_WAV;
        void element.play()?.catch?.(() => undefined);
      } catch {
        // Nothing to ready.
      }
    },
    speak(text, ended) {
      const line = speakLine(text, { onEnd: ended });
      return line && { stop: () => line.cancel() };
    },
    playMargin(margin: Margin, hooks): Stoppable {
      let live = true;
      let url: string | undefined;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const cleanUp = () => {
        clearTimeout(timer);
        if (url) {
          detach(element);
          element.pause();
          URL.revokeObjectURL(url);
          url = undefined;
        }
      };
      const finish = (then: () => void) => {
        if (!live) return;
        live = false;
        cleanUp();
        then();
      };
      if (margin.voice) {
        const voice = margin.voice;
        void tone().then(() => {
          if (!live) return;
          url = URL.createObjectURL(voice.blob);
          detach(element);
          element.src = url;
          element.onended = () => finish(hooks.ended);
          element.onerror = () => finish(hooks.failed);
          element.onplay = () => {
            if (live) hooks.started();
          };
          element.play().catch((error: unknown) => {
            const meaning = clipRejection(error instanceof DOMException ? error.name : undefined);
            if (meaning === 'held') return;
            finish(meaning === 'wait-for-tap' ? hooks.blocked : hooks.failed);
          });
        });
        return {
          stop() {
            if (!live) return;
            live = false;
            cleanUp();
          },
        };
      }
      const shownThenOn = () => {
        timer = setTimeout(() => finish(hooks.ended), WRITTEN_SHOWN_MS);
      };
      if (!readsAloud(margin)) {
        // The sender asked that it not be read aloud (#3445): its words stay up for the usual time, with no tone.
        shownThenOn();
        return { stop: () => finish(() => undefined) };
      }
      const reading = readWrittenMargin(readingIntro(margin), margin.text ?? '', {
        onStart: () => {
          if (live) hooks.started();
        },
        onEnd: () => finish(hooks.ended),
      });
      if (!reading) shownThenOn();
      return {
        stop() {
          if (!live) return;
          live = false;
          clearTimeout(timer);
          reading?.cancel();
        },
      };
    },
  };
}
