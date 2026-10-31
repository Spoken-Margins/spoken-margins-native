// "Back up all Margins" (#3012): every Margin in this browser, in files the iPhone app (Builds 32 and 34) and
// this web app open. Plain TypeScript, so `npm run test:web` covers it (backup.test.ts).
//
// A `.spokenmargins` packet holds one episode, up to 50 Margins, and only Margins with words (the app shares no
// Margin without a transcript). So the backup is the packet writer's own files, one per episode (more past 50),
// unchanged. One packet downloads as itself; more go into one `.zip`, stored rather than compressed. A voice Margin
// with no words can't go in a packet, so its audio goes in the zip under its own folder: not something the apps
// open, but not lost either, and the listener is told.
import { readZip, writeZip, type ZipInput } from '../../packet/zip.ts';
import type { Episode, Margin, Show } from '../../shared/model.ts';
import type { PacketWritten } from '../ports.ts';

export const MARGINS_PER_PACKET = 50;
export const VOICE_ONLY_FOLDER = 'Voice Margins without words';
const PACKET_EXTENSION = '.spokenmargins';

export type WritePacket = (episode: Episode, margins: readonly Margin[], show?: Show) => Promise<PacketWritten>;

export interface BackupFile {
  name: string;
  bytes: Uint8Array;
  mimeType: string;
}

export interface BackupResult {
  /** Undefined when there was nothing to back up. */
  file?: BackupFile;
  /** Margins inside packets, which the apps open. */
  inPackets: number;
  /** Episodes with at least one Margin in a packet. */
  episodes: number;
  /** Voice Margins with no words, kept as audio only. */
  audioOnly: number;
  /** Episodes whose packet couldn't be written, with how many Margins that left out and why. */
  failed: Array<{ title: string; margins: number; error: unknown }>;
  /** Margins whose episode isn't in this browser any more, so no packet can name it. */
  unplaced: number;
}

const hasWords = (m: Margin): boolean => (m.text ?? '').trim() !== '';

function clockForName(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const mm = String(m).padStart(h ? 2 : 1, '0');
  return `${h ? `${h}-` : ''}${mm}-${String(s).padStart(2, '0')}`;
}

function slug(title: string): string {
  return title.normalize('NFKD').replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'Episode';
}

function audioExtension(mimeType: string): string {
  if (/mp4|m4a|aac/i.test(mimeType)) return '.m4a';
  if (/webm/i.test(mimeType)) return '.webm';
  if (/ogg/i.test(mimeType)) return '.ogg';
  return '.audio';
}

/** `name`, or `name-2`, `name-3`… before the extension, whichever isn't taken yet. */
export function uniqueName(name: string, taken: Set<string>): string {
  const dot = name.lastIndexOf('.');
  const stem = dot > 0 ? name.slice(0, dot) : name;
  const ext = dot > 0 ? name.slice(dot) : '';
  let candidate = name;
  for (let n = 2; taken.has(candidate.toLowerCase()); n += 1) candidate = `${stem}-${n}${ext}`;
  taken.add(candidate.toLowerCase());
  return candidate;
}

export function backupFileName(now: Date): string {
  const day = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  return `Spoken-Margins-backup-${day}.zip`;
}

