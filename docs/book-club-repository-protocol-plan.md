# Book Club Repository Protocol: design review and implementation plan

Status: proposed architecture and agent work plan; not an implemented or published standard.

Date: 2026-09-23. Working name: **Open Margin Repository (OMR)**, draft 0.1.

Repository examined: `codex/co-op`, HEAD `34837c6055471297ca0b360c591f734bad5c2c82`, plus the existing working tree.

Scope of this deliverable: planning only. No branch, runtime, schema, account, server deployment, commit, merge, or distribution is authorized by this document.

## 1. Decision and constraints

Adopt the proposal's central idea: a club is a portable repository of signed contributions and referenced content. Files, nearby peers, self-hosted remotes, and the first-party remote exchange the same objects. A functioning club must not require a Spoken Margins account or a reachable server.

Do **not** implement the proposal literally. Its history-parent interpretation overstates what can be inferred about a person's attention; its example `createdIn` back-reference can create a content-hash cycle; an object union alone does not resolve edits or membership; and signatures do not provide confidentiality. Address these before adding transports.

The recommended first release has an append-only content DAG, explicit immutable revisions, private per-revision review state, portable selectors, conservative local projections, encrypted file bundles, and one small HTTPS relay API used by both server offerings. Nearby interactive exchange follows the file engine. No general collaborative editor, public federation, blockchain, global account identity, mandatory AI, or global source catalog is necessary.

### Challenge model

| Layer | Required model and constraint | Consequence |
| --- | --- | --- |
| Actors | Authors, readers, club controller, recipient devices, untrusted carriers, optional relay operator | A device key, club authority, human label, and hosting account are different identities |
| Resources | Phone storage, battery, bounded RAM, bandwidth, user attention; server object storage and egress | Stream blobs, paginate metadata, fetch media selectively, avoid polling every object or re-reviewing duplicate content |
| Execution | Offline creation, arbitrarily reordered files, intermittently online devices, independently operated relays | Eventual convergence for the same accepted object set; no global clock or online sequencer for contributions |
| Content | Margins, revisions, replies, source identities, anchors, maps, scenes, descriptions, summaries, media | Typed immutable objects; separate conversation, source location, revision, and replication relationships |
| Trust | Malicious relay, replay, forged labels, revoked device, malicious member, corrupt archives | Verify before activation; authenticate authors; encrypt content; bound processing; expose incomplete history |
| Product | Existing reviewed sharing, original capture anchors, uncertain source placement, private Library | Publishing is explicit. Import never authorizes source acquisition, autoplay, original-voice forwarding, or map activation |
| Evidence | Repo code, schema fixtures, interoperability vectors, fault tests, device tests, owner acceptance | A build is not protocol interoperability, and automated evidence is not `human_validated` |

Assumptions to measure: initial clubs have at most 64 members / 128 devices, 100,000 metadata objects, and 10 GiB of media; many independent clubs matter more than a single million-member club. These are **proposed tested profile limits**, not observed workloads or promises. A club can contain multiple works and reading periods; an app session is not a club repository. Initial deployment is private, invitation-only, with one portable controller key. The controller governs membership, not contribution order or content custody.

Decision criteria, in order: preserve private content and source-location correctness; converge across carriers; make exact authored revisions auditable; support recoverable offline operation; keep independent implementations small; meet measured storage/latency targets. Reject an optimization that changes these semantics.

### Alternatives considered

| Alternative | Good fit | Reason not selected for the core |
| --- | --- | --- |
| Server database with cloud sync | Simple online authorization and administration | Offline files become second-class exports and server loss can destroy repository identity |
| Actual Git repositories and bundles | Mature immutable history and offline prerequisites | Git's file/tree merge, refs and tooling do not supply annotation, disclosure, membership or review semantics; copying its useful primitives is smaller than exposing Git |
| General CRDT document library | Simultaneous character-level editing | Unnecessary for immutable voice/text revisions; author ownership and conflict policy still need explicit rules. Revisit only for a genuinely shared editor |
| IPFS as mandatory substrate | Content retrieval and addressing | Availability, access control, private discovery and mobile operation remain separate problems; optional future adapter only |
| MLS-based live group | Standard group security with stronger evolving-key guarantees | Valuable future security profile, but membership epochs and concurrent/offline transitions still need application handling; not a drop-in object-store protocol [S6] |
| Signed, immutable object store + adapters | Offline exchange, incremental transfer, deterministic import | Selected; requires explicit membership, encrypted storage and conflict rules below |

Git's full/incremental bundles and prerequisite verification are precedents for the transfer model, not evidence that OMR's rules are already standardized. OMR intentionally permits bounded quarantine of incomplete transfers, unlike treating prerequisites as satisfied. [S1]

## 2. Repository evidence and integration boundaries

Paths below are relative to the repository root. Findings describe inspected code, not a fresh test run.

| Existing surface | What exists | Reuse / gap |
| --- | --- | --- |
| `Packages/SessionKit/Sources/SessionKit/MarginConversation.swift` | Stable contribution/revision references; exact-parent replies; union rejecting conflicting revisions/cycles; missing ancestors allowed | Bridge identities; preserve reply semantics. Installation author IDs and labels are not cryptographic principals |
| `Packages/SessionKit/Sources/SessionKit/SharingModels.swift` | `SharedItemIdentity`, `PortableAnchorEvidence`, imported layers, representation provenance; `PortableListeningMapProposalArtifact` v2 and scene summaries | Reuse semantic mappings, not Swift serialization as an open wire contract; add first-class descriptions and independently addressable scene revisions |
| `Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift` | `.spokenmargins`, SHA-256 content integrity, capability gates, ZIP validation | Existing archives are unsigned. Current bounds: 100 MiB package, 1 MiB manifest, 5 MiB artifact, 20 MiB audio, 50 Margins, 100:1 compression ratio. Do not silently relax them |
| `Packages/SessionKit/Sources/SessionKitSharing/SharingFoundation.swift` | Reviewed package builder/importer; portable derivative assets | Preserve representation selection, evidence opt-outs, and exact-byte preview |
| `Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift` | Atomic imported-layer writes and immutable `conversation_snapshot` records | Add indexed repository tables/object store; do not scale by repeatedly loading every snapshot |
| `Packages/SessionKit/Sources/SessionKit/EpisodeMapModels.swift` | Fingerprint spines, phrase sketches, local `ResolvedListeningMapProjection`, scene drafts | Share proposals/evidence by consent; recipient projections stay local |
| `Packages/SessionKit/Sources/SessionKit/ListeningEdition.swift` | Source text, overview, scenes with title/description/summary/block bounds | Import as typed repository objects without automatically exporting the full `text` |
| `Packages/SessionKit/Sources/SessionKit/CanonicalSourceModels.swift` | Canonical source/navigation structure and local offsets | Explicit edition identity and offset conversion boundary |
| `Packages/SessionKit/Sources/SessionKitSharing/PortableArticleAnchorResolver.swift` | Exact text digest and quoted/contextual matching | Existing offsets are Swift `Character` distances; an open scalar-offset profile needs conversion, never relabeling |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23SharingSeams.swift`, `Build23SenderSharingExperience.swift`, `Build23RecipientSharingExperience.swift` | Sender/recipient workflow seams | Extend reviewed item sharing; keep ordinary direct sharing usable |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ConversationNavigation.swift`, `ConversationContextEditor.swift` | Conversation navigation and optional listening hints | Keep hints separate from original capture anchors and resolved positions |
| `Contracts/schemas/`, `Contracts/fixtures/`, `scripts/validate-contracts.py` | Executable contracts and fixture validation | New wire contract lives here with negative fixtures and independent vectors; root `schemas/` is not the validator's primary input |
| `docs/co-op-listening.md`, `docs/build-25-private-episode-maps.md`, `docs/pkm-workflows.md` | Current product behavior and map/intake constraints | Explicitly preserve uncertain placements, no autoplay, second-tap behavior and private source ownership |

No deployable club backend was identified in the inspected tree. Server architecture below is proposed new work, not integration with an existing service.

