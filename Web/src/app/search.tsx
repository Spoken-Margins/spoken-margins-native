// The one search box every tab uses (#4422, #4427, #4018): a magnifier, a field that filters as you type, and a clear
// button once there is something to clear. Its words and shape are the same on every tab, so a listener who learned it
// on Library finds it again on Margins.
import { useId } from 'react';
import { CloseIcon, SearchIcon } from './icons.tsx';

export function SearchField({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  const id = useId();
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
          id={id}
          type="search"
          inputMode="search"
          enterKeyHint="search"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
          value={value}
          onChange={(event) => onChange(event.target.value)}
        />
        {value !== '' && (
          <button type="button" className="icon-button search-clear" aria-label="Clear search" onClick={() => onChange('')}>
            <CloseIcon />
          </button>
        )}
      </div>
    </div>
  );
}