export async function buildBackup(
  data: { episodes: readonly Episode[]; shows: readonly Show[]; margins: readonly Margin[] },
  write: WritePacket,
  now = new Date(),
): Promise<BackupResult> {
  const episodes = new Map(data.episodes.map((e) => [e.id, e]));
  const shows = new Map(data.shows.map((s) => [s.id, s]));
  const byEpisode = new Map<string, Margin[]>();
  let unplaced = 0;
  for (const margin of data.margins) {
    if (!episodes.has(margin.episodeId)) {
      unplaced += 1;
      continue;
    }
    const list = byEpisode.get(margin.episodeId) ?? [];
    list.push(margin);
    byEpisode.set(margin.episodeId, list);
  }

  const result: BackupResult = { inPackets: 0, episodes: 0, audioOnly: 0, failed: [], unplaced };
  const packets: ZipInput[] = [];
  const audio: ZipInput[] = [];
  const taken = new Set<string>();

  for (const [episodeId, margins] of byEpisode) {
    const episode = episodes.get(episodeId) as Episode;
    const show = shows.get(episode.showId);
    const worded = margins.filter(hasWords).sort((a, b) => a.atSeconds - b.atSeconds);
    let written = 0;
    for (let i = 0; i < worded.length; i += MARGINS_PER_PACKET) {
      const chunk = worded.slice(i, i + MARGINS_PER_PACKET);
      try {
        const packet = await write(episode, chunk, show);
        packets.push({ path: uniqueName(packet.fileName, taken), data: packet.bytes, deflate: false });
        written += packet.included.length;
        // The writer drops a Margin whose words are only spaces by its own (Swift) rules; never let that pass quietly.
        const missed = chunk.length - packet.included.length;
        if (missed > 0) result.failed.push({ title: episode.title, margins: missed, error: new Error(packet.notice ?? 'Left out of the file.') });
      } catch (error) {
        result.failed.push({ title: episode.title, margins: chunk.length, error });
      }
    }
    if (written) {
      result.inPackets += written;
      result.episodes += 1;
    }
    for (const margin of margins) {
      if (hasWords(margin) || !margin.voice) continue;
      const name = `${slug(episode.title)} at ${clockForName(margin.atSeconds)}${audioExtension(margin.voice.mimeType)}`;
      const data = new Uint8Array(await margin.voice.blob.arrayBuffer());
      audio.push({ path: `${VOICE_ONLY_FOLDER}/${uniqueName(name, taken)}`, data, deflate: false });
      result.audioOnly += 1;
    }
  }

  if (packets.length === 1 && audio.length === 0) {
    const only = packets[0] as ZipInput;
    result.file = { name: only.path, bytes: only.data, mimeType: 'application/vnd.spokenmargins.package+zip' };
  } else if (packets.length + audio.length > 0) {
    result.file = { name: backupFileName(now), bytes: await writeZip([...packets, ...audio]), mimeType: 'application/zip' };
  }
  return result;
}

const count = (n: number, one: string, many: string): string => (n === 1 ? `1 ${one}` : `${n} ${many}`);

/** What the listener is told after a backup, and whether any of it is a problem (something not backed up). */
export function backupSummary(result: BackupResult, describe: (error: unknown) => string): { text: string; problem: boolean } {
  const parts: string[] = [];
  if (result.file) {
    parts.push(
      result.inPackets
        ? `Backed up ${count(result.inPackets, 'Margin', 'Margins')} from ${count(result.episodes, 'episode', 'episodes')} as ${result.file.name}.`
        : `Saved ${result.file.name}.`,
    );
  } else {
    parts.push('Nothing was backed up.');
  }
  if (result.audioOnly) {
    parts.push(
      `${count(result.audioOnly, 'voice Margin has', 'voice Margins have')} no words, so ${result.audioOnly === 1 ? 'it is' : 'they are'} in the file as audio only, which the apps can’t open.`,
    );
  }
  for (const failure of result.failed) {
    parts.push(`${count(failure.margins, 'Margin', 'Margins')} on “${failure.title}” couldn’t be backed up. ${describe(failure.error)}`);
  }
  if (result.unplaced) {
    parts.push(`${count(result.unplaced, 'Margin isn’t', 'Margins aren’t')} linked to an episode in this browser, so ${result.unplaced === 1 ? 'it wasn’t' : 'they weren’t'} backed up.`);
  }
  return { text: parts.join(' '), problem: !result.file || result.failed.length > 0 || result.unplaced > 0 };
}

/** Whether a picked file is a backup `.zip` rather than a single packet. */
export function isBackupArchive(fileName: string | undefined): boolean {
  return /\.zip$/i.test(fileName ?? '');
}

/** The packets inside a backup `.zip`, in archive order. Audio-only entries are skipped: no app opens them. */
export async function packetsInBackup(bytes: Uint8Array): Promise<Array<{ name: string; bytes: Uint8Array }>> {
  const entries = await readZip(bytes, {
    totalBytes: 1024 * 1024 * 1024,
    compressionRatio: 100,
    entryBytes: (path) => (path.toLowerCase().endsWith(PACKET_EXTENSION) ? 100 * 1024 * 1024 : 50 * 1024 * 1024),
  });
  const out: Array<{ name: string; bytes: Uint8Array }> = [];
  for (const [path, data] of entries) {
    if (!path.toLowerCase().endsWith(PACKET_EXTENSION)) continue;
    out.push({ name: path.slice(path.lastIndexOf('/') + 1), bytes: data });
  }
  return out;
}
