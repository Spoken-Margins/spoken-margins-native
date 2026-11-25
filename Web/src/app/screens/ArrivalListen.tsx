// The card a friend's browser shows for Margins on something it can't play (#5265): an article, a PDF, a book or a
// pasted text, or an episode or recording with no audio. It lists the sender's Margins with the source's words at each,
// plays them here on one tap (the source's words first, then the Margin), and gives one next step: the iPhone app,
// which plays them in place and lets the friend answer. Every word comes from logic/arrival-card.ts.
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { PlayIcon } from '../icons.tsx';
import { cardSounds, type CardSounds } from '../arrival-run-effects.ts';
import {
  CLIP_FAILED,
  NEXT_STEP_HEADING,
  cardMargins,
  cardName,
  cardWords,
  finishedLine,
  hearButton,
  hearOneLabel,
  hintLine,
  noMarginsLine,
  oneDoneLine,
  rowPlace,
  rowWords,
  runSteps,
  statusLine,
  waitingLine,
  welcomeLine,
  type CardMargin,
  type CardOrigin,
  type CardPhase,
} from '../logic/arrival-card.ts';
import { runMargins, type MarginRunProgress, type Stoppable } from '../logic/arrival-run.ts';
import { GET_APP_LINK, arrivalFacts, readingNote, readsAloud, senderName } from '../logic/arrival.ts';
import { webAddress } from '../logic/playability.ts';
import type { PacketRead } from '../ports.ts';
import { usePlayer } from '../player.tsx';
import { LeadInLine } from './MarginsTab.tsx';

export interface ArrivalListenProps {
  read: PacketRead;
  origin: CardOrigin;
  /** Whether the card offers the iPhone app (not inside the Android app or on an Android browser). */
  iphoneStep: boolean;
  /** The link's expiry line, for a link; none for a file. */
  footer?: string;
  /** Where the report link goes, for a link. */
  reportHref?: string;
  /** Whether the way to the web Library shows from the start: the Library holds something, or this is a file. */
  libraryFirst: boolean;
  /**
   * For an episode or recording (timed Margins): stores the packet in the web Library, as the Play path does, and says
   * which stored Margin each of the packet's Margins became, so the card can mark the ones heard. Called once.
   */
  store?: () => { saved: Promise<void>; storedIds: ReadonlyMap<string, string> };
  /** Margin ids (the packet's) whose stored copy is already heard. */
  heardBefore: ReadonlySet<string>;
  /** Marks a stored Margin heard. */
  setHeard: (storedId: string) => Promise<void>;
  /** The way to the web Library: closes the card onto the Library once `saved` (when given) settles. */
  onLibrary: (saved?: Promise<void>) => void;
}

type Run =
  | { state: 'ready' }
  | { state: 'playing'; index: number; phase: CardPhase; only: boolean }
  | { state: 'waiting'; index: number }
  /** `again`: the whole run ended, so the button reads "Hear them again"; a row's own Hear leaves it as it was. */
  | { state: 'finished'; line: string; again: boolean };

