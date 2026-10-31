// writePacket: the listener's Margins on one episode as a `.spokenmargins` file the iPhone app imports. It writes
// what the app's own writer (SpokenMarginsPackageArchive.prepare and write) writes for a podcast shared by
// reference: one commentary layer of media-anchored Margins, voice as AAC `.m4a`, and a conversation artifact only
// when a Margin answers one from an imported packet. Nothing here is new format, so Builds 32 and 34 import it.
//
// A podcast-anchored packet needs (see the PR for #2984):
// - item: itemType `podcast`, a title, and as many of episodeGUID, enclosureURL and canonicalURL as are public.
//   The app finds the listener's copy by guid, then enclosure, then link; with none it asks them to pick it.
// - itemTransport `reference` when the item has a public https link, else `recipient_supplied`.
// - each Margin: a media anchor with mediaTimeMs (and roughPercent when the length is known), no Shazam evidence.
//   The page streams the episode, so it has no bytes to fingerprint or hash. Without evidence the app (from the
//   build after 35, #3041) places the Margin at the sender's time, marked approximate, and plays it there during
//   playback unless its placement pass finds the two copies' clocks differ. Builds 32 to 35 leave it unplaced.
// - non-empty text on every Margin, voice ones included: the app shares no Margin without a transcript. A voice
//   Margin the listener left without words gets placeholder words instead (src/shared/placeholder.ts, #3025), in
//   the same transcript field, so it is never left out for lack of them.

import { sha256Hex, utf8 } from './bytes.ts';
import { PacketError } from './errors.ts';
import {
  COMMENTARY_LAYER_VERSION, CONVERSATION_VERSION, FILE_EXTENSION, LIMITS, PACKAGE_VERSION, ROLE_ORIGINAL_VOICE,
  contentDigest, previewMarkdown,
} from './format.ts';
import type {
  ArtifactDescriptor, AssetDescriptor, ConversationReply, ItemIdentity, Manifest, MarginRecord,
} from './format.ts';
import { shareableEpisodeGUID, shareableLink } from './links.ts';
import { NotAacError, normalizeM4a } from './m4a.ts';
import { characterCount, swiftFractionalDate, swiftJSON, swiftTrim, swiftWholeSecondDate } from './swift.ts';
import { writeZip } from './zip.ts';
import type { Episode, Margin, Show } from '../shared/model.ts';
import { voicePlaceholder } from '../shared/placeholder.ts';

export interface WritePacketOptions {
  show?: Show;
  /** The name the friend sees ("Ada shared 2 Margins…"). Up to 120 characters. */
  sender?: string;
  /** Fixed for tests; a fresh `package-<uuid>` otherwise. */
  packageId?: string;
  /** Fixed for tests; now otherwise. */
  createdAt?: Date;
  /** Conversation ids of imported Margins (readPacket's `conversationIds`), so a reply to a reply stays in its thread. */
  conversationIds?: Readonly<Record<string, string>>;
}

export interface WrittenPacket {
  bytes: Uint8Array;
  fileName: string;
  mimeType: string;
  packageId: string;
  contentDigest: string;
  /** Ids of the Margins written, in packet order. */
  included: string[];
  /** Ids of written Margins left out because they have no text. A voice Margin is never left out for that. */
  leftOut: string[];
  /** The app's words for what was left out, when anything was. */
  notice?: string;
}

const REPLY_ID = /^packet:([0-9a-f]{64}):(.+)$/;

const pad = (n: number): string => String(n).padStart(4, '0');

const httpsShareable = (value: string | undefined): string | undefined => {
  const link = shareableLink(value);
  return link && link.startsWith('https://') ? link : undefined;
};

/**
 * MarginReplyLink.conversationId(rootedAt:): "conversation-" and the first 16 bytes of SHA-256(digest \n id), for a
 * reply to a Margin that starts a conversation. A reply to a reply takes its parent's conversation id instead.
 */
export async function conversationId(parentDigest: string, parentScopedId: string): Promise<string> {
  const hash = await sha256Hex(utf8(`${parentDigest}\n${parentScopedId}`));
  return `conversation-${hash.slice(0, 32)}`;
}

export function packetFileName(title: string): string {
  const slug = title.normalize('NFKD').replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '').slice(0, 60);
  return `${slug || 'Margins'}.${FILE_EXTENSION}`;
}

/**
 * The words a Margin travels with: its own, or for a voice Margin without any, the placeholder naming the moment,
 * the item and the day it was recorded. '' for a written Margin with no words, which can't travel.
 */
