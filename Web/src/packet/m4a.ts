// AAC in `.m4a`, the only voice format a packet carries (the app checks each voice asset with AudioFile:
// M4A or MPEG-4 audio, 0 to 10 minutes). This file reads the MP4s browsers record (progressive from Safari,
// fragmented from Chrome's MediaRecorder), pulls out the AAC frames, and writes one plain progressive `.m4a`
// with a single chunk, which every Apple decoder reads. It also reads ADTS streams, for tests and tools.

import { concat } from './bytes.ts';

export interface AacTrack {
  /** AudioSpecificConfig, from the esds box. */
  audioSpecificConfig: Uint8Array;
  sampleRate: number;
  channels: number;
  /** Media timescale of `durations`. */
  timescale: number;
  frames: Uint8Array[];
  durations: number[];
}

export class NotAacError extends Error {
  constructor(detail: string) {
    super(`Not AAC audio in MP4: ${detail}`);
    this.name = 'NotAacError';
  }
}

interface Box {
  type: string;
  start: number;
  /** First byte of the payload. */
  body: number;
  end: number;
}

function children(bytes: Uint8Array, start: number, end: number): Box[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const boxes: Box[] = [];
  let at = start;
  while (at + 8 <= end) {
    let size = view.getUint32(at);
    const type = String.fromCharCode(bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]);
    let header = 8;
    if (size === 1) {
      if (at + 16 > end) throw new NotAacError('truncated box');
      const high = view.getUint32(at + 8);
      if (high !== 0) throw new NotAacError('box too large');
      size = view.getUint32(at + 12);
      header = 16;
    } else if (size === 0) {
      size = end - at;
    }
    if (size < header || at + size > end) throw new NotAacError(`box ${type} overruns its parent`);
    boxes.push({ type, start: at, body: at + header, end: at + size });
    at += size;
  }
  return boxes;
}

const find = (boxes: Box[], type: string): Box | undefined => boxes.find((b) => b.type === type);

function need(box: Box | undefined, what: string): Box {
  if (!box) throw new NotAacError(`no ${what} box`);
  return box;
}

function descriptorLength(bytes: Uint8Array, at: number): { length: number; next: number } {
  let length = 0;
  for (let i = 0; i < 4; i += 1) {
    const byte = bytes[at + i];
    length = (length << 7) | (byte & 0x7f);
    if (!(byte & 0x80)) return { length, next: at + i + 1 };
  }
  throw new NotAacError('bad descriptor length');
}

function parseEsds(bytes: Uint8Array, box: Box): Uint8Array {
  let at = box.body + 4;
  if (bytes[at] !== 0x03) throw new NotAacError('esds has no ES descriptor');
  let d = descriptorLength(bytes, at + 1);
  at = d.next + 2;
  const flags = bytes[at];
  at += 1;
  if (flags & 0x80) at += 2;
  if (flags & 0x40) at += 1 + bytes[at];
  if (flags & 0x20) at += 2;
  if (bytes[at] !== 0x04) throw new NotAacError('esds has no decoder config');
  d = descriptorLength(bytes, at + 1);
  const objectType = bytes[d.next];
  if (objectType !== 0x40) throw new NotAacError(`object type 0x${objectType.toString(16)} is not MPEG-4 audio`);
  at = d.next + 13;
  if (bytes[at] !== 0x05) throw new NotAacError('esds has no AudioSpecificConfig');
  d = descriptorLength(bytes, at + 1);
  const asc = bytes.slice(d.next, d.next + d.length);
  const aot = asc[0] >> 3;
  if (![2, 5, 29].includes(aot)) throw new NotAacError(`audio object type ${aot} is not AAC`);
  return asc;
}

