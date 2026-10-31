// Small shared UI: the toast, the relay consent pop-up, and `useRelay`, which wraps any feed read so a
// feed the browser can't read asks the listener once before anything goes through the server.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { useData } from './data.tsx';
import { NeedsRelayConsent } from './ports.ts';

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
  askRelay(): Promise<boolean>;
}

const UiContext = createContext<UiApi | null>(null);

export function UiProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [asking, setAsking] = useState<((yes: boolean) => void) | null>(null);
  const nextId = useRef(1);

  const toast = useCallback((text: string, tone: Toast['tone'] = 'info') => {
    const id = nextId.current++;
    setToasts((list) => [...list, { id, text, tone }]);
    window.setTimeout(() => setToasts((list) => list.filter((t) => t.id !== id)), 5000);
  }, []);

  const askRelay = useCallback(() => new Promise<boolean>((resolve) => setAsking(() => resolve)), []);

  const api = useMemo(() => ({ toast, askRelay }), [toast, askRelay]);
  return (
    <UiContext.Provider value={api}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {toasts.map((t) => (
          <p key={t.id} className={`toast toast-${t.tone}`}>
            <span className="toast-mark" aria-hidden="true">{t.tone === 'problem' ? '!' : 'i'}</span>
            {t.text}
          </p>
        ))}
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

function RelayDialog({ onAnswer }: { onAnswer: (yes: boolean) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
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
