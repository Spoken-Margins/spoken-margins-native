// The words around the web's search boxes (#4427 Design, 2026-11-22): each tab's label, the line read when nothing
// matches, and the counts a screen reader hears once typing pauses. One place, so every tab says it the same way.
// Every function takes the raw query and trims it itself. Plain TypeScript with no DOM, so `npm run test:web` covers it
// (search-words.test.ts).

export type SearchTab = 'library' | 'following' | 'margins';

/** The visible label above each tab's box. Library's is kept: `e2e/library-search.spec.ts` finds the box by it. */
export const SEARCH_LABELS: Record<SearchTab, string> = {
  library: 'Search the Library',
  following: 'Search the shows you follow',
  margins: 'Search your Margins',
};

const NO_MATCH_PLACE: Record<SearchTab, string> = {
  library: 'the Library',
  following: 'the shows you follow',
  margins: 'your Margins',
};

/** "Nothing in the Library matches “{q}”.", shown at once when a search finds nothing. */
export function noMatchLine(tab: SearchTab, query: string): string {
  return `Nothing in ${NO_MATCH_PLACE[tab]} matches “${query.trim()}”.`;
}

/** "1 episode matches." / "{n} episodes match." */
export function libraryMatchLine(n: number): string {
  return n === 1 ? '1 episode matches.' : `${n} episodes match.`;
}

function counted(n: number, one: string, many: string): string {
  return n === 1 ? `1 ${one}` : `${n} ${many}`;
}

/** The Following count, by shows and episodes. A noun is singular at 1. Never called with both zero. */
export function followingMatchLine(shows: number, episodes: number): string {
  if (episodes === 0) return shows === 1 ? '1 show matches.' : `${shows} shows match.`;
  if (shows === 0) return episodes === 1 ? '1 episode matches.' : `${episodes} episodes match.`;
  return `${counted(shows, 'show', 'shows')} and ${counted(episodes, 'episode', 'episodes')} match.`;
}

/** The Margins count: `margins` shown (replies included) across `episodes` groups shown. */
export function marginsMatchLine(margins: number, episodes: number): string {
  if (margins === 1) return '1 Margin matches.';
  return episodes === 1 ? `${margins} Margins match, on 1 episode.` : `${margins} Margins match, on ${episodes} episodes.`;
}

/** A Margins group's count: "1 Margin" / "{n} Margins" when every Margin shows, "{k} of {n} Margins" when a search hides some. */
export function groupCountLine(shown: number, total: number): string {
  if (shown === total) return total === 1 ? '1 Margin' : `${total} Margins`;
  return `${shown} of ${total} Margins`;
}

/** The button on a Following search that finds nothing: it opens the Follow sheet with the query filled in. */
export function lookToFollowLabel(query: string): string {
  return `Look for “${query.trim()}” to follow`;
}