export function ArrivalListen(props: ArrivalListenProps) {
  const { read, origin, iphoneStep } = props;
  const player = usePlayer();
  const sender = read.sender;
  const who = senderName(sender);
  const address = webAddress(read.episode.pageUrl);
  const words = cardWords(read, who, origin, address !== undefined);
  const cards = useMemo(() => cardMargins(read, origin), [read, origin]);
  const steps = useMemo(() => runSteps(cards, words, read.episode.title, sender), [cards, words.noun, words.namedWords, read.episode.title, sender]);
  const facts = arrivalFacts(sender, cards.map((c) => c.margin), { noun: words.noun, place: words.place });
  const minutes = read.episode.durationSeconds ? Math.max(1, Math.round(read.episode.durationSeconds / 60)) : undefined;
  const subtitle = [read.episode.showTitle ?? read.episode.publisher, minutes ? `${minutes} min` : undefined].filter(Boolean).join(' · ');

  const [run, setRun] = useState<Run>({ state: 'ready' });
  const [heard, setHeardIds] = useState<ReadonlySet<string>>(() => new Set(props.heardBefore));
  const [failed, setFailed] = useState<ReadonlySet<string>>(() => new Set());
  const [stored, setStored] = useState(false);
  const handle = useRef<Stoppable | undefined>(undefined);
  const runId = useRef(0);
  const element = useRef<HTMLAudioElement | undefined>(undefined);
  const sounds = useRef<CardSounds | undefined>(undefined);
  const storing = useRef<{ saved: Promise<void>; storedIds: ReadonlyMap<string, string> } | undefined>(undefined);
  const startedHere = useRef(new Set<string>());
  const primary = useRef<HTMLButtonElement>(null);
  const rowsRef = useRef<HTMLOListElement>(null);

  const soundsNow = useCallback((): CardSounds => {
    element.current ??= new Audio();
    sounds.current ??= cardSounds(element.current);
    return sounds.current;
  }, []);

  useEffect(() => {
    primary.current?.focus();
    return () => {
      runId.current += 1;
      handle.current?.stop();
    };
  }, []);

  /** Episode kinds keep their Margins in the web Library, as Keep did: stored once, on the first Hear or the Library. */
  const storeOnce = useCallback(() => {
    if (!props.store) return undefined;
    storing.current ??= props.store();
    setStored(true);
    return storing.current;
  }, [props.store]);

  /** A Margin started sounding: "Heard" on its row, and on its stored copy once the write has landed. */
  const markHeard = useCallback(
    (card: CardMargin) => {
      const id = card.margin.id;
      startedHere.current.add(id);
      setHeardIds((h) => (h.has(id) ? h : new Set([...h, id])));
      const writes = storing.current;
      if (!writes) return;
      void writes.saved
        .then(() => {
          const storedId = writes.storedIds.get(id);
          if (storedId) return props.setHeard(storedId);
          return undefined;
        })
        .catch(() => undefined);
    },
    [props.setHeard],
  );

  const stop = useCallback(() => {
    runId.current += 1;
    handle.current?.stop();
    handle.current = undefined;
    setRun({ state: 'ready' });
  }, []);

  const start = useCallback(
    (from: number, only: boolean) => {
      handle.current?.stop();
      const mine = ++runId.current;
      const fx = soundsNow();
      // Inside the tap: the clip element and the voice are readied before anything is awaited.
      fx.prime();
      if (player.playing) player.pause();
      storeOnce();
      const onProgress = (p: MarginRunProgress) => {
        if (mine !== runId.current) return;
        const card = cards[p.index];
        if (p.phase === 'context') setRun({ state: 'playing', index: p.index, phase: 'context', only });
        else if (p.phase === 'margin') {
          const m = card.margin;
          setRun({ state: 'playing', index: p.index, phase: m.voice ? 'voice' : readsAloud(m) ? 'written' : 'shown', only });
        } else if (p.phase === 'failed') setFailed((f) => new Set([...f, card.margin.id]));
        else if (p.phase === 'blocked') {
          handle.current = undefined;
          setRun({ state: 'waiting', index: p.index });
        } else if (p.phase === 'done') {
          handle.current = undefined;
          const last = cards[p.index] ?? cards[cards.length - 1];
          const again = !only || cards.length === 1;
          setRun({ state: 'finished', again, line: only ? oneDoneLine(p.index, cards.length, last, sender, iphoneStep) : finishedLine(last, sender, iphoneStep) });
          if (again) primary.current?.focus();
        }
      };
      handle.current = runMargins(steps, fx, onProgress, {
        startAt: from,
        only,
        onStarted: (index) => {
          if (mine === runId.current) markHeard(cards[index]);
        },
      });
    },
    [cards, steps, sender, iphoneStep, player, soundsNow, storeOnce, markHeard],
  );

  const playingIndex = run.state === 'playing' ? run.index : undefined;
  // The row that is playing is scrolled into view.
  useLayoutEffect(() => {
    if (playingIndex === undefined) return;
    const row = rowsRef.current?.children[playingIndex] as HTMLElement | undefined;
    row?.scrollIntoView?.({ block: 'nearest' });
  }, [playingIndex]);

  const onPrimary = () => {
    if (run.state === 'playing') stop();
    else if (run.state === 'waiting') start(run.index, false);
    else start(0, false);
  };

  const status = (() => {
    if (run.state === 'playing') {
      const card = cards[run.index];
      return statusLine(run.phase, card, run.index, cards.length, words, sender);
    }
    if (run.state === 'waiting') return waitingLine(who);
    if (run.state === 'finished') return run.line;
    return undefined;
  })();
  const readingCard = run.state === 'playing' && run.phase === 'written' ? cards[run.index] : undefined;
  const primaryLabel = hearButton(who, run.state === 'playing' ? 'playing' : run.state === 'finished' && run.again ? 'finished' : 'ready');
  const showLibrary = props.libraryFirst || stored;
  const none = cards.length === 0;

  const toLibrary = () => {
    stop();
    props.onLibrary(storeOnce()?.saved);
  };

  return (
    <div className="arrival arrival-preview arrival-listen" role="dialog" aria-modal="true" aria-labelledby="arrival-title" data-testid="arrival-listen">
      <div className="arrival-body">
        <p className="arrival-from">
          <span className="arrival-avatar" aria-hidden="true">
            {facts.initial}
          </span>
          <span>From {who}</span>
        </p>
        <h1 id="arrival-title" className="arrival-title">
          {read.episode.title}
        </h1>
        {subtitle && <p className="arrival-sub">{subtitle}</p>}
        {words.sourceLabel && address && (
          <p className="arrival-source">
            <a href={address} target="_blank" rel="noopener noreferrer">
              {words.sourceLabel}
            </a>
          </p>
        )}
        <h2 className="arrival-welcome">{welcomeLine(who)}</h2>
        {none ? (
          <p className="arrival-text">{noMarginsLine(origin)}</p>
        ) : (
          <>
            <p className="arrival-count">{facts.countLine}</p>
            <p className="arrival-explain">{facts.explanation}</p>
            <div role="status" aria-live="polite" className="arrival-hint listen-status" data-testid="listen-status">
              <p>{status ?? hintLine(cards)}</p>
              {readingCard && <p className="listen-note">{readingNote(readingCard.margin)}</p>}
            </div>
            <ol className="listen-rows" ref={rowsRef}>
              {cards.map((card, index) => (
                <ListenRow
                  key={card.margin.id}
                  card={card}
                  sender={sender}
                  playing={playingIndex === index}
                  heard={heard.has(card.margin.id)}
                  failed={failed.has(card.margin.id)}
                  onHear={() => start(index, true)}
                />
              ))}
            </ol>
            {iphoneStep && (
              <section className="listen-next" aria-labelledby="listen-next-title">
                <h2 id="listen-next-title">{NEXT_STEP_HEADING}</h2>
                <p>{words.nextStep}</p>
                <p>{words.again}</p>
                <p>
                  <a className="button arrival-play" href={GET_APP_LINK.href} target="_blank" rel="noopener noreferrer">
                    {GET_APP_LINK.text}
                  </a>
                </p>
              </section>
            )}
          </>
        )}
        <footer className="arrival-foot">
          {props.footer && <p>{props.footer}</p>}
          {props.reportHref && (
            <p>
              <a href={props.reportHref} target="_blank" rel="noopener noreferrer">
                Report this link
              </a>
            </p>
          )}
          {showLibrary && (
            <p>
              <button type="button" className="link-button" onClick={toLibrary}>
                Go to your web Library
              </button>
            </p>
          )}
        </footer>
      </div>
      {!none && (
        <div className="arrival-starts">
          <button ref={primary} type="button" className="button button-primary arrival-play" onClick={onPrimary}>
            {run.state !== 'playing' && <PlayIcon size={22} />}
            {primaryLabel}
          </button>
        </div>
      )}
    </div>
  );
}

