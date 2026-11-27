// The reply box behind a share link (#4675, docs/design/reply-mailbox.md): the sender's phone makes a small box with each
// link, and a friend in the browser answers into it with "Send to <sender>". The web app makes no link and no box (the
// receive-only rule, as the owner allowed on 2026-11-26): it only reads the box's details from the link and posts one
// sealed answer. Plain TypeScript, so `npm run test:web` covers it against research/B4/contracts/fixtures/reply-box-vector.json.
//
// Wire contract (the design's "Wire contract" section):
// - The reply part is `GET <origin>/l/<id>/reply`: JSON {v:1, box, post, seal} sealed with the LINK key as SMLINK part 4,
//   the 8-byte header as additional data. Any failure, or no answer in 5 seconds, is "no reply part": today's Share section.
// - An answer is the `.spokenmargins` packet a file send writes, sealed as a club post: SMLINK part 2 under the seal key,
//   additional data the header then the 16 box id bytes, posted raw to `POST <origin>/api/v1/clubs/<box>/posts` with
//   `Authorization: Bearer <post proof>`.
import { PART, openPart } from '../../packet/share-link.ts';
import type { ShareLinkRef } from './share-link.ts';

/** The share-link part numbers with the reply part, which the landing page's own module doesn't know about. */
export const LINK_PART = Object.freeze({ ...PART, reply: 4 as const });

/** A link's reply part that has opened: where and how to post an answer. Never the box's secret, which only the phone holds. */
export interface ReplyBox {
  /** The link server's origin, which also takes the post. */
  origin: string;
  /** The share link's id, which marks the Margins sent through it (`sentThrough`). */
  linkId: string;
  /** The box id: 32 lowercase hex. */
  box: string;
  /** The post proof: 64 lowercase hex, sent as the bearer. */
  post: string;
  /** The 32-byte AES-256-GCM key an answer is sealed with. */
  seal: Uint8Array;
}

/** A reply fetch that hasn't answered in this long counts as none, so the friend can always act (Default taken 16). */
export const REPLY_FETCH_CEILING_MS = 5_000;
/** A post that hasn't answered in this long is "Couldn't send": a 10 MB answer on a slow phone line still fits. */
export const REPLY_POST_CEILING_MS = 120_000;

const MAGIC = [0x53, 0x4d, 0x4c, 0x49, 0x4e, 0x4b]; // "SMLINK"
const VERSION = 1;
const NONCE_LENGTH = 12;
const KEY_LENGTH = 32;
const BOX_ID = /^[0-9a-f]{32}$/;
const POST_PROOF = /^[0-9a-f]{64}$/;
const SEAL_KEY = /^[A-Za-z0-9_-]{43}$/;

function hexBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i += 1) out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function base64UrlBytes(text: string): Uint8Array | undefined {
  try {
    const binary = atob(text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (text.length % 4)) % 4));
    return Uint8Array.from(binary, (c) => c.charCodeAt(0));
  } catch {
    return undefined;
  }
}

/** Reads an opened reply part. Undefined for anything but `{v:1, box, post, seal}` in the wire shapes; unknown keys are ignored. */
export function readReplyPart(plaintext: Uint8Array): Pick<ReplyBox, 'box' | 'post' | 'seal'> | undefined {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plaintext));
  } catch {
    return undefined;
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const { v, box, post, seal } = value as Record<string, unknown>;
  if (v !== 1 || typeof box !== 'string' || typeof post !== 'string' || typeof seal !== 'string') return undefined;
  if (!BOX_ID.test(box) || !POST_PROOF.test(post) || !SEAL_KEY.test(seal)) return undefined;
  const key = base64UrlBytes(seal);
  if (!key || key.length !== KEY_LENGTH) return undefined;
  return { box, post, seal: key };
}

/** Opens a sealed reply part under the link key. Undefined when it doesn't open or isn't a reply part. */
export async function openReplyPart(sealed: Uint8Array, linkKey: Uint8Array): Promise<Pick<ReplyBox, 'box' | 'post' | 'seal'> | undefined> {
  try {
    return readReplyPart(await openPart(sealed, LINK_PART.reply, linkKey));
  } catch {
    return undefined;
  }
}

/** Runs `work` with an abort signal; `fallback` when it fails or hasn't answered in `ms`. Never rejects. */
export function withCeiling<T>(work: (signal: AbortSignal) => Promise<T>, ms: number, fallback: T): Promise<T> {
  const controller = new AbortController();
  return new Promise<T>((resolve) => {
    const timer = setTimeout(() => {
      controller.abort();
      resolve(fallback);
    }, ms);
    work(controller.signal).then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      () => {
        clearTimeout(timer);
        resolve(fallback);
      },
    );
  });
}

