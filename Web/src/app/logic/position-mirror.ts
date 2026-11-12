// The listener's place, kept twice (#4096). IndexedDB is the record, but a write started while the page unloads (a
// refresh, a swipe away) may never commit, so a refresh during playback went back to the last place that did commit, up
// to five seconds behind or all the way back to the scrub. `localStorage.setItem` is synchronous and finishes before the
// page goes, so each place is also written there, and the next load takes whichever of the two is newer. Plain
// TypeScript, so `npm run test:web` covers it.
import type { PlaybackPosition } from '../../shared/model.ts';

export const MIRROR_KEY = 'sm.positions.v1';
/** While playing, the mirror is written at most this often: a refresh loses at most this much. */
export const MIRROR_EVERY_MS = 1000;

export interface MirrorStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

const isPosition = (value: unknown): value is PlaybackPosition => {
  if (typeof value !== 'object' || value === null) return false;
  const p = value as Record<string, unknown>;
  return typeof p.episodeId === 'string' && typeof p.seconds === 'number' && Number.isFinite(p.seconds) && p.seconds >= 0 && typeof p.updatedAt === 'string';
};

const when = (position: PlaybackPosition | undefined): number => {
  const t = position ? Date.parse(position.updatedAt) : Number.NaN;
  return Number.isNaN(t) ? Number.NEGATIVE_INFINITY : t;
};

/** What the mirror holds, by episode. A missing, unreadable or damaged value reads as empty; a damaged row is dropped. */
export function readMirror(storage: MirrorStorage | undefined): Map<string, PlaybackPosition> {
  const out = new Map<string, PlaybackPosition>();
  try {
    const raw = storage?.getItem(MIRROR_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : undefined;
    if (Array.isArray(parsed)) for (const row of parsed) if (isPosition(row)) out.set(row.episodeId, { episodeId: row.episodeId, seconds: row.seconds, updatedAt: row.updatedAt });
  } catch {
    // No storage, or a value that isn't ours: nothing is mirrored.
  }
  return out;
}

function writeMirror(storage: MirrorStorage | undefined, rows: Map<string, PlaybackPosition>): void {
  try {
    storage?.setItem(MIRROR_KEY, JSON.stringify([...rows.values()]));
  } catch {
    // Private mode or a full disk: the IndexedDB write still happens.
  }
}

/**
 * Writes one place into the mirror, synchronously. The writer is the live player, so its place replaces the episode's
 * row whatever the clock says: a device clock set back must not leave an old row that later beats the real place.
 */
export function mirrorPosition(storage: MirrorStorage | undefined, position: PlaybackPosition): void {
  const rows = readMirror(storage);
  rows.set(position.episodeId, position);
  writeMirror(storage, rows);
}

/** Unfollowing resets an episode's place, so its mirrored copy goes too, or a re-follow would bring it back. */
export function forgetMirrored(storage: MirrorStorage | undefined, episodeIds: Iterable<string>): void {
  const rows = readMirror(storage);
  let changed = false;
  for (const id of episodeIds) changed = rows.delete(id) || changed;
  if (changed) writeMirror(storage, rows);
}

/**
 * The places to use at load: what IndexedDB holds, with any mirrored place that is newer, or for an episode IndexedDB
 * has no place for. `written` is what must go back into IndexedDB. A place for an episode that is no longer in the
 * library (unfollowed since) is left out.
 */
export function mergeMirror(
  stored: readonly PlaybackPosition[],
  mirrored: ReadonlyMap<string, PlaybackPosition>,
  episodeIds: ReadonlySet<string>,
): { positions: PlaybackPosition[]; written: PlaybackPosition[] } {
  const byEpisode = new Map(stored.map((p) => [p.episodeId, p]));
  const written: PlaybackPosition[] = [];
  for (const [id, place] of mirrored) {
    if (!episodeIds.has(id)) continue;
    const have = byEpisode.get(id);
    if (have && when(place) <= when(have)) continue;
    byEpisode.set(id, place);
    written.push(place);
  }
  return { positions: [...byEpisode.values()], written };
}

/**
 * After IndexedDB holds `current`, drops each mirrored place that is no newer than it, and any for an episode that is no
 * longer there, so the mirror stays small.
 */
export function pruneMirror(storage: MirrorStorage | undefined, current: readonly PlaybackPosition[]): void {
  const rows = readMirror(storage);
  const have = new Map(current.map((p) => [p.episodeId, p]));
  for (const [id, place] of rows) {
    const held = have.get(id);
    if (!held || when(place) <= when(held)) rows.delete(id);
  }
  writeMirror(storage, rows);
}

/** `window.localStorage`, or nothing where reading it throws (blocked storage). */
export function browserStorage(): MirrorStorage | undefined {
  try {
    return typeof localStorage === 'undefined' ? undefined : localStorage;
  } catch {
    return undefined;
  }
}
