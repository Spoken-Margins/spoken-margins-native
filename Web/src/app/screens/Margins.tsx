import { formatClock } from '../../shared/clock.ts';
import type { Margin } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { shortDate } from '../format.ts';
import { marginGroups, newestMarginId } from '../logic/library.ts';
import { usePlayer } from '../player.tsx';
import { VoiceButton } from '../voice.tsx';

export function Margins({ onPlay }: { onPlay: () => void }) {
  const data = useData();
  const groups = marginGroups(data.margins, data.episodes);
  const newestId = newestMarginId(data.margins);
  const showTitle = (showId: string | undefined) => data.shows.find((s) => s.id === showId)?.title;

  return (
    <section className="screen" aria-labelledby="margins-title">
      <header className="screen-header">
        <h1 id="margins-title">Margins</h1>
      </header>
      {data.ready && groups.length === 0 ? (
        <div className="empty">
          <p>Margins you write or record while listening appear here, the newest at the top. Tap one to hear its moment.</p>
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
