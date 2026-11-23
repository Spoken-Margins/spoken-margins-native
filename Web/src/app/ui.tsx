// Small shared UI: the toast, the relay consent pop-up, and `useRelay`, which wraps any feed read so a
// feed the browser can't read asks the listener once before anything goes through the server.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useData } from './data.tsx';
import { useRestoreFocus } from './focus.ts';
import { NeedsRelayConsent } from './ports.ts';
import { looksPrivateFeedLink, RELAY_PRIVATE_LINE, relayOnFirstRead, settingsAfterAnswer, whenBlocked } from './logic/relay-consent.ts';

// The pop-up text for the feed relay (#2977, owner 2026-10-30: "you need to use a route through our
// server, and we don't collect data"). Settings shows the same words.
export const RELAY_TITLE = 'Read this feed through our server?';
export const RELAY_BODY =
  'Your browser isn’t allowed to read this feed directly. Spoken Margins can read it through its own server instead. ' +
  'The server passes the feed straight to you and keeps nothing: no record of what you follow or play, and nothing that identifies you.';

interface Toast {
  id: number;
  text: string;
  tone: 'info' | 'problem';
}

interface UiApi {
  toast(text: string, tone?: Toast['tone']): void;
  /**
   * A standing problem that is on screen exactly while its owner says so: `notice(key, text)` shows it, `notice(key,
   * undefined)` takes it down, and calling it again with the same words changes nothing. Unlike `toast` it is a state to
   * show, not an event, so it never depends on when it was raised. `onClose` is called when the listener closes it.
   */
  notice(key: string, text: string | undefined, onClose?: () => void): void;
  /** Shows the consent pop-up; `privateLink` adds the line that names a private-looking link (#4176). */
  askRelay(privateLink?: boolean): Promise<boolean>;
}

const UiContext = createContext<UiApi | null>(null);

export function UiProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [notices, setNotices] = useState<Record<string, { text: string; onClose?: () => void }>>({});
  const [asking, setAsking] = useState<{ answer: (yes: boolean) => void; privateLink: boolean } | null>(null);
  const nextId = useRef(1);

  const dismiss = useCallback((id: number) => setToasts((list) => list.filter((t) => t.id !== id)), []);
  // A note goes after a few seconds, and only the latest is shown. A problem stays until the listener
  // closes it, so nobody has to read it against a timer (WCAG 2.2.1).
  const toast = useCallback(
    (text: string, tone: Toast['tone'] = 'info') => {
      const id = nextId.current++;
      setToasts((list) => [...list.filter((t) => t.tone === 'problem'), { id, text, tone }]);
      if (tone === 'info') window.setTimeout(() => dismiss(id), 6000);
    },
    [dismiss],
  );

  const notice = useCallback((key: string, text: string | undefined, onClose?: () => void) => {
    setNotices((now) => {
      if (text === undefined) {
        if (!(key in now)) return now;
        const { [key]: _gone, ...rest } = now;
        return rest;
      }
      return now[key]?.text === text ? now : { ...now, [key]: { text, onClose } };
    });
  }, []);

  const askRelay = useCallback(
    (privateLink = false) => new Promise<boolean>((resolve) => setAsking({ answer: resolve, privateLink })),
    [],
  );

  const api = useMemo(() => ({ toast, notice, askRelay }), [toast, notice, askRelay]);
  return (
    <UiContext.Provider value={api}>
      {children}
      <div className="toasts">
        {/* role="alert" is announced when it arrives with its text, so it exists only while there is a
            problem; the status region below stays in place so polite notes are heard. */}
        {(toasts.some((t) => t.tone === 'problem') || Object.keys(notices).length > 0) && (
        <div role="alert">
          {Object.entries(notices).map(([key, n]) => (
            <p key={key} className="toast toast-problem">
              <span className="toast-mark" aria-hidden="true">
                !
              </span>
              <span>{n.text}</span>
              <button
                type="button"
                className="toast-close"
                onClick={() => {
                  n.onClose?.();
                  notice(key, undefined);
                }}
              >
                Close
              </button>
            </p>
          ))}
          {toasts
            .filter((t) => t.tone === 'problem')
            .map((t) => (
              <p key={t.id} className="toast toast-problem">
                <span className="toast-mark" aria-hidden="true">
                  !
                </span>
                <span>{t.text}</span>
                <button type="button" className="toast-close" onClick={() => dismiss(t.id)}>
                  Close
                </button>
              </p>
            ))}
        </div>
        )}
        <div role="status">
          {toasts
            .filter((t) => t.tone === 'info')
            .map((t) => (
              <p key={t.id} className="toast toast-info">
                <span className="toast-mark" aria-hidden="true">
                  i
                </span>
                {t.text}
              </p>
            ))}
        </div>
      </div>
      {asking && (
        <RelayDialog
          privateLink={asking.privateLink}
          onAnswer={(yes) => {
            asking.answer(yes);
            setAsking(null);
          }}
        />
      )}
    </UiContext.Provider>
  );
}

