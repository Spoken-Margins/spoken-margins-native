import { useRef, useState } from 'react';
import { formatClock } from '../../shared/clock.ts';
import type { Margin } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { ChevronIcon, StarIcon } from '../icons.tsx';
import { shortDate } from '../format.ts';
import { useMarginFilePicker, type OpenMarginFile, type OpenShareLink } from '../import.tsx';
import { parseShareLink } from '../logic/share-link.ts';
import { marginGroups, newestMarginId, startsCollapsed } from '../logic/library.ts';
import { threadedRows } from '../logic/margin-threads.ts';
import { plainError } from '../logic/messages.ts';
import { firesByItself } from '../logic/margin-autoplay.ts';
import { parentOf, resumeReplying, stopReplying } from '../logic/reply-choice.ts';
import { replyMarginName, replyTo, rowLine, STOP_REPLYING } from '../logic/reply-words.ts';
import { canStar, isStarred, shownStar, starTapWrites } from '../logic/star.ts';
import { NotSavedError } from '../logic/storage.ts';
import { usePlayer } from '../player.tsx';
import { useUi } from '../ui.tsx';
import { VoiceButton } from '../voice.tsx';

export function Margins({ onPlay, onOpenFile, onOpenLink }: { onPlay: () => void; onOpenFile: OpenMarginFile; onOpenLink: OpenShareLink }) {
  const data = useData();
  const picker = useMarginFilePicker(onOpenFile);
  const [linkOpen, setLinkOpen] = useState(false);
  const [linkText, setLinkText] = useState('');
  const [opening, setOpening] = useState(false);
  const groups = marginGroups(data.margins, data.episodes);
  // The listener's own taps on a group's title; a group never tapped follows `startsCollapsed`.
  const [toggled, setToggled] = useState<Record<string, boolean>>({});
  const newestId = newestMarginId(data.margins);
  const showTitle = (showId: string | undefined) => data.shows.find((s) => s.id === showId)?.title;

  return (
    <div className="screen">
      <header className="screen-header">
        <h1 id="margins-title" tabIndex={-1}>
          Margins
        </h1>
        <div className="header-actions">
          <button type="button" className="button" onClick={picker.choose}>
            Open a Margin file
          </button>
          <button type="button" className="button" aria-expanded={linkOpen} aria-controls="open-link" onClick={() => setLinkOpen((open) => !open)}>
            Open a link
          </button>
        </div>
        {picker.input}
      </header>
      {linkOpen && (
        <form
          id="open-link"
          className="open-link"
          onSubmit={(event) => {
            event.preventDefault();
            setOpening(true);
            void onOpenLink(parseShareLink(linkText, window.location.href)).finally(() => {
              setOpening(false);
              setLinkText('');
              setLinkOpen(false);
            });
          }}
        >
          <label htmlFor="share-link-text">A friend’s Spoken Margins link</label>
          <div className="open-link-row">
            <input
              id="share-link-text"
              type="text"
              inputMode="url"
              autoComplete="off"
              spellCheck={false}
              placeholder="https://…/l/…"
              value={linkText}
              onChange={(event) => setLinkText(event.target.value)}
            />
            <button type="submit" className="button button-primary" disabled={opening || !linkText.trim()}>
              {opening ? 'Opening…' : 'Open'}
            </button>
          </div>
        </form>
      )}
      {data.ready && groups.length === 0 ? (
        <div className="empty">
          <p>Margins you write or record while listening appear here, the newest at the top. Tap one to hear its moment.</p>
          <p>A friend’s Margins arrive as a file ending in .spokenmargins. Open it here, or drop it on this page.</p>
        </div>
      ) : (
        groups.map((group, index) => {
          const collapsed = toggled[group.episodeId] ?? startsCollapsed(index, groups.length);
          const listId = `margin-list-${group.episodeId.replace(/[^A-Za-z0-9_-]/g, '_')}`;
          const count = group.margins.length === 1 ? '1 Margin' : `${group.margins.length} Margins`;
          return (
            // Not labelled regions: one landmark per episode would bury the four tabs in a long list.
            // Headings are the way through. The newest Margin carries its own "Newest" tag, so the group
            // doesn't repeat it. A group's title is a button that folds its Margins away, with their count (#4423).
            <section key={group.episodeId} className="margin-group">
              <h2 className="margin-group-header">
                <button
                  type="button"
                  className="margin-group-toggle"
                  aria-expanded={!collapsed}
                  aria-controls={listId}
                  onClick={() => setToggled((current) => ({ ...current, [group.episodeId]: !collapsed }))}
                >
                  <span className="margin-group-title">
                    <span className="row-kicker">{showTitle(group.episode?.showId) ?? 'Unfollowed show'}</span>
                    <span className="group-title">{group.episode?.title ?? 'An episode no longer in your Library'}</span>
                    <span className="row-meta">{count}</span>
                  </span>
                  <span className={`margin-group-chevron${collapsed ? '' : ' is-open'}`} aria-hidden="true">
                    <ChevronIcon />
                  </span>
                </button>
              </h2>
              <ol id={listId} className="margin-list" hidden={collapsed}>
                {threadedRows(group.margins, data.margins).map(({ margin, indented, line }) => (
                  <MarginRow key={margin.id} margin={margin} parent={parentOf(margin, data.margins)} newest={margin.id === newestId} onPlay={onPlay} indented={indented} threadLine={line} />
                ))}
              </ol>
            </section>
          );
        })
      )}
    </div>
  );
}