The current lane explicitly defers accounts/server delivery. `docs/external-testflight-sharing-decision.md` records the September 12 acceptance of bounded **direct** sharing; old lane text about unresolved #14 must not be mistaken for revoking that acceptance. Hosted redistribution and club policy remain an extension. Before runtime work, update `docs/release-lanes.md` through an explicit owner implementation decision; do not invent a branch or issue number. This planning request does not change the lane.

Existing dirty files include Shortcut/intake, app model/UI, Listening Edition, audio adapters, tests, and product/lane documentation. They were left untouched. Re-read status and these integration seams at implementation start; HEAD alone does not identify the entire inspected tree. The September 22 simulator incident restrictions remain binding.

## 3. Review of the supplied proposal

| Proposed idea | Decision / correction |
| --- | --- |
| Every contribution is a commit | Use signed **events** batching immutable revisions; no user-facing Git requirement |
| Parents are what the author reviewed | Parents establish causal availability/dependency, never attention. Explicit review claims are separate |
| A reviewed frontier subtracts all ancestors | Valid only for explicitly downward-closed sets. A person can hear a reply without hearing its ancestors; use exact revision review sets plus optional proven compression |
| A later contribution means earlier ones can be skipped | False unless the author explicitly supersedes particular revisions. B2 must not silently remove B1 |
| Downloaded heads mean caught up | False for partial metadata, missing media, unsupported types, and withheld remote history. Track these separately |
| `margin.createdIn = hash(commit)` | Omit: event → revision is sufficient. Revision → containing event would create a hash cycle if the event hashes that revision |
| Content-address everything | Yes; distinguish stable logical identity, immutable revision digest, raw blob digest and encrypted-envelope digest |
| One immutable union solves merging | It solves receipt, not preferred map, sibling edits, membership, moderation or deletion. Define reducers |
| Signature identifies Mary | It proves possession of a key. Mary is an invite/pairing association; display labels remain editable claims |
| All servers are interchangeable | Yes for repository semantics and export. Billing, retention, account login and availability are service policies |
| Catch-up acknowledgements are automatic | Default private. Share explicit revision claims only with opt-in; never infer comprehension or advertise exact group-wide lag |
| Source selectors work across editions | They are evidence for local resolution, not guaranteed identity or position. Preserve ambiguous/absent states |

## 4. Contract boundaries and conformance profiles

Separate four contracts and three product concerns:

1. **Repository core:** typed objects, bytes/IDs/signatures, authorization, revisions and deterministic projection.
2. **Bundle:** finite inventories and prerequisites, streaming import, exact disclosure, partial/full closure.
3. **Relay:** authenticated opaque byte storage, durable publication discovery, resumable transfer. No source matching.
4. **Private-club security:** key grants, epoch transitions, encryption and offline trust rules.
5. **Local app projection:** matching to local sources, playback, selection, unread/review state, storage budget.
6. **Hosted service operations:** tenancy, quotas, login, abuse response, backup and availability.
7. **Specification governance:** versioning, extension registry, interoperability and licensing.

Proposed profiles: `core-1`, `bundle-1`, `private-club-1`, `relay-1`, and optional `nearby-1`. These names are draft identifiers, not current runtime capabilities. A private club client must implement the first three; a self-hosted or official relay implements `relay-1` and control authorization. Nearby discovery never changes object semantics.

Core can be tested with cleartext fixtures. Product file exports and relays for private clubs require the encryption profile; do not ship a temporary plaintext cloud path. Signing/canonicalization, schemas, validator, runtime and tests must land together when a profile becomes executable.

## 5. Typed data model

### 5.1 IDs and relationship rules

- `repoId`: digest of a signed genesis object. Genesis omits `repoId` to avoid self-reference and includes a random 256-bit nonce, initial controller public key, fixed core/security profile IDs, and limits. It has no private club title.
- `principalId`: `ed25519:` plus unpadded base64url of the 32-byte public key. Use separate signing and HPKE encryption keys; never reinterpret one key's bytes as the other kind.
- `entityId`: immutable tuple `(repoId, creatorPrincipalId, random UUIDv4)`. Identifies one Margin, scene, map, or document across edits. Labels and local database IDs are not identities.
- `oid`: `sha256:` plus 64 lowercase hexadecimal digits, identifying exact canonical structured bytes or blob bytes with domain separation below.
- `revisionId`: the OID of a typed entity-revision object. All replies and summary targets pin a revision, not only an entity.
- `envelopeId`: a separate digest of encrypted transport bytes. Never substitute it for an OID in a semantic reference.

Five independent edges: `parents` (event causal history), `revises` (same-entity predecessors), `replyTo` (conversation), `target` (source/scene/summary anchor), and `reviewed` (explicit attention claim). `dependencies` classify required interpretation objects versus optional evidence/media. No single edge serves all five purposes.

An entity's first revision establishes its creator. Only that creator's certified device keys may revise it; moderators hide content through separate moderation records. Another member edits a map by creating a new map with `derivedFrom`, not by impersonating its author. Device certificates map signing keys to a member root; entity creator is the member root in that case. Plain device IDs alone cannot claim shared authorship.

### 5.2 Structured object inventory

Every structured payload has `v`, `type`, and `requiredFeatures`. Except genesis, it has `repoId`. Unknown optional extension fields are allowed only inside `extensions`, keyed by an absolute namespace URI; unknown required features block semantic application of that object. A reader must preserve original canonical bytes, including unknown extensions.

| Type | Required semantic fields | Projection rule |
| --- | --- | --- |
| `genesis` | nonce, controller key, profiles, limits | Defines repository identity and initial trust; verify root fingerprint out of band |
| `control` | previous control OID, sequence, roster/device certificates, epoch, key-grant references, policy, accepted-old-event frontier | Single signed membership chain; see §8 |
| `device-certificate` | member root, device signing key, HPKE key, random certificate ID | Member-root-signed binding; usable only after controller roster admission |
| `source` | entity ID, `revises`, work identifiers, edition descriptors, title/attribution if known | URL/GUID/ISBN are claims with schemes, not proofs of interchangeable bytes |
| `anchor` | source revision, coordinate space, selector alternatives, evidence refs | Immutable sender evidence; never recipient seek result |
| `document-revision` | entity ID, `revises`, title, optional description and summary refs, source refs | Club/work/reading-period description; controller-owned club metadata versus member-owned documents |
| `margin-revision` | entity ID, `revises`, capture anchor, optional current target, optional exact `replyTo`, body representations, provenance | Preserve capture anchor through reply/context edits; expose conflicting siblings |
| `text-revision` | entity ID, `revises`, role, UTF-8 text, language, provenance, target refs | Roles `description`, `summary`, `transcript`, `note`; source text is a different, consent-gated resource |
| `scene-revision` | entity ID, `revises`, source ref, start/end anchor refs, title, description/summary refs, provenance, eligibility | Scene is independent of map, so maps can point to it without a hash cycle |
| `map-revision` | entity ID, `revises`, source refs, ordered scene-revision refs, optional description/summary refs, `derivedFrom` | Ordered proposal, never an automatic replacement of the recipient's map |
| `blob-descriptor` | raw blob OID or chunk list, media type, byte count, role, duration if audio, representation provenance | Facts checked against decoded media where practical; MIME text is not trusted |
| `event` | author/device certificate, control OID, parents, introduced revision/object OIDs, optional review-claim OIDs, advisory timestamp | Signed publication context; no embedded mutable refs |
| `review-claim` | author, exact revision IDs, method (`marked`, `read`, `played`), optional completion data, superseded claim IDs | Opt-in self-report. Excludes implicit ancestor comprehension |
| `tombstone` | exact target/entity, author, reason code, optional replacement | Hides under defined authority; does not erase replicas or rewrite existing replies |
| `moderation` | exact targets, controller, action/reason | Separate club visibility policy; cannot alter authorship or cryptographically delete bytes |
| `legacy-import` | original package digest, legacy reference, importer principal, mapped object refs, original unverified label | Importer attests the import only; legacy author remains unverified |

Descriptions explain what an item/scene contains; summaries condense its content. Keep separate fields/objects and provenance. A summary or description can itself receive a Margin: the target pins its exact `text-revision` and text selector. A Margin on a scene pins `scene-revision` and may also retain a source anchor. Editing the scene or summary must not move an existing Margin to new prose or a new source interval.

