// The `.spokenmargins` format as Builds 29, 32 and 34 read it. Nothing here is new format: every name, limit and
// rule mirrors `Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift` (unchanged in its
// rules from Build 29 to main) and `Contracts/tools/spoken_margins_format.py`.

import { concat, sha256, sha256Hex, utf8 } from './bytes.ts';
import { characterCount, isPathCharacter, markdownEscaped, swiftCollapseSpaces, swiftFractionalDate, swiftJSON } from './swift.ts';

export const FILE_EXTENSION = 'spokenmargins';
export const MIME_TYPE = 'application/vnd.spokenmargins.package+zip';
export const PACKAGE_VERSION = 'spoken-margins.package.v1';
export const COMMENTARY_LAYER_VERSION = 'spoken-margins.commentary-layer.v1';
export const EMBEDDED_TEXT_ITEM_VERSION = 'spoken-margins.embedded-text-item.v1';
export const CONVERSATION_VERSION = 'spoken-margins.margin-conversation.v1';
export const MAP_PACKET_CAPABILITY = 'spoken-margins.listening-map-packet.v1';
export const SUPPORTED_REQUIRED_CAPABILITIES: ReadonlySet<string> = new Set([
  COMMENTARY_LAYER_VERSION,
  EMBEDDED_TEXT_ITEM_VERSION,
  MAP_PACKET_CAPABILITY,
]);

export const LIMITS = Object.freeze({
  packageBytes: 100 * 1024 * 1024,
  manifestBytes: 1 * 1024 * 1024,
  artifactBytes: 5 * 1024 * 1024,
  audioBytes: 20 * 1024 * 1024,
  evidenceBytes: 1 * 1024 * 1024,
  margins: 50,
  compressionRatio: 100,
  audioMs: 600_000,
  senderCharacters: 120,
  titleCharacters: 500,
  transcriptCharacters: 50_000,
  exactTextCharacters: 1_000,
  contextCharactersPerSide: 500,
});

export const MANIFEST_KEYS = new Set([
  'schemaVersion', 'packageId', 'createdAt', 'contentDigest', 'item', 'itemTransport', 'senderDisplayLabel',
  'suggestedRevealMode', 'requiredCapabilities', 'artifacts', 'assets', 'redactions',
]);
export const ITEM_KEYS = new Set([
  'itemType', 'canonicalURL', 'originalURL', 'title', 'author', 'publisher', 'showTitle', 'episodeGUID',
  'enclosureURL', 'publishedAt', 'durationMs', 'normalizedContentSHA256', 'exactEditionSHA256', 'languageCode', 'source',
]);
export const SOURCE_KEYS = new Set(['sourceType', 'canonicalURL', 'title', 'publisher']);
export const TRANSPORT_KEYS = new Set(['kind', 'embeddedArtifactId', 'rightsBasis']);
export const REDACTION_KEYS = new Set([
  'rawAudioOmitted', 'rawTranscriptOmitted', 'fullItemOmitted', 'itemAudioOmitted', 'diagnosticsOmitted',
  'filesystemPathsOmitted', 'unrelatedTurnsOmitted', 'privateRepresentationsOmitted',
]);
export const ARTIFACT_KEYS = new Set(['id', 'kind', 'schemaVersion', 'path', 'required', 'byteCount', 'sha256']);
export const ASSET_KEYS = new Set([
  'id', 'role', 'path', 'mimeType', 'durationMs', 'anchorOffsetMs', 'provenance', 'byteCount', 'sha256',
]);

export type ItemType = 'text' | 'podcast' | 'pdf' | 'epub' | 'other';
export type TransportKind = 'reference' | 'embedded_text' | 'recipient_supplied';
export type RepresentationKind =
  | 'original_audio_and_text' | 'cleaned_audio_and_text' | 'text_only' | 'summary_text' | 'summary_audio_and_text'
  | 'tts_audio_and_text';