/** Reads the first sound track of an MP4 (progressive or fragmented) and returns its AAC frames. */
export function demuxAac(bytes: Uint8Array): AacTrack {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const top = children(bytes, 0, bytes.length);
  if (top[0]?.type !== 'ftyp') throw new NotAacError('no ftyp box at the start');
  const moov = need(find(top, 'moov'), 'moov');
  const moovKids = children(bytes, moov.body, moov.end);
  let trak: Box | undefined;
  let mdia: Box[] = [];
  for (const candidate of moovKids.filter((b) => b.type === 'trak')) {
    const kids = children(bytes, need(find(children(bytes, candidate.body, candidate.end), 'mdia'), 'mdia').body,
      need(find(children(bytes, candidate.body, candidate.end), 'mdia'), 'mdia').end);
    const hdlr = find(kids, 'hdlr');
    if (hdlr && String.fromCharCode(...bytes.subarray(hdlr.body + 8, hdlr.body + 12)) === 'soun') {
      trak = candidate;
      mdia = kids;
      break;
    }
  }
  if (!trak) throw new NotAacError('no sound track');
  const tkhd = need(find(children(bytes, trak.body, trak.end), 'tkhd'), 'tkhd');
  const trackId = view.getUint32(tkhd.body + (bytes[tkhd.body] === 1 ? 20 : 12));
  const mdhd = need(find(mdia, 'mdhd'), 'mdhd');
  const timescale = view.getUint32(mdhd.body + (bytes[mdhd.body] === 1 ? 20 : 12));
  const minf = need(find(mdia, 'minf'), 'minf');
  const stbl = need(find(children(bytes, minf.body, minf.end), 'stbl'), 'stbl');
  const table = children(bytes, stbl.body, stbl.end);
  const stsd = need(find(table, 'stsd'), 'stsd');
  const entries = children(bytes, stsd.body + 8, stsd.end);
  const entry = entries[0];
  if (!entry) throw new NotAacError('no sample description');
  if (entry.type !== 'mp4a') throw new NotAacError(`sample entry ${entry.type}`);
  // QuickTime sound entries v1 and v2 (Apple's writer) carry 16 or 36 more bytes before their child boxes.
  const soundVersion = view.getUint16(entry.body + 8);
  const extra = soundVersion === 1 ? 16 : soundVersion === 2 ? 36 : 0;
  const esds = need(find(children(bytes, entry.body + 28 + extra, entry.end), 'esds'), 'esds');
  const audioSpecificConfig = parseEsds(bytes, esds);
  // The sample entry's channel count is often a placeholder (Apple writes 2 for mono); the config is the truth.
  const config = readAudioSpecificConfig(audioSpecificConfig);
  const channels = config.channels || view.getUint16(entry.body + 16);
  const sampleRate = config.sampleRate || view.getUint32(entry.body + 24) >>> 16;

  const frames: Uint8Array[] = [];
  const durations: number[] = [];

  // Progressive samples, from the sample table.
  const stsz = find(table, 'stsz');
  const sampleCount = stsz ? view.getUint32(stsz.body + 8) : 0;
  if (stsz && sampleCount > 0) {
    const fixedSize = view.getUint32(stsz.body + 4);
    const sizes = Array.from({ length: sampleCount }, (_, i) => fixedSize || view.getUint32(stsz.body + 12 + 4 * i));
    const stco = find(table, 'stco');
    const co64 = find(table, 'co64');
    const offsets: number[] = [];
    if (stco) {
      for (let i = 0; i < view.getUint32(stco.body + 4); i += 1) offsets.push(view.getUint32(stco.body + 8 + 4 * i));
    } else if (co64) {
      for (let i = 0; i < view.getUint32(co64.body + 4); i += 1) {
        if (view.getUint32(co64.body + 8 + 8 * i) !== 0) throw new NotAacError('chunk offset too large');
        offsets.push(view.getUint32(co64.body + 12 + 8 * i));
      }
    } else {
      throw new NotAacError('no chunk offsets');
    }
    const stsc = need(find(table, 'stsc'), 'stsc');
    const runs = Array.from({ length: view.getUint32(stsc.body + 4) }, (_, i) => ({
      firstChunk: view.getUint32(stsc.body + 8 + 12 * i),
      perChunk: view.getUint32(stsc.body + 12 + 12 * i),
    }));
    let sample = 0;
    for (let chunk = 0; chunk < offsets.length && sample < sampleCount; chunk += 1) {
      const run = [...runs].reverse().find((r) => r.firstChunk <= chunk + 1);
      if (!run) throw new NotAacError('bad sample-to-chunk table');
      let at = offsets[chunk];
      for (let i = 0; i < run.perChunk && sample < sampleCount; i += 1) {
        if (at + sizes[sample] > bytes.length) throw new NotAacError('sample runs past the file');
        frames.push(bytes.slice(at, at + sizes[sample]));
        at += sizes[sample];
        sample += 1;
      }
    }
    const stts = need(find(table, 'stts'), 'stts');
    for (let i = 0; i < view.getUint32(stts.body + 4); i += 1) {
      const count = view.getUint32(stts.body + 8 + 8 * i);
      const delta = view.getUint32(stts.body + 12 + 8 * i);
      for (let n = 0; n < count && durations.length < frames.length; n += 1) durations.push(delta);
    }
    while (durations.length < frames.length) durations.push(1024);
  }

  // Fragmented samples, from each moof.
  let defaultDuration = 1024;
  let defaultSize = 0;
  const mvex = find(moovKids, 'mvex');
  if (mvex) {
    const trex = children(bytes, mvex.body, mvex.end).find((b) => b.type === 'trex' && view.getUint32(b.body + 4) === trackId);
    if (trex) {
      defaultDuration = view.getUint32(trex.body + 12);
      defaultSize = view.getUint32(trex.body + 16);
    }
  }
  for (const moof of top.filter((b) => b.type === 'moof')) {
    for (const traf of children(bytes, moof.body, moof.end).filter((b) => b.type === 'traf')) {
      const parts = children(bytes, traf.body, traf.end);
      const tfhd = need(find(parts, 'tfhd'), 'tfhd');
      const tfFlags = view.getUint32(tfhd.body) & 0xffffff;
      if (view.getUint32(tfhd.body + 4) !== trackId) continue;
      let at = tfhd.body + 8;
      let base = moof.start;
      if (tfFlags & 0x1) {
        if (view.getUint32(at) !== 0) throw new NotAacError('base offset too large');
        base = view.getUint32(at + 4);
        at += 8;
      }
      if (tfFlags & 0x2) at += 4;
      let trafDuration = defaultDuration;
      let trafSize = defaultSize;
      if (tfFlags & 0x8) {
        trafDuration = view.getUint32(at);
        at += 4;
      }
      if (tfFlags & 0x10) trafSize = view.getUint32(at);
      for (const trun of parts.filter((b) => b.type === 'trun')) {
        const flags = view.getUint32(trun.body) & 0xffffff;
        const count = view.getUint32(trun.body + 4);
        let p = trun.body + 8;
        let dataAt = base;
        if (flags & 0x1) {
          dataAt = base + view.getInt32(p);
          p += 4;
        }
        if (flags & 0x4) p += 4;
        for (let i = 0; i < count; i += 1) {
          let duration = trafDuration;
          let size = trafSize;
          if (flags & 0x100) {
            duration = view.getUint32(p);
            p += 4;
          }
          if (flags & 0x200) {
            size = view.getUint32(p);
            p += 4;
          }
          if (flags & 0x400) p += 4;
          if (flags & 0x800) p += 4;
          if (dataAt + size > bytes.length) throw new NotAacError('fragment sample runs past the file');
          frames.push(bytes.slice(dataAt, dataAt + size));
          durations.push(duration);
          dataAt += size;
        }
      }
    }
  }
  if (frames.length === 0) throw new NotAacError('no audio frames');
  return { audioSpecificConfig, sampleRate, channels, timescale, frames, durations };
}

