import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { formatClock } from '../../shared/clock.ts';
import type { Episode, Margin, Show } from '../../shared/model.ts';
import { capacitorBridge } from '../../sources/native-http.ts';
import { useData } from '../data.tsx';
import { useRestoreFocus } from '../focus.ts';
import { BackIcon, DownIcon, DownloadIcon, ForwardIcon, MicIcon, PauseIcon, PenIcon, PlayIcon, ShareIcon, StopIcon } from '../icons.tsx';
import { nextSpeed, timelineFraction, timelinePosts } from '../logic/library.ts';
import { plainError } from '../logic/messages.ts';
import { shareNativePacket } from '../logic/native-packets.ts';
import { SKIP_SECONDS, usePlayer } from '../player.tsx';
import type { RecordedVoice, VoiceRecording } from '../ports.ts';
import { linkPreview, linkUploadMessage } from '../logic/share-link.ts';
import { SHARE_LINKS_OFFERED, services, uploadShareLink } from '../services.ts';
import { shortDate } from '../format.ts';
import { useUi } from '../ui.tsx';
import { MarginRow } from './Margins.tsx';

function newId(): string {
  return crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function NowPlaying({ onClose }: { onClose: () => void }) {
  const player = usePlayer();
  const data = useData();
  const [composer, setComposer] = useState<{ kind: 'write' | 'record'; at: number } | null>(null);
  // Which composer just closed, so focus goes back to the button that opened it.
  const [closedKind, setClosedKind] = useState<'write' | 'record'>();
  const closeRef = useRef<HTMLButtonElement>(null);
  const writeRef = useRef<HTMLButtonElement>(null);
  const recordRef = useRef<HTMLButtonElement>(null);
  const episode = player.episode;
  useRestoreFocus('.mini-open');
  // The track's width, so posts closer than one 44 px target share a post instead of covering each other.
  const [trackWidth, setTrackWidth] = useState(340);
  const scrubberRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const el = scrubberRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(() => setTrackWidth(el.clientWidth || 340));
    observer.observe(el);
    return () => observer.disconnect();
  }, [episode?.id]);

  useEffect(() => closeRef.current?.focus(), []);
  useEffect(() => {
    if (!closedKind) return;
    (closedKind === 'write' ? writeRef : recordRef).current?.focus();
    setClosedKind(undefined);
  }, [closedKind]);
  const closeComposer = (kind: 'write' | 'record') => () => {
    setComposer(null);
    setClosedKind(kind);
  };
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !composer) onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [composer, onClose]);

  if (!episode) return null;
  const show = data.shows.find((s) => s.id === episode.showId);
  const margins = data.margins.filter((m) => m.episodeId === episode.id).sort((a, b) => a.atSeconds - b.atSeconds);
  const duration = player.duration;
  const remaining = duration ? Math.max(0, duration - player.time) : undefined;

  return (
    <div className="now-playing" role="dialog" aria-modal="true" aria-labelledby="np-title">
      <header className="np-header">
        <button ref={closeRef} type="button" className="icon-button" aria-label="Close Now Playing" onClick={onClose}>
          <DownIcon />
        </button>
        <span className="np-header-label">Now Playing</span>
        <span className="icon-button-spacer" />
      </header>

      <div className="np-body">
        <p className="row-kicker">{show?.title}</p>
        <h2 id="np-title" className="np-title">
          {episode.title}
        </h2>

        <div className="timeline">
          {/* The posts are for pointing at. They stay out of the tab order and the screen reader's path,
              because "Margins in this episode" below lists the same Margins, each one a button that plays
              from its moment; reading both would say every Margin twice. */}
          {margins.length > 0 && (
            <div className="timeline-ticks" aria-hidden="true">
              {timelinePosts(margins, duration, 44 / Math.max(trackWidth, 44)).map((post) => (
                <button
                  key={post.margins[0].id}
                  type="button"
                  tabIndex={-1}
                  className={`tick${post.margins.length > 1 ? ' tick-shared' : ''}`}
                  data-at={post.atSeconds}
                  style={{ left: `${post.fraction * 100}%` }}
                  title={post.margins.map((m) => `${formatClock(m.atSeconds)} ${m.text ?? 'Voice Margin'}`).join('\n')}
                  onClick={() => player.seek(post.atSeconds)}
                />
              ))}
            </div>
          )}
          <input
            ref={scrubberRef}
            className="scrubber"
            type="range"
            min={0}
            max={duration ?? 0}
            step={1}
            value={Math.min(player.time, duration ?? player.time)}
            disabled={!duration}
            aria-label="Position"
            aria-valuetext={`${formatClock(player.time)} of ${formatClock(duration ?? 0)}`}
            style={{ '--fill': `${timelineFraction(player.time, duration) * 100}%` } as CSSProperties}
            onChange={(event) => player.seek(Number(event.target.value))}
          />
          <div className="timeline-times">
            <span data-testid="elapsed">{formatClock(player.time)}</span>
            <span>{remaining !== undefined ? `−${formatClock(remaining)}` : '−:−−'}</span>
          </div>
        </div>

        <div className="transport">
          <button type="button" className="speed-button" aria-label={`Speed ${player.rate} times. Change speed`} onClick={() => player.setRate(nextSpeed(player.rate))}>
            {player.rate}×
          </button>
          <button type="button" className="icon-button transport-skip" aria-label={`Back ${SKIP_SECONDS} seconds`} onClick={() => player.skip(-SKIP_SECONDS)}>
            <BackIcon />
          </button>
          <button type="button" className="play-button" aria-label={player.playing ? 'Pause' : 'Play'} onClick={player.toggle}>
            {player.playing ? <PauseIcon size={30} /> : <PlayIcon size={30} />}
          </button>
          <button type="button" className="icon-button transport-skip" aria-label={`Forward ${SKIP_SECONDS} seconds`} onClick={() => player.skip(SKIP_SECONDS)}>
            <ForwardIcon />
          </button>
          <span className="speed-button-spacer" aria-hidden="true" />
        </div>
        {player.loading && <p className="muted np-status">Loading audio…</p>}

        {composer ? (
          composer.kind === 'write' ? (
            <WriteMargin at={composer.at} episodeId={episode.id} onDone={closeComposer('write')} />
          ) : (
            <RecordMargin
              at={composer.at}
              episodeId={episode.id}
              onDone={closeComposer('record')}
              onWriteInstead={() => setComposer({ kind: 'write', at: composer.at })}
            />
          )
        ) : (
          <div className="margin-actions">
            <button ref={writeRef} type="button" className="button button-margin" onClick={() => setComposer({ kind: 'write', at: player.now() })}>
              <PenIcon />
              Write a Margin
            </button>
            <button ref={recordRef} type="button" className="button button-margin" onClick={() => setComposer({ kind: 'record', at: player.now() })}>
              <MicIcon />
              Record a Margin
            </button>
          </div>
        )}

        <section className="np-margins" aria-labelledby="np-margins-title">
          <h3 id="np-margins-title">Margins in this episode</h3>
          {margins.length === 0 ? (
            <p className="muted">None yet. A Margin sits at the moment you add it.</p>
          ) : (
            <>
              <ol className="margin-list">
                {margins.map((margin) => (
                  <MarginRow key={margin.id} margin={margin} compact />
                ))}
              </ol>
              <ShareMargins episode={episode} margins={margins} show={show} />
            </>
          )}
        </section>
      </div>
    </div>
  );
}

