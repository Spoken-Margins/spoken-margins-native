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
