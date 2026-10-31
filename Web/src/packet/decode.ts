// What Swift's synthesized Codable decoder needs from each JSON document in a packet: required keys present, with
// their types and enum values. A port of `decode_problem` and its SWIFT_TYPES table in
// `Contracts/tools/spoken_margins_format.py`, which `scripts/validate-contracts.py` keeps in step with the Swift
// structs. Keys a type doesn't list are ignored here; the closed documents refuse them elsewhere.

import { isSwiftDate } from './swift.ts';

const T = (fields: Record<string, string>): Record<string, string> => fields;

const SWIFT_TYPES: Record<string, Record<string, string>> = {
  SpokenMarginsPackageManifest: T({
    schemaVersion: 'String', packageId: 'String', createdAt: 'Date', contentDigest: 'String?', item: 'SharedItemIdentity',
    itemTransport: 'SharedItemTransport', senderDisplayLabel: 'String?', suggestedRevealMode: 'ImportedCommentaryRevealMode?',
    requiredCapabilities: '[String]', artifacts: '[SpokenMarginsArtifactDescriptor]', assets: '[SpokenMarginsAssetDescriptor]',
    redactions: 'InterjectionPackageRedactions',
  }),
  SharedItemIdentity: T({
    itemType: 'SharedItemType', canonicalURL: 'String?', originalURL: 'String?', title: 'String', author: 'String?',
    publisher: 'String?', showTitle: 'String?', episodeGUID: 'String?', enclosureURL: 'String?', publishedAt: 'String?',
    durationMs: 'Int?', normalizedContentSHA256: 'String?', exactEditionSHA256: 'String?', languageCode: 'String?',
    source: 'SharedSourceIdentity?',
  }),
  SharedSourceIdentity: T({ sourceType: 'SourceType', canonicalURL: 'String', title: 'String?', publisher: 'String?' }),
  SharedItemTransport: T({ kind: 'SharedItemTransportKind', embeddedArtifactId: 'String?', rightsBasis: 'SharedItemRightsBasis?' }),
  InterjectionPackageRedactions: T({
    rawAudioOmitted: 'Bool', rawTranscriptOmitted: 'Bool', fullItemOmitted: 'Bool', itemAudioOmitted: 'Bool',
    diagnosticsOmitted: 'Bool', filesystemPathsOmitted: 'Bool', unrelatedTurnsOmitted: 'Bool',
    privateRepresentationsOmitted: 'Bool',
  }),
  SpokenMarginsArtifactDescriptor: T({
    id: 'String', kind: 'String', schemaVersion: 'String', path: 'String', required: 'Bool', byteCount: 'Int?', sha256: 'String?',
  }),
  SpokenMarginsAssetDescriptor: T({
    id: 'String', role: 'String', path: 'String', mimeType: 'String', durationMs: 'Int?', anchorOffsetMs: 'Int?',
    provenance: 'String', byteCount: 'Int?', sha256: 'String?',
  }),
  SharedCommentaryLayerArtifact: T({ id: 'String', schemaVersion: 'String', interjections: '[SharedInterjectionPackageRecord]' }),
  SharedInterjectionPackageRecord: T({
    packageScopedId: 'String', createdAt: 'Date', anchor: 'PortableAnchorEvidence', defaultRepresentationId: 'String',
    representations: '[SharedInterjectionRepresentation]',
  }),
  SharedInterjectionRepresentation: T({
    id: 'String', kind: 'SharedInterjectionRepresentationKind', approvedTranscript: 'String', assetId: 'String?',
    provenance: 'SharedInterjectionProvenance',
  }),
  PortableAnchorEvidence: T({
    anchorType: 'AnchorType', startChar: 'Int?', endChar: 'Int?', exactText: 'String?', prefix: 'String?', suffix: 'String?',
    mediaTimeMs: 'Int?', roughPercent: 'Int?', transcriptSegmentId: 'String?', chapterTitle: 'String?',
    machineEvidenceAssetIds: '[String]',
  }),
  PortableListeningMapProposalArtifact: T({
    id: 'String', schemaVersion: 'String', languageCode: 'String?', createdAt: 'Date', generator: 'String',
    scenes: '[PortableListeningMapScene]',
  }),
  PortableListeningMapScene: T({
    id: 'String', order: 'Int', title: 'String?', summaryText: 'String?', summaryAssetId: 'String?',
    summaryProvenance: 'PortableSummaryProvenance?', eligibility: 'PortableSceneEligibility', eligibilityReason: 'String?',
    startAnchor: 'PortableAnchorEvidence', endAnchor: 'PortableAnchorEvidence',
  }),
  EditionFingerprintSpineArtifact: T({
    id: 'String', schemaVersion: 'String', itemId: 'String', canonicalURL: 'String?', episodeGUID: 'String?',
    producingEditionDurationMs: 'Int?', producingEditionSHA256: 'String?', createdAt: 'Date', generatorVersion: 'String',
    landmarks: '[EpisodeFingerprintLandmark]',
  }),
  EpisodeFingerprintLandmark: T({
    id: 'String', order: 'Int', sourceMediaStartMs: 'Int', sourceMediaEndMs: 'Int', anchorMediaTimeMs: 'Int',
    continuityEpoch: 'Int', trigger: 'EpisodeFingerprintTrigger', provenance: 'EpisodeFingerprintProvenance',
    signatureAssetId: 'String', transcriptSketchWindowId: 'String?', generatorVersion: 'String',
  }),
  TranscriptPhraseSketchArtifact: T({
    id: 'String', schemaVersion: 'String', itemId: 'String', languageCode: 'String?', saltBase64: 'String',
    normalizationVersion: 'String', shingleWidth: 'Int', maximumHashesPerWindow: 'Int', createdAt: 'Date',
    windows: '[TranscriptPhraseSketchWindow]',
  }),
  TranscriptPhraseSketchWindow: T({ id: 'String', sourceStartMs: 'Int', sourceEndMs: 'Int', hashes: '[String]' }),
  MarginConversationArtifact: T({ id: 'String', schemaVersion: 'String', replies: '[Reply]' }),
  'MarginConversationArtifact.Reply': T({
    packageScopedId: 'String', conversationId: 'String', parentPackageDigest: 'String', parentPackageScopedId: 'String',
  }),
  EmbeddedTextItemArtifact: T({ id: 'String', schemaVersion: 'String', originalMediaType: 'String', text: 'String' }),
};

