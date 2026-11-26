// The page a share link opens (#2168, slice 4 of #3247): the friend's front door. It opens the sealed packet in this
// browser (the key is in the link's `#` part and never leaves it), shows who sent it, what it is and one Play, and
// that tap also starts the episode, so the browser allows sound. Then Now Playing takes over with the countdown to
// the sender's first Margin and a Skip. Every failure says what happened and one thing to do.
import { useCallback, useEffect, useRef, useState } from 'react';
import { PlayIcon } from '../icons.tsx';
import { LABELS, marginRows, playQueue, startFor, startWithUnheardMs, threads, firstToPlay, type Row } from '../logic/margins-control-center.ts';
import type { MarginStart } from '../player.tsx';
import { MarginsControlList } from './MarginsTab.tsx';
import { arrivalResumeAt, playHint, playableArticleMargins, ARRIVAL_WORDS, GET_APP_LINK, arrivalFacts, type ArrivalFacts } from '../logic/arrival.ts';
import { showIphoneStep } from '../logic/arrival-card.ts';
import { isMigrated, libraryEpisodes } from '../logic/library-membership.ts';
import { capacitorBridge } from '../../sources/native-http.ts';
import { ArrivalListen } from './ArrivalListen.tsx';
import { placeImport, previewMargins, unnamedAuthorFor } from '../logic/import.ts';
import { settleAppleEpisode } from '../logic/apple-arrival.ts';
import { playability, webAddress, withOwnedAudio, type VoiceLookup } from '../logic/playability.ts';
import { messageForFailure, messageForOpenedSettled, playCheckHandler, reportPlayCheck, type PlayCheckMessage } from '../play-check.ts';
import { placeMarginsOnAudio } from '../place-margins.ts';
import { plainError } from '../logic/messages.ts';
import { ShareLinkError, linkFooterText, openSharedPacketWithExpiry, type ParsedLink, type ShareLinkFailure, type ShareLinkRef } from '../logic/share-link.ts';
import { FRIEND_HELP_WORDS, friendHelpForFailure } from '../logic/friend-help.ts';
import { FriendHelpLink } from './FriendHelpLink.tsx';
import { fetchReplyBox, type ReplyBox } from '../logic/reply-box.ts';
import { senderNameOrNone } from '../logic/reply-words.ts';
import { trackReplyBox } from '../reply-boxes.ts';
import { NotSavedError } from '../logic/storage.ts';
import { useData } from '../data.tsx';
import type { PacketRead } from '../ports.ts';
import { usePlayer } from '../player.tsx';
import { RELAY_ORIGIN, services } from '../services.ts';
import { linkPacketWords } from '../logic/link-packet-words.ts';
import { primeSpeech } from '../speech.ts';
import { useUi } from '../ui.tsx';

type State =
  | { status: 'opening' }
  | { status: 'failed'; message: string; reason: ShareLinkFailure }
  | { status: 'ready'; read: PacketRead; facts: ArrivalFacts; expires?: string; lookup?: VoiceLookup };

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
  return linkPacketWords(error) ?? ARRIVAL_WORDS.unreadable;
}

