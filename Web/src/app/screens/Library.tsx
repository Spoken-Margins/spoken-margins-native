import { formatClock } from '../../shared/clock.ts';
import { useData } from '../data.tsx';
import { minutes, shortDate } from '../format.ts';
import { PauseIcon, PlayIcon } from '../icons.tsx';
import { useMarginFilePicker, type OpenMarginFile } from '../import.tsx';
import { libraryRows, type LibraryRow } from '../logic/library.ts';
import { usePlayer } from '../player.tsx';

export function Library({ onPlay, onFindShows, onOpenFile }: { onPlay: () => void; onFindShows: () => void; onOpenFile: OpenMarginFile }) {
  const data = useData();
  const player = usePlayer();
  // A friend's Margin file is opened where a listener looks first (#3039, owner 2026-10-31: "I didn't see a way to
  // import margins"). The Margins tab keeps the same button.
  const picker = useMarginFilePicker(onOpenFile);
  const rows = libraryRows(data.episodes, data.shows, data.positions);

  return (
    <div className="screen">
      <header className="screen-header">
        <h1 id="library-title" tabIndex={-1}>
          Library
        </h1>
        <div className="header-actions">
          <button type="button" className="button" onClick={picker.choose}>
            Open a Margin file
          </button>
        </div>
        {picker.input}
      </header>
      {data.ready && rows.length === 0 ? (
        <div className="empty">
          <p>Episodes from the shows and Substacks you follow appear here, newest first.</p>
          <button type="button" className="button button-primary" onClick={onFindShows}>
            Find a show to follow
          </button>
          <p>Got a .spokenmargins file from a friend? Choose Open a Margin file above. It opens at their first Margin, ready to play.</p>
        </div>
      ) : (
        <ul className="rows" aria-label="Episodes, newest first">
          {rows.map((row) => {
            const current = player.episode?.id === row.episode.id;
            return (
            <li key={row.episode.id}>
              <button
                type="button"
                aria-current={current ? 'true' : undefined}
                className={`row episode-row${current ? ' is-current' : ''}`}
                onClick={() => {
                  void player.open(row.episode.id);
                  onPlay();
                }}
              >
                <span className="row-play" aria-hidden="true">
                  {current && player.playing ? <PauseIcon size={20} /> : <PlayIcon size={20} />}
                </span>
                <span className="row-main">
                  <span className="row-kicker">{row.show?.title}</span>
                  <span className="row-title">{row.episode.title}</span>
                  <span className="row-meta">
                    {current ? <span className="tag tag-blue">{player.playing ? 'Playing' : 'Paused'}</span> : <StateTag row={row} />}
                    {[shortDate(row.episode.publishedAt), minutes(row.episode.durationSeconds)].filter(Boolean).join(', ')}
                  </span>
                  {row.state === 'started' && row.progress !== undefined && (
                    <span className="progress" aria-hidden="true">
                      <span style={{ width: `${row.progress * 100}%` }} />
                    </span>
                  )}
                </span>
              </button>
            </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

/** New, Resume at, Played: a word for every state, so none rests on colour. */
export function StateTag({ row }: { row: LibraryRow }) {
  if (row.state === 'started' && row.resumeAt !== undefined) {
    return <span className="tag tag-blue">Resume at {formatClock(row.resumeAt)}</span>;
  }
  if (row.state === 'finished') return <span className="tag tag-quiet">Played</span>;
  if (!row.episode.audioUrl) return <span className="tag tag-quiet">Post, voice checked when you play</span>;
  return <span className="tag tag-outline">New</span>;
}
