import { formatClock } from '../../shared/clock.ts';
import { useData } from '../data.tsx';
import { minutes, shortDate } from '../format.ts';
import { PlayIcon } from '../icons.tsx';
import { libraryRows, type LibraryRow } from '../logic/library.ts';
import { usePlayer } from '../player.tsx';

export function Library({ onPlay, onFindShows }: { onPlay: () => void; onFindShows: () => void }) {
  const data = useData();
  const player = usePlayer();
  const rows = libraryRows(data.episodes, data.shows, data.positions);

  return (
    <section className="screen" aria-labelledby="library-title">
      <header className="screen-header">
        <h1 id="library-title">Library</h1>
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
          {rows.map((row) => (
            <li key={row.episode.id}>
              <button
                type="button"
                className={`row episode-row${player.episode?.id === row.episode.id ? ' is-current' : ''}`}
                onClick={() => {
                  void player.open(row.episode.id);
                  onPlay();
                }}
              >
                <span className="row-play" aria-hidden="true">
                  <PlayIcon size={20} />
                </span>
                <span className="row-main">
                  <span className="row-kicker">{row.show?.title}</span>
                  <span className="row-title">{row.episode.title}</span>
                  <span className="row-meta">
                    <StateTag row={row} />
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
          ))}
        </ul>
      )}
    </section>
  );
}

function StateTag({ row }: { row: LibraryRow }) {
  if (row.state === 'started' && row.resumeAt !== undefined) {
    return <span className="tag tag-blue">Resume at {formatClock(row.resumeAt)}</span>;
  }
  if (row.state === 'finished') return <span className="tag tag-quiet">Played</span>;
  if (!row.episode.audioUrl) return <span className="tag tag-quiet">Post, voice found when you tap</span>;
  return <span className="tag tag-outline">New</span>;
}