export function durationMs(track: AacTrack): number {
  const units = track.durations.reduce((sum, d) => sum + d, 0);
  return Math.round((units * 1000) / track.timescale);
}

const SAMPLE_RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

/** Sample rate and channels from an AudioSpecificConfig (0 when it doesn't say). */
export function readAudioSpecificConfig(asc: Uint8Array): { objectType: number; sampleRate: number; channels: number } {
  const objectType = asc[0] >> 3;
  const index = ((asc[0] & 0x7) << 1) | (asc[1] >> 7);
  if (index === 15) {
    const rate = ((asc[1] & 0x7f) << 17) | (asc[2] << 9) | (asc[3] << 1) | (asc[4] >> 7);
    return { objectType, sampleRate: rate, channels: (asc[4] >> 3) & 0xf };
  }
  return { objectType, sampleRate: SAMPLE_RATES[index] ?? 0, channels: (asc[1] >> 3) & 0xf };
}

/** An AAC-LC AudioSpecificConfig for a sample rate and channel count. */
export function audioSpecificConfig(sampleRate: number, channels: number, objectType = 2): Uint8Array {
  const index = SAMPLE_RATES.indexOf(sampleRate);
  if (index < 0) throw new RangeError(`AAC has no sample-rate index for ${sampleRate} Hz`);
  const bits = (objectType << 11) | (index << 7) | (channels << 3);
  return new Uint8Array([bits >> 8, bits & 0xff]);
}