const set = (...values: string[]): ReadonlySet<string> => new Set(values);

const SWIFT_ENUMS: Record<string, ReadonlySet<string>> = {
  SharedItemType: set('text', 'podcast', 'pdf', 'epub', 'other'),
  'SharedSourceIdentity.SourceType': set('podcast_feed', 'text_feed', 'newsletter', 'blog', 'social_feed', 'other'),
  SharedItemTransportKind: set('reference', 'embedded_text', 'recipient_supplied'),
  SharedItemRightsBasis: set('app_authored', 'sender_confirmed_private_rights'),
  ImportedCommentaryRevealMode: set('fresh', 'companion', 'guided'),
  AnchorType: set('text', 'transcript', 'media', 'turn'),
  SharedInterjectionRepresentationKind: set(
    'text_only', 'summary_text', 'original_audio_and_text', 'cleaned_audio_and_text', 'summary_audio_and_text',
    'tts_audio_and_text',
  ),
  SharedInterjectionProvenance: set(
    'sender_approved_original', 'deterministic_cleanup_v1_sender_approved', 'sender_approved_text_only',
    'sender_approved_summary', 'sender_approved_tts',
  ),
  PortableSceneEligibility: set('eligible', 'excluded', 'unknown'),
  PortableSummaryProvenance: set('publisher_supplied', 'sender_authored', 'deterministic', 'model_generated'),
  EpisodeFingerprintTrigger: set(
    'initial_playback', 'periodic_playback', 'pre_interjection', 'post_interjection_resume', 'stable_post_seek',
    'downloaded_preparation',
  ),
  EpisodeFingerprintProvenance: set('observed_decoded_playback', 'source_window_reference', 'downloaded_source_reference'),
};

export const KIND_SWIFT_TYPE: Record<string, string> = {
  commentary_layer: 'SharedCommentaryLayerArtifact',
  listening_map_proposal: 'PortableListeningMapProposalArtifact',
  edition_fingerprint_spine: 'EditionFingerprintSpineArtifact',
  transcript_phrase_sketch: 'TranscriptPhraseSketchArtifact',
  embedded_text_item: 'EmbeddedTextItemArtifact',
  conversation: 'MarginConversationArtifact',
};

function swiftType(name: string, owner: string | undefined): string {
  for (const candidate of [owner ? `${owner}.${name}` : undefined, name]) {
    if (candidate && (candidate in SWIFT_TYPES || candidate in SWIFT_ENUMS)) return candidate;
  }
  return name;
}

const isInt = (value: unknown): boolean => typeof value === 'number' && Number.isSafeInteger(value);

/** Why Swift would refuse `value` as `type`, or undefined when it decodes. */
export function decodeProblem(value: unknown, type: string, owner?: string, path = ''): string | undefined {
  const optional = type.endsWith('?');
  const base = optional ? type.slice(0, -1) : type;
  const name = path || 'the document';
  if (value === null || value === undefined) return optional ? undefined : `${name} is absent`;
  if (base.startsWith('[')) {
    if (!Array.isArray(value)) return `${name} is not a list`;
    for (let i = 0; i < value.length; i += 1) {
      const problem = decodeProblem(value[i], base.slice(1, -1), owner, `${path}[${i}]`);
      if (problem) return problem;
    }
    return undefined;
  }
  if (base === 'String') return typeof value === 'string' ? undefined : `${name} is not text`;
  if (base === 'Int') return isInt(value) ? undefined : `${name} is not an integer`;
  if (base === 'Bool') return typeof value === 'boolean' ? undefined : `${name} is not true or false`;
  if (base === 'Date') return isSwiftDate(value) ? undefined : `${name} is not an ISO-8601 date and time with a zone`;
  const key = swiftType(base, owner);
  const values = SWIFT_ENUMS[key];
  if (values) return typeof value === 'string' && values.has(value) ? undefined : `${name} is ${JSON.stringify(value)}, which is not known`;
  if (typeof value !== 'object' || Array.isArray(value)) return `${name} is not an object`;
  const fields = SWIFT_TYPES[key];
  if (!fields) return `${name} has unknown type ${key}`;
  for (const [field, fieldType] of Object.entries(fields)) {
    const problem = decodeProblem((value as Record<string, unknown>)[field], fieldType, key, path ? `${path}.${field}` : field);
    if (problem) return problem;
  }
  return undefined;
}
