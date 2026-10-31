// The one audio element and everything that drives it: open an episode (resuming where the listener left
// off), play, pause, skip, speed, seek, and the Media Session, so Android's lock screen and notification
// controls work. Positions are saved every few seconds while playing, and on pause, seek and leaving.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Episode, Margin } from '../shared/model.ts';
import { useData } from './data.tsx';
import { dueMargins } from './logic/margin-autoplay.ts';
import { plainError } from './logic/messages.ts';
import { NotSavedError } from './logic/storage.ts';
import { FINISHED_WITHIN_SECONDS } from './logic/library.ts';
import { services } from './services.ts';
import { useRelay, useUi } from './ui.tsx';

export const SKIP_SECONDS = 15;
const SAVE_EVERY_MS = 5000;
/** How long a written Margin stays on the screen after its moment. */
const WRITTEN_SHOWN_MS = 10_000;

/** A friend's Margin that has just come up in the episode. `blocked`: the browser would not start its clip. */
export interface Arrived {
  margin: Margin;
  blocked: boolean;
}

export interface PlayerApi {
  episode: Episode | undefined;
  playing: boolean;
  loading: boolean;
  time: number;
  duration: number | undefined;
  rate: number;
  /**
   * Opens an episode. `at` jumps to a moment (a Margin); otherwise it resumes where the listener left off. `episode`
   * is the episode itself, for one just stored that this render does not show yet (an opened Margin file).
   */
  open(episodeId: string, options?: { at?: number; episode?: Episode }): Promise<void>;
  toggle(): void;
  skip(seconds: number): void;
  seek(seconds: number): void;
  setRate(rate: number): void;
  /** The current time, read straight from the audio element (for a Margin's anchor). */
  now(): number;
  /** The friend's Margin that last came up by itself (#3058), for Now Playing to show. */
  arrived: Arrived | undefined;
  /** Plays the arrived Margin's clip from a tap (when the browser blocked it), then the episode carries on. */
  playArrived(): void;
}

const PlayerContext = createContext<PlayerApi | null>(null);

