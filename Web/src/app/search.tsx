// The one search box every tab uses (#4422, #4427, #4018): a magnifier, a field that filters as you type, and a clear
// button once there is something to clear. Its words and shape are the same on every tab, so a listener who learned it
// on Library finds it again on Margins.
import { createContext, useCallback, useContext, useEffect, useId, useMemo, useReducer, useRef, useState, type Dispatch, type ReactNode, type SetStateAction } from 'react';
import { CloseIcon, SearchIcon } from './icons.tsx';
import { initialSearchState, searchReducer, type FoldMap, type SearchAction } from './logic/search-state.ts';
import type { SearchTab } from './logic/search-words.ts';

/** How long a count waits after the query last changed, so a screen reader doesn't read one per letter. */
export const COUNT_DELAY_MS = 750;

type SearchValue = { state: typeof initialSearchState; dispatch: Dispatch<SearchAction> };
const SearchContext = createContext<SearchValue | undefined>(undefined);

/**
 * Each tab's query, and the Margins groups' folding, live above the tabs so a tab switch finds them as they were left
 * (#4427). They end on clear, on reload, when a tab's list empties, and in `useClearSearches` when something new arrives.
 */
export function SearchProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(searchReducer, initialSearchState);
  const value = useMemo(() => ({ state, dispatch }), [state]);
  return <SearchContext.Provider value={value}>{children}</SearchContext.Provider>;
}

function useSearch(): SearchValue {
  const value = useContext(SearchContext);
  if (!value) throw new Error('SearchProvider is missing');
  return value;
}

export function useTabSearch(tab: SearchTab): { query: string; setQuery: (query: string) => void } {
  const { state, dispatch } = useSearch();
  const setQuery = useCallback((query: string) => dispatch({ type: 'query', tab, query }), [dispatch, tab]);
  return { query: state.queries[tab], setQuery };
}

export function useMarginFolds(): {
  toggled: FoldMap;
  setToggled: Dispatch<SetStateAction<FoldMap>>;
  searchToggled: FoldMap;
  setSearchToggled: Dispatch<SetStateAction<FoldMap>>;
} {
  const { state, dispatch } = useSearch();
  const setToggled = useCallback((next: SetStateAction<FoldMap>) => dispatch({ type: 'toggled', update: (c) => (typeof next === 'function' ? next(c) : next) }), [dispatch]);
  const setSearchToggled = useCallback((next: SetStateAction<FoldMap>) => dispatch({ type: 'searchToggled', update: (c) => (typeof next === 'function' ? next(c) : next) }), [dispatch]);
  return { toggled: state.toggled, setToggled, searchToggled: state.searchToggled, setSearchToggled };
}

/** Empties every tab's query: for when a friend's file or link opens, or a show is followed, so the new thing isn't hidden. */
export function useClearSearches(): () => void {
  const { dispatch } = useSearch();
  return useCallback(() => dispatch({ type: 'clear' }), [dispatch]);
}

/**
 * The tab's one `role="status"` line, always on the page. Nothing matching is said at once, in the `empty` style; a count
 * is set `COUNT_DELAY_MS` after the query last changed (a timeout reset on each change, not polled) and stays visually
 * hidden, so a screen reader hears it. `matchLine` is undefined when nothing matches.
 */
export function SearchStatus({ query, matchLine, noMatchLine }: { query: string; matchLine: string | undefined; noMatchLine: string }) {
  const searching = query.trim() !== '';
  const counted = searching ? matchLine : undefined;
  const [heard, setHeard] = useState('');
  useEffect(() => {
    if (counted === undefined) {
      setHeard('');
      return;
    }
    const timer = setTimeout(() => setHeard(counted), COUNT_DELAY_MS);
    return () => clearTimeout(timer);
  }, [query, counted]);
  const none = searching && matchLine === undefined;
  return (
    <p className={none ? 'empty' : 'visually-hidden'} role="status">
      {none ? noMatchLine : heard}
    </p>
  );
}

export function SearchField({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  const id = useId();
  const input = useRef<HTMLInputElement>(null);
  return (
    <div className="search" role="search">
      <label htmlFor={id} className="search-label">
        {label}
      </label>
      <div className="search-box">
        <span className="search-icon" aria-hidden="true">
          <SearchIcon />
        </span>
        <input
          ref={input}
          id={id}
          type="search"
          inputMode="search"
          enterKeyHint="search"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
          value={value}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            // A phone's search key closes the keyboard and keeps the query. With a mouse or a hardware keyboard Enter
            // does nothing, so focus never falls to the page body.
            if (event.key === 'Enter' && window.matchMedia('(pointer: coarse)').matches) event.currentTarget.blur();
          }}
        />
        {value !== '' && (
          <button type="button" className="icon-button search-clear" aria-label="Clear search" onClick={() => {
              onChange('');
              // The button goes with the text; the keyboard stays in the field.
              input.current?.focus();
            }}>
            <CloseIcon />
          </button>
        )}
      </div>
    </div>
  );
}
