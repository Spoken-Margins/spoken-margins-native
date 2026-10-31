// Share links, built and OFF. A link is the packet and a small preview, each sealed with AES-256-GCM under a fresh
// key that travels only in the link's `#` part, so the server holds bytes it can't read (#805). The sealed format is
// the app's ShareLinkSealing; opening reuses the landing page's own module, and both are held to
// research/B4/contracts/fixtures/share-link-sealing-vector.json.
//
// SHARE_LINKS_ENABLED stays false in every build until the owner's gates clear: links reach the public only after
// the LLC, the DMCA designated agent and insurance exist (2026-10-20), and a feature is switched on only in a new
// reviewed build, never from a server switch or remote config (2026-10-17). Turning it on is a build change.
//
// The value is fixed when the app is built: Vite replaces `__SM_SHARE_LINKS__` (vite.config.ts), which is true
// only in the Playwright build `--mode share-links-test` (served from `dist-share-links/`, git-ignored, never
// hosted). Every other build, and Node's tests, read false.

import { base64url } from './bytes.ts';
import {
  DAMAGED_MESSAGE,
  DamagedLinkError,
  PART,
  keyFromFragment,
  openPart,
} from '../../../research/B4/server/internal/links/share-link-open.mjs';

declare const __SM_SHARE_LINKS__: boolean | undefined;

export const SHARE_LINKS_ENABLED: boolean = typeof __SM_SHARE_LINKS__ === 'boolean' && __SM_SHARE_LINKS__;

export { DAMAGED_MESSAGE, DamagedLinkError, PART, keyFromFragment, openPart };

const MAGIC = [0x53, 0x4d, 0x4c, 0x49, 0x4e, 0x4b]; // "SMLINK"
const VERSION = 1;

export class ShareLinksOffError extends Error {
  constructor() {
    super("Share links aren't available yet. Send the .spokenmargins file instead.");
    this.name = 'ShareLinksOffError';
  }
}

/** The preview a friend's browser shows before playing, as the landing page reads it. */
export interface LinkPreview {
  schema: 'spokenmargins.link-preview.v1';
  source: { title: string; show?: string; url?: string };
  margins: { text: string; before?: string; after?: string }[];
}

export interface SealedLink {
  /** The 32-byte key as the link's `#` part (base64url, no padding). */
  keyFragment: string;
  preview: Uint8Array;
  packet: Uint8Array;
}

/** header || nonce || AES-256-GCM(ciphertext || tag), with the header as additional data. */
export async function sealPart(plaintext: Uint8Array, part: number, key: Uint8Array, nonce: Uint8Array = crypto.getRandomValues(new Uint8Array(12))): Promise<Uint8Array> {
  if (key.length !== 32) throw new RangeError('a share-link key is 32 bytes');
  if (nonce.length !== 12) throw new RangeError('a share-link nonce is 12 bytes');
  const header = new Uint8Array([...MAGIC, VERSION, part]);
  const cryptoKey = await crypto.subtle.importKey('raw', key as BufferSource, 'AES-GCM', false, ['encrypt']);
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as BufferSource, additionalData: header, tagLength: 128 }, cryptoKey, plaintext as BufferSource,
  ));
  const out = new Uint8Array(header.length + nonce.length + sealed.length);
  out.set(header, 0);
  out.set(nonce, header.length);
  out.set(sealed, header.length + nonce.length);
  return out;
}

/** Seals a packet and its preview under one fresh key. `key` and the nonces are for the test vector only. */
export async function sealPacket(
  packet: Uint8Array,
  preview: LinkPreview | Uint8Array,
  fixed: { key?: Uint8Array; previewNonce?: Uint8Array; packetNonce?: Uint8Array } = {},
): Promise<SealedLink> {
  const key = fixed.key ?? crypto.getRandomValues(new Uint8Array(32));
  const previewBytes = preview instanceof Uint8Array ? preview : new TextEncoder().encode(JSON.stringify(preview));
  return {
    keyFragment: base64url(key),
    preview: await sealPart(previewBytes, PART.preview, key, fixed.previewNonce),
    packet: await sealPart(packet, PART.packet, key, fixed.packetNonce),
  };
}

/** The multipart body `POST /api/v1/links` takes: exactly `preview` and `packet`. */
export function uploadForm(sealed: SealedLink): FormData {
  const form = new FormData();
  form.append('preview', new Blob([sealed.preview as BlobPart], { type: 'application/octet-stream' }), 'preview');
  form.append('packet', new Blob([sealed.packet as BlobPart], { type: 'application/octet-stream' }), 'packet');
  return form;
}

/** The link server refused or failed the upload; `status` is its HTTP status. */
export class ShareLinkUploadError extends Error {
  readonly status: number;
  constructor(status: number) {
    super(`share link upload failed: ${status}`);
    this.name = 'ShareLinkUploadError';
    this.status = status;
  }
}

/** http only for this machine (a local stub link server in tests); every other server must be https. */
function uploadableServer(url: URL): boolean {
  if (url.protocol === 'https:') return true;
  return url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
}

export interface UploadOptions {
  /** The Spoken Margins server, e.g. `https://spokenmargins.proximitytoprogress.com`. */
  server: string;
  fetch?: typeof fetch;
}

/**
 * Seals and uploads a packet, returning the link to send (`<server>/l/<id>#<key>`). Refuses while
 * SHARE_LINKS_ENABLED is false, before anything is sealed or sent.
 */
export async function uploadLink(packet: Uint8Array, preview: LinkPreview, options: UploadOptions): Promise<{ url: string; expiresAt?: string }> {
  if (!SHARE_LINKS_ENABLED) throw new ShareLinksOffError();
  const sealed = await sealPacket(packet, preview);
  const send = options.fetch ?? fetch;
  const base = new URL(options.server);
  if (!uploadableServer(base)) throw new Error('share links upload over https only');
  const response = await send(new URL('/api/v1/links', base), { method: 'POST', body: uploadForm(sealed) });
  if (!response.ok) throw new ShareLinkUploadError(response.status);
  const body = (await response.json()) as { id?: string; path?: string; expiresAt?: string };
  if (!body.path || !/^\/l\/[A-Za-z0-9_-]+$/.test(body.path)) throw new Error('share link upload returned no link');
  return { url: `${new URL(body.path, base).href}#${sealed.keyFragment}`, ...(body.expiresAt && { expiresAt: body.expiresAt }) };
}
