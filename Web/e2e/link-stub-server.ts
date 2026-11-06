// A local stand-in for the link server (research/B4, #805, PR #2994) for the link-opening journeys (#3003). It serves
// the Playwright build (`dist-link-stub/`, never hosted) at the app's root and at `/l/<id>`, and the link routes the
// app reads: `GET /l/<id>/packet` and `GET /l/<id>/preview`. It takes no uploads: the web app cannot make links
// (owner, 2026-11-05, #3542), so any POST gets 405.
//
// Seeded links, all under the test vector's key (research/B4/contracts/fixtures/share-link-sealing-vector.json):
//   AbCdEf123456   the vector's own sealed packet and preview, byte for byte (its packet is not a real packet)
//   vectorvoice01  Contracts/fixtures/web-packets/web-voice.spokenmargins sealed under the vector's key
//   expired00001   answers 410, as an expired link does
//   switchedoff1   answers 503 `disabled`, as the server does while links are switched off
// Run: node e2e/link-stub-server.ts (Node 24 strips the types). Port 4174, or SM_LINK_STUB_PORT.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { readFileSync, statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keyFromFragment, PART } from '../src/packet/share-link.ts';
import { sealPart } from '../src/cli/link-sealing.ts';

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
links.set('vectorvoice01', {
  preview: await sealPart(b64(vector.preview.plaintextBase64), PART.preview, vectorKey),
  packet: await sealPart(voicePacket, PART.packet, vectorKey),
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
