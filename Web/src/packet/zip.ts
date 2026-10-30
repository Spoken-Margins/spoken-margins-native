// A minimal zip reader and writer for `.spokenmargins` packets: stored and deflated entries only, no ZIP64, no
// encryption, no data descriptors on write. Deflate uses the platform's CompressionStream('deflate-raw').
//
// The writer matches what the app's ZIPFoundation writer produces where a reader could tell: every entry dated
// 1980-01-01 00:00, mode 0644, sizes and CRC in the local header.

import { concat, crc32, fromUtf8, transform, utf8 } from './bytes.ts';
import { damaged, tooLarge } from './errors.ts';

export interface ZipEntryInfo {
  path: string;
  method: number;
  compressedSize: number;
  uncompressedSize: number;
  crc: number;
  isDirectory: boolean;
  localHeaderOffset: number;
}

export interface ZipLimits {
  /** Largest sum of uncompressed sizes. */
  totalBytes: number;
  /** Largest uncompressed/compressed ratio for one entry (integer division, as the app checks it). */
  compressionRatio: number;
  /** Largest uncompressed size for one entry, by path. */
  entryBytes: (path: string) => number;
}

const LOCAL = 0x04034b50;
const CENTRAL = 0x02014b50;
const END = 0x06054b50;

/** Lists a zip's entries from its central directory. Throws PacketError('damaged') for anything malformed. */
export function listZip(bytes: Uint8Array): ZipEntryInfo[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const minimumEnd = 22;
  if (bytes.length < minimumEnd) throw damaged('archive is too short to be a zip');
  let end = -1;
  for (let i = bytes.length - minimumEnd; i >= Math.max(0, bytes.length - minimumEnd - 0xffff); i -= 1) {
    if (view.getUint32(i, true) === END) {
      end = i;
      break;
    }
  }
  if (end < 0) throw damaged('no end of central directory');
  const disk = view.getUint16(end + 4, true);
  const cdDisk = view.getUint16(end + 6, true);
  const countHere = view.getUint16(end + 8, true);
  const count = view.getUint16(end + 10, true);
  const cdSize = view.getUint32(end + 12, true);
  const cdOffset = view.getUint32(end + 16, true);
  if (disk !== 0 || cdDisk !== 0 || countHere !== count) throw damaged('multi-disk zip');
  if (count === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) throw damaged('zip64 is not supported');
  if (cdOffset + cdSize > end) throw damaged('central directory overruns the archive');

  const entries: ZipEntryInfo[] = [];
  let at = cdOffset;
  for (let n = 0; n < count; n += 1) {
    if (at + 46 > end || view.getUint32(at, true) !== CENTRAL) throw damaged('central directory entry is malformed');
    const flags = view.getUint16(at + 8, true);
    const method = view.getUint16(at + 10, true);
    const crc = view.getUint32(at + 16, true);
    const compressedSize = view.getUint32(at + 20, true);
    const uncompressedSize = view.getUint32(at + 24, true);
    const nameLength = view.getUint16(at + 28, true);
    const extraLength = view.getUint16(at + 30, true);
    const commentLength = view.getUint16(at + 32, true);
    const localHeaderOffset = view.getUint32(at + 42, true);
    if (flags & 0x1) throw damaged('encrypted entry');
    if (compressedSize === 0xffffffff || uncompressedSize === 0xffffffff || localHeaderOffset === 0xffffffff) {
      throw damaged('zip64 entry');
    }
    const nameEnd = at + 46 + nameLength;
    if (nameEnd + extraLength + commentLength > end) throw damaged('central directory entry overruns');
    const path = fromUtf8(bytes.subarray(at + 46, nameEnd));
    if (path === null) throw damaged('entry name is not UTF-8');
    entries.push({
      path,
      method,
      compressedSize,
      uncompressedSize,
      crc,
      isDirectory: path.endsWith('/'),
      localHeaderOffset,
    });
    at = nameEnd + extraLength + commentLength;
  }
  return entries;
}

