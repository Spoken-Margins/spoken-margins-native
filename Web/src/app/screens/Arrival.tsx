// The page a share link opens (#2168, slice 4 of #3247): the friend's front door. It opens the sealed packet in this
// browser (the key is in the link's `#` part and never leaves it), shows who sent it, what it is and one Play, and
// that tap also starts the episode, so the browser allows sound. Then Now Playing takes over with the countdown to
// the sender's first Margin and a Skip. Every failure says what happened and one thing to do.
import { useCallback, useEffect, useRef, useState } from 'react';
import { PlayIcon } from '../icons.tsx';
import { PLAY_HINT, ARRIVAL_WORDS, arrivalFacts, possessive, senderName, type ArrivalFacts } from '../logic/arrival.ts';
import { UNNAMED_SENDER, placeImport } from '../logic/import.ts';
import { plainError } from '../logic/messages.ts';
import { ShareLinkError, openSharedPacket, type ParsedLink, type ShareLinkRef } from '../logic/share-link.ts';
import { NotSavedError } from '../logic/storage.ts';
import { useData } from '../data.tsx';
import type { PacketRead } from '../ports.ts';
import { usePlayer } from '../player.tsx';
import { RELAY_ORIGIN, services } from '../services.ts';
import { primeSpeech } from '../speech.ts';
import { useUi } from '../ui.tsx';

type State =
  | { status: 'opening' }
  | { status: 'failed'; message: string }
  | { status: 'ready'; read: PacketRead; facts: ArrivalFacts };

/** Words for a link that wouldn't open. A cut-off link and an unopenable key read the same: the friend re-copies it. */
function failureWords(error: unknown): string {
  if (error instanceof ShareLinkError) {
    switch (error.reason) {
      case 'damaged':
        return ARRIVAL_WORDS.cutOff;
      case 'expired':
        return ARRIVAL_WORDS.expired;
      case 'off':
        return ARRIVAL_WORDS.off;
      case 'offline':
        return ARRIVAL_WORDS.offline;
      default:
        return ARRIVAL_WORDS.server;
    }
  }
  return ARRIVAL_WORDS.unreadable;
}

/** The first sentence is the heading; what to do is the rest. */
function splitSentence(message: string): { head: string; rest: string } {
  const at = message.indexOf('. ');
  return at === -1 ? { head: message, rest: '' } : { head: message.slice(0, at + 1), rest: message.slice(at + 2) };
}

/** An address that is safe to offer as a tap: http or https only. */
function webAddress(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The link server is not the web app's own host in production (the app is at app.spokenmargins.com, the links at
 * spokenmargins.com), so the packet is read from the server this build was made for; with none set, from the address the
 * page was opened at, as the local stub does.
 */
function serverFor<T extends { origin: string }>(link: T): T {
  return RELAY_ORIGIN ? { ...link, origin: RELAY_ORIGIN } : link;
}

