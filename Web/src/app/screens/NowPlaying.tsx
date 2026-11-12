import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from 'react';
import { formatClock } from '../../shared/clock.ts';
import type { Episode, Margin, Show } from '../../shared/model.ts';
import { capacitorBridge } from '../../sources/native-http.ts';
import { useData } from '../data.tsx';
import { downloadFile } from '../download.ts';
import { useRestoreFocus } from '../focus.ts';
import { BackIcon, DownIcon, DownloadIcon, ForwardIcon, MicIcon, PauseIcon, PenIcon, PlayIcon, ShareIcon, SkipIcon, StopIcon } from '../icons.tsx';
import { cueFor, friendMargins, leading, possessive, readsAloud, senderName, speakingLine } from '../logic/arrival.ts';
import { landingOffer, type Landing } from '../logic/import.ts';
import { nextSpeed, timelineFraction, timelinePosts } from '../logic/library.ts';
import {
  candidateLabel, nothingPickedReason, pickedMargins, preselected, replyBackOffer, savedFileNextStep, savedMarginCard,
} from '../logic/reply-back.ts';
import { plainError } from '../logic/messages.ts';
import { sendFile, sendRefusedNextStep } from '../logic/share-send.ts';
import { NotSavedError } from '../logic/storage.ts';
import { shareNativePacket } from '../logic/native-packets.ts';
import { SKIP_SECONDS, usePlayer } from '../player.tsx';
import type { RecordedVoice, VoiceRecording } from '../ports.ts';
import { services } from '../services.ts';
import { useUi } from '../ui.tsx';
import { voicePlaceholder } from '../../shared/placeholder.ts';
import { isPlaceholder, prefillOverPlaceholder, voiceMarginOnStop, withWords } from '../logic/voice-words.ts';
import { TranscriptionNote, useTranscription } from '../transcription.tsx';
import { MarginRow } from './Margins.tsx';

