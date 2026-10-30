// readPacket: open a `.spokenmargins` file the way the iPhone app does, and turn it into the web model's Margins.
// Every rule is the shipped reader's (SpokenMarginsPackageArchive.read, Builds 29 to 34), in the order
// `Contracts/tools/spoken_margins_format.py` checks them. A packet this refuses, the app refuses; every refusal is a
// PacketError carrying one plain message.

import { fromUtf8, sha256Hex } from './bytes.ts';
import { KIND_SWIFT_TYPE, decodeProblem } from './decode.ts';
import { PacketError, damaged, mismatch, newerApp, tooLarge } from './errors.ts';
import {
  ARTIFACT_KEYS, ASSET_KEYS, AUDIO_REPRESENTATIONS, COMMENTARY_LAYER_VERSION, CONVERSATION_VERSION,
  EMBEDDED_TEXT_ITEM_VERSION, FILE_EXTENSION, ITEM_KEYS, LIMITS, MANIFEST_KEYS, MAP_PACKET_CAPABILITY, PACKAGE_VERSION,
  REDACTION_KEYS, ROLE_SIGNATURE, ROLE_SUMMARY_VOICE, SOURCE_KEYS, TEXT_REPRESENTATIONS, TRANSPORT_KEYS,
  allowedPackagePath, contentDigest, isHTTPSURL, isSHA256, previewMarkdown, stagedFileName, validArtifactPath,
  validAssetPath,
} from './format.ts';
import type { AssetDescriptor, ItemIdentity, Manifest, MarginRecord } from './format.ts';
import { NotAacError, demuxAac, durationMs as aacDurationMs } from './m4a.ts';
import { characterCount, swiftTrim } from './swift.ts';
import { readZip } from './zip.ts';
import type { ZipEntryInfo } from './zip.ts';
import type { Episode, Margin } from '../shared/model.ts';

type J = any;

const ARTIFACT_VERSIONS: Record<string, string> = {
  commentary_layer: COMMENTARY_LAYER_VERSION,
  listening_map_proposal: 'spoken-margins.listening-map-proposal.v2',
  edition_fingerprint_spine: 'spoken-margins.edition-fingerprint-spine.v1',
  transcript_phrase_sketch: 'spoken-margins.transcript-phrase-sketch.v1',
  embedded_text_item: EMBEDDED_TEXT_ITEM_VERSION,
  conversation: CONVERSATION_VERSION,
};
const ALWAYS_REQUIRED_KINDS = new Set(['commentary_layer', 'embedded_text_item']);
const SUPPORTED_REQUIRED = new Set([COMMENTARY_LAYER_VERSION, EMBEDDED_TEXT_ITEM_VERSION]);
const SIGNATURE_MIME_TYPE = 'application/vnd.apple.shazam.signature';

/** Closed artifacts: unknown keys are refused, like the manifest's. [root keys, list key, entry keys] */
const CLOSED_ARTIFACTS: Record<string, [ReadonlySet<string>, string, ReadonlySet<string>]> = {
  edition_fingerprint_spine: [
    new Set(['id', 'schemaVersion', 'itemId', 'canonicalURL', 'episodeGUID', 'producingEditionDurationMs',
      'producingEditionSHA256', 'createdAt', 'generatorVersion', 'landmarks']),
    'landmarks',
    new Set(['id', 'order', 'sourceMediaStartMs', 'sourceMediaEndMs', 'anchorMediaTimeMs', 'continuityEpoch', 'trigger',
      'provenance', 'signatureAssetId', 'transcriptSketchWindowId', 'generatorVersion']),
  ],
  transcript_phrase_sketch: [
    new Set(['id', 'schemaVersion', 'itemId', 'languageCode', 'saltBase64', 'normalizationVersion', 'shingleWidth',
      'maximumHashesPerWindow', 'createdAt', 'windows']),
    'windows',
    new Set(['id', 'sourceStartMs', 'sourceEndMs', 'hashes']),
  ],
  conversation: [
    new Set(['id', 'schemaVersion', 'replies']),
    'replies',
    new Set(['packageScopedId', 'conversationId', 'parentPackageDigest', 'parentPackageScopedId']),
  ],
};

