// What each surface says about an episode's voice, in one place (#4767, #4783). The Library tag and the player's toast
// are chosen here from `episodeVoice` and the player's answer, so a table test can hold them to the arrival card and the
// sender's check for every shape of packet, and no screen words a voice the others refuse. Plain TypeScript, no DOM.
import { MESSAGES } from './messages.ts';
import type { PlayAttempt } from './newest-playable.ts';
import type { EpisodeVoice } from './playability.ts';

export interface VoiceTag {
  text: string;
  /** `outline` is the quiet "New" mark, `quiet` a plain note about the voice. */
  style: 'quiet' | 'outline';
}

/** The Library card's tag for an unplayed episode. */
export function libraryVoiceTag(voice: EpisodeVoice): VoiceTag {
  switch (voice) {
    case 'own':
      return { text: 'New', style: 'outline' };
    case 'post-lookup':
      return { text: 'Post, voice checked when you play', style: 'quiet' };
    case 'apple-lookup':
      return { text: 'Episode, audio found when you play', style: 'quiet' };
    case 'none':
      return { text: 'No audio in the browser', style: 'quiet' };
  }
}

/** What the player tells the listener when opening an episode didn't start it, or undefined when it needs no words. */
export function attemptToast(attempt: PlayAttempt): string | undefined {
  switch (attempt) {
    case 'paid':
      return MESSAGES.paidPost;
    case 'no-voice':
      return MESSAGES.noVoice;
    case 'no-audio':
      return MESSAGES.noWebAudio;
    case 'played':
    case 'stopped':
      return undefined;
  }
}

/**
 * How opening an episode ended when, after any lookup, it still has no audio address: a Substack post whose voice wasn't
 * found is `no-voice`; anything else (an Apple episode Apple doesn't list with audio, a Spotify or other page) is `no-audio`.
 */
export function attemptWithoutAudio(voice: EpisodeVoice): PlayAttempt {
  return voice === 'post-lookup' ? 'no-voice' : 'no-audio';
}
