// Opened marks (#5275): when a friend presses Play (or another start control) on a link's arrival, this browser tells the
// link server that the link was opened, so the sender's app can show "Opened". It sends only the opened-token, an HMAC of
// the link id under the link's key, so a messenger's preview fetcher holding only `/l/<id>` can't fake or read a mark. It
// sends nothing when the server didn't offer marks (no `X-SM-Link-Opened: 1`), when the listener turned it off in Settings,
// when this browser already sent it, or inside the sender's hidden play check (#4454). The app makes the same token
// (`ShareLinkOpenedToken`); both are held to research/B4/contracts/fixtures/share-link-opened-token.json.
import { playCheckHandler } from '../play-check.ts';

export const OPENED_LABEL = 'spoken-margins opened v1 ';
/** How long a sent link is remembered: a day past the link's 30-day life. */
export const SIGNALLED_KEEP_MS = 31 * 24 * 60 * 60 * 1000;

/** The opened-token: lowercase hex of HMAC-SHA256(key, "spoken-margins opened v1 " + id). */
export async function openedToken(key: Uint8Array, id: string, subtle: SubtleCrypto = crypto.subtle): Promise<string> {
  const hmacKey = await subtle.importKey('raw', key as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await subtle.sign('HMAC', hmacKey, new TextEncoder().encode(OPENED_LABEL + id)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** What decides whether this arrival may signal, and shows the notice. */
export interface OpenedGate {
  /** The packet answer carried `X-SM-Link-Opened: 1`. */
  offered: boolean;
  /** Settings' switch. */
  receiptsOn: boolean;
  signalled: Readonly<Record<string, string>>;
  id: string;
  /** Inside the sender's hidden play check. */
  probe: boolean;
}

export function mayOffer(gate: OpenedGate): boolean {
  return gate.offered && gate.receiptsOn && !gate.probe && !Object.hasOwn(gate.signalled, gate.id);
}

/** True inside the sender's hidden play check (#4454), which must never count as an open. */
export function inSenderCheck(host: unknown = globalThis): boolean {
  return playCheckHandler(host) !== undefined;
}

/**
 * Posts the mark. A simple request (`no-cors`, a text body, no extra headers), so the browser sends no preflight and no
 * cookie, and the page never reads the answer. True when the request left; a network failure is false, and the next
 * start control on the same arrival tries again. A `no-cors` answer can't be read, so a refused post (429) also counts
 * as sent and is not retried; the app, which can read it, counts only a 204.
 */
export async function postOpened(origin: string, id: string, token: string, fetchImpl: typeof fetch = fetch): Promise<boolean> {
  try {
    await fetchImpl(`${origin}/l/${id}/opened`, {
      method: 'POST',
      mode: 'no-cors',
      credentials: 'omit',
      cache: 'no-store',
      keepalive: true,
      redirect: 'error',
      referrerPolicy: 'no-referrer',
      body: token,
    });
    return true;
  } catch {
    return false;
  }
}

/** The signalled set with `id` added and entries past 31 days dropped. */
export function withSignalled(signalled: Readonly<Record<string, string>>, id: string, now: Date): Record<string, string> {
  const kept = Object.entries(signalled).filter(([, at]) => {
    const time = Date.parse(at);
    return Number.isFinite(time) && now.getTime() - time < SIGNALLED_KEEP_MS;
  });
  return { ...Object.fromEntries(kept), [id]: now.toISOString() };
}

/** "When you open these Margins, Ana can see that you did." `who` is the arrival's name, or 'your friend'. */
export function openedNotice(who: string): string {
  return `When you open these Margins, ${who} can see that you did.`;
}

/** "Don't tell Ana", or "Don't tell them" with no name. */
export function dontTellLabel(who: string): string {
  return `Don’t tell ${who === 'your friend' ? 'them' : who}`;
}

/** What the notice says after Don't tell, for the rest of the arrival. */
export function toldNotNotice(who: string): string {
  return `${who === 'your friend' ? 'Your friend' : who} won’t be told. Change this in Settings.`;
}

/** The dependencies of one arrival's signal, so the tests can drive it with no network. */
export interface OpenedSignalPorts {
  gate: () => OpenedGate;
  token: () => Promise<string>;
  post: (token: string) => Promise<boolean>;
  remember: (id: string) => Promise<void>;
}

/**
 * One arrival's signal: the first start control sends it, a second tap while it is in flight sends nothing, and a
 * failed send is tried again by the next start control. Fire and forget: the caller has already started the sound.
 */
export function openedSignaller(ports: OpenedSignalPorts): () => Promise<void> {
  let inFlight = false;
  let sent = false;
  return async () => {
    const gate = ports.gate();
    if (inFlight || sent || !mayOffer(gate)) return;
    inFlight = true;
    try {
      if (await ports.post(await ports.token())) {
        sent = true;
        await ports.remember(gate.id);
      }
    } catch {
      // Not sent; the next start control tries again.
    } finally {
      inFlight = false;
    }
  };
}
