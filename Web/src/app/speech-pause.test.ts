// Pause on a browser that can't hold speech (Chrome on Android) stops the voice; `onEnd` must say so, so the player
// holds its run there instead of starting the next Margin (#5355).
import { test } from 'node:test';
import assert from 'node:assert/strict';

class FakeUtterance {
  onstart: (() => void) | null = null;
  onend: (() => void) | null = null;
  onerror: (() => void) | null = null;
  readonly text: string;
  constructor(text: string) {
    this.text = text;
  }
}

function fakeSynth(holds: boolean) {
  let current: FakeUtterance | undefined;
  return {
    speaking: false,
    pending: false,
    paused: false,
    speak(u: FakeUtterance) {
      current = u;
      this.speaking = true;
      u.onstart?.();
    },
    pause() {
      if (holds) this.paused = true;
    },
    resume() {
      this.paused = false;
    },
    cancel() {
      const u = current;
      current = undefined;
      this.speaking = false;
      u?.onend?.();
    },
  };
}

async function withSynth<T>(holds: boolean, body: (speech: typeof import('./speech.ts')) => T): Promise<T> {
  const g = globalThis as Record<string, unknown>;
  g.window = { speechSynthesis: fakeSynth(holds) };
  g.SpeechSynthesisUtterance = FakeUtterance;
  try {
    return body(await import('./speech.ts'));
  } finally {
    delete g.window;
    delete g.SpeechSynthesisUtterance;
  }
}

test('speakLine: a Pause the browser can’t hold ends the line as paused', async () => {
  await withSynth(false, ({ speakLine }) => {
    const ends: unknown[] = [];
    const line = speakLine('Here are the episode’s words.', { onEnd: (ended) => ends.push(ended) });
    assert.ok(line);
    line.pause();
    assert.deepEqual(ends, [{ paused: true }]);
  });
});

test('speakLine: a Pause the browser holds ends nothing, and a natural end is not paused', async () => {
  await withSynth(true, ({ speakLine }) => {
    const ends: unknown[] = [];
    const line = speakLine('Here are the episode’s words.', { onEnd: (ended) => ends.push(ended) });
    assert.ok(line);
    line.pause();
    assert.deepEqual(ends, []);
    line.resume();
    line.cancel();
    assert.deepEqual(ends, [{ paused: false }]);
  });
});