export function PlayerProvider({ children }: { children: ReactNode }) {
  const data = useData();
  const { toast } = useUi();
  const relay = useRelay();
  const audioRef = useRef<HTMLAudioElement>(null);
  const [episodeId, setEpisodeId] = useState<string>();
  const [playing, setPlaying] = useState(false);
  const [loading, setLoading] = useState(false);
  const [time, setTime] = useState(0);
  const [mediaDuration, setMediaDuration] = useState<number>();
  const lastSave = useRef(0);
  const pendingSeek = useRef<number | undefined>(undefined);
  const [arrived, setArrived] = useState<Arrived>();
  // The previous time update while playing, for spotting a Margin's moment being crossed. Undefined after a seek.
  const lastTime = useRef<number | undefined>(undefined);
  const clip = useRef<{ element: HTMLAudioElement; url: string } | null>(null);
  const clipQueue = useRef<Margin[]>([]);
  // Margins that have come up since the last seek. A browser may resume the episode a hair before the moment it paused
  // at, which would cross the same Margin again; a seek (the listener rewinding over it) lets it fire again.
  const comeUp = useRef(new Set<string>());
  const shownTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const dataRef = useRef(data);
  dataRef.current = data;

  const episode = data.episodes.find((e) => e.id === episodeId);
  const duration = mediaDuration ?? episode?.durationSeconds;
  const rate = data.settings.playbackRate;

  // The episode the audio element holds right now. A ref, so a save never files one episode's time
  // under the next one's id while React catches up.
  const loadedId = useRef<string | undefined>(undefined);

  const save = useCallback(() => {
    const audio = audioRef.current;
    const id = loadedId.current;
    if (!audio || !id || !audio.src || !Number.isFinite(audio.currentTime) || pendingSeek.current !== undefined) return;
    lastSave.current = Date.now();
    void dataRef.current.savePosition({ episodeId: id, seconds: audio.currentTime, updatedAt: new Date().toISOString() });
  }, []);

  const stopClip = useCallback(() => {
    clipQueue.current = [];
    const current = clip.current;
    clip.current = null;
    if (!current) return;
    current.element.onended = null;
    current.element.pause();
    URL.revokeObjectURL(current.url);
  }, []);

  /** Plays a voice Margin's clip with the episode paused, then resumes the episode (or the next queued clip). */
  const playClip = useCallback((margin: Margin) => {
    const audio = audioRef.current;
    if (!audio || !margin.voice) return;
    audio.pause();
    clearTimeout(shownTimer.current);
    setArrived({ margin, blocked: false });
    const url = URL.createObjectURL(margin.voice.blob);
    const element = new Audio(url);
    clip.current = { element, url };
    const finish = () => {
      if (clip.current?.element !== element) return;
      clip.current = null;
      URL.revokeObjectURL(url);
      const next = clipQueue.current.shift();
      if (next) playClip(next);
      else void audio.play().catch(() => undefined);
    };
    element.onended = finish;
    element.onerror = finish;
    element.play().catch((error: unknown) => {
      if (clip.current?.element !== element) return;
      if (error instanceof DOMException && error.name === 'NotAllowedError') {
        // The browser won't start the clip without a tap: the episode stays paused at the Margin, with a Play.
        clip.current = null;
        URL.revokeObjectURL(url);
        setArrived({ margin, blocked: true });
        return;
      }
      finish();
    });
  }, []);

  /** A friend's Margins whose moment playback just reached: written ones appear, spoken ones play. */
  const fire = useCallback(
    (due: Margin[]) => {
      for (const margin of due) {
        if (margin.voice) {
          if (clip.current) clipQueue.current.push(margin);
          else playClip(margin);
        } else {
          setArrived({ margin, blocked: false });
          clearTimeout(shownTimer.current);
          shownTimer.current = setTimeout(() => setArrived((a) => (a?.margin.id === margin.id ? undefined : a)), WRITTEN_SHOWN_MS);
        }
      }
    },
    [playClip],
  );

  const playArrived = useCallback(() => {
    const margin = arrived?.margin;
    if (margin) playClip(margin);
  }, [arrived, playClip]);

  const open = useCallback(
    async (id: string, options: { at?: number; episode?: Episode } = {}) => {
      const audio = audioRef.current;
      let target = options.episode?.id === id ? options.episode : dataRef.current.episodes.find((e) => e.id === id);
      if (!audio || !target) return;
      if (id === loadedId.current && audio.src) {
        if (options.at !== undefined) audio.currentTime = options.at;
        await audio.play().catch(() => undefined);
        return;
      }
      save();
      stopClip();
      setArrived(undefined);
      if (!target.audioUrl && target.pageUrl) {
        // A Substack post: its voice is looked up now, because the listener tapped it (owner, 2026-10-21).
        setLoading(true);
        try {
          const pageUrl = target.pageUrl;
          const voice = await relay((relayAllowed) => services.sources.findPostVoice(pageUrl, { relayAllowed, reason: 'listener-tap' }));
          if (voice) {
            target = { ...target, ...voice };
            await dataRef.current.updateEpisode(target);
          }
        } catch (error) {
          // The relay pop-up's "Not now", a dead page: one message, not a second "no voice" on top of it. A
          // storage failure has already shown its own.
          if (!(error instanceof NotSavedError)) toast(plainError(error), 'problem');
          return;
        } finally {
          setLoading(false);
        }
      }
      if (!target.audioUrl) {
        toast('This post has no voice to play: neither the writer nor Substack offers one.', 'problem');
        return;
      }
      const resume = dataRef.current.positions.find((p) => p.episodeId === id)?.seconds;
      const finished = target.durationSeconds && resume && resume >= target.durationSeconds - FINISHED_WITHIN_SECONDS;
      pendingSeek.current = options.at ?? (finished ? 0 : resume);
      loadedId.current = id;
      setEpisodeId(id);
      setMediaDuration(undefined);
      setTime(pendingSeek.current ?? 0);
      audio.src = target.audioUrl;
      audio.playbackRate = dataRef.current.settings.playbackRate;
      setLoading(true);
      await audio.play().catch((error: unknown) => {
        if (error instanceof DOMException && error.name === 'AbortError') return;
        // Autoplay refused (a Margin file opened with no tap to play): it waits at its moment, paused, for Play.
        if (error instanceof DOMException && error.name === 'NotAllowedError') {
          setLoading(false);
          return;
        }
        toast('This episode’s audio couldn’t be played.', 'problem');
      });
    },
    [relay, save, toast, stopClip],
  );

  const toggle = useCallback(() => {
    const audio = audioRef.current;
    if (!audio || !audio.src) return;
    // A tap on Play while a Margin's clip is playing (or was blocked) goes to the episode: the clip is dropped.
    stopClip();
    setArrived((a) => (a?.blocked ? undefined : a));
    if (audio.paused) void audio.play().catch(() => undefined);
    else audio.pause();
  }, [stopClip]);

  const seek = useCallback((seconds: number) => {
    const audio = audioRef.current;
    if (!audio || !audio.src) return;
    const max = Number.isFinite(audio.duration) ? audio.duration : Number.POSITIVE_INFINITY;
    audio.currentTime = Math.min(Math.max(0, seconds), max);
    setTime(audio.currentTime);
  }, []);

  const skip = useCallback((seconds: number) => seek((audioRef.current?.currentTime ?? 0) + seconds), [seek]);

  const setRate = useCallback((value: number) => {
    if (audioRef.current) audioRef.current.playbackRate = value;
    void dataRef.current.setSetting('playbackRate', value);
  }, []);

  const now = useCallback(() => audioRef.current?.currentTime ?? 0, []);

  // Save when the page is hidden or closed: the last few seconds would otherwise be lost.
  useEffect(() => {
    const onHide = () => {
      if (document.visibilityState === 'hidden') save();
    };
    document.addEventListener('visibilitychange', onHide);
    window.addEventListener('pagehide', save);
    return () => {
      document.removeEventListener('visibilitychange', onHide);
      window.removeEventListener('pagehide', save);
    };
  }, [save]);

  // Media Session: lock screen and notification controls.
  useEffect(() => {
    if (!('mediaSession' in navigator) || !episode) return;
    const show = data.shows.find((s) => s.id === episode.showId);
    navigator.mediaSession.metadata = new MediaMetadata({
      title: episode.title,
      artist: show?.author ?? show?.title ?? '',
      album: show?.title ?? '',
      artwork: show?.artworkUrl ? [{ src: show.artworkUrl, sizes: '600x600' }] : [{ src: './icons/icon-512.png', sizes: '512x512', type: 'image/png' }],
    });
    const handlers: Array<[MediaSessionAction, MediaSessionActionHandler]> = [
      ['play', () => void audioRef.current?.play()],
      ['pause', () => audioRef.current?.pause()],
      ['seekbackward', (d) => skip(-(d.seekOffset ?? SKIP_SECONDS))],
      ['seekforward', (d) => skip(d.seekOffset ?? SKIP_SECONDS)],
      ['seekto', (d) => d.seekTime !== undefined && seek(d.seekTime)],
    ];
    for (const [action, handler] of handlers) {
      try {
        navigator.mediaSession.setActionHandler(action, handler);
      } catch {
        // Not every browser supports every action.
      }
    }
  }, [episode, data.shows, skip, seek]);

  useEffect(() => {
    if (!('mediaSession' in navigator)) return;
    navigator.mediaSession.playbackState = episode ? (playing ? 'playing' : 'paused') : 'none';
    if (episode && duration && Number.isFinite(duration) && time <= duration) {
      try {
        navigator.mediaSession.setPositionState({ duration, playbackRate: rate, position: time });
      } catch {
        // Ignore a state the browser rejects.
      }
    }
  }, [episode, playing, duration, rate, time]);

  const api = useMemo<PlayerApi>(
    () => ({ episode, playing, loading, time, duration, rate, open, toggle, skip, seek, setRate, now, arrived, playArrived }),
    [episode, playing, loading, time, duration, rate, open, toggle, skip, seek, setRate, now, arrived, playArrived],
  );

  return (
    <PlayerContext.Provider value={api}>
      {children}
      <audio
        ref={audioRef}
        preload="metadata"
        data-testid="audio"
        onLoadedMetadata={(event) => {
          const audio = event.currentTarget;
          if (Number.isFinite(audio.duration)) setMediaDuration(audio.duration);
          if (pendingSeek.current !== undefined) {
            audio.currentTime = Math.min(pendingSeek.current, Number.isFinite(audio.duration) ? audio.duration : pendingSeek.current);
            pendingSeek.current = undefined;
          }
        }}
        onDurationChange={(event) => {
          const d = event.currentTarget.duration;
          if (Number.isFinite(d)) setMediaDuration(d);
        }}
        onSeeking={() => {
          lastTime.current = undefined;
          comeUp.current.clear();
        }}
        onPlaying={(event) => {
          lastTime.current = event.currentTarget.currentTime;
          setPlaying(true);
          setLoading(false);
        }}
        onPause={() => {
          setPlaying(false);
          save();
        }}
        onWaiting={() => setLoading(true)}
        onCanPlay={() => setLoading(false)}
        onSeeked={save}
        onEnded={() => {
          setPlaying(false);
          save();
        }}
        onError={() => {
          setLoading(false);
          if (episodeId) toast('This episode’s audio couldn’t be loaded.', 'problem');
        }}
        onTimeUpdate={(event) => {
          const audio = event.currentTarget;
          setTime(audio.currentTime);
          if (!audio.paused && !audio.seeking && loadedId.current) {
            const due = dueMargins(
              dataRef.current.margins.filter((m) => m.episodeId === loadedId.current && !comeUp.current.has(m.id)),
              lastTime.current,
              audio.currentTime,
            );
            for (const m of due) comeUp.current.add(m.id);
            lastTime.current = audio.currentTime;
            if (due.length > 0) fire(due);
          }
          if (Date.now() - lastSave.current > SAVE_EVERY_MS) save();
        }}
      />
    </PlayerContext.Provider>
  );
}

export function usePlayer(): PlayerApi {
  const api = useContext(PlayerContext);
  if (!api) throw new Error('usePlayer outside PlayerProvider');
  return api;
}