const PACKET_TYPE = 'application/vnd.spokenmargins.package+zip';

/** Whether this browser can hand a file to the system share sheet (Android, iPhone, some desktops). */
function canSendFiles(): boolean {
  try {
    return typeof navigator.canShare === 'function' && navigator.canShare({ files: [new File([], 'x.spokenmargins', { type: PACKET_TYPE })] });
  } catch {
    return false;
  }
}

/**
 * Shares this episode's Margins as a `.spokenmargins` file, which the iPhone app (and this web app) opens at each
 * Margin's moment. "Save as a file" works everywhere; "Send" uses the system share sheet where there is one.
 */
function ShareMargins({ episode, margins, show }: { episode: Episode; margins: Margin[]; show: Show | undefined }) {
  const { toast } = useUi();
  const [busy, setBusy] = useState(false);
  const [sendable] = useState(canSendFiles);
  // Inside the Android app (#3009) one button writes the file and opens Android's share sheet, which can also save it.
  const [bridge] = useState(() => capacitorBridge());
  const [link, setLink] = useState('');

  const share = async (how: 'save' | 'send') => {
    setBusy(true);
    try {
      const written = await services.packets.writePacket(episode, margins, show);
      if (bridge) {
        if ((await shareNativePacket(bridge, written.bytes, written.fileName, episode.title)) === 'cancelled') return;
        const count = written.included.length === 1 ? '1 Margin' : `${written.included.length} Margins`;
        toast(`Shared ${count} as ${written.fileName}.${written.notice ? ` ${written.notice}` : ''}`);
        return;
      }
      const file = new File([written.bytes as BlobPart], written.fileName, { type: written.mimeType });
      if (how === 'send') {
        try {
          await navigator.share({ files: [file], title: episode.title });
        } catch (error) {
          if (error instanceof DOMException && error.name === 'AbortError') return;
          throw error;
        }
      } else {
        const url = URL.createObjectURL(file);
        const link = document.createElement('a');
        link.href = url;
        link.download = written.fileName;
        document.body.append(link);
        link.click();
        link.remove();
        window.setTimeout(() => URL.revokeObjectURL(url), 30_000);
      }
      const count = written.included.length === 1 ? '1 Margin' : `${written.included.length} Margins`;
      toast(`${how === 'save' ? 'Saved' : 'Shared'} ${count} as ${written.fileName}.${written.notice ? ` ${written.notice}` : ''}`);
    } catch (error) {
      toast(`These Margins weren’t shared. ${plainError(error)}`, 'problem');
    } finally {
      setBusy(false);
    }
  };

  const makeLink = async () => {
    setBusy(true);
    try {
      const written = await services.packets.writePacket(episode, margins, show);
      const preview = linkPreview(episode, show, margins, written.included);
      const made = await uploadShareLink(written.bytes, preview);
      setLink(made.url);
      let copied = false;
      try {
        await navigator.clipboard.writeText(made.url);
        copied = true;
      } catch {
        // No clipboard permission: the link is in the field below to copy by hand.
      }
      const until = made.expiresAt ? ` It works until ${shortDate(made.expiresAt)}.` : '';
      toast(`${copied ? 'Link copied.' : 'Link ready. Copy it below.'}${until}${written.notice ? ` ${written.notice}` : ''}`);
    } catch (error) {
      toast(`No link was made. ${linkUploadMessage(error)}`, 'problem');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="share-margins">
      <p className="muted">Share them as a .spokenmargins file. A friend opens it in Spoken Margins and hears each one at its moment.</p>
      <div className="share-actions">
        {bridge ? (
          <button type="button" className="button" disabled={busy} onClick={() => void share('send')}>
            <ShareIcon />
            Save or send
          </button>
        ) : (
          <button type="button" className="button" disabled={busy} onClick={() => void share('save')}>
            <DownloadIcon />
            Save as a file
          </button>
        )}
        {!bridge && sendable && (
          <button type="button" className="button" disabled={busy} onClick={() => void share('send')}>
            <ShareIcon />
            Send
          </button>
        )}
        {SHARE_LINKS_OFFERED && (
          <button type="button" className="button" disabled={busy} onClick={() => void makeLink()}>
            <ShareIcon />
            Make a link
          </button>
        )}
      </div>
      {link && (
        <div className="share-link-row">
          <label htmlFor="share-link-made">Link to these Margins</label>
          <input id="share-link-made" type="text" readOnly value={link} onFocus={(event) => event.target.select()} />
        </div>
      )}
    </div>
  );
}

function WriteMargin({ at, episodeId, onDone }: { at: number; episodeId: string; onDone: () => void }) {
  const data = useData();
  const { toast } = useUi();
  const [text, setText] = useState('');
  const input = useRef<HTMLTextAreaElement>(null);
  useEffect(() => input.current?.focus(), []);

  const save = async () => {
    const value = text.trim();
    if (!value) return;
    const margin: Margin = { id: newId(), episodeId, atSeconds: at, createdAt: new Date().toISOString(), text: value };
    try {
      await data.addMargin(margin);
      toast(`Margin saved at ${formatClock(at)}.`);
      onDone();
    } catch (error) {
      toast(`The Margin wasn’t saved: ${plainError(error)}`, 'problem');
    }
  };

  return (
    <form
      className="composer"
      onSubmit={(event) => {
        event.preventDefault();
        void save();
      }}
    >
      <label htmlFor="margin-text">Your Margin at {formatClock(at)}</label>
      <textarea
        id="margin-text"
        ref={input}
        rows={3}
        value={text}
        onChange={(event) => setText(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) void save();
          if (event.key === 'Escape') onDone();
        }}
      />
      <div className="composer-actions">
        <button type="button" className="button" onClick={onDone}>
          Cancel
        </button>
        <button type="submit" className="button button-primary" disabled={!text.trim()}>
          Save Margin
        </button>
      </div>
    </form>
  );
}