Media roles distinguish original user voice, cleaned derivative, transcript, and synthetic voice. Source audio, rendered source-summary audio and full podcast transcripts remain excluded by the current product boundary. A future openly specified capability can carry lawfully supplied assets, but defining it does not enable that product mode. Summary text is in scope now; summary audio is not silently enabled because a legacy model has `summaryAssetId`.

### 5.3 Revision and conflict reducer

For each entity, validate ownership and the acyclic `revises` graph. An edit references all revisions it intentionally resolves. Maximal revisions under `revises` are current candidates. One maximal revision means a single current candidate; multiple mean a visible conflict, even if timestamps differ. An explicit resolving edit can reference all siblings. Never select a destructive winner by arrival order, server sequence, highest device clock, or lexical hash.

A deterministic lexical OID tie-breaker is allowed for **display ordering only**, with conflict state retained. The recipient's preferred map, enabled layers, muted members and manually confirmed positions are local preferences. Optional controller map recommendations are separate signed records, not rewrites of map ownership. Deletion is terminal for the targeted entity in v1; restoring content creates a new entity with `derivedFrom`. Concurrent revisions remain retained beneath the hidden entity.

## 6. Canonical bytes and authentication

Use SHA-256 and Ed25519 initially: the repo already uses SHA-256; mandatory alternative hashes add interoperability cost without an established need. Prefixes reserve future algorithm agility, but a v1 verifier must reject unsupported algorithms rather than negotiate down. Ed25519 has published test vectors; use maintained implementations, not agent-authored curve arithmetic. [S3]

Structured bytes are RFC 8785 JCS UTF-8. Reject duplicate JSON keys before decoding, invalid Unicode, non-finite values, and integers outside `[-(2^53-1), 2^53-1]`. Use nonnegative integer milliseconds/offsets; no floating confidence scores on the core wire (optional evidence uses integer millionths). Do not normalize user text or Unicode before hashing. Sort set-valued reference arrays lexically and reject duplicates; preserve ordered scene/chunk arrays. `JSONEncoder.sortedKeys` is not proof of JCS compliance. [S2]

Define domain separation exactly in conformance fixtures:

```text
payloadBytes = JCS(payload)
message      = UTF8("OMR1-SIGN\n") || payloadBytes
signature    = Ed25519.sign(signingKey, message)
record       = { "payload": payload, "signer": principalId,
                 "signature": base64url(signature) }
recordBytes  = JCS(record)
signedOID    = "sha256:" || hex(SHA256(UTF8("OMR1-SIGNED\n") || recordBytes))
objectOID    = "sha256:" || hex(SHA256(UTF8("OMR1-OBJECT\n") || JCS(object)))
blobOID      = "sha256:" || hex(SHA256(UTF8("OMR1-BLOB\n") || rawBytes))
```

The signed payload MUST contain `author` equal to `signer` (genesis uses its controller as author), so signer identity is bound by the signature. Sign genesis, control, device certificates, events, review claims, tombstones and moderation records. Entity revisions/anchors/descriptors are immutable objects authenticated through a signed event's complete required-object closure. Objects stored without that proof are staged, not authenticated contributions. An event cannot publish someone else's new revision as that author's work: validate creator/device authorization at its control reference. Forwarding an already authenticated revision preserves its original event/proof.

All non-genesis signatures bind `repoId`, `type`, and version through the payload. Replaying another club's valid object cannot create an accepted contribution. A raw audio blob can deduplicate locally, but its descriptor and authorized publication bind it to context. No object embeds its own OID, containing event's OID, or a mutable storage path. The required-object graph must be acyclic too: a scene may reference its summary, but that summary must target pre-existing source anchors, not the scene revision that contains it. Derive the inverse “summary of scene” relationship from the scene reference. Apply the same rule to map descriptions and source metadata. Exact references to older revisions are permitted; reject newly introduced mutual-reference cycles.

Illustrative payload shape (placeholders are not conformance vectors):

```json
{
  "v": 1,
  "type": "event",
  "repoId": "sha256:<genesis>",
  "author": "ed25519:<device-key>",
  "control": "sha256:<control>",
  "deviceCertificate": "sha256:<certificate>",
  "parents": ["sha256:<known-event>"],
  "introduces": ["sha256:<margin-revision>"],
  "reviewClaims": [],
  "requiredFeatures": [],
  "extensions": {}
}
```

The first implementation packet must turn every type into machine-readable schema and real known-answer bytes/hashes/signatures, including empty arrays, omission versus null, Unicode, duplicate keys and extension preservation. This document is not a substitute for those vectors.

## 7. Source identity, maps and local anchor resolution

Distinguish **work** (a publication/conversation item), **edition** (specific text/audio representation), **selector** (sender location evidence) and **projection** (recipient-local result). A matching title never proves work identity; a matching feed GUID never proves a dynamic-ad episode's timing. Keep identifier authority and extraction/canonicalization algorithm versions.

### Portable selector profile

| Source | Required coordinate declaration | Recovery / limitations |
| --- | --- | --- |
| Native text/article/PDF extraction | Exact UTF-8 text digest, extraction profile, scalar-offset interval `[start,end)` where available | Quote plus prefix/suffix; use offsets only after exact-edition verification. PDF extraction/OCR differences remain uncertain |
| EPUB | Publication identifiers, edition digest, resource href; optional standardized locator plus quote | Locator is edition-specific; no promise of stability across repackaging. Full EPUB redistribution stays separate [S9] |
| Podcast/audiobook | Media-edition digest if available, integer time interval in milliseconds, source identifiers | Independent transcript/acoustic evidence and conservative piecewise local alignment; timestamp alone is a proposal |
| Scene/map | Exact scene or map revision and explicit target kind | Resolve its underlying source anchors; selection of a map is recipient-local |
| Summary/description | Exact text revision plus scalar-offset/quote selector | Never convert summary percentage to source percentage |

W3C TextQuoteSelector and TextPositionSelector inform the text profile; temporal selectors can map to Media Fragments. Exporting an annotation representation is an adapter, not a claim that the entire repository is W3C Web Annotation. Define selector combination as alternatives locating the **same** target, not a union of unrelated passages. No remote JSON-LD context fetching is needed to interpret core objects. [S4, S10]

New open-wire offsets count Unicode scalar values. Existing Swift `Character` offsets count extended grapheme clusters. Convert against exact source bytes with a persisted mapping at the boundary. Test emoji families, combining marks, flags, CRLF, non-BMP characters and repeated quotes. If exact text is absent, omit converted positions and retain a namespaced legacy selector/quote; do not guess. Hashing and selector extraction are different operations.

Preserve current outgoing quote limits: 1,000 exact / 500 prefix / 500 suffix characters, with the open profile specifying scalar counting and validating UTF-8 byte limits too. New conversion must not increase existing disclosed excerpts without preview. Retain extractor-specific representations rather than claiming one universal PDF normalization.

Local resolution state is `unresolved`, `ambiguous`, `absent`, `verified`, or `user_confirmed`, with algorithm version, evidence IDs and recipient edition digest. Changing recipient media invalidates affected projections. Existing independent acoustic/transcript attempts, safe interpolation bounds and no extrapolated confident positions remain required. Anchor attachments are optional evidence objects: omitting a signature on a later transfer must not create a different authored Margin. Store evidence associations separately from its semantic revision.

A received map is inert until explicitly selected/accepted locally. Preserve alternative maps, source chapters and generated scenes independently. Descriptions/summaries record author/model/deterministic provenance and generator version where known; they cannot execute instructions or trigger AI work. No sender confidence value is an instruction to seek.

## 8. Membership, offline authority and private-club security

### 8.1 Identity and admission

A club has one active controller signing key in v1, portable between devices by explicit secure transfer. This is a deliberate authorization simplification, not server ownership. Member root keys certify device signing and X25519 encryption keys; the controller's roster admits those certificates and roles (`reader`, `contributor`). Only controller control records change membership/policy. An ordinary hosted account cannot forge a membership change.

