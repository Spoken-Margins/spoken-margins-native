// "Back up all Margins" (#3012): every Margin in this browser, in files the iPhone app (Builds 32 and 34) and
// this web app open. Plain TypeScript, so `npm run test:web` covers it (backup.test.ts).
//
// A `.spokenmargins` packet holds one episode and up to 50 Margins. So the backup is the packet writer's own files,
// one per episode (more past 50), unchanged. One packet downloads as itself; more go into one `.zip`, stored rather
// than compressed. A voice Margin with no words goes in its packet like any other: the writer gives it placeholder
// words (#3025). Backups made before that may also hold a "Voice Margins without words" folder of loose audio,
// which reading a backup skips.
import { readZip, writeZip, type ZipInput } from '../../packet/zip.ts';
import type { Episode, Margin, Show } from '../../shared/model.ts';
import type { PacketWritten } from '../ports.ts';

export const MARGINS_PER_PACKET = 50;
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
  /** Episodes whose packet couldn't be written, with how many Margins that left out and why. */
  failed: Array<{ title: string; margins: number; error: unknown }>;
  /** Margins whose episode isn't in this browser any more, so no packet can name it. */
  unplaced: number;
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

  const result: BackupResult = { inPackets: 0, episodes: 0, failed: [], unplaced };
  const packets: ZipInput[] = [];
  const taken = new Set<string>();

  for (const [episodeId, margins] of byEpisode) {
    const episode = episodes.get(episodeId) as Episode;
    const show = shows.get(episode.showId);
    const sorted = [...margins].sort((a, b) => a.atSeconds - b.atSeconds);
    let written = 0;
    for (let i = 0; i < sorted.length; i += MARGINS_PER_PACKET) {
      const chunk = sorted.slice(i, i + MARGINS_PER_PACKET);
      try {
        const packet = await write(episode, chunk, show);
        packets.push({ path: uniqueName(packet.fileName, taken), data: packet.bytes, deflate: false });
        written += packet.included.length;
        // The writer leaves out a written Margin with no words by its own (Swift) rules; never let that pass quietly.
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
  }

  if (packets.length === 1) {
    const only = packets[0] as ZipInput;
    result.file = { name: only.path, bytes: only.data, mimeType: 'application/vnd.spokenmargins.package+zip' };
  } else if (packets.length > 1) {
    result.file = { name: backupFileName(now), bytes: await writeZip(packets), mimeType: 'application/zip' };
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
  for (const failure of result.failed) {
    parts.push(`${count(failure.margins, 'Margin', 'Margins')} on “${failure.title}” couldn’t be backed up. ${describe(failure.error)}`);
  }
  if (result.unplaced) {
    parts.push(`${count(result.unplaced, 'Margin isn’t', 'Margins aren’t')} linked to an episode in this browser, so ${result.unplaced === 1 ? 'it wasn’t' : 'they weren’t'} backed up.`);
  }
  return { text: parts.join(' '), problem: !result.file || result.failed.length > 0 || result.unplaced > 0 };
}

/**
 * What to open for one file that arrived, however it arrived (picker, drop, the installed app's share target, or a
 * file Android opens the Android app with): a backup `.zip`'s packets, or the file itself. A file with no name (an
 * opaque Android content URI) is looked inside, so a backup still unpacks. Anything that isn't a backup goes to the
 * packet reader as it is, which says plainly when it isn't a Margin file.
 */
export async function packetsToOpen(bytes: Uint8Array, fileName: string | undefined): Promise<Array<{ name: string | undefined; bytes: Uint8Array }>> {
  if (isBackupArchive(fileName) || fileName === undefined) {
    const packets = await packetsInBackup(bytes).catch(() => []);
    if (packets.length > 0) return packets;
  }
  return [{ name: fileName, bytes }];
}

/** Whether a picked file is a backup `.zip` rather than a single packet. */
export function isBackupArchive(fileName: string | undefined): boolean {
  return /\.zip$/i.test(fileName ?? '');
}

/** The packets inside a backup `.zip`, in archive order. Anything else, such as an older backup's loose audio, is skipped. */
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