/** Splits an ADTS stream (what `afconvert -f adts` and most AAC tools write) into raw frames. */
export function parseAdts(bytes: Uint8Array): AacTrack {
  const frames: Uint8Array[] = [];
  let at = 0;
  let profile = -1;
  let rateIndex = -1;
  let channels = 0;
  while (at + 7 <= bytes.length) {
    if (bytes[at] !== 0xff || (bytes[at + 1] & 0xf0) !== 0xf0) throw new NotAacError(`no ADTS sync at ${at}`);
    const protectionAbsent = bytes[at + 1] & 0x1;
    profile = bytes[at + 2] >> 6;
    rateIndex = (bytes[at + 2] >> 2) & 0xf;
    channels = ((bytes[at + 2] & 0x1) << 2) | (bytes[at + 3] >> 6);
    const length = ((bytes[at + 3] & 0x3) << 11) | (bytes[at + 4] << 3) | (bytes[at + 5] >> 5);
    const header = protectionAbsent ? 7 : 9;
    if (length < header || at + length > bytes.length) throw new NotAacError('truncated ADTS frame');
    frames.push(bytes.slice(at + header, at + length));
    at += length;
  }
  if (frames.length === 0) throw new NotAacError('no ADTS frames');
  const sampleRate = SAMPLE_RATES[rateIndex];
  return {
    audioSpecificConfig: audioSpecificConfig(sampleRate, channels, profile + 1),
    sampleRate,
    channels,
    timescale: sampleRate,
    frames,
    durations: frames.map(() => 1024),
  };
}

// --- writing ---------------------------------------------------------------------------------------------------