Join offline: a prospective member creates keys and sends a join request with fingerprints; the controller verifies the human/key association, signs a new roster, and supplies an encrypted key grant plus bootstrap file. A forwarded invitation alone is not admission and contains no reusable bearer epoch key. Online links are expiring rendezvous tokens for that same exchange; the reference relay does not need email or a global social identity. Show and compare repository/controller fingerprint through an independent channel where feasible.

Device loss: another certified member device can request controller admission of a replacement. If the member root is lost, create a new principal and explicit controller-signed continuity label; do not silently claim old signatures. Controller rotation requires the prior controller's signature. If all controller/recovery key material is lost, existing content remains readable/exportable, but authoritative membership changes require an explicitly new repository/fork. Server password reset is not cryptographic key recovery.

### 8.2 Control sequence and revocation

Control records form a strict chain by previous OID and monotonically increasing sequence. A controller must serialize its own changes. Two children of the same control record are an authority fork: quarantine new-branch writes, keep last uncontested state, and expose the fork. Recovery requires an explicit controller-signed reconciliation naming both branches; implement this recovery record in the control schema, not a server-chosen winner. A compromised controller is outside ordinary device-revocation recovery and may require an explicitly trusted repository fork.

No offline protocol can distinguish a backdated malicious post from an honestly delayed one using wall-clock timestamps alone. Therefore each control transition seals previous-epoch content with an **accepted event frontier**: all eligible events reachable from that frontier retain historical acceptance; previously unseen old-epoch events remain quarantined until the controller explicitly admits their exact OIDs in a later signed control record. The controller must display delayed contributions for this decision. Do not silently discard them or relabel them as forged.

This policy trades automatic offline admission during membership changes for reliable revocation semantics. Before a transition is learned, an offline device may show locally accepted old-epoch content; after learning it, rebuild visibility and label unsealed contributions pending admission. This is provisional authorization, not irreversible global finality. Metadata/history can be retained while new publication is blocked.

New epochs rotate encryption keys and relay authorization. Removed members retain anything they already downloaded or decrypted. V1 newly admitted members receive full accepted club history by explicit join disclosure; a future restricted-history profile must not pretend that a delta bundle alone provides cryptographic history isolation. Active members can always leak plaintext; this protocol cannot prevent that.

### 8.3 Proposed encryption profile (security review required before release)

Keep semantic OIDs inside encryption; relays address opaque encrypted envelopes. This prevents a relay from comparing low-entropy plaintext summary hashes across clubs. It does not hide club participation, device public keys, ciphertext lengths, traffic timing, or service accounts. Encryption is not anonymity.

Proposed mandatory suite: Ed25519 signatures; HPKE base mode with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM for device key grants; HKDF-SHA256 plus AES-256-GCM for content envelopes. These are standard primitives [S3, S5, S7, S8], but their composition here is a **new profile requiring independent review**, not an established secure standard.

For each epoch, the controller generates a fresh random 32-byte secret. Grant plaintext binds `(repoId, epoch, recipient device ID, secret)`; HPKE `info` and AAD bind profile, repository, epoch and recipient. The grant is controller-signed and its digest is referenced by the signed control record. Verify this signature before accepting HPKE base-mode output, which alone does not identify a sender.

For each object/chunk, generate a fresh random 32-byte salt; derive a one-use 32-byte key using HKDF with epoch secret as input, that salt, and `info = UTF8("OMR1-ENVELOPE\n") || JCS(header)`. Header contains profile, `repoId`, epoch, salt and plaintext byte length. AES-GCM uses a fixed 12-byte zero nonce **only with this uniquely derived one-use key**; AAD is the canonical header. Persist and resend the exact envelope after a retry; never change plaintext under the same salt/header. Fail on detected salt reuse. The encrypted plaintext binds object kind, semantic OID and exact content bytes. Raw binary chunks use length-delimited framing rather than base64-encoding all audio.

Freeze binary framing, KDF test vectors, nonce/salt rules, limits and domain strings in the security packet before implementing interoperability. Envelopes are identified by SHA-256 over a separate envelope domain plus exact wire bytes. Clients verify envelope hash, AEAD, semantic hash, signature/authorization, and object schema independently. A member with the group key can encrypt garbage but cannot author another member's signed event.

Retain a durable `oid → envelopeId` mapping and reuse envelopes for forwarding/deduplication. Independent encryption of the same plaintext may produce different envelopes; deduplicate after decryption locally, never promise universal ciphertext deduplication. After a removal, no new content is encrypted under the old epoch. Legacy delayed contributions require explicit admission and current-epoch rewrapping for relay publication. No forward secrecy or post-compromise security is claimed for stored epoch keys. If those become requirements, evaluate MLS as a distinct profile rather than advertising them for this one.

Security review must challenge key/nonce uniqueness after restore, cross-protocol replay, grant substitution, roster rollback, malformed ciphertext, rotation with offline writers and compromised devices. If it fails, revise this profile before client/server work depends on it. Do not ship a proprietary crypto fallback or disable encryption to meet a date.

## 9. Causality, review and Catch Up

Maintain these states separately:

- **Known bytes:** received objects, including quarantine. Not necessarily authenticated or interpretable.
- **Accepted metadata frontier:** maximal accepted event heads with complete required semantic closure. No claim that referenced audio is downloaded.
- **Available media:** explicit verified local blobs/chunks; metadata completeness does not imply media completeness.
- **Reviewed revisions:** local per-revision state, with method/progress. Playing one response does not review its ancestors.
- **Published review claims:** opt-in signed subset of exact reviewed revisions. Observers know only the last claim they possess.
- **Publication context:** explicit authored event parents and optionally attached claims. Parents mean causal knowledge, not hearing or agreement.

Default receipts remain local. Disabling public receipts stops new claims; it cannot retract earlier delivered copies. Display “last shared review covers these revisions,” not “Bob is two behind” unless the view explicitly names the local known comparison set. Withheld or unknown history makes exact global freshness impossible.

Catch Up freezes a local snapshot of eligible revisions across accepted heads, respecting item/period selection, muted layers, tombstones and supported types. Let `eligible(S)` be that snapshot and `reviewed` be exact revision IDs. Work set is `eligible(S) − reviewed`, not the ancestors of arbitrary heard tips. Display missing dependencies/media separately. Replies can remain directly listenable with a missing-parent placeholder; do not invent parent content or a source seek.

Order by causal constraints and exact reply dependencies when both are present, then stable OID tie-breaks for concurrent entries. UI can group by author or source location without claiming that grouping is causal time. New imports enter the next snapshot or an explicit “include new arrivals” action. Completing a review transaction updates only the entries actually reviewed. An explicit “mark this snapshot reviewed” can record all its IDs; skipped/muted entries are not automatically reviewed.

Frontier compression is optional and safe only when every relevant revision in its declared closure is reviewed; retain exceptions. Start with indexed exact sets. Review claims and acknowledgements are not eligible discussion content and must not create endless catch-up work. Edits create new reviewable revisions; an unchanged forwarded revision does not. A newer Bob contribution never suppresses his earlier one without a typed supersession/revision relationship.

## 10. Bundles, nearby exchange and import lifecycle

### 10.1 Bundle contract

Introduce a distinct proposed `.omrclub` extension/UTType and draft vendor media type after checking collisions; do not make old `.spokenmargins` readers parse an unrelated repository. Registration/public naming is part of specification release. Legacy import remains supported.

Use ZIP as a carrier with fixed safe paths and streaming entry validation. Semantic identity never depends on ZIP timestamps, entry order or compression. Outer manifest: profile/version, repository ID, mode, part ID, control-record/grant paths, encrypted catalog envelope ID, declared entry IDs/sizes, and required profile features. It exposes no club title or plaintext content hashes. Paths are generated from fixed hex IDs, never supplied arbitrary filenames. The encrypted signed catalog identifies selected heads, logical OIDs, envelope mapping and closure/prerequisite classes.

Modes:

