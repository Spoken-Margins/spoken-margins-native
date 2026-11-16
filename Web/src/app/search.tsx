// The one search box every tab uses (#4422, #4427, #4018): a magnifier, a field that filters as you type, and a clear
// button once there is something to clear. Its words and shape are the same on every tab, so a listener who learned it
// on Library finds it again on Margins.
import { useId, useRef } from 'react';
import { CloseIcon, SearchIcon } from './icons.tsx';

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
