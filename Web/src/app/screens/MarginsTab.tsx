// The Margins tab inside playback and the arrival preview's list (owner's prototype v3, part of #3216). What the list
// shows, in which order, which Margin is heard, where a start control goes and what Next Margin does are decided in
// logic/margins-control-center.ts, from the cases SessionKit also runs; this file only draws them.
//
// Owner rules this keeps: the player never moves the listener by itself (every jump here is a button the listener taps);
// unheard is a blue bar and dot (#56B4E9) with a spoken "Unheard", never bold or bigger, and heard rows are greyed with a
// check and the word "Heard", so no state rests on colour alone.
import { useLayoutEffect, useRef, useState } from 'react';
import { formatClock } from '../../shared/clock.ts';
import type { Margin } from '../../shared/model.ts';
import { useData } from '../data.tsx';
import { CheckIcon, DownIcon, PlayIcon, SkipBackIcon, SkipIcon, StarIcon } from '../icons.tsx';
import {
  AUTOPLAY_CHOICES, CONSTANTS, LABELS, autoplayTitle, threads, type Autoplay, type NextMargin, type Row,
} from '../logic/margins-control-center.ts';
import { plainError } from '../logic/messages.ts';
import { shownStar, starTapWrites } from '../logic/star.ts';
import { NotSavedError } from '../logic/storage.ts';
import { useUi } from '../ui.tsx';

export type MarginsFilter = 'all' | 'mine' | 'shared';
const FILTERS: Array<{ id: MarginsFilter; label: string }> = [
  { id: 'all', label: 'All' },
  { id: 'mine', label: 'Mine' },
  { id: 'shared', label: 'Shared' },
];

/** "You" for the listener's own Margin, the friend's name otherwise. */
export const displaySender = (sender: string): string => (sender === CONSTANTS.ownSender ? 'You' : sender);

const clock = (ms: number | null) => (ms === null ? '' : formatClock(ms / 1000));