- **Complete:** all accepted metadata required to reconstruct the advertised heads, all selected required media, and enough membership/proof history. No source publication bytes are implied. Missing prerequisites make it invalid as complete.
- **Incremental:** selected new events/objects, explicitly declared prerequisite OIDs and omitted media. Missing prerequisites are nonfatal quarantine, never silently satisfied.
- **Metadata-only:** complete declared metadata scope with intentionally lazy media. Must not be called an offline-complete archive.

A large logical bundle can be multiple independently importable parts, each with its own inventory and prerequisites. Set ID/part count is a convenience, not proof of completion; prove closure from OIDs. Part imports never activate incomplete required object graphs. Export can over-send known objects safely; never infer receiver possession merely because a file was sent yesterday.

Start with 100 MiB per file, 1 MiB manifest/catalog page, 1 MiB structured core object, 4 MiB raw media chunks, 10,000 entries per part, 64 JSON nesting levels, 64 parents per event, and 1,024 introduced objects per event. If more than 64 heads exist, create bounded no-content merge events before publishing. Enforce an aggregate session byte/object budget across parts. These new limits do not change the old archive's limits. Plaintext media descriptors can span chunks; verify whole-media digest after assembly and chunk digests before local use. Compression is store-only for encrypted entries; no gain is expected from compressing ciphertext.

### 10.2 Import state machine

`received → bounded staging → envelope/hash verified → decrypted/schema verified → authenticated → dependency/authority pending OR accepted → local projection`.

Reject path traversal, absolute paths, symlinks, duplicate entry names, undeclared entries, count/size overflow, malformed JSON, mismatched hashes, unsupported required profiles and archive bombs before active state changes. Authentication failure is not “missing history.” Quarantine cannot be unlimited: enforce per-club and global disk quotas, retry budgets and user-visible eviction policy. Evictable staged data must never include unpublished local contributions.

Persist files into a content-addressed store using temporary files, verified lengths/hashes, durable rename and a journal. Then commit indexes, accepted-event state and publication cursor in one SQLite transaction. SQLite atomicity does not cover arbitrary external audio files [S11]; use a recovery journal and crash injection around both boundaries. Restart must discard incomplete staging, repair indexes from committed manifests, and collect unreferenced orphan files only after a grace period.

A corrupt bundle's newly staged entries do not partially activate. Previously accepted objects remain untouched. A valid incomplete bundle can store verified objects with exact missing-OID diagnostics; later arrivals retry affected dependencies through reverse indexes. No full-history rescan per object. A contribution can be accepted with unavailable optional audio and still display a transcript; media-dependent playback requires verified media.

### 10.3 Consent and P2P

Private drafts never enter repository sync automatically. “Publish to club” selects immutable revisions and representations, lists source excerpts/maps/evidence/forwarded bodies, round-trips the exact outgoing bundle/catalog, then publishes those bytes. Later remote synchronization may resend those already authorized objects. New revisions or additional original voice require new review. A complete clone is an explicit club-join/history transfer with review of its scope, not an accidental consequence of “send my two new Margins.”

AirDrop, Files, USB, email and group-chat attachments move files through system interfaces. No integration with a chat provider is needed. Nearby interactive v1 uses explicit pairing with a QR/fingerprint and a foreground local-network session. Discovery carries a random rendezvous value, not club name or member list. Use authenticated TLS/pinned pairing plus the same encrypted objects. Respect local-network denial; provide file fallback. No promise of always-on iOS hosting, background LAN discovery, Bluetooth mesh, NAT traversal, WebRTC relay or Internet-wide DHT.

An authenticated peer exchanges bounded heads/inventories and exact missing OID requests; validate every advertised closure. Bloom filters, if later added, are hints and require exact repair for false positives. Both interactive and file paths call the same repository import/export engine. Nearby capability is optional; arbitrary file transport is the baseline P2P guarantee.

## 11. Relay protocol and first-party implementation

### 11.1 Blind relay design

The relay stores public control/grant metadata, encrypted envelopes, and opaque signed publication announcements. It does not decrypt sources, search summaries, choose a map, resolve an anchor, mark content reviewed or decide a content conflict. The same code/API runs self-hosted and first-party; hosting accounts, billing and push tokens are a separate control plane.

An encrypted publication catalog maps logical OIDs to envelope IDs and advertises heads/prerequisites. A clear announcement binds `repoId`, publication ID, publisher device, control OID, catalog envelope ID and uploaded envelope inventory (paged if necessary), signed by that device. It contains no human title or content OIDs. Server sequencing of announcements is a pagination mechanism, not causal order.

The relay cannot compute semantic DAG closure through encrypted catalogs. **Clients** compute missing logical objects, decrypt catalogs and request ciphertext by envelope ID. This costs metadata enumeration, but avoids a misleading promise that an opaque server can implement plaintext `want/have`. A future encrypted index optimization must preserve this trust boundary.

### 11.2 Required HTTP surface

Draft endpoint root `/omr/v1/repos/{repoId}`; OpenAPI and executable request/response fixtures are required before server implementation. HTTPS required outside authenticated local pairing. HTTP ETags/ranges/conditional requests follow HTTP semantics, not a custom conflicting interpretation. [S12]

| Operation | Contract |
| --- | --- |
| `GET /omr/v1/capabilities` | Supported profiles and bounded limits; no private repo existence disclosure |
| `POST /omr/v1/challenges` and `POST /omr/v1/sessions` | Single-use challenge then device signature over challenge, origin, repo, control and audience; short-lived repo-scoped token. Self-hosted path does not require an official account |
| `GET /controls?after=…` | Paginated public-key/control records and encrypted key grants after repo access check; pinned genesis verification remains client-side |
| `PUT /controls/{oid}` | Controller signature and chain validation; conditional expected prior head; conflict returns 409, never overwrite a branch |
| `HEAD/GET /envelopes/{envelopeId}` | Scoped existence/read; immutable ETag, byte count; single-range resumable GET with `If-Range` |
| `PUT /envelopes/{envelopeId}` | Bounded streaming upload, verify ciphertext hash; identical retry succeeds. A conflicting body cannot replace existing bytes. 4 MiB chunk size bounds upload retry cost |
| `POST /publications` | Signed announcement + exact uploaded inventory; deduplicate by announcement digest; atomically check active device/control and existence of every referenced uploaded envelope before appending durable catalog entry |
| `GET /publications?cursor=…&limit=…` | Stable bounded pages, next cursor and snapshot watermark; includes all accepted announcements, not only latest per-device head |
| `POST /envelopes/availability` | At most 256 encrypted IDs; reports present/missing for this repository only; optional latency optimization, no cross-tenant existence oracle |

Response errors: 400 malformed, 401 authentication, 403 denied, 404 absent/undisclosed, 409 stale control or publication conflict, 413 size/limit, 429 quota/backoff, 503 temporary unavailable. Bodies have stable code, retryable flag, request ID and bounded missing-ID list; no secrets or content text. Document 201 first creation / 200 or 204 identical retry consistently in OpenAPI. Request timeouts, backoff with jitter, cancellation, and token refresh are client responsibilities. Check current control at publication commit even when an old token is still unexpired.

Relay upload privileges require current admission; readers can fetch but not publish. Clients independently validate semantics and signatures even after the relay authorizes an upload. Anonymous genesis creation is disabled on first-party hosting; self-host operators can configure repo provisioning. Provisioning authority does not become the club controller.

### 11.3 Client reconciliation

1. Fetch control chain, verify pin/rotation, obtain available grants. If revoked, preserve readable local data and stop publishing.
2. Page announcements to a frozen watermark; authenticate publishers and store cursors only with durable imported catalog state.
3. Decrypt new catalogs. Union claimed heads as hints, compare semantic OIDs, schedule missing metadata first. Fetch only selected media.
4. Verify and import through the same engine as files. Quarantine incomplete/old-epoch content. Retry advertised missing objects with a bounded budget; show unavailable, not endless loading.
5. Upload already reviewed unpublished objects/envelopes, then publish their announcement last. If control changed meanwhile, refresh and seek explicit admission/review as required; do not silently upgrade authorization.
6. Record relay acknowledgement separately from local publication, remote possession and human review. A relay acknowledgement does not prove every peer received data.

