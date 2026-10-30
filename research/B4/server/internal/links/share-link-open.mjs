// Opens a sealed share link in the browser (#805). The landing page for friends without the app
// embeds this module: it reads the key from location.hash (never sent to the server), fetches the
// sealed preview, and decrypts it here with WebCrypto. The server only ever holds sealed bytes.
//
// Format, shared with the app's ShareLinkSealing (SessionKit): a sealed part is
//   header (8: "SMLINK", version 1, part) || nonce (12) || ciphertext || tag (16)
// and the header is the AES-256-GCM additional data. Both sides are checked against
// research/B4/contracts/fixtures/share-link-sealing-vector.json.

export const PART = Object.freeze({ preview: 1, packet: 2 });

export const DAMAGED_MESSAGE = 'This link is incomplete or damaged.';

const MAGIC = [0x53, 0x4d, 0x4c, 0x49, 0x4e, 0x4b]; // "SMLINK"
const VERSION = 1;
const HEADER_LENGTH = MAGIC.length + 2;
const NONCE_LENGTH = 12;
const TAG_LENGTH = 16;
const KEY_LENGTH = 32;

/** Every failure, from a missing key to a flipped byte, is this one plain error. */
export class DamagedLinkError extends Error {
  constructor() {
    super(DAMAGED_MESSAGE);
    this.name = 'DamagedLinkError';
  }
}

/** The 32-byte key from a link's `#` part (with or without the `#`), or null. */
export function keyFromFragment(hash) {
  if (typeof hash !== 'string') return null;
  const fragment = hash.startsWith('#') ? hash.slice(1) : hash;
  const match = /^([A-Za-z0-9_-]+)=*$/.exec(fragment);
  if (!match) return null;
  const base64 = match[1].replace(/-/g, '+').replace(/_/g, '/');
  if (base64.length % 4 === 1) return null;
  let binary;
  try {
    binary = atob(base64 + '='.repeat((4 - (base64.length % 4)) % 4));
  } catch {
    return null;
  }
  if (binary.length !== KEY_LENGTH) return null;
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/** Decrypts one sealed part. Throws DamagedLinkError for a missing key or any damage. */
export async function openPart(sealed, part, keyBytes, subtle = globalThis.crypto?.subtle) {
  if (!keyBytes || keyBytes.length !== KEY_LENGTH || !subtle) throw new DamagedLinkError();
  const bytes = sealed instanceof Uint8Array ? sealed : new Uint8Array(sealed);
  const header = Uint8Array.from([...MAGIC, VERSION, part]);
  if (bytes.length < HEADER_LENGTH + NONCE_LENGTH + TAG_LENGTH) throw new DamagedLinkError();
  for (let i = 0; i < HEADER_LENGTH; i += 1) {
    if (bytes[i] !== header[i]) throw new DamagedLinkError();
  }
  try {
    const key = await subtle.importKey('raw', keyBytes, { name: 'AES-GCM' }, false, ['decrypt']);
    const plaintext = await subtle.decrypt(
      {
        name: 'AES-GCM',
        iv: bytes.subarray(HEADER_LENGTH, HEADER_LENGTH + NONCE_LENGTH),
        additionalData: header,
        tagLength: TAG_LENGTH * 8,
      },
      key,
      bytes.subarray(HEADER_LENGTH + NONCE_LENGTH),
    );
    return new Uint8Array(plaintext);
  } catch {
    throw new DamagedLinkError();
  }
}

/** Decrypts the sealed preview and parses its JSON, using the key in `hash` (location.hash). */
export async function openPreview(sealed, hash, subtle = globalThis.crypto?.subtle) {
  const plaintext = await openPart(sealed, PART.preview, keyFromFragment(hash), subtle);
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plaintext));
  } catch {
    throw new DamagedLinkError();
  }
}

// The share page's excerpt ceilings (owner, 2026-10-20, D16 in docs/legal/attorney-questions.md; #2237),
// in Unicode code points. The app's ExcerptCapRule (SessionKit) scales the "before" side to the comment
// (280 to 800) and holds "after" to 120; Builds 32 and 34 refuse packet context over 500 a side, so the
// "before" ceiling stays 500 until they retire. The server can't read the sealed preview, so the page
// checks these after opening it, as the server's ParsePreview did before #805 reached it.
export const MAX_BEFORE_CHARACTERS = 500;
export const MAX_AFTER_CHARACTERS = 120;

const codePoints = (value) => [...value].length;
const optionalString = (value) => value === undefined || typeof value === 'string';

/**
 * Checks an opened preview the way the server used to: a source title, at least one Margin, string
 * fields, and excerpts within the ceilings. Fields it doesn't know (such as `schema`) are ignored.
 * Returns only the fields the page shows; anything else fails as DamagedLinkError.
 */
export function checkPreview(preview) {
  const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
  if (!isObject(preview) || !isObject(preview.source) || !Array.isArray(preview.margins)) throw new DamagedLinkError();
  const { title, show, url } = preview.source;
  if (typeof title !== 'string' || title.trim() === '' || !optionalString(show) || !optionalString(url)) {
    throw new DamagedLinkError();
  }
  if (preview.margins.length === 0) throw new DamagedLinkError();
  const margins = preview.margins.map((margin) => {
    if (!isObject(margin) || typeof margin.text !== 'string' || !optionalString(margin.before) || !optionalString(margin.after)) {
      throw new DamagedLinkError();
    }
    const before = margin.before ?? '';
    const after = margin.after ?? '';
    if (codePoints(before) > MAX_BEFORE_CHARACTERS || codePoints(after) > MAX_AFTER_CHARACTERS) throw new DamagedLinkError();
    return { text: margin.text, before, after };
  });
  return { source: { title, show: show ?? '', url: url ?? '' }, margins };
}

/**
 * The source link the page may show, or '' to leave it out: http or https with a host, and no
 * credentials, query or fragment, which could disclose signed or private URLs.
 */
export function safeSourceURL(raw) {
  if (typeof raw !== 'string' || raw === '' || raw.trim() !== raw || /[\u0000-\u001f\u007f?#]/.test(raw)) return '';
  if (!/^https?:\/\/[^/]/i.test(raw)) return '';
  let url;
  try {
    url = new URL(raw);
  } catch {
    return '';
  }
  if ((url.protocol !== 'https:' && url.protocol !== 'http:') || url.hostname === '' || url.username !== '' || url.password !== '') {
    return '';
  }
  if (/%(?![0-9a-f]{2})/i.test(raw)) return '';
  return url.href;
}