export function sharedWords(margin: Margin, itemTitle: string): string {
  const own = swiftTrim(margin.text ?? '');
  if (own || !margin.voice) return own;
  return voicePlaceholder({ atSeconds: margin.atSeconds, title: itemTitle, recordedAt: new Date(margin.createdAt) });
}

export async function writePacket(episode: Episode, margins: readonly Margin[], options: WritePacketOptions = {}): Promise<WrittenPacket> {
  const title = swiftTrim(episode.title);
  const ordered = [...margins].sort((a, b) => a.atSeconds - b.atSeconds);
  const words = new Map(ordered.map((m) => [m, sharedWords(m, title)]));
  const withText = ordered.filter((m) => words.get(m) !== '');
  const leftOut = ordered.filter((m) => !withText.includes(m)).map((m) => m.id);
  if (withText.length === 0) {
    throw new PacketError('cannotShare', 'no Margin has text',
      ordered.length === 1
        ? "This Margin has no words yet, so there's nothing to share. Add its text, then share it."
        : "These Margins have no words yet, so there's nothing to share. Add their text, then share them.");
  }
  if (withText.length > LIMITS.margins) {
    throw new PacketError('cannotShare', `${withText.length} Margins`, 'Spoken Margins shares up to 50 Margins at a time. Pick fewer, then share again.');
  }
  if (!title || characterCount(title) > LIMITS.titleCharacters) {
    throw new PacketError('cannotShare', 'episode title is empty or too long');
  }

  const durationMs = episode.durationSeconds !== undefined && episode.durationSeconds > 0
    ? Math.round(episode.durationSeconds * 1000) : undefined;
  const show = options.show;
  const canonicalURL = httpsShareable(episode.pageUrl) ?? httpsShareable(episode.audioUrl);
  const enclosureURL = httpsShareable(episode.audioUrl);
  const feedURL = httpsShareable(show?.feedUrl);
  const guid = shareableEpisodeGUID(episode.guid);
  const item: ItemIdentity = {
    itemType: 'podcast',
    title,
    ...(canonicalURL && { canonicalURL }),
    ...(enclosureURL && { enclosureURL }),
    ...(guid && characterCount(guid) <= 1000 && { episodeGUID: guid }),
    ...(show?.title && characterCount(show.title) <= 500 && { showTitle: show.title }),
    ...(show?.author && characterCount(show.author) <= 300 && { publisher: show.author }),
    ...(durationMs !== undefined && { durationMs }),
    ...(episode.publishedAt && characterCount(episode.publishedAt) <= 100 && { publishedAt: episode.publishedAt }),
    ...(feedURL && {
      source: {
        sourceType: show?.kind === 'substack' ? 'newsletter' : 'podcast_feed',
        canonicalURL: feedURL,
        ...(show?.title && characterCount(show.title) <= 500 && { title: show.title }),
      },
    }),
  };

  const records: MarginRecord[] = [];
  const assets: AssetDescriptor[] = [];
  const files = new Map<string, Uint8Array>();
  const replies: ConversationReply[] = [];
  for (const [index, margin] of withText.entries()) {
    const n = pad(index + 1);
    const scopedId = `margin-${n}`;
    const text = words.get(margin) as string;
    if (characterCount(text) > LIMITS.transcriptCharacters) throw new PacketError('cannotShare', `${margin.id} text is too long`);
    const mediaTimeMs = Math.max(0, Math.round(margin.atSeconds * 1000));
    let representation;
    if (margin.voice) {
      let audio: { bytes: Uint8Array; durationMs: number };
      try {
        audio = normalizeM4a(new Uint8Array(await margin.voice.blob.arrayBuffer()));
      } catch (error) {
        if (error instanceof NotAacError) throw new PacketError('cannotShare', `${margin.id}: ${error.message}`);
        throw error;
      }
      if (audio.durationMs <= 0 || audio.durationMs > LIMITS.audioMs) {
        throw new PacketError('cannotShare', `${margin.id} voice is ${audio.durationMs} ms`, 'A voice Margin can be up to 10 minutes long.');
      }
      const path = `assets/audio/margin-${n}-original.m4a`;
      const assetId = `asset-${n}-original`;
      files.set(path, audio.bytes);
      assets.push({
        id: assetId, role: ROLE_ORIGINAL_VOICE, path, mimeType: 'audio/mp4', durationMs: audio.durationMs,
        provenance: 'sender_approved_original', byteCount: audio.bytes.length, sha256: await sha256Hex(audio.bytes),
      });
      representation = {
        id: `representation-${n}-original`, kind: 'original_audio_and_text' as const, approvedTranscript: text, assetId,
        provenance: 'sender_approved_original',
      };
    } else {
      representation = {
        id: `representation-${n}-text`, kind: 'text_only' as const, approvedTranscript: text, provenance: 'sender_approved_text_only',
      };
    }
    records.push({
      packageScopedId: scopedId,
      createdAt: swiftWholeSecondDate(new Date(margin.createdAt)),
      anchor: {
        anchorType: 'media',
        mediaTimeMs,
        ...(durationMs !== undefined && { roughPercent: Math.min(100, Math.floor((mediaTimeMs * 100) / durationMs)) }),
        machineEvidenceAssetIds: [],
      },
      defaultRepresentationId: representation.id,
      representations: [representation],
    });
    const parent = margin.replyToId ? REPLY_ID.exec(margin.replyToId) : null;
    if (parent) {
      replies.push({
        packageScopedId: scopedId,
        conversationId: options.conversationIds?.[margin.replyToId as string] ?? await conversationId(parent[1], parent[2]),
        parentPackageDigest: parent[1],
        parentPackageScopedId: parent[2],
      });
    }
  }

  const artifacts: ArtifactDescriptor[] = [];
  const addArtifact = async (id: string, kind: string, schemaVersion: string, path: string, required: boolean, value: unknown): Promise<void> => {
    const data = utf8(swiftJSON(value));
    files.set(path, data);
    artifacts.push({ id, kind, schemaVersion, path, required, byteCount: data.length, sha256: await sha256Hex(data) });
  };
  await addArtifact('commentary-layer', 'commentary_layer', COMMENTARY_LAYER_VERSION, 'artifacts/commentary-layer.json', true,
    { id: 'commentary-layer', schemaVersion: COMMENTARY_LAYER_VERSION, interjections: records });
  // Only a packet with a reply gets the artifact; it is optional, so Build 29 imports the replies as plain Margins.
  if (replies.length) {
    await addArtifact('margin-conversation', 'conversation', CONVERSATION_VERSION, 'artifacts/margin-conversation.json', false,
      { id: 'margin-conversation', schemaVersion: CONVERSATION_VERSION, replies });
  }

  const sender = options.sender ? [...swiftTrim(options.sender)].slice(0, LIMITS.senderCharacters).join('') : '';
  const createdAt = swiftFractionalDate((options.createdAt ?? new Date()).toISOString());
  const manifest: Manifest = {
    schemaVersion: PACKAGE_VERSION,
    packageId: options.packageId ?? `package-${crypto.randomUUID()}`,
    createdAt,
    item,
    itemTransport: { kind: canonicalURL ? 'reference' : 'recipient_supplied' },
    ...(sender && { senderDisplayLabel: sender }),
    requiredCapabilities: [COMMENTARY_LAYER_VERSION],
    artifacts,
    assets,
    redactions: {
      rawAudioOmitted: true, rawTranscriptOmitted: true, fullItemOmitted: true, itemAudioOmitted: true,
      diagnosticsOmitted: true, filesystemPathsOmitted: true, unrelatedTurnsOmitted: true, privateRepresentationsOmitted: true,
    },
  };
  const preview = utf8(previewMarkdown(manifest, records));
  const digest = await contentDigest(manifest, preview, files);
  const signed = { ...manifest, contentDigest: digest };

  const sorted = (prefix: string): [string, Uint8Array][] => [...files].filter(([p]) => p.startsWith(prefix)).sort(([a], [b]) => (a < b ? -1 : 1));
  const bytes = await writeZip([
    { path: 'manifest.json', data: utf8(swiftJSON(signed)), deflate: true },
    { path: 'preview.md', data: preview, deflate: true },
    ...sorted('artifacts/').map(([path, data]) => ({ path, data, deflate: true })),
    ...sorted('assets/').map(([path, data]) => ({ path, data, deflate: false })),
  ]);
  if (bytes.length > LIMITS.packageBytes) throw new PacketError('tooLarge', 'packet is larger than 100 MB');

  const result: WrittenPacket = {
    bytes,
    fileName: packetFileName(title),
    mimeType: 'application/vnd.spokenmargins.package+zip',
    packageId: manifest.packageId,
    contentDigest: digest,
    included: withText.map((m) => m.id),
    leftOut,
  };
  if (leftOut.length) {
    result.notice = leftOut.length === 1
      ? "1 Margin has no transcript and wasn't included."
      : `${leftOut.length} Margins have no transcript and weren't included.`;
  }
  return result;
}