Pagination cursors are opaque and per relay. Expired cursor → bounded rescan/dedup; do not erase local heads. An omitted/replayed page must not cause rollback of accepted local history. A relay can withhold unknown data; clients cannot prove global completeness from one untrusted source. Comparison with another peer/remote detects some omissions. UI says “synced with this remote as of …,” not universally synchronized.

### 11.4 Service shape and operations

Proposed server implementation: a small Go service using a maintained HTTP stack, PostgreSQL for tenancy/control/publication indexes, and private S3-compatible object storage. Self-host edition uses the same service with SQLite and a local filesystem backend, initially single process. Choose/pin concrete supported versions and dependency licenses at implementation time. No dependency on a specific cloud provider enters wire data.

Data indexes: repositories; active control pointers; admitted device keys; scoped hashed tokens; encrypted envelope inventory keyed `(repoId,envelopeId)`; publications with unique announcement digest and monotonic local cursor; staged-upload expiry; quotas; deletion jobs. First-party login maps accounts to provisioning/admin access, never to member private keys. Do not make server IDs appear in semantic objects.

Scale API replicas statelessly; serialize only control updates and per-repo publication sequence transactions. Keep audio out of PostgreSQL; stream upload/download with bounded buffers. Partition/shard by repo when measurements require it. Avoid global cross-club deduplication, which complicates privacy and deletion. Object reads dominate egress; measure this before adding distributed infrastructure. A CDN is optional only with private scoped authorization and equivalent revocation behavior.

Backups must restore both the publication/control database and all referenced ciphertext. Acceptance of a publication occurs after durable object write plus metadata transaction; object-write failure cannot produce a successful announcement. Restore drill checks inventory against blobs and repairs missing objects from peers. Proposed first-party targets: 24-hour backup RPO, 4-hour restore RTO, publication-accepted data survives process/node restart. These are operational targets to test, not inherited cloud guarantees; durability before the backup window needs replicated object/database storage.

Proposed retention: unreferenced staged uploads expire after 7 days; referenced encrypted objects are retained while the repository is active; user-approved hosted repository deletion removes live objects/indexes within 24 hours and ages backups out within 30 days. Legal holds, if applicable, require separately reviewed service policy and truthful disclosure. No promise covers offline recipients or other remotes. Local cache eviction is independent and must protect unpublished contributions and sole known copies. V1 performs no destructive history compaction: signed event/control/proof metadata is retained; media can be evicted only when recoverable or after explicit local deletion, with unavailable state preserved. A tombstone is not a garbage-collection certificate. A future checkpoint format requires independent reconstruction vectors before deleting ancestors. Hosted deletion uses a separate authenticated service-admin job, never an ordinary member event; document its API, authorization and audit record in P09.

No source text, voice, cryptographic keys, raw bearer tokens or full catalog bodies in logs. Metrics: bytes, verification failures, missing dependencies, quarantine reason, sync retries, publication latency, storage/egress, quota rejection. E2EE moderation cannot rely on server reading content: provide membership removal, rate limits, reporting through explicit user-selected disclosure, and repository suspension for service abuse. Suspension removes a hosting endpoint, not a club's local repository.

Migration between remotes: export full accepted closure/control history plus encrypted key grants; upload to a fresh remote; independently verify counts, heads and sampled/all hashes; switch configured endpoints; retain old remote until restore is proven. Multiple remotes are optional; no special official ref is authoritative.

## 12. Persistence and compatibility plan

Proposed new modules under `Packages/SessionKit`: `SessionKitRepository` (pure core reducer/codec), repository persistence adapters, and `SessionKitRepositoryTransport` (files/HTTP). Keep AVFoundation and SwiftUI out of the core. Crypto adapters must be usable by a headless conformance client. Final module boundaries may reuse `SessionKitSharing` where that avoids cycles, but one import engine must own semantic acceptance.

Add indexed tables for repository objects, events/edges, entities/revisions, authorization/control, dependencies, media availability, review state, outbound journal and relay cursors. Scope keys by repository. Store blobs in a private CAS, never local paths on the wire. Incremental indexes make ingest proportional to new edges/bytes; unknown dependency arrivals queue only affected objects. Persist causal/revision indexes so a restart does not traverse all history. A rebuild from signed accepted objects is a required recovery path.

Legacy `.spokenmargins` stays readable and its current capability rejection rules remain intact. A legacy packet maps to a `legacy-import` attestation containing its verified digest, original immutable reference and importer. Keep a durable unique mapping `(repoId, package digest, legacy contribution/revision)`; do not regenerate identities on every re-import. Different packets carrying the same legacy revision deduplicate only after the existing content-equality checks; contradictory bodies quarantine rather than minting trusted replacements. Legacy claims cannot collide with cryptographically authored entities because their namespace is distinct.

Do not automatically sign another person's old work as theirs. An author can explicitly claim/re-publish their own legacy content as a new signed revision with provenance; retain the legacy reference. Existing reply chains continue to pin original versions. Evidence attachments and recording paths must not change content equality. The bridge preserves map proposals, source/summary coordinate spaces and original capture anchors even when they cannot be converted to the new scalar profile.

Migration is additive and transactional. Record a migration version and completion checkpoint, test with copied pre-change libraries, and back up the database before upgrade. Do not rewrite originals or require a clean Library. New private repository storage can be disabled/removed without removing private captures or old imported layers. Downgrade must fail explicitly if a binary cannot interpret new state; never silently discard it.

## 13. Sequential, bounded agent work packets

Single-agent execution is the repository default. These are **handoff-sized tasks**, not standing authorization for parallel agents. Each packet starts from the immediately prior accepted artifact and owns only its listed files/surfaces. No agent should need the full chat.

### Shared packet header (copy into every assigned task)

Read `AGENTS.md`, `docs/release-lanes.md`, this document's named sections, and the previous packet's handoff. Report branch/HEAD, dirty files and active authorization. Preserve unrelated changes. Do not create a branch, commit, deploy, merge, publish a spec, or distribute unless separately authorized. Update schema/validator/runtime/tests together for new executable vocabulary. Stop at a contradicted contract or security boundary; record the smallest concrete decision needed and continue independent authorized work. Do not resolve a protocol conflict by inventing a hidden fallback.

Deliver: changed-path list; exact contract delta; positive/negative fixtures; commands and exit status; limitations; unresolved decisions; and a short `artifacts/validation/club-protocol/<packet>/handoff.md` with candidate SHA plus dirty-diff identity. Use `implemented`/`verified`/`human_validated` accurately. No simulator boot until the existing incident has an evidence-backed repair and owner stop is lifted where applicable.

### P00 — Authorize and freeze scope

**Depends on:** owner implementation decision. **Read:** §§1–4, current lane and sharing policy. **Allowed:** `docs/release-lanes.md`, this plan, `docs/co-op-listening.md`, scoped work-packet/handoff docs. **Forbidden:** runtime, schemas, server resources.

Record assigned existing release lane, issue IDs, profile limits, private-club policy expansion, selected first release and exact merge direction. Resolve stale policy language without erasing historical evidence. Record whether full-history joins and controller admission of delayed old-epoch contributions are accepted. Exit: one unambiguous authorized lane and profile contract. No new tests for prose-only changes.

### P01 — Executable wire specification and independent vectors

**Depends on:** P00. **Read:** §§4–7, 9–10. **Allowed:** new `Contracts/schemas/omr/`, `Contracts/fixtures/omr/`, `docs/specs/omr/`, protocol vector generator; bounded additions to `scripts/validate-contracts.py` and inventory. **Forbidden:** app UI, legacy schema reinterpretation, network/deployment.

Define every object/edge/profile, required versus optional dependency, exact IDs, signature bytes, canonical JSON, limits and error codes. Add W3C selector mapping and Unicode conversion fixtures. Implement a small independent Python reference verifier/vector generator using maintained crypto/JCS libraries; pin dependencies after checking support/licenses. Provide real valid and invalid bytes/signatures, not just schema-valid JSON. Explicitly test unknown required features, hash cycles and wrong-club signatures. Exit: frozen draft fixtures and reference output; no placeholder IDs in executable vectors.

### P02 — Security and control profile