/** Swift compares Strings by canonical equivalence. */
const canon = (text: string): string => text.normalize('NFC');
const lengthOK = (value: unknown, maximum: number): boolean =>
  value === undefined || value === null || (typeof value === 'string' && characterCount(value) <= maximum);
const isObject = (value: unknown): value is Record<string, J> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

function closedKeys(document: Record<string, unknown>, allowed: ReadonlySet<string>, context: string): void {
  const unknown = Object.keys(document).filter((key) => !allowed.has(key)).sort();
  if (unknown.length) throw mismatch(`unknown ${context} fields: ${unknown.join(', ')}`);
}

function parseJSON(bytes: Uint8Array, where: string): J {
  const text = fromUtf8(bytes);
  if (text === null) throw mismatch(`${where} is not UTF-8`);
  try {
    return JSON.parse(text);
  } catch {
    throw mismatch(`${where} is not JSON`);
  }
}

/** A Margin anchored to a passage of text (an article packet) rather than a time. The web app shows these only. */
export interface TextMargin {
  id: string;
  createdAt: string;
  text: string;
  quote?: string;
  prefix?: string;
  suffix?: string;
  author?: string;
  replyToId?: string;
}

/** The episode a packet is about, as far as the packet says. The app matches by guid, then enclosure, then page. */
export interface PacketEpisode extends Omit<Episode, 'id' | 'showId'> {
  itemType: string;
  showTitle?: string;
  publisher?: string;
}

export interface ReadPacketResult {
  packageId: string;
  contentDigest: string;
  createdAt: string;
  sender?: string;
  item: ItemIdentity;
  episode: PacketEpisode;
  /** Margins placed by time, ready for the player. */
  margins: Margin[];
  /** Margins placed by a quote in text. */
  textMargins: TextMargin[];
}

export interface ReadPacketOptions {
  /** The file's name, when it came from a file picker. Anything not ending in `.spokenmargins` is refused. */
  fileName?: string;
  /** The listener's own episode these Margins belong to. Defaults to `packet:<contentDigest>`. */
  episodeId?: string;
}

/** The id an imported Margin gets, and the id a reply names its parent by. */
export const packetMarginId = (digest: string, scopedId: string): string => `packet:${digest}:${scopedId}`;

const firstFailed = (rules: [string, () => boolean][]): string | undefined => rules.find(([, holds]) => !holds())?.[0];

function base64Length(value: string): number | undefined {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 !== 0) return undefined;
  try {
    return atob(value).length;
  } catch {
    return undefined;
  }
}

type Position = [number | null, number | null];

function position(anchor: J, isEnd: boolean): Position | null {
  const [first, second] = isEnd ? ['endChar', 'startChar'] : ['startChar', 'endChar'];
  const character = anchor[first] ?? anchor[second] ?? null;
  if (anchor.mediaTimeMs == null && character === null) return null;
  return [anchor.mediaTimeMs ?? null, character];
}
const isPast = (reached: Position, start: Position): boolean =>
  reached.some((left, i) => left !== null && start[i] !== null && left > (start[i] as number));
const furthest = (reached: Position, p: Position | null): Position =>
  p === null ? reached : (reached.map((v, i) => (v === null ? p[i] : p[i] === null ? v : Math.max(v, p[i] as number))) as Position);

/** PortableListeningMapContract.violations without the quotation rules, on scenes as forSharing leaves them. */
function breaksSceneRule(scenes: J[]): boolean {
  let reachedStart: Position = [null, null];
  let reachedEnd: Position = [null, null];
  for (const scene of scenes) {
    if (scene.eligibility === 'eligible' && (!scene.summaryText || scene.summaryProvenance == null)) return true;
    const start = position(scene.startAnchor, false);
    const end = position(scene.endAnchor, true);
    if (start && end && isPast(start, end)) return true;
    if (start && (isPast(reachedStart, start) || isPast(reachedEnd, start))) return true;
    reachedStart = furthest(reachedStart, start);
    reachedEnd = furthest(reachedEnd, end);
  }
  return false;
}