function ListenRow({ card, sender, playing, heard, failed, onHear }: { card: CardMargin; sender: string | undefined; playing: boolean; heard: boolean; failed: boolean; onHear: () => void }) {
  const [expanded, setExpanded] = useState(false);
  const [cut, setCut] = useState(false);
  const textRef = useRef<HTMLParagraphElement>(null);
  const { words, voiceLine } = rowWords(card.margin);
  useLayoutEffect(() => {
    const el = textRef.current;
    if (el && !expanded) setCut(el.scrollHeight > el.clientHeight + 2);
  }, [words, expanded]);
  const name = cardName(card, sender);
  const place = rowPlace(card);
  const state = playing ? 'playing' : heard ? 'heard' : 'unheard';
  return (
    <li className={`mc-row mc-${state}`} data-testid="listen-row" aria-label={`${name}’s Margin${place ? ` ${place}` : ''}`}>
      <p className="mc-head">
        <span className="mc-who">{name}</span>
        {place && <span>{place}</span>}
        {playing && <span className="mc-playtag">Playing</span>}
        {!playing && heard && <span className="mc-heardtag">Heard</span>}
      </p>
      {card.context && <LeadInLine text={card.context} />}
      {words === null ? (
        <p className="mc-text">{voiceLine}</p>
      ) : (
        <>
          <p ref={textRef} className={`mc-text${expanded ? ' is-expanded' : ''}`}>
            {words}
          </p>
          {voiceLine && <p className="listen-voice">{voiceLine}</p>}
        </>
      )}
      {failed && <p className="listen-failed">{CLIP_FAILED}</p>}
      <div className="mc-acts">
        {words !== null && (cut || expanded) && (
          <button type="button" className="mc-more" aria-expanded={expanded} onClick={() => setExpanded((e) => !e)}>
            {expanded ? 'See less' : 'See more'}
          </button>
        )}
        <button type="button" className="mc-start" aria-label={hearOneLabel(card, sender)} onClick={onHear}>
          <PlayIcon size={18} />
          Hear this one
        </button>
      </div>
    </li>
  );
}
