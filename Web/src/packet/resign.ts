// Test support: rewrites a packet's commentary layer and signs it again, so the reader's size, hash and digest checks
// pass. The web writer never writes `readAloud` (the page offers no such choice), so tests that need a packet the
// iPhone app would write build it from a web packet with this. Nothing in the app imports it.
import { sha256Hex } from './bytes.ts';
import { contentDigest } from './format.ts';
import { readZip, writeZip } from './zip.ts';

const unlimited = { totalBytes: Infinity, compressionRatio: Infinity, entryBytes: () => Infinity };
const text = new TextDecoder();
const utf8 = new TextEncoder();

/** Applies `change` to the commentary layer's Margin records and returns the re-signed packet. */
export async function withLayer(bytes: Uint8Array, change: (interjections: Record<string, unknown>[]) => void): Promise<Uint8Array> {
  const entries = await readZip(bytes, unlimited);
  const layerPath = 'artifacts/commentary-layer.json';
  const layer = JSON.parse(text.decode(entries.get(layerPath)));
  change(layer.interjections);
  entries.set(layerPath, utf8.encode(JSON.stringify(layer)));

  const manifest = JSON.parse(text.decode(entries.get('manifest.json')));
  // Every artifact's descriptor states its size and hash, and the reader checks both.
  for (const d of manifest.artifacts as { path: string; byteCount: number; sha256: string }[]) {
    const body = entries.get(d.path) as Uint8Array;
    d.byteCount = body.length;
    d.sha256 = await sha256Hex(body);
  }
  const files = new Map<string, Uint8Array>(
    [...manifest.artifacts, ...manifest.assets].map((d: { path: string }) => [d.path, entries.get(d.path) as Uint8Array] as const),
  );
  manifest.contentDigest = await contentDigest(manifest, entries.get('preview.md') as Uint8Array, files);
  entries.set('manifest.json', utf8.encode(JSON.stringify(manifest)));
  return writeZip([...entries].map(([path, data]) => ({ path, data, deflate: !path.startsWith('assets/') })));
}
