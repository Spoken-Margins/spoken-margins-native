import { useRef, useState } from 'react';
import { formatClock } from '../../shared/clock.ts';
import type { Margin } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { shortDate } from '../format.ts';
import { openFiles, type OpenMarginFile, type OpenShareLink } from '../import.tsx';
import { parseShareLink } from '../logic/share-link.ts';
import { marginGroups, newestMarginId } from '../logic/library.ts';
import { usePlayer } from '../player.tsx';
import { VoiceButton } from '../voice.tsx';

export function Margins({ onPlay, onOpenFile, onOpenLink }: { onPlay: () => void; onOpenFile: OpenMarginFile; onOpenLink: OpenShareLink }) {
  const data = useData();
  const picker = useRef<HTMLInputElement>(null);
  const [linkOpen, setLinkOpen] = useState(false);
  const [linkText, setLinkText] = useState('');
  const [opening, setOpening] = useState(false);
  const groups = marginGroups(data.margins, data.episodes);
  const newestId = newestMarginId(data.margins);
  const showTitle = (showId: string | undefined) => data.shows.find((s) => s.id === showId)?.title;

  return (
    <section className="screen" aria-labelledby="margins-title">
      <header className="screen-header">
        <h1 id="margins-title">Margins</h1>
        <div className="header-actions">
          <button type="button" className="button" onClick={() => picker.current?.click()}>
            Open a Margin file
          </button>
          <button type="button" className="button" aria-expanded={linkOpen} aria-controls="open-link" onClick={() => setLinkOpen((open) => !open)}>
            Open a link
          </button>
        </div>
        <input
          ref={picker}
          type="file"
          accept=".spokenmargins,application/vnd.spokenmargins.package+zip"
          hidden
          data-testid="margin-file"
          onChange={(event) => {
            const files = Array.from(event.target.files ?? []);
            event.target.value = '';
            void openFiles(files, onOpenFile);
          }}
        />
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
        groups.map((group, index) => (
          <section key={group.episodeId} className="margin-group" aria-labelledby={`group-${group.episodeId}`}>
            <header className="margin-group-header">
              <h2 id={`group-${group.episodeId}`}>
                <span className="row-kicker">{showTitle(group.episode?.showId) ?? 'Unfollowed show'}</span>
                <span className="group-title">{group.episode?.title ?? 'An episode no longer in your Library'}</span>
              </h2>
              {index === 0 && <span className="tag tag-orange">Newest</span>}
            </header>
            <ol className="margin-list">
              {group.margins.map((margin) => (
                <MarginRow key={margin.id} margin={margin} newest={margin.id === newestId} onPlay={onPlay} />
              ))}
            </ol>
          </section>
        ))
      )}
    </section>
  );
}

export function MarginRow({ margin, newest, onPlay, compact }: { margin: Margin; newest?: boolean; onPlay?: () => void; compact?: boolean }) {
  const player = usePlayer();
  const label = margin.text ? margin.text : `Voice Margin, ${formatClock(margin.voice?.durationSeconds ?? 0)} long`;
  return (
    <li className={`margin${newest ? ' is-newest' : ''}`}>
      <button
        type="button"
        className="margin-open"
        aria-label={`Play from ${formatClock(margin.atSeconds)}: ${label}`}
        onClick={() => {
          void player.open(margin.episodeId, { at: margin.atSeconds });
          onPlay?.();
        }}
      >
        <span className="margin-time">{formatClock(margin.atSeconds)}</span>
        <span className="margin-body">
          {margin.text ? <span className="margin-text">{margin.text}</span> : <span className="margin-text margin-voice-label">Voice Margin</span>}
          {!compact && (
            <span className="row-meta">
              {newest && <span className="tag tag-orange">Newest</span>}
              {margin.author ? `${margin.author}, ` : ''}
              {shortDate(margin.createdAt)}
            </span>
          )}
        </span>
      </button>
      {margin.voice && <VoiceButton voice={margin.voice} />}
    </li>
  );
}