export const TEXT_REPRESENTATIONS = new Set<string>(['text_only', 'summary_text']);
export const AUDIO_REPRESENTATIONS = new Set<string>([
  'original_audio_and_text', 'cleaned_audio_and_text', 'summary_audio_and_text', 'tts_audio_and_text',
]);
export const REPRESENTATION_PROVENANCE = new Set([
  'sender_approved_original', 'deterministic_cleanup_v1_sender_approved', 'sender_approved_text_only',
  'sender_approved_summary', 'sender_approved_tts',
]);
export const ANCHOR_TYPES = new Set(['text', 'transcript', 'media', 'turn']);
export const ITEM_TYPES = new Set(['text', 'podcast', 'pdf', 'epub', 'other']);
export const REVEAL_MODES = new Set(['fresh', 'companion', 'guided']);
export const ROLE_ORIGINAL_VOICE = 'original_voice';
export const ROLE_SIGNATURE = 'acoustic_signature';
export const ROLE_SUMMARY_VOICE = 'summary_voice';

export interface ItemIdentity {
  itemType: ItemType;
  canonicalURL?: string;
  originalURL?: string;
  title: string;
  author?: string;
  publisher?: string;
  showTitle?: string;
  episodeGUID?: string;
  enclosureURL?: string;
  publishedAt?: string;
  durationMs?: number;
  normalizedContentSHA256?: string;
  exactEditionSHA256?: string;
  languageCode?: string;
  source?: { sourceType: string; canonicalURL: string; title?: string; publisher?: string };
}

export interface ArtifactDescriptor {
  id: string;
  kind: string;
  schemaVersion: string;
  path: string;
  required: boolean;
  byteCount?: number;
  sha256?: string;
}

export interface AssetDescriptor {
  id: string;
  role: string;
  path: string;
  mimeType: string;
  durationMs?: number;
  anchorOffsetMs?: number;
  provenance: string;
  byteCount?: number;
  sha256?: string;
}

export interface Manifest {
  schemaVersion: string;
  packageId: string;
  createdAt: string;
  contentDigest?: string;
  item: ItemIdentity;
  itemTransport: { kind: TransportKind; embeddedArtifactId?: string; rightsBasis?: string };
  senderDisplayLabel?: string;
  suggestedRevealMode?: string;
  requiredCapabilities: string[];
  artifacts: ArtifactDescriptor[];
  assets: AssetDescriptor[];
  redactions: Record<string, boolean>;
}

export interface Anchor {
  anchorType: string;
  startChar?: number;
  endChar?: number;
  exactText?: string;
  prefix?: string;
  suffix?: string;
  mediaTimeMs?: number;
  roughPercent?: number;
  transcriptSegmentId?: string;
  chapterTitle?: string;
  machineEvidenceAssetIds: string[];
}

export interface Representation {
  id: string;
  kind: RepresentationKind;
  approvedTranscript: string;
  assetId?: string;
  provenance: string;
}

export interface MarginRecord {
  packageScopedId: string;
  createdAt: string;
  anchor: Anchor;
  defaultRepresentationId: string;
  representations: Representation[];
}

export interface CommentaryLayer {
  id: string;
  schemaVersion: string;
  interjections: MarginRecord[];
}

export interface ConversationReply {
  packageScopedId: string;
  conversationId: string;
  parentPackageDigest: string;
  parentPackageScopedId: string;
}

export const SHA256_PATTERN = /^[0-9a-f]{64}$/;

export function isSHA256(value: unknown): value is string {
  return typeof value === 'string' && SHA256_PATTERN.test(value);
}

/** `validHTTPSURL`: https, a host, no user or password, no whitespace and no angle brackets. */
export function isHTTPSURL(value: unknown): value is string {
  if (typeof value !== 'string' || /[\s<>]/u.test(value)) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return url.protocol === 'https:' && url.hostname !== '' && url.username === '' && url.password === '';
}

function validNestedPath(path: string, prefix: string, extension: string): boolean {
  if (!path.startsWith(prefix) || path.includes('..') || path.includes('\\') || path.includes('//')) return false;
  const component = path.slice(prefix.length);
  if (!component || component.includes('/')) return false;
  if (![...component].every(isPathCharacter)) return false;
  const dot = component.lastIndexOf('.');
  return dot > 0 && component.slice(dot + 1) === extension;
}

export const validArtifactPath = (path: string): boolean => validNestedPath(path, 'artifacts/', 'json');
export const validAudioPath = (path: string): boolean => validNestedPath(path, 'assets/audio/', 'm4a');
export const validEvidencePath = (path: string): boolean =>
  validNestedPath(path, 'assets/evidence/', 'shazamsignature');