/** The first sentence is the heading; what to do is the rest. */
function splitSentence(message: string): { head: string; rest: string } {
  const at = message.indexOf('. ');
  return at === -1 ? { head: message, rest: '' } : { head: message.slice(0, at + 1), rest: message.slice(at + 2) };
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
  // The link's reply part (#4675), fetched beside the packet and never waited on: the Share section reads it once it settles.
  const replyFetch = useRef<Promise<ReplyBox | undefined>>(undefined);

  // Inside the sender's hidden check (#4454) this says the page is running; anywhere else it does nothing.
  const announced = useRef(false);
  useEffect(() => {
    if (announced.current) return;
    announced.current = true;
    reportPlayCheck({ type: 'started' });
  }, []);

  // Open the packet once storage is ready (so the episode can match the listener's own copy).
  useEffect(() => {
    if (started.current || !data.ready) return;
    started.current = true;
    if (link.kind !== 'link') {
      setState({ status: 'failed', message: ARRIVAL_WORDS.cutOff, reason: 'damaged' });
      reportPlayCheck({ type: 'failed', reason: 'link-broken' });
      return;
    }
    // Not inside the sender's hidden check (#4454), which shares nothing back.
    if (!playCheckHandler()) replyFetch.current = fetchReplyBox(serverFor(link.link));
    void (async () => {
      let message: PlayCheckMessage | undefined;
      let opened: PacketRead | undefined;
      try {
        const { bytes, expires } = await openSharedPacketWithExpiry(serverFor(link.link));
        const packet = await services.packets.readPacket(bytes, 'shared.spokenmargins');
        // An Apple Podcasts episode page with no audio address: Apple's lookup finds its audio now, so Play starts at once.
        // Not inside the sender's hidden check, which reads only through the app (`messageForOpenedSettled`).
        const { read, lookup } = playCheckHandler()
          ? { read: packet, lookup: undefined }
          : await settleAppleEpisode(packet, (pageUrl) =>
              services.sources.findAppleEpisodeAudio(pageUrl, { relayAllowed: data.settings.relayAllowed, title: packet.episode.title }),
            );
        setState({
          status: 'ready',
          read,
          facts: arrivalFacts(read.sender, [...read.margins, ...playableArticleMargins(read)]),
          ...(expires === undefined ? {} : { expires }),
          ...(lookup && { lookup }),
        });
        opened = packet;
        message = undefined;
      } catch (error) {
        setState({ status: 'failed', message: failureWords(error), reason: error instanceof ShareLinkError ? error.reason : 'other' });
        message = messageForFailure(error);
      }
      // After the try, so nothing about the sender's check can turn a link that opened into the failed card. Inside the
      // app's check it may read the post's voice and the audio's start through the app; anywhere else it reads nothing.
      reportPlayCheck(message ?? (opened ? await messageForOpenedSettled(opened) : { type: 'failed', reason: 'server' }));
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
    const placed = placeImport(read, current.shows, current.episodes, undefined, current.margins, { unnamedAuthor: unnamedAuthorFor('link') });
    if (replyFetch.current) trackReplyBox(placed.episode.id, replyFetch.current, senderNameOrNone(read.sender), read.contentDigest);
    const saved = (async () => {
      if (placed.show) await current.follow(placed.show, [placed.episode]);
      else if (placed.newEpisode) await current.updateEpisode(placed.episode);
      for (const margin of placed.margins) await current.addMargin(margin);
      await current.addToLibrary(placed.episode.id, { quiet: true });
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
    (read: PacketRead, at?: number, start?: MarginStart) => {
      setBusy(true);
      try {
        primeSpeech();
        const current = dataRef.current;
        const { placed, saved } = store(read);
        // Started inside the tap, before any wait: a browser lets sound start only from the friend's own tap. Now
        // Playing opens as soon as the Margins are stored; it shows "Loading audio…" while the episode buffers.
        // A Margin on the article's words has no time of its own: the player places it on the voice once the audio says how long it is (#4421).
        const placeMargins = placeMarginsOnAudio(placed, saved);
        void player.open(placed.episode.id, {
          at: at ?? arrivalResumeAt(read, current.episodes, current.positions) ?? 0,
          episode: placed.episode,
          ...(placeMargins && { placeMargins }),
          ...(start && { start }),
        });
        void finish(saved, true);
      } catch (error) {
        setBusy(false);
        toast(`This couldn’t be opened. ${plainError(error)}`, 'problem');
      }
    },
    [finish, player, store, toast],
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
    const helpTopic = friendHelpForFailure(state.reason);
    return (
      <div className="arrival" role="dialog" aria-modal="true" aria-labelledby="arrival-title" data-testid="arrival-failed">
        <div className="arrival-body arrival-centered">
          <p className="arrival-brand">Spoken Margins</p>
          <h1 id="arrival-title" className="arrival-title" ref={failedRef} tabIndex={-1}>
            {head}
          </h1>
          {rest && <p className="arrival-text">{rest}</p>}
          {helpTopic && <FriendHelpLink topic={helpTopic} />}
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

  const { facts, expires, lookup } = state;
  const who = facts.who;
  // What the browser can do with this packet is one function's answer, so the sender's check says the same (#4454).
  // A Substack post has no audio address yet: its voice is looked up when the friend taps Play, as for a pasted link.
  const verdict = playability(state.read, lookup);
  // An episode with no audio that the listener's own web Library holds with audio plays on their copy (#5265).
  const owned = verdict.verdict === 'cannot' && verdict.reason === 'no-episode-audio' ? withOwnedAudio(state.read, data.episodes) : undefined;
  const read = owned && playability(owned).verdict === 'plays' ? owned : state.read;
  const episode = read.episode;
  const can = read === state.read ? verdict : playability(read);
  // Margins on something the browser can't play are heard on the listen-here card (#5265).
  if (can.verdict === 'cannot' && (can.reason === 'article' || can.reason === 'no-episode-audio')) {
    const held = read.margins.length > 0 ? previewMargins(read, data.shows, data.episodes, data.margins, unnamedAuthorFor('link')) : [];
    return (
      <ArrivalListen
        read={read}
        origin="link"
        iphoneStep={showIphoneStep(capacitorBridge() !== undefined, navigator.userAgent)}
        footer={linkFooterText(expires)}
        {...(reportHref && { reportHref })}
        libraryFirst={libraryEpisodes(data.episodes, data.library, isMigrated(data.settings)).length > 0}
        heardBefore={new Set(read.margins.filter((_, i) => held[i]?.heard).map((m) => m.id))}
        setHeard={data.setHeard}
        {...(read.margins.length > 0 && {
          store: () => {
            const { placed, saved } = store(read);
            // `held` lines up with the packet's timed Margins: each one, or the copy already stored for it.
            return { saved, storedIds: new Map(read.margins.map((m, i) => [m.id, placed.held[i]?.id ?? m.id])) };
          },
        })}
        onLibrary={(saved) => void finish(saved ?? Promise.resolve(), false)}
      />
    );
  }
  const articleAddress = webAddress(episode.pageUrl);
  const minutes = episode.durationSeconds ? Math.max(1, Math.round(episode.durationSeconds / 60)) : undefined;
  const subtitle = [episode.showTitle, minutes ? `${minutes} min` : undefined].filter(Boolean).join(' · ');
  const title = episode.title;
  // The arrival preview (part of #3216): the friend's Margins listed before anything plays, each with its own start, and
  // two starts pinned at the bottom. A packet with only an article's rough places keeps its one Play.
  const preview = read.margins.length > 0;
  const autoplay = data.settings.marginAutoplay;
  const rows = preview ? marginRows(previewMargins(read, data.shows, data.episodes, data.margins, unnamedAuthorFor('link'))) : [];
  const unheardAt = preview ? startWithUnheardMs(rows) : null;
  const startRow = (row: Row) => {
    const start = startFor(row, rows, autoplay, 0);
    if (start) play(read, start.seekToMs / 1000, { atSeconds: start.atMs / 1000, queue: start.queue });
  };
  const startWithUnheard = () => {
    if (unheardAt === null) return;
    const thread = threads(rows).find((t) => t[0].startHereMs === unheardAt && t.some((r) => r.hearing === 'unheard'));
    const first = thread && firstToPlay(thread, 'unheard');
    if (!thread || !first || thread[0].timeMs === null) return;
    play(read, unheardAt / 1000, { atSeconds: thread[0].timeMs / 1000, queue: playQueue(rows, first.id, autoplay === 'none' ? 'none' : 'unheard') });
  };

  if (preview) {
    return (
      <div className="arrival arrival-preview" role="dialog" aria-modal="true" aria-labelledby="arrival-title" data-testid="arrival">
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
          <h2 className="arrival-welcome">Welcome. {who} left these Margins for you.</h2>
          <p className="arrival-count">{facts.countLine}</p>
          <p className="arrival-explain">{facts.explanation}</p>
          <MarginsControlList
            context="arrival"
            rows={rows}
            margins={new Map()}
            playheadMs={0}
            autoplay={autoplay}
            onAutoplay={(choice) => void data.setSetting('marginAutoplay', choice)}
            onStart={(row) => (busy ? undefined : startRow(row))}
          />
          <footer className="arrival-foot">
            <p>{linkFooterText(expires)}</p>
            {reportHref && (
              <p>
                <a href={reportHref} target="_blank" rel="noopener noreferrer">
                  Report this link
                </a>
              </p>
            )}
            <p>
              <a href={GET_APP_LINK.href} target="_blank" rel="noopener noreferrer">
                {GET_APP_LINK.text}
              </a>
            </p>
            <FriendHelpLink text={FRIEND_HELP_WORDS.footer} />
          </footer>
        </div>
        <div className="arrival-starts">
          {unheardAt !== null && (
            <button ref={playRef} type="button" className="button button-primary arrival-play" disabled={busy} onClick={startWithUnheard}>
              <PlayIcon size={22} />
              {LABELS.startWithUnheard}
            </button>
          )}
          <button
            ref={unheardAt === null ? playRef : undefined}
            type="button"
            className={`button arrival-play${unheardAt === null ? ' button-primary' : ''}`}
            disabled={busy}
            onClick={() => play(read, 0)}
          >
            {LABELS.startFromBeginning}
          </button>
        </div>
      </div>
    );
  }

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
        <p className="arrival-count">{facts.countLine}</p>
        <p className="arrival-explain">{facts.explanation}</p>
        <button ref={playRef} type="button" className="button button-primary arrival-play" disabled={busy} onClick={() => play(read)}>
          <PlayIcon size={22} />
          Play
        </button>
        <p className="arrival-hint">{playHint(who, arrivalResumeAt(read, data.episodes, data.positions))}</p>
        {/* A post whose voice can't be found (a paid post, none offered) leaves the friend the article itself (#4421). */}
        {read.margins.length === 0 && articleAddress && (
          <p className="arrival-hint">
            <a href={articleAddress} target="_blank" rel="noopener noreferrer">
              Open the article
            </a>
          </p>
        )}
        <footer className="arrival-foot">
          <p>{linkFooterText(expires)}</p>
          {reportHref && (
            <p>
              <a href={reportHref} target="_blank" rel="noopener noreferrer">
                Report this link
              </a>
            </p>
          )}
          <p>
            <a href={GET_APP_LINK.href} target="_blank" rel="noopener noreferrer">
              {GET_APP_LINK.text}
            </a>
          </p>
          <FriendHelpLink text={FRIEND_HELP_WORDS.footer} />
        </footer>
      </div>
    </div>
  );
}