**Depends on:** P01. **Read:** §§6, 8, 11. **Allowed:** crypto/control spec, schemas/fixtures, isolated security adapter/core files and tests. **Forbidden:** UI auto-publish, production hosting, bespoke primitive implementations.

Finalize envelope framing and algorithm IDs; implement canonical signing, grants, key storage interface, roster chain, recovery reconciliation and accepted-old-event rules. Write threat analysis and known-answer tests shared with reference verifier. Inject restore/salt collision, duplicate control sequence, compromised/revoked device, grant substitution, stale token/control, old-epoch arrivals and key loss. Obtain independent security review before freezing `private-club-1`; use explicit qualified review, not a self-declared agent pass. Exit: review findings resolved or a documented blocker; subsequent sensitive transport work cannot bypass it.

### P03 — Repository engine and durable store

**Depends on:** P01–P02. **Read:** §§5–6, 9, 12 and existing conversation/store code. **Allowed:** proposed `SessionKitRepository`, scoped SessionKit domain/protocol additions, repository tables/CAS adapter, package target wiring, core tests. **Forbidden:** source resolver changes, UI redesign, server.

Implement authenticated object ingestion, dependency quarantine, event and revision graphs, ownership/moderation reducer, exact review sets, indexed heads and local rebuild. Keep missing media separate. Journal file/database commit boundaries. Add permutation/idempotence/property tests, cross-club collision tests, same-author sibling edits, forged forwards, crash recovery and low-disk failure. Exit: equivalent accepted projection for all arrival permutations; local unpublished data survives cancellation/restart.

### P04 — Typed content and legacy bridge

**Depends on:** P03. **Read:** §§2, 5, 7, 12; existing map/edition/sharing models and resolver tests. **Allowed:** new bridge files in SessionKit/Sharing, bounded sharing/persistence integration, schema fixtures and focused tests. **Forbidden:** reinterpret old offsets, modify source audio capture, activate imported maps automatically.

Map Margins, exact replies, selected voice/transcript, maps, independent scenes, descriptions, summaries and evidence into OMR. Separate summary/scene targets from capture anchors. Implement scalar↔Swift conversion only with exact text, and legacy provenance/mapping. Preserve old-package acceptance/rejection and source/evidence omission choices. Exit: existing package → bridge → bundle/import → app projection round trip without trust upgrade, duplication or source-coordinate drift.

### P05 — File bundles and reviewed offline club workflow

**Depends on:** P04. **Read:** §§9–10 and existing sender/recipient seams. **Allowed:** bundle adapter, app club create/join/publish/import flow, scoped UTType/project config, archive and app tests. **Forbidden:** official login, hosted service, auto-post of drafts, independent-Margin shortcut bypassing the existing item-share boundary.

Implement complete/delta/metadata-only exports, multipart recovery, encrypted verified preview and system share/import. Provide club history scope, forward-body disclosure, missing-prerequisite request file, no-source Add Source return, direct unresolved playback and item-wide conversation projections. Preserve existing direct quick sharing and second-tap exit. Exit: three-member airplane-mode file round trip, duplicate/reverse arrival, omitted source/voice, exact preview invalidation, old imports and restart all supported by automated evidence plus a prepared owner checklist. Owner acceptance is separate.

### P06 — Catch Up and local map selection

**Depends on:** P05. **Read:** §§5, 7, 9. **Allowed:** pure catch-up query, local review storage, scoped club screen/navigation integration and tests. **Forbidden:** AI ranking, unrequested automatic reels, automatic public receipts or map replacement.

Implement frozen review snapshots, exact revision progress, missing-content state, manual conflict/map selection, explicit optional signed receipts. Explain concurrent history without asserting another user's attention. Existing navigation remains usable for unanchored content. Exit: hearing a reply does not mark ancestors reviewed; B2 does not hide B1; import during playback does not reorder the queue; edited summaries retain old reply targets. Do not add full automatic reel playback without its own product contract and applicable audio checks.

### P07 — Reference relay and HTTP conformance

**Depends on:** P02–P05. **Read:** §11. **Allowed:** proposed `Servers/OMRRelay/`, `docs/specs/omr/relay.openapi.yaml`, isolated relay integration tests/container config, client HTTP adapter. **Forbidden:** production credentials/resources, official-only data formats, content decryption on relay, source acquisition.

Implement one service with local/SQLite and PostgreSQL/S3 adapters, scoped device auth, control CAS, quota enforcement, streaming objects, idempotent announcements, stable pagination and ranges. Use a local disposable test environment. Freeze exact request signatures/token scope and cursor/error semantics. Exit: reference client and Swift client interoperate; two tenants cannot probe/read/write each other; concurrent uploads/retries/control changes are deterministic; process crash after blob-before-publication recovers; missing object never yields successful publication.

### P08 — Nearby peer adapter

**Depends on:** P05, P07's protocol fixtures (not a hosted deployment). **Read:** §10.3. **Allowed:** foreground pairing/discovery/transport adapter and scoped app UI/tests. **Forbidden:** background-hosting guarantees, Internet traversal, custom Bluetooth protocol, independent merge engine.

Implement explicit nearby session pairing and bounded inventory/missing-object exchange using existing engine/envelopes. Test denied local-network permission, wrong fingerprint, disconnect/reconnect, duplicate frames and cancellation. File exchange must remain usable. Exit: two physical devices exchange the same accepted closure as files; test evidence records actual device/OS/network. Simulator success alone cannot establish nearby behavior.

### P09 — First-party service operations and account boundary

**Depends on:** P07, security review, explicit hosting/policy authorization. **Read:** §§8, 11 and current product policy. **Allowed:** first-party provisioning/config/IaC in a named new service area, operations docs, staged client remote settings and integration tests. **Forbidden:** production deployment without authorization, escrow of member private keys, proprietary semantic fields.

Add account-based repo provisioning, quota/usage UI, optional generic push hints, report/block flows, backup/restore, deletion/retention jobs, secret management and health dashboards. Self-host setup uses device keys/operator provisioning without official account login. Test staging restore, endpoint replacement, stale-token revocation, quota exhaustion and deletion replay behavior. Exit: same conformance suite on self-host and first-party staging; export and restore survive removal of official account/service. Publish measured operating costs and supported limits before launch.

### P10 — Release evidence and open-spec candidate

**Depends on:** P06–P09 and all required fixes. **Allowed:** protocol docs/vectors, tests, focused bug fixes within lane, product handoff and candidate release artifacts. **Forbidden:** declaring owner acceptance, public-standard status or shipping because tests passed.

Run interoperability, fault/security, scale and applicable app/release gates; generate a full handoff with build number/SHA, OS/devices, exact flows, known issues, reset, seeded clubs, diagnostics and owner pass/fail checklist. Verify no plaintext source/voice leak, no unsigned trust upgrade, no uncertain seek promotion. Prepare specification license, change process and independent implementation kit. Exit: implementation `verified`; product remains pending until owner exercise, publication/distribution remain their own authorized actions.

## 14. Verification, falsification and stopping rules

### Required evidence matrix

| Claim | Falsification test / evidence |
| --- | --- |
| Transport independence | A publishes by file, B replies offline, C receives C/B dependencies out of order, then all reconcile via self-host and first-party staging; accepted OIDs and projections equal |
| Offline usefulness | Create/join with prepared invite, contribute, review and export in airplane mode; no official account/token lookup required |
| Deterministic merge | Duplicate and randomized transfer permutations, independent clocks ±1 year, same-device restore fork, concurrent revisions; same accepted set produces same conflict state |
| Correct attention semantics | Download all history but review only a child; ancestors remain unreviewed; partial audio, muted items and unsupported objects cannot produce full-review claims |
| Stable content targets | Edit a scene and summary after a reply; reply still points to old revision; source anchor and selected listening context remain distinct |
| Correct edition resolution | Changed PDF extraction, emoji offsets, repeated text, dynamic-ad edits, contradictory acoustic/transcript candidates, missing scenes; no false confident seek |
| Identity and privacy | Modified signature, wrong club, spoofed label, revoked key, forged legacy attribution, missing grant, unexpected original voice/source bytes all fail at correct boundary |
| Durable import | Kill before/after file rename, journal write, SQLite commit, cursor update; no accepted row references nonexistent data and no acknowledged contribution disappears |
| Safe hostile input | ZIP traversal/bombs, duplicate JSON keys, cycles, deeply nested objects, huge parent arrays, decompression/decoder failure, unsupported critical feature; bounded resource use |
| Relay correctness | Replay upload, expired cursor, withholding relay, stale auth after control change, missing blob, DB restore, range retry, two-tenant probes; no authority or history rollback |
| Encryption/profile interoperability | Independent implementations match KDF/JCS/signatures and decrypt each other's envelopes; salt reuse and wrong AAD rejected |
| Compatibility | Pre-change Library copy, existing `.spokenmargins` fixtures, legacy replies, Listening Edition intake, no schema downgrade or source overwrite |
| Complete export | Walk advertised metadata/media/proof closure in an empty independent reader; every required OID resolves, all other omissions explicitly declared |

