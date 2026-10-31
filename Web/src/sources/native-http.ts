// Native HTTP for the Android app (#2981). Inside the Capacitor wrapper, feeds, Substack pages and podcast search
// are read with Android's own HTTP stack, so no site's browser rules (CORS) apply: there is no relay and no
// consent pop-up (owner, 2026-10-30: "so it doesn't require a server to hit the podcasts"). In a browser the read
// path is unchanged.
//
// This file only picks the transport and adapts Capacitor's answer into a `Response`. Everything about what is read
// and when (the post-page tap rule, size caps, redirects, parsing) stays in `read.ts` and `search.ts`, so both
// transports share it. It imports no package: it calls the bridge Capacitor injects into the WebView
// (`window.Capacitor`, from `@capacitor/android`'s native-bridge.js), which is what `@capacitor/core` calls too.

import type { FetchLike } from './search.ts';

/** How a read reaches the site: the browser's `fetch`, or the Android app's own HTTP stack. */
export interface ReadTransport {
  kind: 'browser' | 'native';
  fetch: FetchLike;
}

/** The two members of Capacitor's injected bridge this file uses. */
export interface CapacitorBridge {
  isNativePlatform: () => boolean;
  nativePromise: (pluginName: string, methodName: string, options: Record<string, unknown>) => Promise<unknown>;
}

/** What `CapacitorHttp.request` resolves with (`HttpResponse` in `@capacitor/core`). */
interface NativeHttpResponse {
  status?: unknown;
  headers?: unknown;
  url?: unknown;
  data?: unknown;
}

/** Connect and read timeouts for a native read. The browser's own defaults are longer; a feed that takes 30 s is down. */
export const NATIVE_TIMEOUT_MS = 30_000;

/** Statuses whose `Response` must have no body. */
const NULL_BODY_STATUSES = new Set([101, 103, 204, 205, 304]);

/** The native bridge when this page runs inside the Capacitor app, else undefined (a browser, or node in tests). */
export function capacitorBridge(host: unknown = globalThis): CapacitorBridge | undefined {
  const cap = (host as { Capacitor?: Partial<CapacitorBridge> } | null | undefined)?.Capacitor;
  if (!cap || typeof cap.isNativePlatform !== 'function' || typeof cap.nativePromise !== 'function') return undefined;
  try {
    return cap.isNativePlatform() ? (cap as CapacitorBridge) : undefined;
  } catch {
    return undefined;
  }
}

/** The browser's `fetch`, looked up at call time so a test or a later polyfill is honoured. */
export const browserFetch: FetchLike = (input, init) => fetch(input, init);

/** Picks native HTTP inside the Capacitor app and the browser's `fetch` everywhere else. */
export function pickReadTransport(host: unknown = globalThis): ReadTransport {
  const bridge = capacitorBridge(host);
  return bridge ? { kind: 'native', fetch: nativeFetch(bridge) } : { kind: 'browser', fetch: browserFetch };
}

function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === 'object' && typeof (error as { message?: unknown }).message === 'string') return (error as { message: string }).message;
  return String(error);
}

function requestHeaders(init: RequestInit | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  new Headers(init?.headers).forEach((value, key) => {
    out[key] = value;
  });
  return out;
}

function responseHeaders(raw: unknown): Headers {
  const headers = new Headers();
  if (!raw || typeof raw !== 'object') return headers;
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof value !== 'string') continue;
    try {
      headers.append(key, value);
    } catch {
      // Android can report a header the Fetch API refuses (a status-line pseudo-header, say). Drop it.
    }
  }
  return headers;
}

function responseBody(status: number, data: unknown): string | null {
  if (NULL_BODY_STATUSES.has(status)) return null;
  if (data === undefined || data === null) return '';
  // Capacitor parses a JSON content type into an object whatever `responseType` asked for.
  return typeof data === 'string' ? data : JSON.stringify(data);
}

/** Turns what native HTTP answered into the `Response` the read path expects, `url` included. */
export function toResponse(raw: unknown, requestedUrl: string): Response {
  const answer = (raw ?? {}) as NativeHttpResponse;
  const status = answer.status;
  if (typeof status !== 'number' || !Number.isInteger(status) || status < 200 || status > 599) {
    throw new TypeError(`Network request failed: native HTTP answered with status ${String(status)}.`);
  }
  const response = new Response(responseBody(status, answer.data), { status, headers: responseHeaders(answer.headers) });
  // `url` is a getter on Response's prototype; Capacitor's own patched fetch sets it the same way.
  const finalUrl = typeof answer.url === 'string' && answer.url ? answer.url : requestedUrl;
  Object.defineProperty(response, 'url', { value: finalUrl });
  return response;
}

/**
 * A `fetch` for GET reads through `CapacitorHttp.request`. Credentials are never sent: native HTTP has no browser
 * cookies unless `CapacitorCookies` is on, and the app leaves it off. A failure to connect rejects with a
 * `TypeError` naming the network, like a browser's `fetch`, so the UI says "offline" for both.
 */
export function nativeFetch(bridge: CapacitorBridge): FetchLike {
  return async (input, init) => {
    const method = (init?.method ?? 'GET').toUpperCase();
    if (method !== 'GET') throw new TypeError(`Native HTTP here reads only; ${method} is not supported.`);
    let raw: unknown;
    try {
      raw = await bridge.nativePromise('CapacitorHttp', 'request', {
        url: input,
        method: 'GET',
        headers: requestHeaders(init),
        responseType: 'text',
        connectTimeout: NATIVE_TIMEOUT_MS,
        readTimeout: NATIVE_TIMEOUT_MS,
      });
    } catch (error) {
      throw new TypeError(`Network request failed: ${messageOf(error)}`);
    }
    return toResponse(raw, input);
  };
}