/**
 * Fetches and opens a link's reply part. Undefined for every failure (no box, an expired link, offline, damage, an older
 * server) and for no answer within `ceilingMs`: the caller then shows today's Share section. Never throws.
 */
export function fetchReplyBox(
  link: ShareLinkRef,
  fetchImpl: typeof fetch = fetch,
  ceilingMs: number = REPLY_FETCH_CEILING_MS,
): Promise<ReplyBox | undefined> {
  return withCeiling(
    async (signal) => {
      const response = await fetchImpl(`${link.origin}/l/${link.id}/reply`, {
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
        referrerPolicy: 'no-referrer',
        signal,
      });
      if (response.status !== 200) return undefined;
      const opened = await openReplyPart(new Uint8Array(await response.arrayBuffer()), link.key);
      return opened && { origin: link.origin, linkId: link.id, ...opened };
    },
    ceilingMs,
    undefined,
  );
}

/**
 * Seals an answer as a club post: header (SMLINK, version 1, part 2) || nonce || AES-256-GCM(packet), with the header
 * then the 16 box id bytes as additional data. The nonce is fresh unless a test passes the vector's. Named `sealAnswer`,
 * never the link sealer's name: the web bundle must hold no link sealer (src/app/no-link-creation.test.ts).
 */
export async function sealAnswer(
  packet: Uint8Array,
  box: Pick<ReplyBox, 'box' | 'seal'>,
  nonce: Uint8Array = crypto.getRandomValues(new Uint8Array(NONCE_LENGTH)),
): Promise<Uint8Array> {
  if (!BOX_ID.test(box.box)) throw new RangeError('a reply box id is 32 lowercase hex');
  if (box.seal.length !== KEY_LENGTH) throw new RangeError('a seal key is 32 bytes');
  if (nonce.length !== NONCE_LENGTH) throw new RangeError('a nonce is 12 bytes');
  const header = new Uint8Array([...MAGIC, VERSION, LINK_PART.packet]);
  const aad = new Uint8Array([...header, ...hexBytes(box.box)]);
  const key = await crypto.subtle.importKey('raw', box.seal as BufferSource, 'AES-GCM', false, ['encrypt']);
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce as BufferSource, additionalData: aad, tagLength: 128 }, key, packet as BufferSource),
  );
  const out = new Uint8Array(header.length + nonce.length + sealed.length);
  out.set(header, 0);
  out.set(nonce, header.length);
  out.set(sealed, header.length + nonce.length);
  return out;
}

/**
 * Screen B's three error rows. `ended`: the box is closed, full or gone, so Send goes and the file button leads.
 * `too-big`: untick something or send a file. `retry`: offline, rate-limited or busy, so "Try again".
 */
export type ReplyFailure = 'ended' | 'too-big' | 'retry';

export type ReplyPostResult = { kind: 'sent' } | { kind: 'failed'; failure: ReplyFailure };

/** The row for a server answer that isn't 2xx: its status, and the `error` code from its JSON body when there was one. */
export function replyFailureFor(status: number, code: string | undefined): ReplyFailure {
  if (status === 410 || status === 409 || status === 404) return 'ended';
  if (status === 413) return 'too-big';
  if (status === 503 && (code === 'full' || code === 'disabled')) return 'ended';
  // 429 rate_limited, 503 busy, and anything unexpected: the friend can try again, and the file button stays.
  return 'retry';
}

async function errorCode(response: Response): Promise<string | undefined> {
  try {
    const body = (await response.json()) as unknown;
    const code = body !== null && typeof body === 'object' ? (body as { error?: unknown }).error : undefined;
    return typeof code === 'string' ? code : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Seals `packet` and posts it into the box. Any 2xx is sent (the body's fields are not relied on); a network failure or
 * no answer within `ceilingMs` is `retry`. Never throws.
 */
export async function postAnswer(
  box: ReplyBox,
  packet: Uint8Array,
  fetchImpl: typeof fetch = fetch,
  ceilingMs: number = REPLY_POST_CEILING_MS,
): Promise<ReplyPostResult> {
  let sealed: Uint8Array;
  try {
    sealed = await sealAnswer(packet, box);
  } catch {
    return { kind: 'failed', failure: 'retry' };
  }
  const retry: ReplyPostResult = { kind: 'failed', failure: 'retry' };
  return withCeiling(
    async (signal) => {
      const response = await fetchImpl(`${box.origin}/api/v1/clubs/${box.box}/posts`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${box.post}`, 'Content-Type': 'application/octet-stream' },
        body: sealed as BodyInit,
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
        referrerPolicy: 'no-referrer',
        signal,
      });
      if (response.ok) return { kind: 'sent' } as const;
      return { kind: 'failed', failure: replyFailureFor(response.status, await errorCode(response)) } as const;
    },
    ceilingMs,
    retry,
  );
}
