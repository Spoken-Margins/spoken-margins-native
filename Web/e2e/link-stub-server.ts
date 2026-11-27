// A local stand-in for the link server (research/B4, #805, PR #2994) for the link-opening journeys (#3003). It serves
// the Playwright build (`dist-link-stub/`, never hosted) at the app's root and at `/l/<id>`, and the link routes the
// app reads: `GET /l/<id>/packet`, `GET /l/<id>/preview` and `GET /l/<id>/reply`. It takes no uploads: the web app cannot
// make links (owner, 2026-11-05, #3542), so any POST gets 405, except a post into a reply box (#4675, below).
//
// Seeded links, all under the test vector's key (research/B4/contracts/fixtures/share-link-sealing-vector.json):
//   AbCdEf123456   the vector's own sealed packet and preview, byte for byte (its packet is not a real packet)
//   vectorvoice01  Contracts/fixtures/web-packets/web-voice.spokenmargins sealed under the vector's key, naming the 180 s the specs serve
//   vectorvoice33  the same, from a copy 33 s longer than the one served: the copy-length note shows (#4614)
//   vectorpost01   a Substack post's Margins: the web-written packet's Margins moved onto the post's words, each with
//                  only how far through the post it sits (what the iPhone app writes for an article; #4421)
//   vectorarticle1 an article on an ordinary site (not Substack) with Margins that carry only how far through they sit:
//                  no audio of its own and no voice to look up, so a browser can't play it (#4454)
//   vectorapple01  an Apple Podcasts episode with only its page: the owner's 2026-11-20 share, whose packet held the episode
//                  page and no audio address and no GUID (#4767, #4783). Two timed Margins, as vectorvoice01's
//   vectorapple02  the same page-only shape as the owner's 2026-11-22 share of a 2019 episode: Apple's lookup of the show does not
//                  list it, so its audio is found only in the show's feed (#4783)
//   vectorpdf001   a PDF's Margins (#5265): web-voice's Margins moved onto the PDF's words, no address (recipient supplied)
//   vectorbook01   a book's (EPUB) Margins, from web-written, the same way
//   vectortext01   a pasted text's Margins, from web-written, the same way
//   vectornoaud1   a podcast episode on an ordinary site's page with no audio address: web-voice's two timed Margins
//   vectornewer01  vectorvoice01's packet declaring a required capability this page doesn't know, as a packet from a newer
//                  Spoken Margins does: the page says it is a version gap, not damage (#5266)
//   expired00001   answers 410, as an expired link does
//   switchedoff1   answers 503 `disabled`, as the server does while links are switched off
//
// Reply boxes (#4675, docs/design/reply-mailbox.md). Each `reply*` link is vectorvoice01's packet and preview with a reply
// part at `GET /l/<id>/reply`: JSON {v:1, box, post, seal} sealed as SMLINK part 4 under the link key, as the phone seals
// it (research/B4/contracts/fixtures/reply-box-vector.json; the post proof and seal key are the vector's, the box id is
// made from the link id). `POST /api/v1/clubs/<box>/posts` (and its OPTIONS preflight, with the link CORS the real server
// sends) checks the bearer, opens the answer with the seal key and the box id as additional data, and answers:
//   replyvoice01   201: the answer is kept, and `GET /__stub/box/<box>` returns what was posted (test-only)
//   replyretry01   429 rate_limited to the first post, 201 after
//   replyclosed1   410 expired_or_removed     replyfull409  409 club_full      replygone404  404 not_found
//   replyfull503   503 full                   replyoff0503  503 disabled       replybig0413  413 too_large
//   replyrate429   429 rate_limited           replybusy503  503 busy
//   replyslow001   201, but its reply part answers only after 8 seconds: the page has given up by then (5 s)
// `GET /__stub/reply/<link id>` gives a spec the box id of a link (test-only).
// Run: node e2e/link-stub-server.ts (Node 24 strips the types). Port 4174, or SM_LINK_STUB_PORT.
import { createHash } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { readFileSync, statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keyFromFragment, PART } from '../src/packet/share-link.ts';
import { sealPart } from '../src/cli/link-sealing.ts';
import { withLayer } from '../src/packet/resign.ts';

