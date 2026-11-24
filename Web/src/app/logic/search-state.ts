// What the web's search boxes remember while the page is open (#4427 Design, 2026-11-22). One query per tab, kept when
// the listener switches tabs, plus the Margins groups' folding: `toggled` is the listener's own taps, `searchToggled` the
// taps made while a Margins search is on. Pure, so `npm run test:web` covers the rules (search-state.test.ts).
import type { SearchTab } from './search-words.ts';

export type FoldMap = Record<string, boolean>;

export interface SearchState {
  queries: Record<SearchTab, string>;
  toggled: FoldMap;
  searchToggled: FoldMap;
}

export const initialSearchState: SearchState = {
  queries: { library: '', following: '', margins: '' },
  toggled: {},
  searchToggled: {},
};

export type SearchAction =
  | { type: 'query'; tab: SearchTab; query: string }
  | { type: 'toggled'; update: (current: FoldMap) => FoldMap }
  | { type: 'searchToggled'; update: (current: FoldMap) => FoldMap }
  | { type: 'clear' };

export function searchReducer(state: SearchState, action: SearchAction): SearchState {
  switch (action.type) {
    case 'query': {
      if (state.queries[action.tab] === action.query) return state;
      const queries = { ...state.queries, [action.tab]: action.query };
      // Search-time taps last until the Margins query is cleared; `toggled` is never touched, so clearing brings back the earlier folding.
      const blank = action.tab === 'margins' && action.query.trim() === '';
      return { ...state, queries, searchToggled: blank ? {} : state.searchToggled };
    }
    case 'toggled':
      return { ...state, toggled: action.update(state.toggled) };
    case 'searchToggled':
      return { ...state, searchToggled: action.update(state.searchToggled) };
    case 'clear': {
      const none = Object.values(state.queries).every((q) => q === '') && Object.keys(state.searchToggled).length === 0;
      return none ? state : { ...state, queries: initialSearchState.queries, searchToggled: {} };
    }
  }
}