/** The Autoplay control: one compact button, and a menu of the three choices under its title. */
export function AutoplayMenu({ autoplay, onChange }: { autoplay: Autoplay; onChange: (next: Autoplay) => void }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (!open) return;
    const close = (event: Event) => {
      if (!box.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('pointerdown', close);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('pointerdown', close);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);
  // The button's short word is the first word of the menu's own label ("Unheard Margins" reads "Unheard").
  const short = autoplayTitle(autoplay).split(' ')[0];
  return (
    <div className="mc-autoplay" ref={box}>
      <button
        type="button"
        className="mc-autoplay-button"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={`Autoplay: ${autoplayTitle(autoplay)}`}
        onClick={() => setOpen((o) => !o)}
      >
        Autoplay <b>{short}</b>
        <DownIcon />
      </button>
      {open && (
        <div className="mc-menu" role="menu" aria-label={LABELS.autoplayMenuTitle}>
          <p className="mc-menu-title">{LABELS.autoplayMenuTitle}</p>
          {AUTOPLAY_CHOICES.map((choice) => (
            <button
              key={choice}
              type="button"
              role="menuitemradio"
              aria-checked={autoplay === choice}
              onClick={() => {
                onChange(choice);
                setOpen(false);
              }}
            >
              <span className="mc-menu-check">{autoplay === choice && <CheckIcon size={18} />}</span>
              {autoplayTitle(choice)}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/** The star on the listener's own Margin: flips at once, held until the stored Margin agrees (as MarginRow's does). */
function RowStar({ margin }: { margin: Margin }) {
  const data = useData();
  const { toast } = useUi();
  const [pending, setPending] = useState<boolean>();
  const writes = useRef(0);
  const starred = shownStar(pending, margin.starred === true);
  const flip = async () => {
    const next = starTapWrites(pending, margin.starred === true);
    setPending(next);
    writes.current += 1;
    try {
      await data.setStarred(margin.id, next);
    } catch (error) {
      if (!(error instanceof NotSavedError)) toast(`The star wasn’t kept: ${plainError(error)}`, 'problem');
    } finally {
      writes.current -= 1;
      if (writes.current === 0) setPending(undefined);
    }
  };
  return (
    <button type="button" className="mc-star" aria-label="Star for sharing" aria-pressed={starred} onClick={() => void flip()}>
      <StarIcon filled={starred} />
    </button>
  );
}

export interface ListProps {
  /** Arrival preview rows say "Start with this Margin"; the Margins tab's say "Jump to this Margin". */
  context: 'arrival' | 'playback';
  rows: readonly Row[];
  /** The stored Margins behind the rows, for the star (missing on the arrival preview of a packet not yet stored). */
  margins: ReadonlyMap<string, Margin>;
  playheadMs: number;
  /** The Margin sounding now, marked "Playing". */
  playingId?: string;
  autoplay: Autoplay;
  onAutoplay: (next: Autoplay) => void;
  onStart: (row: Row) => void;
}

function MarginRowView({ row, parent, props }: { row: Row; parent: Row | undefined; props: ListProps }) {
  const [expanded, setExpanded] = useState(false);
  const [cut, setCut] = useState(false);
  const textRef = useRef<HTMLParagraphElement>(null);
  useLayoutEffect(() => {
    const el = textRef.current;
    // "See more" only where the two lines cut the words.
    if (el && !expanded) setCut(el.scrollHeight > el.clientHeight + 2);
  }, [row.words, expanded]);
  const playing = props.playingId === row.id;
  const own = row.hearing === 'yours';
  const stored = props.margins.get(row.id);
  const who = displaySender(row.sender);
  const state = playing ? 'playing' : row.hearing;
  const ahead = row.timeMs !== null && row.timeMs > props.playheadMs;
  return (
    <div className={`mc-row mc-${state}${row.depth > 0 ? ' mc-reply' : ''}`} role="group" aria-label={`${who}’s Margin at ${clock(row.timeMs)}`} data-testid="mc-row" data-margin-id={row.id}>
      <p className="mc-head">
        {state === 'unheard' && <span className="mc-dot" aria-hidden="true" />}
        <span className="mc-who">{who}</span>
        {row.depth > 1 && parent && <span>to {displaySender(parent.sender)}</span>}
        <span>{clock(row.timeMs)}</span>
        {state === 'playing' && <span className="mc-playtag">Playing</span>}
        {state === 'heard' && (
          <span className="mc-heardtag">
            <CheckIcon size={14} /> Heard
          </span>
        )}
        {state === 'unheard' && <span className="visually-hidden">Unheard</span>}
        <span className="mc-spacer" />
        {own && stored && <RowStar margin={stored} />}
      </p>
      {row.note && <p className="mc-note">{row.note}</p>}
      {row.depth === 0 && row.leadIn && (
        <p className="mc-leadin">
          <span className="mc-leadin-after">After</span> “{row.leadIn}”
        </p>
      )}
      {row.words === null ? (
        <p className="mc-placeholder">No transcript yet</p>
      ) : (
        <p ref={textRef} className={`mc-text${expanded ? ' is-expanded' : ''}`}>
          {row.words}
        </p>
      )}
      <div className="mc-acts">
        {row.words !== null && (cut || expanded) && (
          <button type="button" className="mc-more" aria-expanded={expanded} onClick={() => setExpanded((e) => !e)}>
            {expanded ? 'See less' : 'See more'}
          </button>
        )}
        {!playing && row.startHereMs !== null && (
          <button type="button" className="mc-start" onClick={() => props.onStart(row)}>
            {props.context === 'arrival' ? <PlayIcon size={18} /> : ahead ? <SkipIcon /> : <SkipBackIcon />}
            {LABELS.rowStart[props.context]}
          </button>
        )}
      </div>
    </div>
  );
}

/** The filters, the Autoplay menu and the threaded list. */
export function MarginsControlList(props: ListProps) {
  const [filter, setFilter] = useState<MarginsFilter>('all');
  const all = threads(props.rows);
  const shown = all.filter((thread) =>
    filter === 'all' ? true : filter === 'mine' ? thread.some((r) => r.hearing === 'yours') : thread.some((r) => r.hearing !== 'yours'),
  );
  const byId = new Map(props.rows.map((r) => [r.id, r]));
  return (
    <div className="mc-list">
      <div className="mc-controls">
        <div className="mc-filter" role="group" aria-label="Show">
          {FILTERS.map(({ id, label }) => (
            <button key={id} type="button" aria-pressed={filter === id} onClick={() => setFilter(id)}>
              {filter === id && <CheckIcon size={16} />}
              {label}
            </button>
          ))}
        </div>
        <AutoplayMenu autoplay={props.autoplay} onChange={props.onAutoplay} />
      </div>
      {shown.length === 0 && <p className="mc-empty">{all.length === 0 ? 'No Margins yet.' : 'No Margins in this filter.'}</p>}
      {shown.map((thread) => (
        <div key={thread[0].id} className="mc-thread">
          <MarginRowView row={thread[0]} parent={undefined} props={props} />
          {thread.length > 1 && (
            <div className="mc-replies">
              {thread.slice(1).map((row) => (
                <MarginRowView key={row.id} row={row} parent={row.parentId ? byId.get(row.parentId) : undefined} props={props} />
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

/** The floating Next Margin pill: double-forward and the m:ss countdown. Hidden when there is no next Margin. */
export function NextMarginPill({ next, onPress }: { next: NextMargin | null; onPress: (next: NextMargin) => void }) {
  if (!next) return null;
  return (
    <button type="button" className="mc-next" aria-label={`Next Margin, in ${next.countdown}`} onClick={() => onPress(next)} data-testid="next-margin">
      <SkipIcon />
      Next Margin <span className="mc-next-clock">{next.countdown}</span>
    </button>
  );
}