function newId(): string {
  return crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

/**
 * A file just opened here, and the browser wouldn't start it without a tap: one clear button to hear it from the
 * first Margin (#3039). It goes once it plays.
 */
function LandingOffer({ landing }: { landing?: Landing }) {
  const player = usePlayer();
  // The landing that has played: a new file's landing offers again.
  const [playedLanding, setPlayedLanding] = useState<Landing>();
  const playingLanding = Boolean(landing && player.playing && player.episode?.id === landing.episodeId);
  useEffect(() => {
    if (playingLanding) setPlayedLanding(landing);
  }, [playingLanding, landing]);
  const label = landingOffer(landing, {
    episodeId: player.episode?.id,
    playing: player.playing,
    played: playedLanding !== undefined && playedLanding === landing,
    marginArrived: player.arrived !== undefined,
    loading: player.loading,
  });
  if (!landing || !label) return null;
  return (
    <p className="landing-offer">
      <button
        type="button"
        className="button button-primary"
        onClick={() => {
          player.seek(landing.at);
          player.toggle();
        }}
      >
        <PlayIcon size={18} />
        {label}
      </button>
    </p>
  );
}

/**
 * A friend's Margin that has just come up in the episode (#3058): who is speaking and which of how many, then the
 * words of a written one, the words and a note for a spoken one. A written Margin is read aloud by this browser's own
 * voice, and the card says so, so a synthetic voice never passes for the sender's. When the browser wouldn't start the
 * spoken clip, the episode waits here with a Play for it.
 */
function ArrivedMargin({ margins }: { margins: readonly Margin[] }) {
  const player = usePlayer();
  const arrived = player.arrived;
  if (!arrived) return null;
  const { margin, blocked } = arrived;
  const words = margin.text ?? (margin.voice ? 'A spoken Margin' : '');
  const line = speakingLine(margin, margins, friendMargins(margins)[0]?.author);
  const voiced = readsAloud(margin) && typeof window !== 'undefined' && 'speechSynthesis' in window;
  return (
    <div className="arrived-margin" role="status" data-testid="arrived-margin">
      <p className="arrived-margin-head">
        <strong>{line.title}</strong>
        {line.position && <span> · {line.position}</span>}
      </p>
      <p className="arrived-margin-text">
        {margin.author ? <strong>{margin.author}</strong> : null} {formatClock(margin.atSeconds)}: {words}
      </p>
      {voiced && <p className="arrived-margin-note">Your device’s voice is reading {possessive(senderName(margin.author))} words.</p>}
      {blocked && (
        <button type="button" className="button button-primary" onClick={player.playArrived}>
          <PlayIcon size={18} />
          Play {margin.author ? `${leading(possessive(senderName(margin.author)))}` : 'this'} Margin
        </button>
      )}
    </div>
  );
}

/**
 * The countdown to the next Margin a friend left, always in reach while the episode plays (owner, 2026-11-02: "it is
 * clear that there's a countdown to the friend's margins" and "obvious what the user can do to skip directly to the
 * margin"). The first Skip lands 20 seconds before it, so the episode's own lead-in is heard; inside the lead-in the
 * Skip goes straight to the Margin. After the last, it points at the Margin buttons below, which are how to answer.
 */
function MarginCue({ margins, saved }: { margins: readonly Margin[]; /** The listener just saved a Margin (2026-11-06 card). */ saved: boolean }) {
  const player = usePlayer();
  const sender = friendMargins(margins)[0]?.author;
  const cue = cueFor(margins, player.time, sender, { failed: player.failed, heardWithoutEpisode: player.withoutEpisode === 'done' });
  // While this card says the episode can't play, the player shows no toast of its own for it (#3356).
  // A Margin card on top of it hides the sentence, unless the Margins are playing without the episode (it was said first).
  const sayingFailure = (cue?.kind === 'unplayable' || cue?.kind === 'unplayable-done') && (!player.arrived || player.withoutEpisode !== 'idle');
  const { registerFailureCard } = player;
  // A layout effect: the card and the player's notice are settled before the screen paints, so never both.
  useLayoutEffect(() => (sayingFailure ? registerFailureCard() : undefined), [sayingFailure, registerFailureCard]);
  if (player.arrived) return null;
  // After a save on a friend's item: what Share does with it, in place of the countdown or "That was X's last Margin"
  // until a friend's Margin plays (2026-11-06).
  const card = saved ? savedMarginCard(margins, cue) : undefined;
  if (card) {
    return (
      <section className="margin-cue" aria-label="Your Margin is saved" data-testid="margin-cue">
        <p className="margin-cue-line">
          <strong>{card.sentence}</strong>
        </p>
      </section>
    );
  }
  if (!cue) return null;
  if (cue.kind === 'unplayable' || cue.kind === 'unplayable-done') {
    // The episode can't play here (#3356): one sentence, and for the first, one button. No countdown, no Skip.
    return (
      <section className="margin-cue" aria-label={`${leading(possessive(cue.who))} Margins`} data-testid="margin-cue">
        <p className="margin-cue-line">
          <strong>{cue.sentence}</strong>
        </p>
        {cue.kind === 'unplayable' && (
          <button type="button" className="button button-primary margin-cue-skip" onClick={player.playWithoutEpisode}>
            <PlayIcon size={18} />
            {cue.button}
          </button>
        )}
      </section>
    );
  }
  if (cue.kind === 'after-last') {
    return (
      <section className="margin-cue" aria-label={`${cue.lead}’s Margins`} data-testid="margin-cue">
        <p className="margin-cue-line">
          <strong>That was {cue.who}’s last Margin.</strong>
        </p>
        <p className="margin-cue-note">To answer {cue.who}, add a Margin of your own: write one or record one below.</p>
      </section>
    );
  }
  return (
    <section className={`margin-cue${cue.leadIn ? ' margin-cue-lead-in' : ''}`} aria-label={`Next Margin from ${senderName(sender)}`} data-testid="margin-cue">
      <p className="margin-cue-line">
        <span aria-hidden="true">{cue.label}</span>
        <span className="margin-cue-clock" aria-hidden="true" data-testid="margin-cue-clock">
          {cue.clock}
        </span>
        <span className="visually-hidden">{cue.spoken}</span>
      </p>
      {cue.leadIn && (
        <div className="margin-cue-meter" aria-hidden="true">
          <i style={{ width: `${cue.leadInLeft * 100}%` }} />
        </div>
      )}
      <button
        type="button"
        className="button button-primary margin-cue-skip"
        onClick={() => {
          player.seek(cue.skip.to);
          if (!player.playing) player.toggle();
        }}
      >
        <SkipIcon />
        {cue.skip.label}
      </button>
    </section>
  );
}

export function NowPlaying({ onClose, landing }: { onClose: () => void; landing?: Landing }) {
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
  // The listener's own Margins on this episode: a rise while a composer was open means a Margin was saved.
  const ownCount = () => data.margins.filter((m) => m.episodeId === episode?.id && !m.author).length;
  const ownAtOpen = useRef<number | undefined>(undefined);
  const composerOpen = composer !== null;
  // Checked after the render that closes the composer, so the saved Margin is already in `data.margins`.
  useEffect(() => {
    if (composerOpen) {
      ownAtOpen.current ??= ownCount();
      return;
    }
    if (ownAtOpen.current !== undefined && ownCount() > ownAtOpen.current) setSavedCard(true);
    ownAtOpen.current = undefined;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [composerOpen]);
  // The saved card stays until a friend's Margin plays (the player's `arrived`).
  const [savedCard, setSavedCard] = useState(false);
  const arrivedNow = player.arrived !== undefined;
  useEffect(() => {
    if (arrivedNow) setSavedCard(false);
  }, [arrivedNow]);
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
          {/* Speed sits on the right: on an iPhone the volume indicator slides in over the left edge (#3037). The
              spacer on the left keeps Play centred. */}
          <span className="speed-button-spacer" aria-hidden="true" />
          <button type="button" className="icon-button transport-skip" aria-label={`Back ${SKIP_SECONDS} seconds`} onClick={() => player.skip(-SKIP_SECONDS)}>
            <BackIcon />
          </button>
          <button type="button" className="play-button" aria-label={player.playing ? 'Pause' : 'Play'} onClick={player.toggle}>
            {player.playing ? <PauseIcon size={30} /> : <PlayIcon size={30} />}
          </button>
          <button type="button" className="icon-button transport-skip" aria-label={`Forward ${SKIP_SECONDS} seconds`} onClick={() => player.skip(SKIP_SECONDS)}>
            <ForwardIcon />
          </button>
          <button type="button" className="speed-button" aria-label={`Speed ${player.rate} times. Change speed`} onClick={() => player.setRate(nextSpeed(player.rate))}>
            {player.rate}×
          </button>
        </div>
        {player.loading && <p className="muted np-status">Loading audio…</p>}
        <LandingOffer landing={landing} />
        <MarginCue margins={margins} saved={savedCard} />
        <ArrivedMargin margins={margins} />

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
              <ShareMargins key={episode.id} episode={episode} margins={margins} show={show} />
            </>
          )}
        </section>
      </div>
    </div>
  );
}