const web = fileURLToPath(new URL('../', import.meta.url));
const repo = fileURLToPath(new URL('../../', import.meta.url));
const dist = join(web, 'dist-link-stub');
const port = Number(process.env.SM_LINK_STUB_PORT ?? 4174);

const vector = JSON.parse(readFileSync(join(repo, 'research/B4/contracts/fixtures/share-link-sealing-vector.json'), 'utf8'));
const b64 = (value: string): Uint8Array => Uint8Array.from(Buffer.from(value, 'base64'));
const vectorKey = keyFromFragment(vector.keyFragment) as Uint8Array;

interface Stored {
  preview: Uint8Array;
  packet: Uint8Array;
  /** The sealed reply part, on a link the phone made with a reply box (#4675). */
  reply?: Uint8Array;
}
const links = new Map<string, Stored>();
const GONE = 'expired00001';
const OFF = 'switchedoff1';

links.set('AbCdEf123456', { preview: b64(vector.preview.sealedBase64), packet: b64(vector.packet.sealedBase64) });
const voicePacket = new Uint8Array(readFileSync(join(repo, 'Contracts/fixtures/web-packets/web-voice.spokenmargins')));
// The committed packet says its episode is 1,800,000 ms (30 minutes); the specs serve 180 seconds of audio, so a link that
// names the committed length would show the copy-length note (#4614). The seeded links name the length the specs serve.
const SERVED_EPISODE_MS = 180_000;
/** The committed voice packet with the length of the copy its Margins were made on. */
const voicePacketOfLength = (durationMs: number): Promise<Uint8Array> =>
  withLayer(
    voicePacket,
    () => {},
    (manifest) => {
      manifest.item = { ...(manifest.item as Record<string, unknown>), durationMs };
    },
  );
links.set('vectorvoice01', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(await voicePacketOfLength(SERVED_EPISODE_MS), PART.packet, vectorKey),
});
// The same packet from a copy 33 seconds longer than the one served (about 15% of the longer copy): the note shows (#4614).
links.set('vectorvoice33', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(await voicePacketOfLength(SERVED_EPISODE_MS + 33_000), PART.packet, vectorKey),
});
// A packet from a newer Spoken Margins: it needs a capability this page has never heard of (#5266).
links.set('vectornewer01', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(
    await withLayer(
      await voicePacketOfLength(SERVED_EPISODE_MS),
      () => {},
      (manifest) => {
        manifest.requiredCapabilities = [...((manifest.requiredCapabilities as string[] | undefined) ?? []), 'spokenmargins.capability.from-the-future.v1'];
      },
    ),
    PART.packet,
    vectorKey,
  ),
});

const writtenPacket = new Uint8Array(readFileSync(join(repo, 'Contracts/fixtures/web-packets/web-written.spokenmargins')));
const articlePacket = await withLayer(
  writtenPacket,
  (records) => {
    // 20% and 60% of the way through the post, on its words, with no time: the app's anchor for a Margin on an article.
    records.forEach((record, i) => {
      record.anchor = { anchorType: 'text', startChar: 400 + 1000 * i, endChar: 460 + 1000 * i, exactText: 'A sentence in the post.', prefix: 'Before.', suffix: 'After.', roughPercent: [20, 60][i], machineEvidenceAssetIds: [] };
    });
  },
  (manifest) => {
    manifest.item = {
      canonicalURL: 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory',
      itemType: 'text',
      title: 'Leaked Anthropic Draft AI Regulatory Bill Is Unacceptable and Troubling',
      publisher: 'Zvi Mowshowitz',
      source: { sourceType: 'newsletter', canonicalURL: 'https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory' },
    };
  },
);
links.set('vectorpost01', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(articlePacket, PART.packet, vectorKey),
});

