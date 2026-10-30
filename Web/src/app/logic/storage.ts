// Keeping a listener's Margins when the browser's storage fails (#3012). A listener's Margins are their data
// (AGENTS.md, "Protect owner data"), so nothing here may drop one without telling them:
// - a failed write names what wasn't saved and why, in one plain sentence;
// - persistent storage is asked for once, after the first saved Margin, never on load;
// - Settings says plainly when the browser hasn't agreed to keep them.
// Plain TypeScript, so `npm run test:web` covers it (storage.test.ts).

/** What a failed write leaves the listener with: the first sentence names it, the second says why. */
export const STORAGE_REASONS = Object.freeze({
  full: 'This browser has run out of space for this site. Back up your Margins in Settings, then free some space.',
  refused: 'This browser wouldn’t store it. Try again, and back up your Margins in Settings if it keeps happening.',
});

/** Whether a browser storage error means the site is out of space. Looks through `cause`, as wrappers keep it there. */
export function isQuotaError(error: unknown): boolean {
  for (let current = error, depth = 0; current && depth < 4; depth += 1) {
    if (typeof current !== 'object') return false;
    const { name, code } = current as { name?: unknown; code?: unknown };
    // Chrome and Safari name it; old Safari gives only code 22; Firefox's IndexedDB once used its own name.
    if (name === 'QuotaExceededError' || name === 'NS_ERROR_DOM_QUOTA_REACHED' || code === 22 || code === 1014) return true;
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}

/** One plain message for a write that failed: `lead` names what (“Your Margin at 12:04 wasn’t saved.”). */
export function notSavedMessage(lead: string, error: unknown): string {
  return `${lead} ${isQuotaError(error) ? STORAGE_REASONS.full : STORAGE_REASONS.refused}`;
}

/** A write that failed and has already been shown to the listener, so a caller doesn't show it twice. */
export class NotSavedError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = 'NotSavedError';
  }
}

/**
 * Which failures to show. A write the listener asked for (a Margin, a follow) is shown every time it fails. The
 * ones the app makes on its own every few seconds (your place in an episode, a setting) are shown on the first
 * failure only, and again only after one of that kind has worked, so a full disk doesn't stack a toast a second.
 */
export type WriteKind = 'margin' | 'delete-margin' | 'follow' | 'unfollow' | 'episode' | 'position' | 'setting';
const QUIET_REPEATS: ReadonlySet<WriteKind> = new Set(['position', 'setting']);

export class FailureGate {
  readonly #failing = new Set<WriteKind>();

  /** Call when a write fails; true when the listener should be told. */
  failed(kind: WriteKind): boolean {
    if (!QUIET_REPEATS.has(kind)) return true;
    if (this.#failing.has(kind)) return false;
    this.#failing.add(kind);
    return true;
  }

  /** Call when a write works, so the next failure of its kind is shown again. */
  worked(kind: WriteKind): void {
    this.#failing.delete(kind);
  }
}

/**
 * Whether the browser keeps this site's storage when space runs low. `unknown` until it has been checked;
 * `unsupported` where the browser has no StorageManager.persist (some older and in-app browsers).
 */
export type PersistState = 'unknown' | 'kept' | 'not-kept' | 'unsupported';

/**
 * Ask the browser to keep storage only once there is something worth keeping: after a Margin is saved, never on
 * load, and only once (Firefox shows a prompt; asking on every Margin would nag).
 */
export function shouldAskToPersist(state: PersistState, asked: boolean, marginsSaved: number): boolean {
  return marginsSaved > 0 && !asked && (state === 'not-kept' || state === 'unknown');
}

/** The quiet line Settings shows when the browser hasn't agreed to keep the listener's Margins, or nothing. */
export function persistNote(state: PersistState, asked: boolean): string | undefined {
  if (state === 'unsupported') return 'This browser doesn’t promise to keep your Margins if space runs low, so back them up now and then.';
  if (state === 'not-kept' && asked) return 'This browser hasn’t agreed to keep your Margins for good, and may clear them if space runs low. Back them up now and then.';
  return undefined;
}

/** “Last backed up 30 Oct 2026, 9:12 pm”, or that there has been no backup yet. */
export function lastBackupLine(iso: string | undefined, locale?: string): string {
  const when = iso ? new Date(iso) : undefined;
  if (!when || Number.isNaN(when.getTime())) return 'Not backed up yet.';
  const date = when.toLocaleDateString(locale, { day: 'numeric', month: 'short', year: 'numeric' });
  const time = when.toLocaleTimeString(locale, { hour: 'numeric', minute: '2-digit' });
  return `Last backed up ${date}, ${time}.`;
}
