// Sealing and uploading a share link, for the Mac's make-share-link command (#3239) and the tests that seed a link
// server. The web app never imports this file: it is receive-only for links (owner, 2026-11-05, #3542), and
// src/app/no-link-creation.test.ts fails if anything under src/app or the opening code reaches it. Opening is in
// src/packet/share-link.ts.
//
// The sealed format is the app's ShareLinkSealing, held to research/B4/contracts/fixtures/share-link-sealing-vector.json.

import { base64url } from '../packet/bytes.ts';
import { PART } from '../packet/share-link.ts';

const MAGIC = [0x53, 0x4d, 0x4c, 0x49, 0x4e, 0x4b]; // "SMLINK"
const VERSION = 1;

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
  /** The Spoken Margins server, e.g. `https://spokenmargins.com`. */
  server: string;
  fetch?: typeof fetch;
}

/**
 * Uploads an already sealed link and returns the link to send. Only the Mac's make-share-link command (#3239) calls it.
 */
export async function postSealedLink(sealed: SealedLink, options: UploadOptions): Promise<{ url: string; expiresAt?: string }> {
  const send = options.fetch ?? fetch;
  const base = new URL(options.server);
  if (!uploadableServer(base)) throw new Error('share links upload over https only');
  const response = await send(new URL('/api/v1/links', base), { method: 'POST', body: uploadForm(sealed) });
  if (!response.ok) throw new ShareLinkUploadError(response.status);
  const body = (await response.json()) as { id?: string; path?: string; expiresAt?: string };
  if (!body.path || !/^\/l\/[A-Za-z0-9_-]+$/.test(body.path)) throw new Error('share link upload returned no link');
  return { url: `${new URL(body.path, base).href}#${sealed.keyFragment}`, ...(body.expiresAt && { expiresAt: body.expiresAt }) };
}
