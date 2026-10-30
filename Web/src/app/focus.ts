// Focus goes back where the listener was when a layer (Now Playing, a sheet, a pop-up) closes. Without
// this, closing one drops focus on the page itself and a keyboard or screen-reader user starts over at
// the top (WCAG 2.4.3).
import { useEffect, useState } from 'react';

/**
 * On unmount, focuses what had focus when the component first rendered. If that element is gone (the
 * mini player unmounts while Now Playing is open), focuses the first match of `fallback`, then the
 * screen's heading.
 */
export function useRestoreFocus(fallback?: string): void {
  // Read during the first render, before any child effect moves focus into the new layer.
  const [before] = useState(() => document.activeElement as HTMLElement | null);
  useEffect(
    () => () => {
      // After React has finished the commit that removed this layer and put the opener back.
      requestAnimationFrame(() => {
        const active = document.activeElement;
        if (active && active !== document.body) return;
        if (before && before !== document.body && before.isConnected) {
          before.focus();
          return;
        }
        const next = (fallback ? document.querySelector<HTMLElement>(fallback) : null) ?? document.querySelector<HTMLElement>('main h1');
        next?.focus();
      });
    },
    [before, fallback],
  );
}
