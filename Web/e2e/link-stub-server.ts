// A local stand-in for the link server (research/B4, #805, PR #2994) for the link-opening journeys (#3003). It serves
// the Playwright build (`dist-link-stub/`, never hosted) at the app's root and at `/l/<id>`, and the link routes the
// app reads: `GET /l/<id>/packet` and `GET /l/<id>/preview`. It takes no uploads: the web app cannot make links
// (owner, 2026-11-05, #3542), so any POST gets 405.
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
// Run: node e2e/link-stub-server.ts (Node 24 strips the types). Port 4174, or SM_LINK_STUB_PORT.
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

createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);
  const parts = /^\/l\/([A-Za-z0-9_-]{1,64})(?:\/(packet|preview))?\/?$/.exec(url.pathname);
  if (req.method !== 'GET') return json(res, 405, { error: 'method' });
  if (parts && parts[2]) {
    if (parts[1] === GONE) return json(res, 410, { error: 'expired' });
    if (parts[1] === OFF) return json(res, 503, { error: 'disabled' });
    const stored = links.get(parts[1]);
    if (!stored) return json(res, 404, { error: 'not_found' });
    res.writeHead(200, { 'content-type': 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(parts[2] === 'packet' ? stored.packet : stored.preview);
    return;
  }
  if (parts) return page(res, true);
  if (url.pathname === '/' || url.pathname === '/index.html') return page(res, false);
  if (file(res, url.pathname)) return;
  json(res, 404, { error: 'not_found' });
}).listen(port, '127.0.0.1', () => console.log(`link stub on http://127.0.0.1:${port}/`));
