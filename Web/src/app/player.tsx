// The one audio element and everything that drives it: open an episode (resuming where the listener left
// off), play, pause, skip, speed, seek, and the Media Session, so Android's lock screen and notification
// controls work. Positions are saved every few seconds while playing, and on pause, seek and leaving.
import { createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Episode, Margin, PlaybackPosition } from '../shared/model.ts';
import { useData } from './data.tsx';
import { friendMargins, readsAloud } from './logic/arrival.ts';
import { clipRejection, EPISODE_FAILED, failureNoticeShown, nextFailure, type FailureEvent } from './logic/episode-failure.ts';
import { CrossingClock } from './logic/margin-autoplay.ts';
import { MESSAGES, plainError } from './logic/messages.ts';
import { newestPlayableMessage, playCandidates, playNewestAvailable, type PlayAttempt } from './logic/newest-playable.ts';
import { browserStorage, MIRROR_EVERY_MS, mirrorPosition } from './logic/position-mirror.ts';
import { NotSavedError } from './logic/storage.ts';
import { FINISHED_WITHIN_SECONDS } from './logic/library.ts';
import { services } from './services.ts';
import { PaidPostNoVoice } from '../sources/read.ts';
import { ended, NOTHING_HEARD, replyForComposer, started, type ReplyMemory } from './logic/reply-memory.ts';
import { readWrittenMargin, type Reading } from './speech.ts';
import { useRelay, useUi } from './ui.tsx';

export const SKIP_SECONDS = 15;
const SAVE_EVERY_MS = 5000;
/** How long a written Margin stays on the screen after its moment. */
const WRITTEN_SHOWN_MS = 10_000;
/** The episode's volume while the browser's voice reads a friend's written Margin. */
const DUCKED_VOLUME = 0.25;

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
  /** A show's play button: starts the newest of these (newest first) that can actually play, and says so if it isn't the first. */
  openNewestPlayable(newestFirst: readonly Episode[]): Promise<void>;
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
  /**
   * The friend's Margin that a Margin begun now on `episodeId` answers (#4107): the one playing or showing, or one that
   * ended under 20 seconds ago. Undefined when there is none, or it is not among `friends`.
   */
  replyParent(episodeId: string, friends: readonly Margin[]): Margin | undefined;
  /**
   * Recording must not capture a friend's clip: stops the one that is playing (or the voice reading a written one),
   * clears its card and drops the Margins queued behind it, which stay on the list and count as heard. Says whether the
   * episode should carry on once the composer closes. Does nothing, and says no, when nothing of a friend's is sounding.
   */
  interruptForRecording(): { resume: boolean };
  /** The episode failed to load (#3356): its address answered nothing playable, or the connection broke. One state. */
  failed: boolean;
  /** Plays the friend's Margins on their own, in order, while the episode can't play. `done`: all heard. */
  withoutEpisode: 'idle' | 'playing' | 'done';
  playWithoutEpisode(): void;
  /** The cue card calls this while it is on screen saying the episode failed; a failure then needs no toast. Returns the undo. */
  registerFailureCard(): () => void;
}

const PlayerContext = createContext<PlayerApi | null>(null);