const essayPacket = await withLayer(
  writtenPacket,
  (records) => {
    records.forEach((record, i) => {
      record.anchor = { anchorType: 'text', startChar: 400 + 1000 * i, endChar: 460 + 1000 * i, exactText: 'A sentence in the essay.', prefix: 'Before.', suffix: 'After.', roughPercent: [20, 60][i], machineEvidenceAssetIds: [] };
    });
  },
  (manifest) => {
    manifest.item = {
      canonicalURL: 'https://example.com/essay',
      itemType: 'text',
      title: 'An essay on an ordinary site',
      publisher: 'Example Publisher',
      source: { sourceType: 'newsletter', canonicalURL: 'https://example.com/essay' },
    };
  },
);
links.set('vectorarticle1', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(essayPacket, PART.packet, vectorKey),
});

// #5265: links whose Margins sit on something a browser can't play, each as the iPhone app writes it. A PDF and a book have
// no address (`recipient_supplied`): the friend needs their own copy. One Margin carries a quote and a rough place, the other
// only the words before it.
const onTheWords = (records: Record<string, unknown>[]) => {
  records.forEach((record, i) => {
    record.anchor = i === 0
      ? { anchorType: 'text', startChar: 120, endChar: 180, exactText: 'The first quoted sentence of the source.', prefix: 'Words before the first.', roughPercent: 25, machineEvidenceAssetIds: [] }
      : { anchorType: 'text', prefix: 'Words before the second Margin.', machineEvidenceAssetIds: [] };
  });
};
const withoutAddress = (itemType: string, title: string) => (manifest: Record<string, unknown>) => {
  manifest.item = { itemType, title };
  manifest.itemTransport = { kind: 'recipient_supplied' };
};
const cannotPlay: Array<[string, Uint8Array]> = [
  ['vectorpdf001', await withLayer(voicePacket, onTheWords, withoutAddress('pdf', 'A paper as a PDF'))],
  ['vectorbook01', await withLayer(writtenPacket, onTheWords, withoutAddress('epub', 'A book as an EPUB'))],
  ['vectortext01', await withLayer(writtenPacket, onTheWords, withoutAddress('text', 'A pasted text'))],
  // A podcast episode on an ordinary site's page with no audio address: nothing to look up, so no audio in a browser.
  ['vectornoaud1', await withLayer(voicePacket, () => {}, (manifest) => {
    manifest.item = { itemType: 'podcast', canonicalURL: 'https://example.org/show/episode-7', title: 'An episode with no public audio', showTitle: 'A private show', durationMs: SERVED_EPISODE_MS };
  })],
];
for (const [id, packet] of cannotPlay) {
  links.set(id, {
    preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
    packet: await sealPart(packet, PART.packet, vectorKey),
  });
}

const APPLE_EPISODE = 'https://podcasts.apple.com/us/podcast/people-parks-and-policy-with-rffs-margaret-walls/id1445582279?i=1000427709574';
const applePacket = await withLayer(
  voicePacket,
  () => {},
  (manifest) => {
    manifest.item = {
      canonicalURL: APPLE_EPISODE,
      originalURL: APPLE_EPISODE,
      itemType: 'podcast',
      title: 'People, Parks, and Policy with RFF’s Margaret Walls',
      showTitle: 'Resources Radio',
      durationMs: SERVED_EPISODE_MS,
    };
  },
);
links.set('vectorapple01', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(applePacket, PART.packet, vectorKey),
});

const applePacketOutsideLookup = await withLayer(
  voicePacket,
  () => {},
  (manifest) => {
    manifest.item = {
      canonicalURL: APPLE_EPISODE,
      originalURL: APPLE_EPISODE,
      itemType: 'podcast',
      // As the feed words it, with the straight apostrophe and the comma after "Policy" that Apple's own page leaves out.
      title: "People, Parks, and Policy, with RFF's Margaret Walls",
      showTitle: 'Resources Radio',
      durationMs: 1_295_000,
    };
  },
);
links.set('vectorapple02', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(applePacketOutsideLookup, PART.packet, vectorKey),
});

