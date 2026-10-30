// Ordering and grouping for the Library, Following and Margins tabs. Plain TypeScript with no DOM, so
// `npm run test:web` covers it (library.test.ts).
import type { Episode, Margin, PlaybackPosition, Show } from '../../shared/model.ts';

/** Seconds from the end at which an episode counts as finished. */
export const FINISHED_WITHIN_SECONDS = 15;

/** A short, stable id from text (FNV-1a, 32-bit, hex). Ids only need to be stable, not secret. */
export function stableId(text: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

function time(iso: string | undefined): number {
  if (!iso) return Number.NEGATIVE_INFINITY;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? Number.NEGATIVE_INFINITY : t;
}

/** Newest first by published date. Undated items go last, in title order, so the list never jumps. */
export function newestFirst(episodes: readonly Episode[]): Episode[] {
  return [...episodes].sort((a, b) => {
    const d = time(b.publishedAt) - time(a.publishedAt);
    if (d !== 0 && !Number.isNaN(d)) return d;
    return a.title.localeCompare(b.title);
  });
}

export type ListenState = 'new' | 'started' | 'finished';

export interface LibraryRow {
  episode: Episode;
  show: Show | undefined;
  /** Where to resume, when the listener has started it. */
  resumeAt: number | undefined;
  /** 0 to 1, when both a position and a duration are known. */
  progress: number | undefined;
  state: ListenState;
}

export function listenState(episode: Episode, position: PlaybackPosition | undefined): ListenState {
  if (!position || position.seconds <= 0) return 'new';
  const duration = episode.durationSeconds;
  if (duration && position.seconds >= duration - FINISHED_WITHIN_SECONDS) return 'finished';
  return 'started';
}

export function libraryRows(
  episodes: readonly Episode[],
  shows: readonly Show[],
  positions: readonly PlaybackPosition[],
): LibraryRow[] {
  const showById = new Map(shows.map((s) => [s.id, s]));
  const positionById = new Map(positions.map((p) => [p.episodeId, p]));
  return newestFirst(episodes.filter((e) => showById.has(e.showId))).map((episode) => {
    const position = positionById.get(episode.id);
    const state = listenState(episode, position);
    const duration = episode.durationSeconds;
    return {
      episode,
      show: showById.get(episode.showId),
      resumeAt: state === 'started' ? position?.seconds : undefined,
      progress: position && duration ? Math.min(1, Math.max(0, position.seconds / duration)) : undefined,
      state,
    };
  });
}

export interface FollowingRow {
  show: Show;
  newest: Episode | undefined;
  /** Episodes the listener hasn't started. */
  newCount: number;
}

/** One row per show, the show with the newest episode first (Four tabs: "sorted by newest"). */
export function followingRows(
  shows: readonly Show[],
  episodes: readonly Episode[],
  positions: readonly PlaybackPosition[],
): FollowingRow[] {
  const started = new Set(positions.filter((p) => p.seconds > 0).map((p) => p.episodeId));
  const rows = shows.map((show) => {
    const own = newestFirst(episodes.filter((e) => e.showId === show.id));
    return { show, newest: own[0], newCount: own.filter((e) => !started.has(e.id)).length };
  });
  return rows.sort((a, b) => {
    const d = time(b.newest?.publishedAt) - time(a.newest?.publishedAt);
    if (d !== 0 && !Number.isNaN(d)) return d;
    return a.show.title.localeCompare(b.show.title);
  });
}

export interface MarginGroup {
  episodeId: string;
  episode: Episode | undefined;
  /** In the order they sit in the audio. */
  margins: Margin[];
  newestAt: string;
}

/**
 * Margins grouped by episode, the group holding the newest Margin first (Four tabs: "groups are ordered
 * by their newest Margin"), so the Margin added last is always in the top group.
 */
export function marginGroups(margins: readonly Margin[], episodes: readonly Episode[]): MarginGroup[] {
  const episodeById = new Map(episodes.map((e) => [e.id, e]));
  const groups = new Map<string, Margin[]>();
  for (const margin of margins) {
    const list = groups.get(margin.episodeId) ?? [];
    list.push(margin);
    groups.set(margin.episodeId, list);
  }
  return [...groups.entries()]
    .map(([episodeId, list]) => {
      const newestAt = list.reduce((best, m) => (time(m.createdAt) > time(best) ? m.createdAt : best), list[0].createdAt);
      return {
        episodeId,
        episode: episodeById.get(episodeId),
        margins: [...list].sort((a, b) => a.atSeconds - b.atSeconds),
        newestAt,
      };
    })
    .sort((a, b) => time(b.newestAt) - time(a.newestAt));
}

/** The id of the newest Margin overall, for the "Newest" label. */
export function newestMarginId(margins: readonly Margin[]): string | undefined {
  let best: Margin | undefined;
  for (const m of margins) if (!best || time(m.createdAt) > time(best.createdAt)) best = m;
  return best?.id;
}

export const SPEEDS: readonly number[] = [0.8, 1, 1.25, 1.5, 1.75, 2];

/** The next playback speed in the cycle; an unknown speed goes back to 1×. */
export function nextSpeed(rate: number): number {
  const i = SPEEDS.findIndex((s) => Math.abs(s - rate) < 0.001);
  if (i < 0) return 1;
  return SPEEDS[(i + 1) % SPEEDS.length];
}

/** Where a Margin sits along the timeline, 0 to 1. Unknown durations put it at the start. */
export function timelineFraction(atSeconds: number, durationSeconds: number | undefined): number {
  if (!durationSeconds || !Number.isFinite(durationSeconds) || durationSeconds <= 0) return 0;
  return Math.min(1, Math.max(0, atSeconds / durationSeconds));
}