export function PlayerProvider({ children }: { children: ReactNode }) {
  const data = useData();
  const { toast, notice } = useUi();
  const relay = useRelay();
  const audioRef = useRef<HTMLAudioElement>(null);
  const [episodeId, setEpisodeId] = useState<string>();
  const [playing, setPlaying] = useState(false);
  const [loading, setLoading] = useState(false);
  const [time, setTime] = useState(0);
  const [mediaDuration, setMediaDuration] = useState<number>();
  const lastSave = useRef(0);
  const lastMirror = useRef(0);
  const pendingSeek = useRef<number | undefined>(undefined);
  const [arrived, setArrived] = useState<Arrived>();
  // Whether the episode failed to load, as a ref (events must see it at once) and as state (the screen shows it).
  const failedRef = useRef(false);
  const [failed, setFailed] = useState(false);
  // How many cue cards are on screen saying the episode failed, and whether the listener closed the notice for this failure.
  const [failureCards, setFailureCards] = useState(0);
  const [noticeClosed, setNoticeClosed] = useState(false);
  const [withoutEpisode, setWithoutEpisode] = useState<'idle' | 'playing' | 'done'>('idle');
  // Which run of the Margins-without-the-episode is current; a new one, or leaving, ends the old one.
  const runId = useRef(0);
  // Where playback last was, for spotting a Margin's moment being crossed.
  const crossing = useRef(new CrossingClock());
  // What to do after a blocked clip is played from the tap (the rest of a run of Margins without the episode).
  const blockedDone = useRef<(() => void) | undefined>(undefined);
  const clip = useRef<{ element: HTMLAudioElement; url: string } | null>(null);
  const clipQueue = useRef<Margin[]>([]);
  // The voice reading a friend's written Margin aloud, while it does.
  const reading = useRef<Reading | undefined>(undefined);
  // Margins that have come up since the last seek. A browser may resume the episode a hair before the moment it paused
  // at, which would cross the same Margin again; a seek (the listener rewinding over it) lets it fire again.
  const comeUp = useRef(new Set<string>());
  // The last friend's Margin heard, so a Margin begun while it sounds or just after answers it (#4107; reply-memory.ts).
  const replyMemory = useRef<ReplyMemory>(NOTHING_HEARD);
  const shownTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const dataRef = useRef(data);
  dataRef.current = data;

  const episode = data.episodes.find((e) => e.id === episodeId);
  const duration = mediaDuration ?? episode?.durationSeconds;
  const rate = data.settings.playbackRate;

  // The episode the audio element holds right now. A ref, so a save never files one episode's time
  // under the next one's id while React catches up.
  const loadedId = useRef<string | undefined>(undefined);

  // The place now, or nothing while an episode is loading or has none (a place filed then would be 0 or another episode's).
  const placeNow = useCallback((): PlaybackPosition | undefined => {
    const audio = audioRef.current;
    const id = loadedId.current;
    if (!audio || !id || !audio.src || !Number.isFinite(audio.currentTime) || pendingSeek.current !== undefined) return undefined;
    return { episodeId: id, seconds: audio.currentTime, updatedAt: new Date().toISOString() };
  }, []);

  // Writes the place to localStorage, which finishes before the page can go (#4096). Never waits on anything.
  const remember = useCallback(() => {
    const place = placeNow();
    if (!place) return;
    lastMirror.current = Date.now();
    mirrorPosition(browserStorage(), place);
  }, [placeNow]);

  const save = useCallback(() => {
    const place = placeNow();
    if (!place) return;
    const now = Date.now();
    lastSave.current = now;
    lastMirror.current = now;
    // First the synchronous copy: an IndexedDB write begun while the page unloads may not commit (#4096).
    mirrorPosition(browserStorage(), place);
    void dataRef.current.savePosition(place);
  }, [placeNow]);

  const stopReading = useCallback(() => {
    const current = reading.current;
    reading.current = undefined;
    current?.cancel();
  }, []);

  const stopClip = useCallback(() => {
    runId.current++;
    setWithoutEpisode((w) => (w === 'playing' ? 'idle' : w));
    stopReading();
    clipQueue.current = [];
    const current = clip.current;
    clip.current = null;
    if (!current) return;
    current.element.onended = null;
    current.element.pause();
    URL.revokeObjectURL(current.url);
  }, [stopReading]);

  /** Plays a voice Margin's clip with the episode paused, then resumes the episode (or the next queued clip). */
  const playClip = useCallback((margin: Margin, onDone?: () => void) => {
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
      // Nothing is speaking once the clip has ended: the card goes, so the countdown, or "That was X's last Margin",
      // shows again (#3797). A next Margin sets its own card, and a run without the episode sets or clears the next.
      if (!next) setArrived((a) => (a?.margin.id === margin.id ? undefined : a));
      if (next) playClip(next, onDone);
      else if (onDone) onDone();
      else void audio.play().catch(() => undefined);
    };
    element.onended = finish;
    element.onerror = finish;
    element.play().catch((error: unknown) => {
      if (clip.current?.element !== element) return;
      if (clipRejection(error instanceof DOMException ? error.name : undefined) === 'wait-for-tap') {
        // The browser won't start the clip without a tap: the episode stays paused at the Margin, with a Play. A run
        // of Margins without the episode carries on with the rest from that tap.
        clip.current = null;
        URL.revokeObjectURL(url);
        blockedDone.current = onDone;
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
          // The sender asked that this one not be read aloud: the words stay up, and nothing else changes (#3445).
          if (!readsAloud(margin)) continue;
          // A tone, then "Cole wrote:" and the words in this browser's own voice, with the episode turned down.
          reading.current?.cancel();
          const audio = audioRef.current;
          const heard = readWrittenMargin(margin.author, margin.text ?? '', {
            onStart: () => {
              if (audio) audio.volume = DUCKED_VOLUME;
            },
            onEnd: () => {
              if (audio) audio.volume = 1;
              if (reading.current === heard) reading.current = undefined;
            },
          });
          reading.current = heard;
        }
      }
    },
    [playClip],
  );

  /** Feeds the one failure state an event; shows the problem only when this event is the one that made it fail. */
  const apply = useCallback(
    (event: FailureEvent) => {
      const was = failedRef.current;
      const step = nextFailure(was, event);
      failedRef.current = step.failed;
      setFailed(step.failed);
      if (!step.failed) setWithoutEpisode((w) => (w === 'playing' ? w : 'idle'));
      if (step.failed && !was) {
        setLoading(false);
        setPlaying(false);
        setNoticeClosed(false);
      }
    },
    [],
  );

  // The problem sentence: the cue card renders it while it is on screen; otherwise this notice does. It is derived from
  // the state now, in a layout effect so the screen never paints both, and it holds no memory of when the failure came.
  const noticeShown = failureNoticeShown({ failed, cardsShowing: failureCards, closed: noticeClosed });
  useLayoutEffect(() => {
    notice('episode-failed', noticeShown ? EPISODE_FAILED : undefined, () => setNoticeClosed(true));
  }, [noticeShown, notice]);

  const registerFailureCard = useCallback(() => {
    setFailureCards((n) => n + 1);
    return () => setFailureCards((n) => n - 1);
  }, []);

  /** A `play()` that was refused or failed: a failed source is the one failure; a refused autoplay is just a wait. */
  const onPlayRejected = useCallback(
    (error: unknown) => {
      const name = error instanceof DOMException ? error.name : undefined;
      // Autoplay refused (a Margin file opened with no tap to play): it waits at its moment, paused, for Play.
      if (name === 'NotAllowedError') setLoading(false);
      apply({ kind: 'play-rejected', name });
    },
    [apply],
  );

  /** Asks the element to load the failed episode again, where it was, and play. */
  const retry = useCallback(
    (audio: HTMLAudioElement) => {
      apply({ kind: 'retry' });
      const at = Number.isFinite(audio.currentTime) && audio.currentTime > 0 ? audio.currentTime : undefined;
      pendingSeek.current = at;
      setLoading(true);
      audio.load();
      void audio.play().catch(onPlayRejected);
    },
    [apply, onPlayRejected],
  );

  /** The friend's Margins, one after the other, with no episode: a voice Margin from its blob, a written one read aloud. */
  const playWithoutEpisode = useCallback(() => {
    const list = friendMargins(dataRef.current.margins.filter((m) => m.episodeId === loadedId.current));
    if (list.length === 0) return;
    stopClip();
    const run = ++runId.current;
    setWithoutEpisode('playing');
    clearTimeout(shownTimer.current);
    const step = (index: number): void => {
      if (run !== runId.current) return;
      const margin = list[index];
      if (!margin) {
        setArrived(undefined);
        setWithoutEpisode('done');
        return;
      }
      const next = () => step(index + 1);
      if (margin.voice) {
        // The same clip path as a Margin that comes up in the episode: a refused clip waits for a tap, then carries on.
        playClip(margin, next);
      } else {
        setArrived({ margin, blocked: false });
        // Not read aloud (#3445): the words show for the usual time, then the run moves on, as with no voice.
        const heard = readsAloud(margin) ? readWrittenMargin(margin.author, margin.text ?? '', {
          onStart: () => undefined,
          onEnd: () => {
            if (run !== runId.current) return;
            if (reading.current === heard) reading.current = undefined;
            next();
          },
        }) : undefined;
        reading.current = heard;
        // A browser with no voice leaves the words up for the usual time, then moves on.
        if (!heard) shownTimer.current = setTimeout(() => run === runId.current && next(), WRITTEN_SHOWN_MS);
      }
    };
    step(0);
  }, [stopClip, playClip]);

  // One effect on `arrived` tells the memory every start and end, whichever path set or cleared it: a clip ending, a
  // written card's timer, the voice finishing, another Margin, a seek away or a new episode. A clip the browser blocked
  // has not started (`blocked`) until the listener plays it.
  const sounding = arrived && !arrived.blocked ? arrived.margin : undefined;
  const soundingId = sounding?.id;
  const soundingEpisode = sounding?.episodeId;
  useEffect(() => {
    replyMemory.current = soundingId === undefined || soundingEpisode === undefined
      ? ended(replyMemory.current, Date.now())
      : started(replyMemory.current, soundingId, soundingEpisode);
  }, [soundingId, soundingEpisode]);

  const replyParent = useCallback(
    (id: string, friends: readonly Margin[]) => replyForComposer(replyMemory.current, id, Date.now(), friends),
    [],
  );

  const interruptForRecording = useCallback((): { resume: boolean } => {
    if (!arrived || arrived.blocked || (!clip.current && !reading.current)) return { resume: false };
    // Read before `stopClip`, which ends the run of Margins without the episode: that run has no episode to resume.
    const resume = withoutEpisode !== 'playing';
    stopClip();
    clearTimeout(shownTimer.current);
    setArrived(undefined);
    return { resume };
  }, [arrived, withoutEpisode, stopClip]);

  const playArrived = useCallback(() => {
    const margin = arrived?.margin;
    const done = blockedDone.current;
    blockedDone.current = undefined;
    if (margin) playClip(margin, done);
  }, [arrived, playClip]);

  /** Opens an episode and says how it went. `paid` and `no-voice` are left for the caller to tell the listener. */
  const attemptOpen = useCallback(
    async (id: string, options: { at?: number; episode?: Episode } = {}): Promise<PlayAttempt> => {
      const audio = audioRef.current;
      let target = options.episode?.id === id ? options.episode : dataRef.current.episodes.find((e) => e.id === id);
      if (!audio || !target) return 'stopped';
      if (id === loadedId.current && audio.src) {
        if (failedRef.current) {
          retry(audio);
          return 'played';
        }
        if (options.at !== undefined) audio.currentTime = options.at;
        await audio.play().catch(() => undefined);
        return 'played';
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
          if (error instanceof PaidPostNoVoice) return 'paid';
          // The relay pop-up's "Not now", a dead page: one message, not a second "no voice" on top of it. A
          // storage failure has already shown its own.
          if (!(error instanceof NotSavedError)) toast(plainError(error), 'problem');
          return 'stopped';
        } finally {
          setLoading(false);
        }
      }
      if (!target.audioUrl) return 'no-voice';
      const resume = dataRef.current.positions.find((p) => p.episodeId === id)?.seconds;
      const finished = target.durationSeconds && resume && resume >= target.durationSeconds - FINISHED_WITHIN_SECONDS;
      pendingSeek.current = options.at ?? (finished ? 0 : resume);
      crossing.current.reset();
      loadedId.current = id;
      apply({ kind: 'source-changed' });
      setEpisodeId(id);
      setMediaDuration(undefined);
      setTime(pendingSeek.current ?? 0);
      audio.src = target.audioUrl;
      audio.playbackRate = dataRef.current.settings.playbackRate;
      setLoading(true);
      await audio.play().catch(onPlayRejected);
      return 'played';
    },
    [relay, save, toast, stopClip, apply, retry, onPlayRejected],
  );

  const open = useCallback(
    async (id: string, options: { at?: number; episode?: Episode } = {}) => {
      const result = await attemptOpen(id, options);
      if (result === 'paid') toast(MESSAGES.paidPost, 'problem');
      if (result === 'no-voice') toast(MESSAGES.noVoice, 'problem');
    },
    [attemptOpen, toast],
  );

  const openNewestPlayable = useCallback(
    async (newestFirst: readonly Episode[]) => {
      const result = await playNewestAvailable(playCandidates(newestFirst), (episode) => attemptOpen(episode.id));
      const message = newestPlayableMessage(result);
      if (message) toast(message.text, message.tone);
    },
    [attemptOpen, toast],
  );

  const toggle = useCallback(() => {
    const audio = audioRef.current;
    if (!audio || !audio.src) return;
    // A tap on Play while a Margin's clip is playing (or was blocked) goes to the episode: the clip is dropped, and its
    // card with it, so the reply memory sees the end (a card left up would keep answering that Margin for good, #4107).
    const cutClip = clip.current !== null;
    stopClip();
    setArrived((a) => (a?.blocked || failedRef.current || cutClip ? undefined : a));
    // A tap on Play after the episode failed is a retry.
    if (failedRef.current) {
      retry(audio);
      return;
    }
    if (audio.paused) void audio.play().catch(() => undefined);
    else audio.pause();
  }, [stopClip, retry]);

  const seek = useCallback((seconds: number) => {
    const audio = audioRef.current;
    if (!audio || !audio.src) return;
    const max = Number.isFinite(audio.duration) ? audio.duration : Number.POSITIVE_INFINITY;
    audio.currentTime = Math.min(Math.max(0, seconds), max);
    setTime(audio.currentTime);
    // The scrub itself is the place, even if the page goes before the browser reports the seek finished (#4096).
    remember();
  }, [remember]);

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
    () => ({ episode, playing, loading, time, duration, rate, open, openNewestPlayable, toggle, skip, seek, setRate, now, arrived, playArrived, replyParent, interruptForRecording, failed, withoutEpisode, playWithoutEpisode, registerFailureCard }),
    [episode, playing, loading, time, duration, rate, open, openNewestPlayable, toggle, skip, seek, setRate, now, arrived, playArrived, replyParent, interruptForRecording, failed, withoutEpisode, playWithoutEpisode, registerFailureCard],
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
        onSeeking={(event) => {
          stopReading();
          crossing.current.seeking(event.currentTarget.currentTime);
          comeUp.current.clear();
        }}
        onPlaying={(event) => {
          apply({ kind: 'playing' });
          crossing.current.playing(event.currentTarget.currentTime);
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
          if (loadedId.current) apply({ kind: 'media-error' });
        }}
        onTimeUpdate={(event) => {
          const audio = event.currentTarget;
          setTime(audio.currentTime);
          if (!audio.paused && !audio.seeking && loadedId.current) {
            const due = crossing.current.update(
              dataRef.current.margins.filter((m) => m.episodeId === loadedId.current && !comeUp.current.has(m.id)),
              audio.currentTime,
            );
            for (const m of due) comeUp.current.add(m.id);
            if (due.length > 0) fire(due);
          }
          const now = Date.now();
          if (now - lastSave.current > SAVE_EVERY_MS) save();
          else if (now - lastMirror.current > MIRROR_EVERY_MS) remember();
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