// Reply boxes (#4675). The vector's post proof and seal key; a box id per link.
const replyVector = JSON.parse(readFileSync(join(repo, 'research/B4/contracts/fixtures/reply-box-vector.json'), 'utf8'));
const POST_PROOF: string = replyVector.postProof;
const SEAL_KEY = Uint8Array.from(Buffer.from(replyVector.sealKeyHex, 'hex'));
const REPLY_PART = 4;
type BoxAnswer = { status: number; error?: string };
interface Box {
  answers: BoxAnswer[];
  posts: Uint8Array[];
}
const boxes = new Map<string, Box>();
const boxOfLink = new Map<string, string>();
const SLOW_REPLY = 'replyslow001';
const REPLY_LINKS: Record<string, BoxAnswer[]> = {
  replyvoice01: [],
  replyretry01: [{ status: 429, error: 'rate_limited' }],
  replyclosed1: [{ status: 410, error: 'expired_or_removed' }],
  replyfull409: [{ status: 409, error: 'club_full' }],
  replygone404: [{ status: 404, error: 'not_found' }],
  replyfull503: [{ status: 503, error: 'full' }],
  replyoff0503: [{ status: 503, error: 'disabled' }],
  replybig0413: [{ status: 413, error: 'too_large' }],
  replyrate429: [{ status: 429, error: 'rate_limited' }],
  replybusy503: [{ status: 503, error: 'busy' }],
  [SLOW_REPLY]: [],
};
for (const [id, answers] of Object.entries(REPLY_LINKS)) {
  const box = createHash('sha256').update(id).digest('hex').slice(0, 32);
  const seal = Buffer.from(SEAL_KEY).toString('base64url');
  const part = new TextEncoder().encode(JSON.stringify({ v: 1, box, post: POST_PROOF, seal }));
  links.set(id, {
    preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
    packet: await sealPart(await voicePacketOfLength(SERVED_EPISODE_MS), PART.packet, vectorKey),
    reply: await sealPart(part, REPLY_PART, vectorKey),
  });
  // Error rows repeat for every post; the retry row answers its error once, then takes posts.
  boxes.set(box, { answers: id === 'replyretry01' ? [...answers] : answers.length ? Array(1000).fill(answers[0]) : [], posts: [] });
  boxOfLink.set(id, box);
}

/** Opens an answer as the club server does: SMLINK part 2 under the seal key, the header then the box id as additional data. */
async function openAnswer(sealed: Uint8Array, box: string): Promise<Uint8Array | undefined> {
  const header = sealed.subarray(0, 8);
  const expected = [0x53, 0x4d, 0x4c, 0x49, 0x4e, 0x4b, 1, PART.packet];
  if (sealed.length < 36 || expected.some((byte, i) => header[i] !== byte)) return undefined;
  try {
    const key = await crypto.subtle.importKey('raw', SEAL_KEY, 'AES-GCM', false, ['decrypt']);
    const additionalData = new Uint8Array([...header, ...Buffer.from(box, 'hex')]);
    return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: sealed.subarray(8, 20), additionalData }, key, sealed.subarray(20)));
  } catch {
    return undefined;
  }
}

function body(req: IncomingMessage): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (chunk: Buffer) => chunks.push(chunk));
    req.on('end', () => resolve(new Uint8Array(Buffer.concat(chunks))));
    req.on('error', reject);
  });
}

/** The CORS the real server sends on a reply box's post route, before any check (link_cors.go's pattern). */
function boxCors(req: IncomingMessage, res: ServerResponse): void {
  const origin = req.headers.origin;
  if (typeof origin === 'string') {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }
}