export const validAssetPath = (path: string): boolean => validAudioPath(path) || validEvidencePath(path);
export const allowedPackagePath = (path: string): boolean =>
  path === 'manifest.json' || path === 'preview.md' || validArtifactPath(path) || validAssetPath(path);

/** Where the app extracts an asset; two assets landing on one name (ignoring case) are refused. */
export function stagedFileName(descriptor: AssetDescriptor): string {
  const dot = descriptor.path.lastIndexOf('.');
  const extension = dot >= 0 ? descriptor.path.slice(dot) : '';
  return [...descriptor.id].map((c) => (isPathCharacter(c) ? c : '-')).join('') + extension;
}

/** The bytes the content digest starts with: the manifest without contentDigest, as Swift re-encodes it. */
export function canonicalManifest(manifest: Manifest): string {
  const { contentDigest: _unused, ...unsigned } = manifest;
  return swiftJSON({ ...unsigned, createdAt: swiftFractionalDate(manifest.createdAt) });
}

/**
 * SpokenMarginsPackageArchive.digest: SHA-256 over the unsigned manifest, then preview.md and each declared file in
 * path order, each as `path NUL sha256(bytes) NUL byte-count NUL`.
 */
export async function contentDigest(
  manifest: Manifest,
  preview: Uint8Array,
  files: ReadonlyMap<string, Uint8Array>,
): Promise<string> {
  const parts: Uint8Array[] = [utf8(canonicalManifest(manifest))];
  const add = async (path: string, data: Uint8Array): Promise<void> => {
    parts.push(utf8(path), new Uint8Array([0]), await sha256(data), new Uint8Array([0]), utf8(String(data.length)), new Uint8Array([0]));
  };
  await add('preview.md', preview);
  for (const path of [...files.keys()].sort()) await add(path, files.get(path) as Uint8Array);
  return sha256Hex(concat(parts));
}

export interface PreviewCounts {
  proposals: number;
  spines: number;
  sketches: number;
  embeddedText?: string;
}

/** SpokenMarginsPackageArchive.previewMarkdown for a Margin packet. The reader compares it byte for byte. */
export function previewMarkdown(
  manifest: Manifest,
  margins: readonly MarginRecord[],
  counts: PreviewCounts = { proposals: 0, spines: 0, sketches: 0 },
): string {
  const sender = swiftCollapseSpaces(manifest.senderDisplayLabel ?? '');
  const count = margins.length;
  let transport: string;
  if (manifest.itemTransport.kind === 'reference') {
    transport = 'Item transport: reference only; the recipient reconstructs the item.';
  } else if (manifest.itemTransport.kind === 'recipient_supplied') {
    transport = 'Item transport: not included; the recipient must provide the same item.';
  } else {
    transport = `Item transport: full listened-to text included (${characterCount(counts.embeddedText ?? '')} characters) after a private-sharing rights confirmation.`;
  }
  const lines = [
    '# Spoken Margins', '',
    `${markdownEscaped(sender || 'Someone')} shared ${count} reviewed Margin${count === 1 ? '' : 's'} about **${markdownEscaped(manifest.item.title)}**.`,
    '',
    manifest.item.canonicalURL !== undefined ? `Item reference: <${manifest.item.canonicalURL}>` : 'Item reference: no public URL',
    '',
    transport,
    'Item audio is not included.',
    `Voice assets: ${manifest.assets.filter((a) => a.path.startsWith('assets/audio/')).length}.`,
    `Acoustic signatures: ${manifest.assets.filter((a) => a.role === ROLE_SIGNATURE).length}. These are opaque matching evidence, not item audio.`,
    `Listening Map proposals: ${counts.proposals}. Proposals are not activated automatically.`,
    `Episode fingerprint maps: ${counts.spines}. Transcript phrase sketches: ${counts.sketches}. Full episode transcripts and source audio are not included.`,
    '',
  ];
  margins.forEach((margin, index) => {
    const representation = margin.representations.find((r) => r.id === margin.defaultRepresentationId);
    lines.push(`## Margin ${index + 1}`, '', markdownEscaped(representation?.approvedTranscript ?? 'Unavailable representation'), '');
  });
  return lines.join('\n');
}