/** Reads every entry, checking the limits before inflating anything. Returns path to bytes, in archive order. */
export async function readZip(
  bytes: Uint8Array,
  limits: ZipLimits,
  checkEntry: (entry: ZipEntryInfo) => void = () => undefined,
): Promise<Map<string, Uint8Array>> {
  const entries = listZip(bytes);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let total = 0;
  for (const entry of entries) {
    checkEntry(entry);
    total += entry.uncompressedSize;
    if (total > limits.totalBytes) throw tooLarge('package is larger than 100 MB uncompressed');
    if (entry.uncompressedSize > limits.entryBytes(entry.path)) throw tooLarge(`entry too large: ${entry.path}`);
    if (entry.compressedSize > 0 && Math.floor(entry.uncompressedSize / entry.compressedSize) > limits.compressionRatio) {
      throw damaged(`unsafe compression ratio: ${entry.path}`);
    }
  }
  const out = new Map<string, Uint8Array>();
  for (const entry of entries) {
    const at = entry.localHeaderOffset;
    if (at + 30 > bytes.length || view.getUint32(at, true) !== LOCAL) throw damaged(`local header missing: ${entry.path}`);
    const start = at + 30 + view.getUint16(at + 26, true) + view.getUint16(at + 28, true);
    const stop = start + entry.compressedSize;
    if (stop > bytes.length) throw damaged(`entry is truncated: ${entry.path}`);
    const raw = bytes.subarray(start, stop);
    let data: Uint8Array;
    if (entry.method === 0) {
      data = raw.slice();
    } else if (entry.method === 8) {
      try {
        data = await transform(raw, new DecompressionStream('deflate-raw'), entry.uncompressedSize);
      } catch {
        throw damaged(`entry does not inflate: ${entry.path}`);
      }
    } else {
      throw damaged(`unsupported compression method ${entry.method}: ${entry.path}`);
    }
    if (data.length !== entry.uncompressedSize || crc32(data) !== entry.crc) {
      throw damaged(`entry fails its check: ${entry.path}`);
    }
    out.set(entry.path, data);
  }
  return out;
}

export interface ZipInput {
  path: string;
  data: Uint8Array;
  /** Deflate this entry. One that would squeeze past `maxRatio` is stored instead, as the app's writer does. */
  deflate: boolean;
}

/** DOS date for 1980-01-01, time 00:00 (the app's fixedArchiveDate). */
const DOS_DATE = (0 << 9) | (1 << 5) | 1;
const DOS_TIME = 0;
const MODE_0644 = (0o100644 << 16) >>> 0;

export async function writeZip(inputs: readonly ZipInput[], maxRatio = 100): Promise<Uint8Array> {
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  for (const input of inputs) {
    const name = utf8(input.path);
    const crc = crc32(input.data);
    let method = 0;
    let body = input.data;
    if (input.deflate) {
      const deflated = await transform(input.data, new CompressionStream('deflate-raw'));
      if (!(deflated.length > 0 && Math.floor(input.data.length / deflated.length) > maxRatio)) {
        method = 8;
        body = deflated;
      }
    }
    const flags = /^[\x20-\x7e]*$/.test(input.path) ? 0 : 0x800;
    const local = new Uint8Array(30 + name.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, LOCAL, true);
    lv.setUint16(4, 20, true);
    lv.setUint16(6, flags, true);
    lv.setUint16(8, method, true);
    lv.setUint16(10, DOS_TIME, true);
    lv.setUint16(12, DOS_DATE, true);
    lv.setUint32(14, crc, true);
    lv.setUint32(18, body.length, true);
    lv.setUint32(22, input.data.length, true);
    lv.setUint16(26, name.length, true);
    lv.setUint16(28, 0, true);
    local.set(name, 30);

    const central = new Uint8Array(46 + name.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, CENTRAL, true);
    cv.setUint16(4, (3 << 8) | 20, true);
    cv.setUint16(6, 20, true);
    cv.setUint16(8, flags, true);
    cv.setUint16(10, method, true);
    cv.setUint16(12, DOS_TIME, true);
    cv.setUint16(14, DOS_DATE, true);
    cv.setUint32(16, crc, true);
    cv.setUint32(20, body.length, true);
    cv.setUint32(24, input.data.length, true);
    cv.setUint16(28, name.length, true);
    cv.setUint32(38, MODE_0644, true);
    cv.setUint32(42, offset, true);
    central.set(name, 46);

    locals.push(local, body);
    centrals.push(central);
    offset += local.length + body.length;
  }
  const directory = concat(centrals);
  const endRecord = new Uint8Array(22);
  const ev = new DataView(endRecord.buffer);
  ev.setUint32(0, END, true);
  ev.setUint16(8, inputs.length, true);
  ev.setUint16(10, inputs.length, true);
  ev.setUint32(12, directory.length, true);
  ev.setUint32(16, offset, true);
  return concat([...locals, directory, endRecord]);
}
