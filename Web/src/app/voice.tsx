// Plays a voice Margin's own audio, separately from the episode. The episode pauses first, so the two
// never talk over each other.
import { useEffect, useRef, useState } from 'react';
import { formatClock } from '../shared/clock.ts';
import { PauseIcon, PlayIcon } from './icons.tsx';
import { usePlayer } from './player.tsx';

export function VoiceButton({ voice }: { voice: { blob: Blob; durationSeconds: number } }) {
  const player = usePlayer();
  const [playing, setPlaying] = useState(false);
  const audio = useRef<HTMLAudioElement | null>(null);

  useEffect(
    () => () => {
      if (audio.current) {
        audio.current.pause();
        URL.revokeObjectURL(audio.current.src);
      }
    },
    [],
  );

  const toggle = () => {
    if (playing && audio.current) {
      audio.current.pause();
      return;
    }
    if (player.playing) player.toggle();
    if (!audio.current) {
      const element = new Audio(URL.createObjectURL(voice.blob));
      element.onplay = () => setPlaying(true);
      element.onpause = () => setPlaying(false);
      element.onended = () => setPlaying(false);
      audio.current = element;
    }
    void audio.current.play().catch(() => setPlaying(false));
  };

  return (
    <button type="button" className="icon-button voice-button" onClick={toggle} aria-label={playing ? 'Pause this voice Margin' : `Hear this voice Margin, ${formatClock(voice.durationSeconds)}`}>
      {playing ? <PauseIcon size={20} /> : <PlayIcon size={20} />}
    </button>
  );
}
