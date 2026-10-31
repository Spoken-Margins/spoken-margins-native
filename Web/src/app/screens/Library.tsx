import { formatClock } from '../../shared/clock.ts';
import { useData } from '../data.tsx';
import { minutes, shortDate } from '../format.ts';
import { PauseIcon, PlayIcon } from '../icons.tsx';
import { libraryRows, type LibraryRow } from '../logic/library.ts';
import { usePlayer } from '../player.tsx';

export function Library({ onPlay, onFindShows }: { onPlay: () => void; onFindShows: () => void }) {
  const data = useData();
  const player = usePlayer();
  const rows = libraryRows(data.episodes, data.shows, data.positions);

  return (
    <div className="screen">
      <header className="screen-header">
        <h1 id="library-title" tabIndex={-1}>
          Library
        </h1>
      </header>
      {data.ready && rows.length === 0 ? (
        <div className="empty">
          <p>Episodes from the shows and Substacks you follow appear here, newest first.</p>
          <button type="button" className="button button-primary" onClick={onFindShows}>
            Find a show to follow
          </button>
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
                    {current ? <span className="tag tag-status">{player.playing ? 'Playing' : 'Paused'}</span> : <StateTag row={row} />}
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
    return <span className="tag tag-status">Resume at {formatClock(row.resumeAt)}</span>;
  }
  if (row.state === 'finished') return <span className="tag tag-quiet">Played</span>;
  if (!row.episode.audioUrl) return <span className="tag tag-quiet">Post, voice checked when you play</span>;
  return <span className="tag tag-outline">New</span>;
}