/**
 * One Margin in a list. The listener's own Margins that are, or were, replies say whom they answer, with a button that
 * stops the reply and puts it back (#4107, B5). A friend's row gets a "Reply" button when the list passes `onReply`
 * (Now Playing's does; the Margins tab stays a list to play from). `parent` is the Margin a reply answers, found by the
 * caller among all the Margins. The listener's own Margins end with a star: "Star for sharing", which Share starts ticked
 * (#4172). It is the last control, after the Reply buttons. On the Margins screen a reply sits under the Margin it answers
 * (`indented`), and a friend's reply says which on a first line (`threadLine`, #4174).
 */
export function MarginRow({
  margin,
  newest,
  onPlay,
  compact,
  parent,
  onReply,
  replyDisabled,
  indented,
  threadLine,
}: {
  margin: Margin;
  newest?: boolean;
  onPlay?: () => void;
  compact?: boolean;
  parent?: Margin;
  onReply?: (friend: Margin) => void;
  /** A composer is open: a second reply can't begin, and a saved reply can't change under the composer's own copy of it, until it closes. */
  replyDisabled?: boolean;
  /** The Margins screen lists this reply under the Margin it answers. */
  indented?: boolean;
  /** A friend's reply on the Margins screen: "Reply to your Margin at 12:34", or that this browser can't find it. Shown first. */
  threadLine?: string;
}) {
  const player = usePlayer();
  const data = useData();
  const { toast } = useUi();
  const label = margin.text ? margin.text : `Voice Margin, ${formatClock(margin.voice?.durationSeconds ?? 0)} long`;
  const replyLine = margin.author === undefined ? rowLine(margin, parent) : undefined;
  // The visible row says more than the label used to: keep the tag, author, date and reply line in the spoken name.
  const [starPending, setStarPending] = useState<boolean>();
  const starWrites = useRef(0);
  const starred = shownStar(starPending, isStarred(margin));
  const details = [newest ? 'Newest' : '', margin.author ?? '', starred ? 'Starred' : '', compact ? '' : shortDate(margin.createdAt), replyLine ?? ''].filter(Boolean).join(', ');
  // "Stop replying" and "Reply to Cole" are one button: it needs the Margin it answers, or answered, to be on the episode.
  const stoppable = replyLine !== undefined && parent !== undefined;
  const replying = margin.replyToId !== undefined;
  const change = async () => {
    try {
      await data.addMargin(replying ? stopReplying(margin) : resumeReplying(margin));
    } catch (error) {
      // A storage failure has already said what wasn't saved.
      if (!(error instanceof NotSavedError)) toast(`The reply wasn’t updated: ${plainError(error)}`, 'problem');
    }
  };
  // The star flips at once and is held here until the stored Margin agrees; a failed write flips it back, and the write
  // has already said what wasn't saved. A double tap is two writes in order, and it ends where it began.
  const flipStar = async () => {
    const next = starTapWrites(starPending, isStarred(margin));
    setStarPending(next);
    starWrites.current += 1;
    try {
      await data.setStarred(margin.id, next);
    } catch (error) {
      if (!(error instanceof NotSavedError)) toast(`The star wasn’t kept: ${plainError(error)}`, 'problem');
    } finally {
      starWrites.current -= 1;
      if (starWrites.current === 0) setStarPending(undefined);
    }
  };
  return (
    <li className={`margin${newest ? ' is-newest' : ''}${indented ? ' is-reply' : ''}`}>
      <button
        type="button"
        className="margin-open"
        aria-label={`${threadLine ? `${threadLine}. ` : ''}Play from ${formatClock(margin.atSeconds)}: ${label}${details ? `. ${details}` : ''}`}
        onClick={() => {
          void player.open(margin.episodeId, { at: margin.atSeconds });
          onPlay?.();
        }}
      >
        <span className="margin-time">{formatClock(margin.atSeconds)}</span>
        <span className="margin-body">
          {threadLine !== undefined && <span className="row-meta reply-meta">{threadLine}</span>}
          {margin.text ? <span className="margin-text">{margin.text}</span> : <span className="margin-text margin-voice-label">Voice Margin, {formatClock(margin.voice?.durationSeconds ?? 0)}</span>}
          {!compact && (
            <span className="row-meta">
              {newest && <span className="tag tag-orange">Newest</span>}
              {starred && <span className="tag tag-quiet">Starred</span>}
              {margin.author ? `${margin.author}, ` : ''}
              {shortDate(margin.createdAt)}
            </span>
          )}
          {replyLine !== undefined && <span className="row-meta reply-meta">{replyLine}</span>}
        </span>
      </button>
      {margin.voice && <VoiceButton voice={margin.voice} />}
      {stoppable && (
        <button type="button" className="margin-reply" disabled={replyDisabled} onClick={() => void change()}>
          {replying ? STOP_REPLYING : replyTo(parent.author)}
        </button>
      )}
      {onReply && firesByItself(margin) && (
        <button type="button" className="margin-reply" aria-label={replyMarginName(margin)} disabled={replyDisabled} onClick={() => onReply(margin)}>
          Reply
        </button>
      )}
      {canStar(margin) && (
        <button type="button" className="icon-button margin-star" aria-label="Star for sharing" aria-pressed={starred} onClick={() => void flipStar()}>
          <StarIcon filled={starred} />
        </button>
      )}
    </li>
  );
}
