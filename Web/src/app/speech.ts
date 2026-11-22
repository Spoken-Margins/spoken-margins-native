// A friend's written Margin is heard, not shown alone (owner, 2026-11-02): a tone, then the browser's own voice says
// "Cole wrote:" and reads the words, so a synthetic voice never passes for the sender's. Nothing is fetched and
// nothing leaves the page; the voice is the one this browser ships. Where a browser has no voice, the Margin still
// shows on screen and nothing else changes.

let context: AudioContext | undefined;

/** A short, soft tone. Resolves when it ends, or at once where this browser won't make one. */
export function tone(): Promise<void> {
  return new Promise((resolve) => {
    // A browser that keeps the audio context suspended never ends the tone; speech goes ahead without it.
    setTimeout(resolve, 600);
    try {
      context ??= new AudioContext();
      const now = context.currentTime;
      const oscillator = context.createOscillator();
      const gain = context.createGain();
      oscillator.frequency.value = 660;
      gain.gain.setValueAtTime(0.0001, now);
      gain.gain.exponentialRampToValueAtTime(0.2, now + 0.03);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.28);
      oscillator.connect(gain).connect(context.destination);
      oscillator.onended = () => resolve();
      void context.resume().catch(() => undefined);
      oscillator.start(now);
      oscillator.stop(now + 0.3);
    } catch {
      resolve();
    }
  });
}

/**
 * Called from the friend's own tap (the arrival page's Play), so Safari lets the tone and the voice start later, when a
 * Margin comes up by itself. Safe to call anywhere; it does nothing where there is no audio context or voice.
 */
export function primeSpeech(): void {
  try {
    context ??= new AudioContext();
    void context.resume().catch(() => undefined);
    const synth = window.speechSynthesis;
    if (synth && typeof SpeechSynthesisUtterance !== 'undefined') {
      const silent = new SpeechSynthesisUtterance('');
      silent.volume = 0;
      synth.speak(silent);
    }
  } catch {
    // Nothing to prime.
  }
}

export interface Reading {
  /** Stops the tone or the voice. `onEnd` still fires if the voice had begun, so the episode comes back up. */
  cancel(): void;
  /**
   * Holds the voice where it is, for the player's Pause (#4473). A browser that can't hold speech (Chrome on Android
   * keeps talking) has the reading stopped instead, so Pause always silences it; `onEnd` then fires as for `cancel`.
   */
  pause(): void;
  /** Carries on a held voice from where it stopped. Does nothing once the reading has ended. */
  resume(): void;
}

/**
 * Plays the tone, then says `intro` ("Cole wrote:", "You wrote:"; readingIntro) and the words. `onStart` fires as the voice begins (the player turns the
 * episode down); `onEnd` fires when it finishes or can't speak. Returns undefined where this browser has no voice, and
 * then calls neither.
 */
export function readWrittenMargin(intro: string, words: string, hooks: { onStart(): void; onEnd(): void }): Reading | undefined {
  const synth = typeof window !== 'undefined' ? window.speechSynthesis : undefined;
  if (!synth || typeof SpeechSynthesisUtterance === 'undefined' || !words.trim()) return undefined;
  let live = true;
  let started = false;
  // Paused before the tone ended: the voice waits for `resume` instead of starting.
  let paused = false;
  let speakLater: (() => void) | undefined;
  let held: SpeechSynthesisUtterance | undefined;
  let safety: ReturnType<typeof setTimeout> | undefined;
  let safetyMs = 0;
  const armSafety = () => {
    clearTimeout(safety);
    safety = setTimeout(end, safetyMs);
  };
  const end = () => {
    if (!live) return;
    live = false;
    clearTimeout(safety);
    held = undefined;
    hooks.onEnd();
  };
  const speak = () => {
    if (!live) return;
    const utterance = new SpeechSynthesisUtterance(`${intro} ${words}`);
    // Chrome can collect an utterance that nothing holds, and then never fires `onend`: hold it, and give up on a
    // reading that outlasts any plausible speech so the episode never stays turned down.
    held = utterance;
    safetyMs = 8000 + words.length * 120;
    armSafety();
    utterance.onstart = () => {
      started = true;
      if (live) hooks.onStart();
    };
    utterance.onend = end;
    utterance.onerror = end;
    try {
      synth.speak(utterance);
    } catch {
      end();
    }
  };
  void tone().then(() => {
    if (paused) speakLater = speak;
    else speak();
  });
  const cancel = () => {
    if (!live) return;
    live = false;
    clearTimeout(safety);
    held = undefined;
    try {
      if (started || synth.speaking || synth.pending) synth.cancel();
    } catch {
      // Nothing to stop.
    }
    if (started) hooks.onEnd();
  };
  return {
    cancel,
    pause() {
      if (!live || paused) return;
      paused = true;
      if (!held) return; // Still in the tone: the voice waits for `resume`.
      // A held reading never times out while it waits.
      clearTimeout(safety);
      try {
        synth.pause();
      } catch {
        // Handled below: a voice that is still talking is stopped.
      }
      if (!synth.paused) cancel();
    },
    resume() {
      if (!live || !paused) return;
      paused = false;
      const later = speakLater;
      speakLater = undefined;
      if (later) {
        later();
        return;
      }
      if (!held) return;
      armSafety();
      try {
        synth.resume();
      } catch {
        cancel();
      }
    },
  };
}