async function postToBox(req: IncomingMessage, res: ServerResponse, boxId: string): Promise<void> {
  boxCors(req, res);
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Methods': 'POST',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
      'Access-Control-Max-Age': '600',
    });
    res.end();
    return;
  }
  if (req.method !== 'POST') return json(res, 405, { error: 'method' });
  const box = boxes.get(boxId);
  const sealed = await body(req);
  if (!box || req.headers.authorization !== `Bearer ${POST_PROOF}`) return json(res, 404, { error: 'not_found' });
  const answer = box.answers.shift();
  if (answer) return json(res, answer.status, { error: answer.error });
  const opened = await openAnswer(sealed, boxId);
  if (!opened) return json(res, 400, { error: 'bad_post' });
  box.posts.push(opened);
  json(res, 201, { seq: box.posts.length });
}

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.webmanifest': 'application/manifest+json',
};

/** The app's page. At `/l/<id>` it gets `<base href="/">`, as a host serving the app there would add. */
function page(res: ServerResponse, atLink: boolean): void {
  let html = readFileSync(join(dist, 'index.html'), 'utf8');
  if (atLink) html = html.replace('<head>', '<head>\n    <base href="/" />');
  res.writeHead(200, { 'content-type': TYPES['.html'], 'cache-control': 'no-store' });
  res.end(html);
}

function file(res: ServerResponse, path: string): boolean {
  const full = normalize(join(dist, path));
  if (!full.startsWith(dist)) return false;
  try {
    if (!statSync(full).isFile()) return false;
  } catch {
    return false;
  }
  res.writeHead(200, { 'content-type': TYPES[extname(full)] ?? 'application/octet-stream' });
  res.end(readFileSync(full));
  return true;
}

function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);
  const parts = /^\/l\/([A-Za-z0-9_-]{1,64})(?:\/(packet|preview|reply))?\/?$/.exec(url.pathname);
  // A post into a reply box (#4675), the one write a browser may make. Creating a club or a box is not here: 405.
  const boxRoute = /^\/api\/v1\/clubs\/([0-9a-f]{32})\/posts$/.exec(url.pathname);
  if (boxRoute) return postToBox(req, res, boxRoute[1]);
  if (req.method !== 'GET') return json(res, 405, { error: 'method' });
  const peek = /^\/__stub\/(box|reply)\/([A-Za-z0-9_-]{1,64})$/.exec(url.pathname);
  if (peek && peek[1] === 'box') {
    const box = boxes.get(peek[2]);
    return box ? json(res, 200, { posts: box.posts.map((p) => Buffer.from(p).toString('base64')) }) : json(res, 404, { error: 'not_found' });
  }
  if (peek) return boxOfLink.has(peek[2]) ? json(res, 200, { box: boxOfLink.get(peek[2]) }) : json(res, 404, { error: 'not_found' });
  if (parts && parts[2]) {
    if (parts[1] === GONE) return json(res, 410, { error: 'expired' });
    if (parts[1] === OFF) return json(res, 503, { error: 'disabled' });
    const stored = links.get(parts[1]);
    if (!stored) return json(res, 404, { error: 'not_found' });
    if (parts[2] === 'reply') {
      if (!stored.reply) return json(res, 404, { error: 'not_found' });
      if (parts[1] === SLOW_REPLY) await new Promise((resolve) => setTimeout(resolve, 8_000));
    }
    res.writeHead(200, { 'content-type': 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(parts[2] === 'packet' ? stored.packet : parts[2] === 'reply' ? stored.reply : stored.preview);
    return;
  }
  if (parts) return page(res, true);
  if (url.pathname === '/' || url.pathname === '/index.html') return page(res, false);
  if (file(res, url.pathname)) return;
  json(res, 404, { error: 'not_found' });
}).listen(port, '127.0.0.1', () => console.log(`link stub on http://127.0.0.1:${port}/`));