function RecordMargin({
  at,
  episodeId,
  onDone,
  onWriteInstead,
}: {
  at: number;
  episodeId: string;
  onDone: () => void;
  /** When the microphone fails, the same moment can still get a written Margin. */
  onWriteInstead: () => void;
}) {
  const data = useData();
  const player = usePlayer();
  const { toast } = useUi();
  const [recording, setRecording] = useState<VoiceRecording | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [problem, setProblem] = useState<string>();
  const [recorded, setRecorded] = useState<RecordedVoice>();
  const [words, setWords] = useState('');
  const resumeAfter = useRef(false);
  const started = useRef(false);
  const live = useRef<VoiceRecording | null>(null);
  const gone = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    // The episode pauses while you speak, so the Margin records your voice, not the show.
    resumeAfter.current = player.playing;
    if (player.playing) player.toggle();
    services.recorder
      .start()
      .then((r) => {
        if (gone.current) {
          r.cancel();
          return;
        }
        live.current = r;
        setRecording(r);
      })
      .catch((error: unknown) => setProblem(`Recording didn’t start. ${plainError(error, 'microphone')}`));
  }, [player]);

  // Leaving Now Playing mid-recording throws the recording away and frees the microphone.
  useEffect(() => {
    gone.current = false;
    return () => {
      gone.current = true;
      live.current?.cancel();
    };
  }, []);

  useEffect(() => {
    if (!recording) return;
    const begun = Date.now();
    const timer = window.setInterval(() => setElapsed((Date.now() - begun) / 1000), 250);
    return () => window.clearInterval(timer);
  }, [recording]);

  const close = () => {
    setRecording(null);
    if (resumeAfter.current && !player.playing) player.toggle();
    onDone();
  };

  const cancel = () => {
    live.current = null;
    recording?.cancel();
    close();
  };

  const stop = async () => {
    if (!recording) return;
    live.current = null;
    try {
      setRecorded(await recording.stop());
      setRecording(null);
    } catch (error) {
      setRecording(null);
      setProblem(plainError(error, 'microphone'));
    }
  };

  const save = async () => {
    if (!recorded) return;
    const text = words.trim();
    try {
      await data.addMargin({
        id: newId(), episodeId, atSeconds: at, createdAt: new Date().toISOString(), voice: recorded, ...(text && { text }),
      });
      toast(`Voice Margin saved at ${formatClock(at)}.${text ? '' : ' It has no words, so it stays out of shared files.'}`);
    } catch (error) {
      toast(`The voice Margin wasn’t saved: ${plainError(error)}`, 'problem');
    }
    close();
  };

  if (problem) {
    return (
      <div className="composer composer-recording" aria-live="polite">
        <p className="problem" role="alert">
          <span className="toast-mark" aria-hidden="true">!</span>
          {problem}
        </p>
        <div className="composer-actions">
          <button type="button" className="button" onClick={close}>
            Close
          </button>
          <button
            type="button"
            className="button button-primary"
            onClick={() => {
              if (resumeAfter.current && !player.playing) player.toggle();
              onWriteInstead();
            }}
          >
            Write it instead
          </button>
        </div>
      </div>
    );
  }

  if (recorded) {
    // The iPhone app shares a voice Margin only with words (a transcript), and the web app has no speech
    // recognition, so the listener types a few. Optional: without them the Margin stays here.
    return (
      <form
        className="composer"
        onSubmit={(event) => {
          event.preventDefault();
          void save();
        }}
      >
        <label htmlFor="voice-words">Words to go with your voice Margin at {formatClock(at)}</label>
        <p className="muted composer-hint" id="voice-words-hint">
          Friends read these alongside your voice. A voice Margin is shared only with words.
        </p>
        <textarea id="voice-words" aria-describedby="voice-words-hint" rows={2} value={words} onChange={(event) => setWords(event.target.value)} />
        <div className="composer-actions">
          <button type="button" className="button" onClick={close}>
            Discard
          </button>
          <button type="submit" className="button button-primary">
            Save Margin
          </button>
        </div>
      </form>
    );
  }

  return (
    <div className="composer composer-recording">
      {/* Announced once when recording starts; the running clock is not a live region, so a screen
          reader isn't interrupted every second. */}
      <p className="recording-line" role="status">
        <span className="rec-dot" aria-hidden="true" />
        {recording ? 'Recording' : 'Starting the microphone…'}
        {recording && (
          <span className="recording-clock" aria-hidden="true">
            {formatClock(elapsed)} so far
          </span>
        )}
      </p>
      <p className="muted">Your Margin goes at {formatClock(at)} in the episode.</p>
      <div className="composer-actions">
        <button type="button" className="button" onClick={cancel}>
          Cancel
        </button>
        <button type="button" className="button button-primary" disabled={!recording} onClick={() => void stop()}>
          <StopIcon />
          Stop
        </button>
      </div>
    </div>
  );
}

export function MiniPlayer({ onOpen }: { onOpen: () => void }) {
  const player = usePlayer();
  if (!player.episode) return null;
  return (
    <div className="mini-player">
      <span className="mini-progress" aria-hidden="true">
        <span style={{ width: `${timelineFraction(player.time, player.duration) * 100}%` }} />
      </span>
      <button type="button" className="mini-open" onClick={onOpen} aria-label={`Open Now Playing: ${player.episode.title}`}>
        <span className="mini-title">{player.episode.title}</span>
        <span className="mini-time">{formatClock(player.time)}</span>
      </button>
      <button type="button" className="icon-button" aria-label={player.playing ? 'Pause' : 'Play'} onClick={player.toggle}>
        {player.playing ? <PauseIcon /> : <PlayIcon />}
      </button>
    </div>
  );
}