/** When this page opened: a Margin made since is one the listener made while listening to the friend's (#3784). */
const PAGE_OPENED_AT = Date.now();

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
  // After a friend's Margins, Share offers "Send replies to <friend>" (#2168, as the app's #3221): the replies and the
  // Margins made since this page opened picked, older notes unpicked, the friend's own never listed. With no offer Share is as before.
  const offer = replyBackOffer(margins);
  // The listener's own changes sit over the starting picks, so a reply made while this is open starts picked too.
  const [changed, setChanged] = useState<Readonly<Record<string, boolean>>>({});
  const starting = offer ? preselected(offer, PAGE_OPENED_AT) : new Set<string>();
  const picked = new Set([...(offer?.candidates ?? [])].map((m) => m.id).filter((id) => changed[id] ?? starting.has(id)));
  const toWrite = offer ? pickedMargins(offer, picked) : margins;
  const nothingPicked = toWrite.length === 0;
  // Greyed buttons say why (#3784), and point at the sentence so a screen reader reads it too.
  const whyNot = nothingPickedReason(offer, toWrite.length);
  // What to do with a saved file, kept on the panel: a toast is gone in six seconds.
  const [nextStep, setNextStep] = useState<string>();
  // The browser refused its share sheet (#4095): Send is replaced by the sentence and Save as a file.
  const [sendRefused, setSendRefused] = useState(false);

  const share = async (how: 'save' | 'send') => {
    setBusy(true);
    try {
      const written = await services.packets.writePacket(episode, toWrite, show);
      if (bridge) {
        if ((await shareNativePacket(bridge, written.bytes, written.fileName, episode.title)) === 'cancelled') return;
        const count = written.included.length === 1 ? '1 Margin' : `${written.included.length} Margins`;
        toast(`Shared ${count} as ${written.fileName}.${written.notice ? ` ${written.notice}` : ''}`);
        return;
      }
      const file = new File([written.bytes as BlobPart], written.fileName, { type: written.mimeType });
      if (how === 'send') {
        // The browser may refuse the sheet (#4095); then Send goes away and Save as a file says what to do instead.
        const outcome = await sendFile((data) => navigator.share(data), file, episode.title);
        if (outcome === 'cancelled') return;
        if (outcome === 'refused') {
          // The sentence sits on the panel, whose status region announces it; the focused Send is about to go, so focus moves to Save.
          setSendRefused(true);
          setNextStep(sendRefusedNextStep(offer));
          requestAnimationFrame(() => document.getElementById('share-save')?.focus());
          return;
        }
      } else {
        downloadFile(file);
      }
      const count = written.included.length === 1 ? '1 Margin' : `${written.included.length} Margins`;
      const next = how === 'save' && offer ? savedFileNextStep(offer) : undefined;
      setNextStep(next);
      toast(`${how === 'save' ? 'Saved' : 'Shared'} ${count} as ${written.fileName}.${written.notice ? ` ${written.notice}` : ''}${next ? ` ${next}` : ''}`);
    } catch (error) {
      toast(`These Margins weren’t shared. ${plainError(error)}`, 'problem');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="share-margins">
      {offer && (
        <fieldset className="reply-back">
          <legend>{offer.title}</legend>
          <ul className="reply-back-list">
            {offer.candidates.map((margin) => (
              <li key={margin.id}>
                <label>
                  <input
                    type="checkbox"
                    checked={picked.has(margin.id)}
                    onChange={(event) => setChanged({ ...changed, [margin.id]: event.target.checked })}
                  />
                  <span className="margin-time">{formatClock(margin.atSeconds)}</span>
                  <span className="margin-text">{candidateLabel(margin, formatClock)}</span>
                </label>
              </li>
            ))}
          </ul>
        </fieldset>
      )}
      <p className="muted">Share them as a file. Your friend opens it in Spoken Margins and hears each one at its moment.</p>
      {/* The live region stays mounted and only its words change, so a screen reader announces them. */}
      <div role="status" id="share-why-not">
        {whyNot ? <p className="muted">{whyNot}</p> : nextStep ? <p className="muted">{nextStep}</p> : null}
      </div>
      <div className="share-actions">
        {bridge ? (
          <button type="button" className="button" disabled={busy || nothingPicked} aria-describedby={whyNot ? 'share-why-not' : undefined} onClick={() => void share('send')}>
            <ShareIcon />
            Save or send
          </button>
        ) : (
          <button type="button" id="share-save" className="button" disabled={busy || nothingPicked} aria-describedby={whyNot || nextStep ? 'share-why-not' : undefined} onClick={() => void share('save')}>
            <DownloadIcon />
            Save as a file
          </button>
        )}
        {!bridge && sendable && !sendRefused && (
          <button type="button" className="button" disabled={busy || nothingPicked} aria-describedby={whyNot ? 'share-why-not' : undefined} onClick={() => void share('send')}>
            <ShareIcon />
            Send
          </button>
        )}
      </div>
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
      // A storage failure has already said what wasn't saved. The words stay in the box to try again.
      if (!(error instanceof NotSavedError)) toast(`The Margin wasn’t saved: ${plainError(error)}`, 'problem');
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
  // When the recording stopped: the Margin's createdAt, and the day its placeholder words name (#3025).
  const [recordedAt, setRecordedAt] = useState<Date>();
  const title = data.episodes.find((e) => e.id === episodeId)?.title;
  // The same words the packet writer gives a voice Margin saved without any, so what the listener sees is what's sent.
  const placeholder = recordedAt ? voicePlaceholder({ atSeconds: at, ...(title !== undefined && { title }), recordedAt }) : '';
  const placeholderRef = useRef(placeholder);
  placeholderRef.current = placeholder;
  const [words, setWords] = useState('');
  // Whether the listener has typed in the words box since the recording stopped: the transcript never overwrites that.
  const edited = useRef(false);
  const wordsRef = useRef(words);
  wordsRef.current = words;
  const [prefilled, setPrefilled] = useState(false);
  const [suggestion, setSuggestion] = useState<string>();
  // Stop saves the Margin (#3038). `saved` is what is stored now; the words box then updates it.
  const [saving, setSaving] = useState<'saving' | 'saved' | 'not-saved'>('saving');
  const saved = useRef<Margin | undefined>(undefined);
  const marginId = useRef(newId());
  // Every write for this Margin runs in order, so an Undo can't land before the save it undoes.
  const writes = useRef<Promise<unknown>>(Promise.resolve());
  const wordsTimer = useRef<number | undefined>(undefined);
  const showingPlaceholder = recorded !== undefined && isPlaceholder(words, placeholder);

  /** Puts the box's words on the saved Margin, when they change it. */
  const storeWords = (value: string) => {
    window.clearTimeout(wordsTimer.current);
    wordsTimer.current = undefined;
    writes.current = writes.current.then(async () => {
      const current = saved.current;
      if (!current) return;
      const next = withWords(current, value, placeholderRef.current);
      if (!next) return;
      saved.current = next;
      try {
        await data.addMargin(next);
      } catch (error) {
        saved.current = current;
        if (!(error instanceof NotSavedError)) toast(`The words weren’t saved: ${plainError(error)}`, 'problem');
      }
    });
    return writes.current;
  };
  const storeWordsRef = useRef(storeWords);
  storeWordsRef.current = storeWords;

  const transcription = useTranscription(recorded?.blob, (transcript) => {
    const result = prefillOverPlaceholder(wordsRef.current, edited.current, transcript, placeholderRef.current);
    if (result.words !== wordsRef.current) {
      setWords(result.words);
      setPrefilled(true);
      void storeWordsRef.current(result.words);
    }
    setSuggestion(result.suggestion);
  });
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

  // Leaving Now Playing mid-recording throws the recording away and frees the microphone. Leaving after Stop keeps
  // the saved Margin, with whatever was typed in the words box.
  useEffect(() => {
    gone.current = false;
    return () => {
      gone.current = true;
      live.current?.cancel();
      if (wordsTimer.current !== undefined) void storeWordsRef.current(wordsRef.current);
    };
  }, []);

  useEffect(() => {
    if (!recording) return;
    const begun = Date.now();
    const timer = window.setInterval(() => setElapsed((Date.now() - begun) / 1000), 250);
    return () => window.clearInterval(timer);
  }, [recording]);

  const resume = () => {
    if (resumeAfter.current && !player.playing) player.toggle();
    resumeAfter.current = false;
  };

  const close = () => {
    setRecording(null);
    resume();
    onDone();
  };

  const cancel = () => {
    live.current = null;
    recording?.cancel();
    close();
  };

  /** Saves the recording as a new Margin, with the box's words if they are the listener's or a transcript's. */
  const saveNew = (voice: RecordedVoice, stoppedAt: Date) => {
    setSaving('saving');
    writes.current = writes.current.then(async () => {
      const bare = voiceMarginOnStop({ id: marginId.current, episodeId, atSeconds: at, recordedAt: stoppedAt, voice });
      const margin = withWords(bare, wordsRef.current, placeholderRef.current) ?? bare;
      try {
        await data.addMargin(margin);
        saved.current = margin;
        setSaving('saved');
        // The episode carries on: the Margin is kept, and the words can be changed while it plays.
        resume();
      } catch (error) {
        // The recording stays here, so the listener can free space or back up and then save it again.
        setSaving('not-saved');
        if (!(error instanceof NotSavedError)) toast(`The voice Margin wasn’t saved: ${plainError(error)}`, 'problem');
      }
    });
  };

  const stop = async () => {
    if (!recording) return;
    live.current = null;
    try {
      const voice = await recording.stop();
      const stoppedAt = new Date();
      setRecordedAt(stoppedAt);
      const initial = voicePlaceholder({ atSeconds: at, ...(title !== undefined && { title }), recordedAt: stoppedAt });
      placeholderRef.current = initial;
      // The words box starts with the placeholder; a transcript or the listener's own words replace it.
      if (!edited.current && wordsRef.current === '') {
        wordsRef.current = initial;
        setWords(initial);
      }
      setRecorded(voice);
      setRecording(null);
      saveNew(voice, stoppedAt);
    } catch (error) {
      setRecording(null);
      setProblem(plainError(error, 'microphone'));
    }
  };

  const done = async () => {
    await storeWords(wordsRef.current);
    close();
  };

  const undo = async () => {
    window.clearTimeout(wordsTimer.current);
    wordsTimer.current = undefined;
    // A recording that couldn't be saved is only thrown away.
    if (saving === 'not-saved') {
      close();
      return;
    }
    let removed = false;
    writes.current = writes.current.then(async () => {
      const current = saved.current;
      if (!current) {
        removed = true;
        return;
      }
      try {
        await data.deleteMargin(current.id);
        saved.current = undefined;
        removed = true;
      } catch (error) {
        if (!(error instanceof NotSavedError)) toast(`The voice Margin wasn’t removed: ${plainError(error)}`, 'problem');
      }
    });
    await writes.current;
    if (!removed) return;
    toast(`Voice Margin at ${formatClock(at)} removed.`);
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
    // Stop has saved the Margin (#3038). The iPhone app shares a voice Margin only with words, so the box starts with
    // placeholder words (#3025), shown muted; a transcript (transcription on) or the listener's own words replace
    // them, and each change goes on the saved Margin. Undo takes the Margin away again.
    return (
      <form
        className="composer"
        onSubmit={(event) => {
          event.preventDefault();
          if (saving === 'not-saved') saveNew(recorded, recordedAt ?? new Date());
          else void done();
        }}
      >
        <p className="saved-line" role="status" data-testid="voice-saved">
          {saving === 'saved' && (
            <>
              <span className="tag tag-status">Saved</span> Voice Margin at {formatClock(at)}.
            </>
          )}
          {saving === 'saving' && 'Saving your voice Margin…'}
          {saving === 'not-saved' && (
            <>
              <span className="tag tag-quiet">Not saved</span> Your recording is still here. Try again.
            </>
          )}
        </p>
        <label htmlFor="voice-words">Words to go with your voice Margin at {formatClock(at)}</label>
        <p className="muted composer-hint" id="voice-words-hint">
          {showingPlaceholder ? (
            <>
              <span className="placeholder-tag">Placeholder</span> Replace with your own words. Friends read them alongside your voice.
            </>
          ) : (
            'Friends read these alongside your voice. Changes are kept as you type.'
          )}
        </p>
        <textarea
          id="voice-words"
          aria-describedby="voice-words-hint"
          rows={2}
          value={words}
          placeholder={placeholder}
          className={showingPlaceholder ? 'words-placeholder' : undefined}
          data-placeholder={showingPlaceholder ? 'true' : undefined}
          onFocus={(event) => {
            // One tap and typing replaces the placeholder whole; the listener can still click to edit it instead.
            if (isPlaceholder(event.target.value, placeholder) && event.target.value) event.target.select();
          }}
          onChange={(event) => {
            edited.current = true;
            setWords(event.target.value);
            const value = event.target.value;
            window.clearTimeout(wordsTimer.current);
            wordsTimer.current = window.setTimeout(() => void storeWordsRef.current(value), 700);
          }}
          onBlur={() => {
            if (wordsTimer.current !== undefined) void storeWords(wordsRef.current);
          }}
        />
        <TranscriptionNote
          transcription={transcription}
          prefilled={prefilled}
          {...(suggestion !== undefined && { suggestion })}
          onUseSuggestion={() => {
            if (suggestion) {
              setWords(suggestion);
              void storeWords(suggestion);
            }
            setSuggestion(undefined);
            setPrefilled(true);
          }}
        />
        <div className="composer-actions">
          <button type="button" className="button" disabled={saving === 'saving'} onClick={() => void undo()}>
            {saving === 'not-saved' ? 'Discard' : 'Undo'}
          </button>
          <button type="submit" className="button button-primary" disabled={saving === 'saving'}>
            {saving === 'not-saved' ? 'Save Margin' : 'Done'}
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
      <p className="muted">Your Margin goes at {formatClock(at)} in the episode. Stop saves it.</p>
      <div className="composer-actions">
        <button type="button" className="button" onClick={cancel}>
          Cancel
        </button>
        <button type="button" className="button button-primary" disabled={!recording} onClick={() => void stop()}>
          <StopIcon />
          Stop and save
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