export async function readPacket(input: Uint8Array | ArrayBuffer | Blob, options: ReadPacketOptions = {}): Promise<ReadPacketResult> {
  if (options.fileName !== undefined && !options.fileName.toLowerCase().endsWith(`.${FILE_EXTENSION}`)) {
    throw new PacketError('notAPacket', `file name ${options.fileName} has the wrong extension`);
  }
  const bytes = input instanceof Uint8Array
    ? input
    : new Uint8Array(input instanceof Blob ? await input.arrayBuffer() : input);
  if (bytes.length < 4 || bytes[0] !== 0x50 || bytes[1] !== 0x4b) throw new PacketError('notAPacket', 'not a zip archive');
  if (bytes.length > LIMITS.packageBytes) throw tooLarge('the packet is larger than 100 MB');

  // The archive: allowed paths only, each under its limit, nothing that inflates past 100 times.
  const seen = new Set<string>();
  const checkEntry = (entry: ZipEntryInfo): void => {
    if (seen.has(entry.path)) throw damaged(`duplicate entry ${entry.path}`);
    seen.add(entry.path);
    if (entry.isDirectory || !allowedPackagePath(entry.path)) throw damaged(`unsafe entry ${entry.path}`);
    const size = entry.uncompressedSize;
    if (entry.path === 'manifest.json' && size > LIMITS.manifestBytes) throw damaged('manifest is too large');
    if (entry.path.startsWith('artifacts/') && size > LIMITS.artifactBytes) throw mismatch(`${entry.path} is too large`);
    if (entry.path.startsWith('assets/audio/') && size > LIMITS.audioBytes) throw tooLarge(`voice asset too large: ${entry.path}`);
    if (entry.path.startsWith('assets/evidence/') && size > LIMITS.evidenceBytes) throw mismatch(`${entry.path} is too large`);
  };
  const entries = await readZip(bytes, {
    totalBytes: LIMITS.packageBytes,
    compressionRatio: LIMITS.compressionRatio,
    entryBytes: () => Number.MAX_SAFE_INTEGER,
  }, checkEntry);

  const manifestBytes = entries.get('manifest.json');
  if (!manifestBytes) throw damaged('the packet has no manifest.json');
  const manifest: J = parseJSON(manifestBytes, 'manifest.json');

  // Shape: the version first, then the closed key sets, then what Codable needs.
  if (!isObject(manifest)) throw mismatch('the manifest root is not an object');
  if (typeof manifest.schemaVersion === 'string' && manifest.schemaVersion !== PACKAGE_VERSION) {
    throw newerApp(`package version ${manifest.schemaVersion}`);
  }
  closedKeys(manifest, MANIFEST_KEYS, 'manifest');
  for (const [key, list] of [['item', false], ['itemTransport', false], ['artifacts', true], ['assets', true], ['redactions', false]] as const) {
    if (list ? !Array.isArray(manifest[key]) : !isObject(manifest[key])) throw mismatch(`${key} is absent or has the wrong type`);
  }
  closedKeys(manifest.item, ITEM_KEYS, 'item');
  if (isObject(manifest.item.source)) closedKeys(manifest.item.source, SOURCE_KEYS, 'source');
  closedKeys(manifest.itemTransport, TRANSPORT_KEYS, 'item transport');
  closedKeys(manifest.redactions, REDACTION_KEYS, 'redactions');
  for (const d of manifest.artifacts) {
    if (!isObject(d)) throw mismatch('an artifact descriptor is not an object');
    closedKeys(d, ARTIFACT_KEYS, 'artifact descriptor');
  }
  for (const d of manifest.assets) {
    if (!isObject(d)) throw mismatch('an asset descriptor is not an object');
    closedKeys(d, ASSET_KEYS, 'asset descriptor');
  }
  const problem = decodeProblem(manifest, 'SpokenMarginsPackageManifest');
  if (problem) throw mismatch(problem);
  const m = manifest as Manifest;

  for (const group of [m.artifacts.map((a) => a.id), m.assets.map((a) => a.id), m.artifacts.map((a) => a.path),
    m.assets.map((a) => a.path), m.assets.map((a) => stagedFileName(a).toLowerCase())]) {
    if (new Set(group.map(canon)).size !== group.length) throw mismatch('descriptor identities are not unique');
  }

  const declared = new Set(['manifest.json', 'preview.md', ...m.artifacts.map((d) => d.path), ...m.assets.map((d) => d.path)]);
  if (declared.size !== entries.size || [...entries.keys()].some((path) => !declared.has(path))) {
    throw damaged('declared entries do not match the archive');
  }
  for (const d of [...m.artifacts, ...m.assets]) {
    const body = entries.get(d.path) as Uint8Array;
    if (d.byteCount !== body.length || d.sha256 !== await sha256Hex(body)) throw damaged(`${d.path} changed after export`);
  }

  // Artifacts, each at the one version this reader knows.
  const decoded: Record<string, J[]> = Object.fromEntries(Object.keys(ARTIFACT_VERSIONS).map((k) => [k, []]));
  for (const d of m.artifacts) {
    const expected = ARTIFACT_VERSIONS[d.kind];
    if (expected === undefined) {
      if (d.required) throw newerApp(`required artifact kind ${d.kind}`);
      continue;
    }
    if (d.schemaVersion !== expected) {
      if (d.required || ALWAYS_REQUIRED_KINDS.has(d.kind)) throw newerApp(`${d.kind} version ${d.schemaVersion}`);
      continue;
    }
    const value = parseJSON(entries.get(d.path) as Uint8Array, d.path);
    if (!isObject(value)) throw mismatch(`${d.kind} root is not an object`);
    const closed = CLOSED_ARTIFACTS[d.kind];
    if (closed) {
      const [keys, listKey, entryKeys] = closed;
      closedKeys(value, keys, d.kind);
      if (!Array.isArray(value[listKey]) || !value[listKey].every(isObject)) throw mismatch(`${d.kind} ${listKey} are absent`);
      for (const entry of value[listKey]) closedKeys(entry, entryKeys, `${d.kind} entry`);
    }
    const artifactProblem = decodeProblem(value, KIND_SWIFT_TYPE[d.kind]);
    if (artifactProblem) throw mismatch(`${d.kind} does not decode: ${artifactProblem}`);
    if (canon(value.id) !== canon(d.id) || value.schemaVersion !== d.schemaVersion) {
      throw mismatch(`${d.kind} id or schemaVersion does not match its descriptor`);
    }
    decoded[d.kind].push(value);
  }

  // The boundary: what a packet may say about its item, its transport and its privacy.
  const { item, itemTransport: transport, redactions } = m;
  const layers = decoded.commentary_layer;
  if (characterCount(m.packageId) < 1 || [...m.packageId].length > 200 || m.artifacts.length === 0 || layers.length !== 1) {
    throw mismatch('a packet needs a packageId of 1-200 characters and exactly one commentary layer');
  }
  for (const capability of m.requiredCapabilities) {
    if (capability === MAP_PACKET_CAPABILITY) {
      throw new PacketError('needsNewerApp', 'Listening Map packet',
        'This file holds a Listening Map. Open it in the Spoken Margins iPhone app; the web app reads Margins only.');
    }
    if (!SUPPORTED_REQUIRED.has(capability)) throw newerApp(`required capability ${capability}`);
  }
  if (!isSHA256(m.contentDigest)) throw mismatch('contentDigest is absent or not a lowercase SHA-256');
  if (m.senderDisplayLabel !== undefined && m.senderDisplayLabel !== null && characterCount(m.senderDisplayLabel) > LIMITS.senderCharacters) {
    throw mismatch('senderDisplayLabel is longer than 120 characters');
  }
  for (const key of REDACTION_KEYS) {
    if (key !== 'fullItemOmitted' && redactions[key] !== true) throw mismatch(`redaction ${key} must be true`);
  }
  for (const key of ['canonicalURL', 'originalURL', 'enclosureURL'] as const) {
    if (item[key] !== undefined && item[key] !== null && !isHTTPSURL(item[key])) throw mismatch(`item.${key} is not https`);
  }
  if (item.source && !isHTTPSURL(item.source.canonicalURL)) throw mismatch('item.source.canonicalURL is not https');
  if (characterCount(item.title) < 1 || characterCount(item.title) > LIMITS.titleCharacters || !swiftTrim(item.title)) {
    throw mismatch('title is empty or longer than 500 characters');
  }
  const itemLimits: Record<string, number> = { author: 300, publisher: 300, showTitle: 500, episodeGUID: 1000, publishedAt: 100, languageCode: 35 };
  for (const [key, maximum] of Object.entries(itemLimits)) {
    if (!lengthOK((item as J)[key], maximum)) throw mismatch(`${key} is longer than ${maximum} characters`);
  }
  if (!lengthOK(item.source?.title, 500) || !lengthOK(item.source?.publisher, 300)) throw mismatch('source title or publisher is too long');
  if (typeof item.durationMs === 'number' && item.durationMs < 0) throw mismatch('durationMs is negative');
  for (const key of ['normalizedContentSHA256', 'exactEditionSHA256'] as const) {
    if (item[key] !== undefined && item[key] !== null && !isSHA256(item[key])) throw mismatch(`${key} is not a lowercase SHA-256`);
  }
  for (const d of m.artifacts) if (!validArtifactPath(d.path)) throw mismatch(`artifact path ${d.path} is not allowed`);
  for (const d of m.assets) {
    const { durationMs, anchorOffsetMs: offset } = d;
    if (!validAssetPath(d.path) || !d.role || !d.mimeType || characterCount(d.provenance) > 200
      || (typeof durationMs === 'number' && (durationMs < 0 || durationMs > LIMITS.audioMs))
      || (typeof offset === 'number' && (offset < -LIMITS.audioMs || offset > LIMITS.audioMs))
      || (d.role === ROLE_SIGNATURE && (offset === undefined || offset === null))) {
      throw mismatch(`asset descriptor ${d.path} is out of bounds`);
    }
  }

  const embedded = decoded.embedded_text_item;
  if (transport.kind === 'reference' || transport.kind === 'recipient_supplied') {
    const hasURL = item.canonicalURL !== undefined && item.canonicalURL !== null;
    if (hasURL !== (transport.kind === 'reference') || transport.embeddedArtifactId != null || transport.rightsBasis != null
      || redactions.fullItemOmitted !== true || embedded.length > 0) {
      throw mismatch('item transport is inconsistent');
    }
  } else {
    if (item.canonicalURL != null || item.itemType === 'podcast' || transport.rightsBasis == null
      || redactions.fullItemOmitted !== false || embedded.length !== 1
      || canon(embedded[0].id) !== canon(transport.embeddedArtifactId ?? '')) {
      throw mismatch('embedded item transport is inconsistent');
    }
    const text = embedded[0].text;
    if (!swiftTrim(text) || embedded[0].originalMediaType !== item.itemType) throw mismatch('embedded item transport is inconsistent');
    if (item.exactEditionSHA256 !== await sha256Hex(new TextEncoder().encode(text))) {
      throw mismatch('embedded item transport is inconsistent: the text is another edition');
    }
    // normalizedContentSHA256 needs Foundation's case folding; the exact-edition hash above already pins the text.
  }

  const assetsById = new Map(m.assets.map((a) => [canon(a.id), a] as const));
  const asset = (id: string | undefined | null): AssetDescriptor | undefined => (id == null ? undefined : assetsById.get(canon(id)));
  const layer = layers[0];
  const interjections: MarginRecord[] = layer.interjections;
  if (interjections.length < 1 || interjections.length > LIMITS.margins) throw mismatch('the commentary layer needs 1-50 Margins');
  if (new Set(interjections.map((r) => canon(r.packageScopedId))).size !== interjections.length) {
    throw mismatch('package-scoped Margin ids are not unique');
  }
  for (const record of interjections) {
    const { anchor, representations } = record;
    const start = anchor.startChar;
    const end = anchor.endChar;
    const bounded = characterCount(record.packageScopedId) >= 1 && characterCount(record.packageScopedId) <= 200
      && representations.length > 0
      && new Set(representations.map((r) => canon(r.id))).size === representations.length
      && representations.some((r) => canon(r.id) === canon(record.defaultRepresentationId))
      && [start, end, anchor.mediaTimeMs].every((v) => v === undefined || v === null || v >= 0)
      && (start == null || end == null || end >= start)
      && lengthOK(anchor.exactText, LIMITS.exactTextCharacters)
      && lengthOK(anchor.prefix, LIMITS.contextCharactersPerSide)
      && lengthOK(anchor.suffix, LIMITS.contextCharactersPerSide)
      && (anchor.roughPercent == null || (anchor.roughPercent >= 0 && anchor.roughPercent <= 100))
      && lengthOK(anchor.transcriptSegmentId, 300)
      && lengthOK(anchor.chapterTitle, 500);
    if (!bounded) throw mismatch('a Margin field is absent or out of bounds');
    for (const evidence of anchor.machineEvidenceAssetIds) {
      if (asset(evidence)?.role !== ROLE_SIGNATURE) throw mismatch(`anchor evidence ${evidence} is not an acoustic signature`);
    }
    for (const r of representations) {
      if (characterCount(r.id) < 1 || characterCount(r.id) > 200 || !swiftTrim(r.approvedTranscript)
        || characterCount(r.approvedTranscript) > LIMITS.transcriptCharacters) {
        throw mismatch('a representation is empty or out of bounds');
      }
      if (TEXT_REPRESENTATIONS.has(r.kind) && r.assetId != null) throw mismatch('a text representation references audio');
      if (AUDIO_REPRESENTATIONS.has(r.kind) && !(asset(r.assetId)?.path ?? '').startsWith('assets/audio/')) {
        throw mismatch('an audio representation names no voice asset');
      }
    }
  }

  // Listening Map proposals, fingerprint spines and phrase sketches: the web app uses none of them, but a packet
  // whose copy breaks a bound is refused by the app, so it is refused here too.
  for (const proposal of decoded.listening_map_proposal) {
    // forSharing (#480): a proposal that still breaks a scene rule once excluded scenes lose their summaries is
    // left out, and its Margins import. (The app also drops one whose summary quotes its source; the web app never
    // shows proposals, so that check isn't ported.)
    if (breaksSceneRule(proposal.scenes)) continue;
    const scenes: J[] = proposal.scenes;
    if (!scenes.length || characterCount(proposal.generator) > 200 || new Set(scenes.map((s) => canon(s.id))).size !== scenes.length
      || scenes.some((s, i) => s.order !== i)) {
      throw mismatch('Listening Map proposal order is invalid');
    }
    for (const scene of scenes) {
      if (!lengthOK(scene.title, 500) || !lengthOK(scene.summaryText, 10_000) || !lengthOK(scene.eligibilityReason, 500)) {
        throw mismatch('Listening Map scene is out of bounds');
      }
      // A summary on a scene that isn't eligible is stripped before the app checks it (forSharing, #480).
      if (scene.eligibility === 'eligible' && scene.summaryAssetId != null && asset(scene.summaryAssetId)?.role !== ROLE_SUMMARY_VOICE) {
        throw mismatch('scene summary asset is absent or has the wrong role');
      }
    }
  }
  for (const spine of decoded.edition_fingerprint_spine) {
    const landmarks: J[] = spine.landmarks;
    const failed = firstFailed([
      ['item_id', () => characterCount(spine.itemId) >= 1 && characterCount(spine.itemId) <= 500],
      ['landmark_count', () => landmarks.length <= 500],
      ['generator_version', () => characterCount(spine.generatorVersion) <= 200],
      ['canonical_url', () => spine.canonicalURL == null || isHTTPSURL(spine.canonicalURL)],
      ['episode_guid', () => lengthOK(spine.episodeGUID, 1000)],
      ['duration', () => spine.producingEditionDurationMs == null || spine.producingEditionDurationMs >= 0],
      ['edition_sha256', () => spine.producingEditionSHA256 == null || isSHA256(spine.producingEditionSHA256)],
      ['landmark_ids', () => new Set(landmarks.map((l) => canon(l.id))).size === landmarks.length],
      ['landmark_order', () => landmarks.every((l, i) => l.order === i)],
    ]);
    if (failed) throw mismatch(`episode fingerprint spine is out of bounds: ${failed}`);
    if (item.episodeGUID != null && spine.episodeGUID != null && canon(spine.episodeGUID) !== canon(item.episodeGUID)) {
      throw mismatch('the fingerprint spine names a different episode');
    }
    for (const l of landmarks) {
      const landmarkFailed = firstFailed([
        ['source_range', () => l.sourceMediaStartMs >= 0 && l.sourceMediaEndMs >= l.sourceMediaStartMs],
        ['duration', () => l.sourceMediaEndMs - l.sourceMediaStartMs <= 30_000],
        ['anchor_time', () => l.anchorMediaTimeMs >= 0],
        ['continuity_epoch', () => l.continuityEpoch >= 0],
        ['generator_version', () => characterCount(l.generatorVersion) <= 200],
        ['signature_asset', () => asset(l.signatureAssetId)?.role === ROLE_SIGNATURE],
      ]);
      if (landmarkFailed) throw mismatch(`fingerprint landmark is invalid: ${landmarkFailed}`);
    }
  }
  for (const sketch of decoded.transcript_phrase_sketch) {
    const windows: J[] = sketch.windows;
    const failed = firstFailed([
      ['item_id', () => characterCount(sketch.itemId) >= 1 && characterCount(sketch.itemId) <= 500],
      ['normalization_version', () => characterCount(sketch.normalizationVersion) <= 200],
      ['shingle_width', () => sketch.shingleWidth === 3],
      ['maximum_hashes', () => sketch.maximumHashesPerWindow === 24],
      ['salt', () => base64Length(sketch.saltBase64) === 32],
      ['window_count', () => windows.length <= 10_000],
      ['window_ids', () => new Set(windows.map((w) => canon(w.id))).size === windows.length],
    ]);
    if (failed) throw mismatch(`transcript phrase sketch is out of bounds: ${failed}`);
    for (const w of windows) {
      const windowFailed = firstFailed([
        ['start', () => w.sourceStartMs >= 0],
        ['range', () => w.sourceEndMs >= w.sourceStartMs],
        ['span', () => w.sourceEndMs - w.sourceStartMs <= 30_000],
        ['hash_count', () => w.hashes.length <= sketch.maximumHashesPerWindow],
        ['hash_form', () => w.hashes.every((h: string) => /^[0-9a-f]{32}$/.test(h))],
      ]);
      if (windowFailed) throw mismatch(`transcript phrase sketch window is invalid: ${windowFailed}`);
    }
  }
  if (decoded.conversation.length > 1) throw mismatch('more than one conversation artifact');
  const scoped = new Set(interjections.map((r) => canon(r.packageScopedId)));
  const replyTo = new Map<string, string>();
  for (const conversation of decoded.conversation) {
    const replies: J[] = conversation.replies;
    if (replies.length < 1 || replies.length > LIMITS.margins * 4) throw mismatch('the conversation is empty or too large');
    for (const reply of replies) {
      if (!scoped.has(canon(reply.packageScopedId)) || !isSHA256(reply.parentPackageDigest)
        || reply.conversationId.length < 1 || reply.conversationId.length > 200
        || reply.parentPackageScopedId.length < 1 || reply.parentPackageScopedId.length > 200) {
        throw mismatch('a reply link names no Margin in this packet or is out of bounds');
      }
      replyTo.set(canon(reply.packageScopedId), packetMarginId(reply.parentPackageDigest, reply.parentPackageScopedId));
    }
  }

  // The digest and the preview: anything edited after export is refused.
  const files = new Map(m.artifacts.concat(m.assets as J).map((d: { path: string }) => [d.path, entries.get(d.path) as Uint8Array] as const));
  const preview = entries.get('preview.md');
  if (!preview) throw damaged('the packet has no preview.md');
  const digest = await contentDigest(m, preview, files);
  if (digest !== m.contentDigest) throw damaged('the packet changed after it was exported');
  const expectedPreview = previewMarkdown(m, interjections, {
    proposals: decoded.listening_map_proposal.length,
    spines: decoded.edition_fingerprint_spine.length,
    sketches: decoded.transcript_phrase_sketch.length,
    embeddedText: embedded[0]?.text,
  });
  if (fromUtf8(preview) !== expectedPreview) throw damaged('preview.md does not match the packet');

  // Asset bytes: voice is AAC in MPEG-4 audio, up to 10 minutes; evidence is a Shazam signature.
  const voiceDurations = new Map<string, number>();
  for (const d of m.assets) {
    const data = entries.get(d.path) as Uint8Array;
    if (d.path.startsWith('assets/audio/')) {
      let ms: number;
      try {
        ms = aacDurationMs(demuxAac(data));
      } catch (error) {
        if (error instanceof NotAacError) throw new PacketError('doesNotMatch', `voice asset ${d.path}: ${error.message}`);
        throw error;
      }
      if (ms <= 0) throw mismatch(`voice asset ${d.path} is empty`);
      if (ms > LIMITS.audioMs) throw tooLarge(`voice asset ${d.path} is longer than 10 minutes`);
      voiceDurations.set(canon(d.id), ms);
    } else if (d.role !== ROLE_SIGNATURE || d.mimeType !== SIGNATURE_MIME_TYPE || data.length === 0) {
      throw mismatch(`evidence ${d.path} is not an acoustic signature`);
    }
  }

  // The web model.
  const sender = m.senderDisplayLabel ? m.senderDisplayLabel : undefined;
  const episodeId = options.episodeId ?? `packet:${digest}`;
  const margins: Margin[] = [];
  const textMargins: TextMargin[] = [];
  for (const record of interjections) {
    const representation = record.representations.find((r) => canon(r.id) === canon(record.defaultRepresentationId));
    if (!representation) continue;
    const id = packetMarginId(digest, record.packageScopedId);
    const replyToId = replyTo.get(canon(record.packageScopedId));
    const { anchor } = record;
    let atMs = anchor.mediaTimeMs;
    if (atMs == null && anchor.roughPercent != null && typeof item.durationMs === 'number' && anchor.anchorType !== 'text') {
      atMs = Math.round((anchor.roughPercent * item.durationMs) / 100);
    }
    if (atMs == null || anchor.anchorType === 'text') {
      textMargins.push({
        id, createdAt: record.createdAt, text: representation.approvedTranscript,
        ...(anchor.exactText != null && { quote: anchor.exactText }),
        ...(anchor.prefix != null && { prefix: anchor.prefix }),
        ...(anchor.suffix != null && { suffix: anchor.suffix }),
        ...(sender && { author: sender }),
        ...(replyToId && { replyToId }),
      });
      continue;
    }
    const margin: Margin = { id, episodeId, atSeconds: atMs / 1000, createdAt: record.createdAt, text: representation.approvedTranscript };
    const voiceAsset = AUDIO_REPRESENTATIONS.has(representation.kind) ? asset(representation.assetId) : undefined;
    if (voiceAsset) {
      const data = entries.get(voiceAsset.path) as Uint8Array;
      margin.voice = {
        blob: new Blob([data], { type: 'audio/mp4' }),
        mimeType: 'audio/mp4',
        durationSeconds: (voiceDurations.get(canon(voiceAsset.id)) ?? voiceAsset.durationMs ?? 0) / 1000,
      };
    }
    if (sender) margin.author = sender;
    if (replyToId) margin.replyToId = replyToId;
    margins.push(margin);
  }
  margins.sort((a, b) => a.atSeconds - b.atSeconds);

  const episode: PacketEpisode = {
    itemType: item.itemType,
    title: item.title,
    ...(item.episodeGUID != null && { guid: item.episodeGUID }),
    ...(item.canonicalURL != null && { pageUrl: item.canonicalURL }),
    ...(item.enclosureURL != null && { audioUrl: item.enclosureURL, audioOrigin: 'podcast-enclosure' as const }),
    ...(typeof item.durationMs === 'number' && { durationSeconds: item.durationMs / 1000 }),
    ...(item.publishedAt != null && { publishedAt: item.publishedAt }),
    ...(item.showTitle != null && { showTitle: item.showTitle }),
    ...(item.publisher != null && { publisher: item.publisher }),
  };
  return { packageId: m.packageId, contentDigest: digest, createdAt: m.createdAt, ...(sender && { sender }), item, episode, margins, textMargins };
}