function RelayDialog({ privateLink, onAnswer }: { privateLink: boolean; onAnswer: (yes: boolean) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useRestoreFocus();
  useEffect(() => {
    const dialog = ref.current;
    if (dialog && !dialog.open) dialog.showModal();
  }, []);
  return (
    <dialog ref={ref} className="dialog" aria-labelledby="relay-title" onCancel={() => onAnswer(false)}>
      <h2 id="relay-title">{RELAY_TITLE}</h2>
      <p>{RELAY_BODY}</p>
      {privateLink && <p data-testid="relay-private-line">{RELAY_PRIVATE_LINE}</p>}
      <p className="muted">You can change this any time in Settings.</p>
      <div className="dialog-actions">
        <button type="button" className="button" onClick={() => onAnswer(false)}>
          Not now
        </button>
        <button type="button" className="button button-primary" onClick={() => onAnswer(true)}>
          Use the server
        </button>
      </div>
    </dialog>
  );
}

export function useUi(): UiApi {
  const api = useContext(UiContext);
  if (!api) throw new Error('useUi outside UiProvider');
  return api;
}

/**
 * Wraps a feed read so a feed the browser can't read asks the listener before anything goes through the server.
 * `options.link` is the address being read: following a private-looking one (a paid show's RSS link) never sends it
 * through the server without asking, even with the server on, and the pop-up names it (#4176, owner 2026-11-21).
 * That named yes also covers the show's later refreshes (refresh.tsx), which use the standing server setting.
 */
export function useRelay() {
  const { settings, setSetting } = useData();
  const { askRelay } = useUi();
  return useCallback(
    async <T,>(read: (relayAllowed: boolean) => Promise<T>, options: { link?: string } = {}): Promise<T> => {
      const privateLink = options.link !== undefined && looksPrivateFeedLink(options.link);
      try {
        return await read(relayOnFirstRead(settings, privateLink));
      } catch (error) {
        if (!(error instanceof NeedsRelayConsent)) throw error;
        // Offline, every feed read fails the way a refused one does. Asking about the server then would
        // be the wrong question, and a "Not now" would be remembered for good.
        if (!navigator.onLine) throw new Error('You’re offline. Connect to the internet and try again.');
        if (whenBlocked(settings) === 'off') {
          throw new Error('This feed needs our server to read it. Reading feeds through the server is off in Settings.');
        }
        const yes = await askRelay(privateLink);
        const changes = settingsAfterAnswer(settings, yes);
        if (changes.relayAsked !== undefined) await setSetting('relayAsked', changes.relayAsked);
        if (changes.relayAllowed !== undefined) await setSetting('relayAllowed', changes.relayAllowed);
        if (!yes) throw new Error('Not followed. This feed can only be read through our server.');
        return read(true);
      }
    },
    [settings, setSetting, askRelay],
  );
}