Repo commands remain those in `docs/testing.md`: bootstrap tools, `--plan fast`; add `--plan app` for app orchestration, `--plan adapters` for audio/inference changes, `--plan speech-canary` for speech/playback changes, scoped `--plan ui`, and `--plan release` before release handoff. Run generic simulator/device builds for integration changes per `AGENTS.md`. Add new suites to inventory instead of claiming standalone focused tests satisfy full gates. Preserve simulator incident evidence and stop affected tests immediately on system crashes; no device-switch workaround.

For **this documentation-only deliverable**, check source references, policy consistency, Markdown links and diff only. No app tests or simulator boots are necessary.

### Proposed performance experiments

Use a synthetic license-safe corpus: 64 members/128 devices, 100,000 structured objects, 10 GiB of chunked media, 1,000 concurrent small clubs on the relay test harness. Capture device/server hardware and network assumptions. Initial targets, subject to measurement: 1,000-object metadata import p95 under 2 seconds on the oldest supported physical phone after I/O warm-up; additional streaming memory under 64 MiB; warm Catch Up query under 200 ms; duplicate import transfers no already indexed semantic media when an interactive peer has an exact inventory; server control/announcement p95 below 500 ms at 50 ms RTT excluding upload. Measure cold starts separately, and do not excuse data loss for latency.

Account for space amplification: retained original/private recording + encrypted upload envelope + temporary export can multiply storage. Reserve bytes before export, stream within a budget, clean staging after cancel, and protect the only local copies. Report ciphertext overhead, bytes/object, sync bytes for one new Margin, number of metadata requests after 30 days offline, battery use and server egress. Optimize only the measured bottleneck. Avoid full DAG traversal on every launch or announcement.

### Gates and stopping conditions

Stop external release for cryptographic review findings, unknown required schema semantics, source/voice disclosure mismatch, unsigned identity upgrade, wrong-coordinate placement, nondeterministic conflicts, lost contributions, an encryption downgrade, or inability to restore without the official service. Stop performance broadening when the agreed corpus and correctness gates pass; rerun only for changed inputs or unresolved findings. Missing/unsupported device evidence is inconclusive, never a pass.

Owner validation checklist must include: create offline club; admit another device; two-way and three-way file exchange; concurrent edits/replies; select map and hear scene/summary-anchored Margins; missing/changed source recovery; Catch Up with partial review; explicit receipt opt-in; move to self-host; remove member then reconcile delayed offline work; recover from backup/key loss; delete local and hosted copies with truthful retained-copy explanation. Seed at least native text with emoji, a repeated-passage PDF, a dynamic-edition podcast, and conflicting scene maps. Record exact build/commit/device/OS, reset procedure, diagnostics export and pass/fail notes per flow.

## 15. Path to an open specification

Publish only after two independently written readers can reconstruct equivalent state from the same vectors, and at least two writers exchange signatures/envelopes/bundles both ways. Swift and a small independent reference client count only if they do not share the same codec implementation. Self-host and first-party services using one server binary are useful deployment tests, not independent protocol implementations.

The public package should contain:

- Core, security, bundle and relay specifications with normative language separated from Spoken Margins product policy.
- JSON Schemas, OpenAPI, canonical byte/signature/encryption vectors, malformed-input corpus and a conformance CLI with machine-readable reports.
- Text/media selector mappings, Unicode examples, map/scene/summary examples, exact conflict/revocation rules and a threat model.
- Minimal command-line create/inspect/verify/import/export/sync workflow independent of Apple UI, plus a reproducible self-host deployment and backup/restore guide.
- Extension registry, compatibility rules, version negotiation, security reporting/contact, changelog and deprecation process.
- Explicit licenses for specification text, code and fixture media, with contributor/IP policy reviewed before public release. Naming/MIME/UTType registration is not presumed completed.

Major profile changes require explicit opt-in or migration; additive optional extensions preserve bytes and do not alter core meaning. Unknown required semantics block the affected object/application, not erase the rest of a repository. Experimental extensions remain namespaced until two independent implementations and compatibility tests justify promotion. No official-server private capability may be necessary to read, author, export or recover a conforming club.

Coverage audit: offline/no-account creation and file transfer → P03/P05; nearby negotiation → P08; self-host and official relay → P07/P09; audio Margins and exact replies → P04/P05; maps/scenes/descriptions/summaries and their own anchors → P01/P04/P06; lifecycle/security → P02/P03/P09; independent open-spec interoperability → P01/P10. None may be dropped while claiming the requested feature set complete.

Open issues intentionally left as release decisions: independent security assessment of the proposed envelope profile; final public name/license/registrations; measured profile limits and service SLOs; acceptance of the bounded controller/revocation/full-history-join policy; concrete supported server/library versions at build time. Defaults are specified above so agents can prototype without inventing semantics, but no unresolved security/policy choice may be silently treated as approved production behavior.

## 16. Sources and audit trail

Primary sources checked 2026-09-23. Standards supply primitives and constraints; the object types, membership policy, encryption composition, limits and work packets above are design recommendations for this project, not claims those sources endorse OMR.

- **S1:** [Git bundle documentation](https://git-scm.com/docs/git-bundle) — full/incremental transfer and prerequisites.
- **S2:** [RFC 8785: JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785.html) — interoperable canonical JSON for cryptographic operations.
- **S3:** [RFC 8032: EdDSA](https://www.rfc-editor.org/rfc/rfc8032.html) — Ed25519 algorithm and test vectors.
- **S4:** [W3C Web Annotation Data Model](https://www.w3.org/TR/annotation-model/) — bodies, targets and selectors.
- **S5:** [RFC 9180: Hybrid Public Key Encryption](https://www.rfc-editor.org/info/rfc9180/) — standard recipient-key encryption primitive; not a complete group membership system.
- **S6:** [RFC 9420: Messaging Layer Security](https://www.rfc-editor.org/info/rfc9420/) — group epochs and group-security alternative.
- **S7:** [RFC 5869: HKDF](https://www.rfc-editor.org/info/rfc5869/) — key derivation primitive.
- **S8:** [RFC 5116: Authenticated Encryption](https://www.rfc-editor.org/rfc/rfc5116.html) — AEAD interface and nonce requirements.
- **S9:** [EPUB 3.3](https://www.w3.org/TR/epub-33/) — publication/resource structure for edition-specific locators.
- **S10:** [Media Fragments URI 1.0](https://www.w3.org/TR/media-frags/) — temporal addressing interoperability.
- **S11:** [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html) and [WAL](https://www.sqlite.org/wal.html) — database durability boundary; external-file journaling remains an application responsibility.
- **S12:** [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — conditional requests, representations and range semantics.

Repository starting points: [release lanes](release-lanes.md), [co-op behavior](co-op-listening.md), [direct-sharing policy](external-testflight-sharing-decision.md), [testing](testing.md), [private episode maps](build-25-private-episode-maps.md), [PKM workflows](pkm-workflows.md), and [recursive-reply handoff](../artifacts/validation/gate-1/co-op-2026-09-22/recursive-replies/handoff.md). The supplied proposal was reviewed from the user attachment; all implementation-critical conclusions are restated here so future agents do not need that attachment or this conversation.