function u32(value: number): number[] {
  return [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
}
function u16(value: number): number[] {
  return [(value >>> 8) & 0xff, value & 0xff];
}
function ascii(text: string): number[] {
  return [...text].map((c) => c.charCodeAt(0));
}
function box(type: string, ...payload: (number[] | Uint8Array)[]): Uint8Array {
  const body = concat(payload.map((p) => (p instanceof Uint8Array ? p : new Uint8Array(p))));
  return concat([new Uint8Array([...u32(8 + body.length), ...ascii(type)]), body]);
}
function fullBox(type: string, version: number, flags: number, ...payload: (number[] | Uint8Array)[]): Uint8Array {
  return box(type, [version, (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff], ...payload);
}
function descriptor(tag: number, ...payload: (number[] | Uint8Array)[]): Uint8Array {
  const body = concat(payload.map((p) => (p instanceof Uint8Array ? p : new Uint8Array(p))));
  const length = body.length;
  // The four-byte length form, as Apple's writer uses.
  return concat([new Uint8Array([tag, 0x80 | ((length >> 21) & 0x7f), 0x80 | ((length >> 14) & 0x7f), 0x80 | ((length >> 7) & 0x7f), length & 0x7f]), body]);
}

const MATRIX = [...u32(0x00010000), ...u32(0), ...u32(0), ...u32(0), ...u32(0x00010000), ...u32(0), ...u32(0), ...u32(0), ...u32(0x40000000)];

/** Writes AAC frames as a plain progressive `.m4a`: ftyp, moov, then one mdat holding a single chunk. */
export function muxM4a(track: AacTrack): Uint8Array {
  if (track.frames.length === 0) throw new RangeError('no audio frames to write');
  if (track.frames.length !== track.durations.length) throw new RangeError('one duration per frame');
  const totalUnits = track.durations.reduce((sum, d) => sum + d, 0);
  const sizes = track.frames.map((f) => f.length);
  const bitrate = Math.round((sizes.reduce((a, b) => a + b, 0) * 8 * track.timescale) / Math.max(1, totalUnits));
  const maxFrame = Math.max(...sizes);

  const stts: number[] = [];
  let runs = 0;
  for (let i = 0; i < track.durations.length; ) {
    let n = 1;
    while (i + n < track.durations.length && track.durations[i + n] === track.durations[i]) n += 1;
    stts.push(...u32(n), ...u32(track.durations[i]));
    runs += 1;
    i += n;
  }

  const esds = fullBox('esds', 0, 0, descriptor(0x03, u16(0), [0],
    descriptor(0x04, [0x40, 0x15], [(maxFrame >> 16) & 0xff, (maxFrame >> 8) & 0xff, maxFrame & 0xff], u32(bitrate), u32(bitrate),
      descriptor(0x05, track.audioSpecificConfig)),
    descriptor(0x06, [0x02])));
  const mp4a = box('mp4a', [0, 0, 0, 0, 0, 0], u16(1), new Array(8).fill(0), u16(track.channels), u16(16), u16(0), u16(0),
    u32((track.sampleRate << 16) >>> 0), esds);

  const build = (chunkOffset: number): Uint8Array => {
    const stbl = box('stbl',
      fullBox('stsd', 0, 0, u32(1), mp4a),
      fullBox('stts', 0, 0, u32(runs), stts),
      fullBox('stsc', 0, 0, u32(1), u32(1), u32(track.frames.length), u32(1)),
      fullBox('stsz', 0, 0, u32(0), u32(track.frames.length), sizes.flatMap(u32)),
      fullBox('stco', 0, 0, u32(1), u32(chunkOffset)));
    const minf = box('minf',
      fullBox('smhd', 0, 0, u16(0), u16(0)),
      box('dinf', fullBox('dref', 0, 0, u32(1), fullBox('url ', 0, 1))),
      stbl);
    const mdia = box('mdia',
      fullBox('mdhd', 0, 0, u32(0), u32(0), u32(track.timescale), u32(totalUnits), u16(0x55c4), u16(0)),
      fullBox('hdlr', 0, 0, u32(0), ascii('soun'), new Array(12).fill(0), ascii('SoundHandler'), [0]),
      minf);
    const tkhd = fullBox('tkhd', 0, 3, u32(0), u32(0), u32(1), u32(0), u32(totalUnits), new Array(8).fill(0), u16(0), u16(0),
      u16(0x0100), u16(0), MATRIX, u32(0), u32(0));
    const mvhd = fullBox('mvhd', 0, 0, u32(0), u32(0), u32(track.timescale), u32(totalUnits), u32(0x00010000), u16(0x0100),
      new Array(10).fill(0), MATRIX, new Array(24).fill(0), u32(2));
    return box('moov', mvhd, box('trak', tkhd, mdia));
  };
  const ftyp = box('ftyp', ascii('M4A '), u32(0), ascii('M4A '), ascii('mp42'), ascii('isom'));
  const sizing = build(0);
  const moov = build(ftyp.length + sizing.length + 8);
  return concat([ftyp, moov, box('mdat', concat(track.frames))]);
}

/** Any AAC MP4 a browser recorded, rewritten as a plain `.m4a`, with its length. Throws NotAacError otherwise. */
export function normalizeM4a(bytes: Uint8Array): { bytes: Uint8Array; durationMs: number } {
  const track = demuxAac(bytes);
  return { bytes: muxM4a(track), durationMs: durationMs(track) };
}
