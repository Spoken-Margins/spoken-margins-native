// A local stand-in for the link server (research/B4, #805, PR #2994) for the share-link journeys (#3003). It serves
// the Playwright build with link creation on (`dist-share-links/`, never hosted) at the app's root and at `/l/<id>`,
// and the link routes the app calls: `GET /l/<id>/packet`, `GET /l/<id>/preview` and `POST /api/v1/links`.
// Like the real server, it stores sealed bytes unread: an upload is checked only for the SMLINK header.
//
// Seeded links, all under the test vector's key (research/B4/contracts/fixtures/share-link-sealing-vector.json):
//   AbCdEf123456   the vector's own sealed packet and preview, byte for byte (its packet is not a real packet)
//   vectorvoice01  Contracts/fixtures/web-packets/web-voice.spokenmargins sealed under the vector's key
//   expired00001   answers 410, as an expired link does
// Run: node e2e/link-stub-server.ts (Node 24 strips the types). Port 4174, or SM_LINK_STUB_PORT.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomBytes } from 'node:crypto';
import { readFileSync, statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keyFromFragment, sealPart, PART } from '../src/packet/share-link.ts';

const web = fileURLToPath(new URL('../', import.meta.url));
const repo = fileURLToPath(new URL('../../', import.meta.url));
const dist = join(web, 'dist-share-links');
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

function sealedAs(bytes: Uint8Array, part: number): boolean {
  const header = [0x53, 0x4d, 0x4c, 0x49, 0x4e, 0x4b, 1, part];
  return bytes.length >= header.length + 12 + 16 && header.every((byte, i) => bytes[i] === byte);
}

async function upload(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const request = new Request(`http://127.0.0.1:${port}/api/v1/links`, {
    method: 'POST',
    headers: { 'content-type': req.headers['content-type'] ?? '' },
    body: Buffer.concat(chunks),
  });
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return json(res, 400, { error: 'bad_request' });
  }
  const part = async (name: string) => {
    const value = form.get(name);
    return value instanceof Blob ? new Uint8Array(await value.arrayBuffer()) : null;
  };
  const preview = await part('preview');
  const packet = await part('packet');
  if (!preview || !sealedAs(preview, 1)) return json(res, 400, { error: 'bad_preview' });
  if (!packet || !sealedAs(packet, 2)) return json(res, 400, { error: 'bad_packet' });
  const id = randomBytes(16).toString('hex');
  links.set(id, { preview, packet });
  const expiresAt = new Date(Date.now() + 30 * 86_400_000).toISOString();
  json(res, 201, { id, path: `/l/${id}`, expiresAt });
}

createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`);
  const parts = /^\/l\/([A-Za-z0-9_-]{1,64})(?:\/(packet|preview))?\/?$/.exec(url.pathname);
  if (req.method === 'POST' && url.pathname === '/api/v1/links') {
    void upload(req, res);
    return;
  }
  if (req.method !== 'GET') return json(res, 405, { error: 'method' });
  if (parts && parts[2]) {
    if (parts[1] === GONE) return json(res, 410, { error: 'expired' });
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