export function Arrival({ link, onDone }: { link: ParsedLink; onDone: (playing: boolean) => void }) {
  const data = useData();
  const player = usePlayer();
  const { toast } = useUi();
  const [state, setState] = useState<State>({ status: 'opening' });
  const [busy, setBusy] = useState(false);
  const started = useRef(false);
  const playRef = useRef<HTMLButtonElement>(null);
  const dataRef = useRef(data);
  dataRef.current = data;

  // Open the packet once storage is ready (so the episode can match the listener's own copy).
  useEffect(() => {
    if (started.current || !data.ready) return;
    started.current = true;
    if (link.kind !== 'link') {
      setState({ status: 'failed', message: ARRIVAL_WORDS.cutOff });
      return;
    }
    void (async () => {
      try {
        const bytes = await openSharedPacket(serverFor(link.link));
        const read = await services.packets.readPacket(bytes, 'shared.spokenmargins');
        setState({ status: 'ready', read, facts: arrivalFacts(read.sender, read.margins) });
      } catch (error) {
        setState({ status: 'failed', message: failureWords(error) });
      }
    })();
  }, [data.ready, link]);

  const failedRef = useRef<HTMLHeadingElement>(null);
  const heading = state.status === 'ready' ? `From ${state.facts.who}` : state.status === 'failed' ? splitSentence(state.message).head : 'Opening the Margins…';
  useEffect(() => {
    document.title = `${heading} · Spoken Margins`;
  }, [heading]);
  useEffect(() => {
    if (state.status === 'ready') playRef.current?.focus();
    // A failure is announced by moving focus to its sentence.
    if (state.status === 'failed') failedRef.current?.focus();
  }, [state.status]);

  /**
   * Places the packet's Margins and starts storing them. Not async: the caller must reach `player.open` in the same
   * call stack as the friend's tap, before anything is awaited, or Safari refuses to start the sound.
   */
  const store = useCallback((read: PacketRead) => {
    const current = dataRef.current;
    const placed = placeImport(read, current.shows, current.episodes, undefined, current.margins, { unnamedAuthor: UNNAMED_SENDER });
    const saved = (async () => {
      if (placed.show) await current.follow(placed.show, [placed.episode]);
      else if (placed.newEpisode) await current.updateEpisode(placed.episode);
      for (const margin of placed.margins) await current.addMargin(margin);
    })();
    return { placed, saved };
  }, []);

  const finish = useCallback(
    async (saved: Promise<void>, playing: boolean) => {
      try {
        await saved;
      } catch (error) {
        if (!(error instanceof NotSavedError)) toast(`These Margins weren’t saved. ${plainError(error)}`, 'problem');
      }
      onDone(playing);
    },
    [onDone, toast],
  );

  const play = useCallback(
    (read: PacketRead) => {
      setBusy(true);
      try {
        primeSpeech();
        const { placed, saved } = store(read);
        // Started inside the tap, before any wait: a browser lets sound start only from the friend's own tap. Now
        // Playing opens as soon as the Margins are stored; it shows "Loading audio…" while the episode buffers.
        void player.open(placed.episode.id, { at: 0, episode: placed.episode });
        void finish(saved, true);
      } catch (error) {
        setBusy(false);
        toast(`This couldn’t be opened. ${plainError(error)}`, 'problem');
      }
    },
    [finish, player, store, toast],
  );

  const keep = useCallback(
    (read: PacketRead) => {
      setBusy(true);
      try {
        void finish(store(read).saved, false);
      } catch (error) {
        setBusy(false);
        toast(`This couldn’t be opened. ${plainError(error)}`, 'problem');
      }
    },
    [finish, store, toast],
  );

  // The report form lives on the link server's page, never on the app's host, and the address carries no key (#3355).
  const reportable = link.kind === 'link' ? serverFor(link.link) : link.kind === 'damaged' ? link.reportable && serverFor(link.reportable) : undefined;
  const reportHref = reportable ? `${reportable.origin}/l/${reportable.id}?report` : undefined;

  if (state.status === 'opening') {
    return (
      <div className="arrival" role="dialog" aria-modal="true" aria-label="Opening the Margins">
        <div className="arrival-body">
          <p className="arrival-brand">Spoken Margins</p>
          <p role="status" className="arrival-status">
            Opening the Margins…
          </p>
        </div>
      </div>
    );
  }

  if (state.status === 'failed') {
    const { head, rest } = splitSentence(state.message);
    return (
      <div className="arrival" role="dialog" aria-modal="true" aria-labelledby="arrival-title" data-testid="arrival-failed">
        <div className="arrival-body arrival-centered">
          <p className="arrival-brand">Spoken Margins</p>
          <h1 id="arrival-title" className="arrival-title" ref={failedRef} tabIndex={-1}>
            {head}
          </h1>
          {rest && <p className="arrival-text">{rest}</p>}
          {state.message === ARRIVAL_WORDS.cutOff && reportHref && (
            <p className="arrival-foot">
              <a href={reportHref} target="_blank" rel="noopener noreferrer">
                Report this link
              </a>
            </p>
          )}
        </div>
      </div>
    );
  }

  const { read, facts } = state;
  const who = facts.who;
  const episode = read.episode;
  const article = read.margins.length === 0;
  // A Substack post has no audio address yet: its voice is looked up when the friend taps Play, as for a pasted link.
  const unplayable = !article && !episode.audioUrl && !episode.pageUrl;
  const articleAddress = webAddress(episode.pageUrl);
  const minutes = episode.durationSeconds ? Math.max(1, Math.round(episode.durationSeconds / 60)) : undefined;
  const subtitle = [episode.showTitle, minutes ? `${minutes} min` : undefined].filter(Boolean).join(' · ');
  const title = episode.title;

  return (
    <div className="arrival" role="dialog" aria-modal="true" aria-labelledby="arrival-title" data-testid="arrival">
      <div className="arrival-body">
        <p className="arrival-from">
          <span className="arrival-avatar" aria-hidden="true">
            {facts.initial}
          </span>
          <span>From {who}</span>
        </p>
        <h1 id="arrival-title" className="arrival-title">
          {title}
        </h1>
        {subtitle && <p className="arrival-sub">{subtitle}</p>}
        {article ? (
          <>
            <p className="arrival-text">{ARRIVAL_WORDS.article(who)}</p>
            {articleAddress && (
              <p>
                <a className="button button-primary arrival-play" href={articleAddress} target="_blank" rel="noopener noreferrer">
                  Open the article
                </a>
              </p>
            )}
            <button type="button" className="button arrival-play" onClick={() => onDone(false)}>
              Open Spoken Margins
            </button>
          </>
        ) : (
          <>
            <p className="arrival-count">{facts.countLine}</p>
            <p className="arrival-explain">{facts.explanation}</p>
            {unplayable && <p className="arrival-text">{ARRIVAL_WORDS.noEpisodeAudio(who)}</p>}
            <button
              ref={playRef}
              type="button"
              className="button button-primary arrival-play"
              disabled={busy}
              onClick={() => (unplayable ? keep(read) : play(read))}
            >
              <PlayIcon size={22} />
              {unplayable ? `Keep ${possessive(who)} Margins` : 'Play'}
            </button>
            {!unplayable && <p className="arrival-hint">{PLAY_HINT(who)}</p>}
          </>
        )}
        <footer className="arrival-foot">
          <p>This link works for 30 days.</p>
          {reportHref && (
            <p>
              <a href={reportHref} target="_blank" rel="noopener noreferrer">
                Report this link
              </a>
            </p>
          )}
          <p>Want the app? Ask {senderName(read.sender)} for an invite.</p>
        </footer>
      </div>
    </div>
  );
}
