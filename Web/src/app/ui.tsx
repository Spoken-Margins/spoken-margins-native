// Small shared UI: the toast, the relay consent pop-up, and `useRelay`, which wraps any feed read so a
// feed the browser can't read asks the listener once before anything goes through the server.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useData } from './data.tsx';
import { useRestoreFocus } from './focus.ts';
import { NeedsRelayConsent } from './ports.ts';
import { close, expired, pause, remainingMs, resume, start, toastMs } from './logic/toast-timer.ts';

// The pop-up text for the feed relay (#2977, owner 2026-10-30: "you need to use a route through our
// server, and we don't collect data"). Settings shows the same words.
export const RELAY_TITLE = 'Read this feed through our server?';
export const RELAY_BODY =
  'Your browser isn’t allowed to read this feed directly. Spoken Margins can read it through its own server instead. ' +
  'The server passes the feed straight to you and keeps nothing: no record of what you follow or play, and nothing that identifies you.';

/** A button on an info toast, such as Undo. `run` is called once, and the toast closes. */
export interface ToastAction {
  label: string;
  run(): void | Promise<void>;
}

interface Toast {
  id: number;
  text: string;
  tone: 'info' | 'problem';
  action?: ToastAction;
}

interface UiApi {
  toast(text: string, tone?: Toast['tone'], action?: ToastAction): void;
  /**
   * A standing problem that is on screen exactly while its owner says so: `notice(key, text)` shows it, `notice(key,
   * undefined)` takes it down, and calling it again with the same words changes nothing. Unlike `toast` it is a state to
   * show, not an event, so it never depends on when it was raised. `onClose` is called when the listener closes it.
   */
  notice(key: string, text: string | undefined, onClose?: () => void): void;
  askRelay(): Promise<boolean>;
}

const UiContext = createContext<UiApi | null>(null);

export function UiProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [notices, setNotices] = useState<Record<string, { text: string; onClose?: () => void }>>({});
  const [asking, setAsking] = useState<((yes: boolean) => void) | null>(null);
  const nextId = useRef(1);

  const dismiss = useCallback((id: number) => setToasts((list) => list.filter((t) => t.id !== id)), []);
  // A note goes after a few seconds, and only the latest is shown. A problem stays until the listener
  // closes it, so nobody has to read it against a timer (WCAG 2.2.1).
  const toast = useCallback(
    (text: string, tone: Toast['tone'] = 'info', action?: ToastAction) => {
      const id = nextId.current++;
      // Only an info toast has an action, and each one keeps its own timer (`InfoToast`).
      setToasts((list) => [...list.filter((t) => t.tone === 'problem'), { id, text, tone, action: tone === 'info' ? action : undefined }]);
    },
    [],
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

  const askRelay = useCallback(() => new Promise<boolean>((resolve) => setAsking(() => resolve)), []);

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
              <InfoToast key={t.id} text={t.text} action={t.action} onDone={() => dismiss(t.id)} />
            ))}
        </div>
      </div>
      {asking && (
        <RelayDialog
          onAnswer={(yes) => {
            asking(yes);
            setAsking(null);
          }}
        />
      )}
    </UiContext.Provider>
  );
}

/**
 * One info toast with its own timer: 6 s, fixed, for a plain note; 10 s for one with a button, paused while keyboard
 * focus or the pointer is inside it (#4424, WCAG 2.2.1). The action runs once and closes the toast.
 */
function InfoToast({ text, action, onDone }: { text: string; action?: ToastAction; onDone: () => void }) {
  const hasAction = action !== undefined;
  const timer = useRef(start(toastMs(hasAction), performance.now()));
  const done = useRef(onDone);
  done.current = onDone;
  const ran = useRef(false);
  const [focused, setFocused] = useState(false);
  const [hovered, setHovered] = useState(false);
  const paused = hasAction && (focused || hovered);

  useEffect(() => {
    timer.current = paused ? pause(timer.current, performance.now()) : resume(timer.current, performance.now());
    if (paused) return;
    const id = window.setTimeout(() => {
      const result = expired(timer.current, performance.now());
      timer.current = result.timer;
      if (result.fire) done.current();
    }, remainingMs(timer.current, performance.now()));
    return () => window.clearTimeout(id);
  }, [paused]);

  const onAction = () => {
    if (!action || ran.current) return;
    ran.current = true;
    timer.current = close(timer.current);
    done.current();
    Promise.resolve()
      .then(() => action.run())
      .catch((error) => console.error('A toast action failed.', error));
  };

  return (
    <p
      className={hasAction ? 'toast toast-info toast-with-action' : 'toast toast-info'}
      onPointerEnter={hasAction ? () => setHovered(true) : undefined}
      onPointerLeave={hasAction ? () => setHovered(false) : undefined}
      onFocus={hasAction ? () => setFocused(true) : undefined}
      onBlur={hasAction ? () => setFocused(false) : undefined}
    >
      <span className="toast-mark" aria-hidden="true">
        i
      </span>
      {hasAction ? <span>{text}</span> : text}
      {action && (
        <button type="button" className="toast-action" onClick={onAction}>
          {action.label}
        </button>
      )}
    </p>
  );
}

function RelayDialog({ onAnswer }: { onAnswer: (yes: boolean) => void }) {
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

/** Runs a feed read, asking once for the relay when the browser can't read the feed itself. */
export function useRelay() {
  const { settings, setSetting } = useData();
  const { askRelay } = useUi();
  return useCallback(
    async <T,>(read: (relayAllowed: boolean) => Promise<T>): Promise<T> => {
      try {
        return await read(settings.relayAllowed);
      } catch (error) {
        if (!(error instanceof NeedsRelayConsent)) throw error;
        // Offline, every feed read fails the way a refused one does. Asking about the server then would
        // be the wrong question, and a "Not now" would be remembered for good.
        if (!navigator.onLine) throw new Error('You’re offline. Connect to the internet and try again.');
        if (settings.relayAsked) {
          throw new Error('This feed needs our server to read it. Reading feeds through the server is off in Settings.');
        }
        const yes = await askRelay();
        await setSetting('relayAsked', true);
        await setSetting('relayAllowed', yes);
        if (!yes) throw new Error('Not followed. This feed can only be read through our server.');
        return read(true);
      }
    },
    [settings.relayAllowed, settings.relayAsked, setSetting, askRelay],
  );
}
