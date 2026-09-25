# Podcast anchor reliability: root cause and implementation brief

September 23, 2026. Investigation and design only. No app implementation changed, simulator booted, device installation performed, or product flow validated.

**Implementation authorization added September 23:** the owner subsequently requested implementation with sub-agents, sparse supervision, and strictly more than 85% account usage remaining. See the current entry in [release-lanes.md](release-lanes.md) and the [implementation status](../artifacts/validation/gate-1/podcast-anchor-reliability-2026-09-23/implementation-status.md). The investigation statements and future-work wording below describe the brief at creation; current authorization supersedes its original no-implementation/sequential-only boundary. No distribution or product acceptance is implied.

## 1. Decision and scope

**Fix the production capture wiring first.** `RoutedAudioPlaybackClient` does not forward either source-audio capture method. Calls from `SessionEngine` resolve to protocol defaults returning `false`. Consequently, the primary pre/post fingerprint path is never requested through the app’s normal audio client—even when the podcast continues playing.

This is a confirmed source defect with an isolated executable reproduction, not merely a proposed explanation involving streaming or speech recognition. It exists in the inspected current source and the Build 27 tag. The exact installed sender commit and the subsequent fate of each of the five historical Margins remain unproven.

The complete remedy is a reliable capture-to-export system, not just two forwarding methods. Preserve recorded Margins, original anchors, privacy boundaries, quick sharing, and conservative recipient placement. Success means ordinary listening produces evidence automatically; interruptions recover without repeated user effort; genuine uncertainty remains explicit instead of producing a confident wrong position. No system can guarantee a unique match for deleted or repeated content, or capture audio never played.

This document is a handoff for **future authorized implementation**, not authorization to start it. Work is currently on `codex/co-op`, HEAD `34837c6055471297ca0b360c591f734bad5c2c82`, with existing uncommitted changes. Before implementation, reconcile scope with [release-lanes.md](release-lanes.md), recording any owner-approved expansion there. Use the existing lane; no new branch, commit, merge, distribution, server, or cloud-ASR work is authorized by this brief. Work packets below are sequential agent handoffs. Parallel execution still requires the repository’s explicit owner assignments and merge order.

## 2. Evidence and causal chain

### Confirmed root defect

| Boundary | Evidence |
| --- | --- |
| App → router | `makeAudioPlaybackClient()` returns `RoutedAudioPlaybackClient(speech:…, media: makeMediaPlaybackClient())`. [App composition](../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift#L11269) |
| Engine → capture requests | Margin completion calls `captureBufferedPreInterjectionAudioSample` and `armPostResumeAudioSample` on its `AudioPlaybackClient`. Both false results mark capture unavailable. [Engine](../Packages/SessionKit/Sources/SessionKit/SessionEngine.swift#L1519) |
| Protocol → silent default | Both methods have default implementations returning `false`. [Protocol](../Packages/SessionKit/Sources/SessionKit/Protocols.swift#L310) |
| Router → missing forwarding | The router implements playback, seeks, pause, etc., but neither capture method. The media implementation exists below this missing boundary. [Router](../Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift#L2637) |

A host-only probe compiled the **unchanged router class extracted from current source**, all current SessionKit core sources, and a media spy. The spy implements both capture methods and returns true. After selecting the media route, calls through `any AudioPlaybackClient` produced:

```text
direct pre=true post=true calls=2
routed pre=false post=false calls=0
```

Compilation and execution succeeded. This verifies dispatch failure independently of AVPlayer, network access, ShazamKit, or speech services. It does not verify the eventual capture fix on an iPhone. An initial attempt to reuse cached modules failed due to Swift 6.3.3/6.4 incompatibility; the successful probe compiled current source instead. No repository test or implementation file was edited.

The omission also exists in `testflight/0.1-build-27` (`adeb923fc1d081b19dfe9d650b50ac9fb036535a`), whose app constructs the same router. The diagnostic build string `device-diagnostics-20260908-C` is a static label, not sufficient binary provenance.

### Why the backups do not make this harmless

1. Both primary requests return false. The app then tries exact-local generation only if a validated downloaded file is the file actively playing. Streaming without that local match has no eligible exact-local fallback.
2. Source-context recovery can return early using an existing transcript, without generating acoustic evidence. Otherwise its window API requires successful transcription before returning temporary audio for fingerprinting. Thus text availability can skip acoustic repair, while speech failure can prevent it. [Context recovery](../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift#L13015), [window API](../Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift#L3490).
3. Sparse playback landmarks use a separate continuous tap attempt, but installation requires tracks immediately at player creation. No readiness-triggered retry exists there. This is a separate coverage gap, not a proven explanation for absent historical landmarks.
4. Export permits no evidence, drops missing files, and uses a draft’s copied Margin rather than freshly loading capture evidence. The packet can be structurally intact while lacking positioning evidence. [Export](../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift#L14204).
5. Capture state is aggregated; diagnostic keys commonly use only `interjection.id`, although IDs repeat across sessions. A later fallback can overwrite the useful original failure. Relaunch diagnostics do not reconstruct the full history from stored records.

The test gap is equally concrete: core tests inject a fake audio client, and fingerprint tests invoke the tap context directly. Passing both does not exercise the app’s router between them. Existing router seek tests illustrate the missing boundary test. [Core tests](../Packages/SessionKit/Tests/SessionKitTests/SessionKitCoreTests.swift#L86), [capture tests](../Packages/SessionKit/Tests/SessionKitTests/SharingTests.swift#L481).

### What is established for the supplied packet

The September 23 re-export contains five cleaned voice assets, no signature assets, empty machine-evidence references, no fingerprint spine, and no exact source-edition hash. Every declared asset/artifact size and digest matches. Diagnostics independently report `margins=5;evidence=0`.

Four recording positions exactly match packet anchors; each resumes and advances over 50 source seconds within approximately 30 wall-clock seconds. The retained log begins after the first Margin. This rejects insufficient continued listening as a general explanation for those four; it does not prove tap delivery. Re-export did not recover anything. A later offline download does not establish the edition used during capture. The separate recipient simulator speech failure cannot explain absent sender fingerprints.

**Attribution limit:** the router defect explains a deterministic failure of the intended mechanism. The supplied snapshot cannot prove which fallback ran for each historical Margin, whether evidence inclusion was disabled, or whether any generated files were later lost. Do not claim all five are forensically explained. The first implementation packet must read stored per-Margin evidence/failure fields and establish installed version/commit when available, without altering original records. If unavailable, retain the uncertainty; repairing the reproduced defect need not wait indefinitely.

Evidence identifiers and exact playback advances are in [the concise review](../artifacts/validation/gate-1/co-op-2026-09-22/fingerprint-reliability-review.md). Packet SHA-256: `aa69ae8355fb30268afb43a1d43e88762bbf9dc1a1942eed33251bcd8f5479a0`.

## 3. System model and invariants

Keep these layers separate:

| Layer | Owns | Must not imply |
| --- | --- | --- |
| Source identity | Canonical episode, observed playback instance, local file digest where available | Same URL/title means identical audio edition |
| Acquisition | Actual source samples, media time, continuity, format | Audible playback means samples reached the app |
| Derivation | Signature and bounded transcript generation | A signature is a unique recipient match |
| Durable storage | Per-window outcomes, asset integrity, retries | Saved voice means saved source evidence |
| Transport | Reviewed snapshot and complete referenced assets | A valid archive is adequately positioned |
| Resolution | Candidate search, uniqueness, contradictions, edition offsets | A sender timestamp is a verified recipient position |
| Product state | Saving, readiness, exceptional recovery, user confirmation | Automated verification is owner acceptance |

Required invariants:

- Margin voice/text and original anchor survive any evidence failure. Evidence work cannot block saving the Margin or resuming playback.
- Every eligible Margin has independently recorded pre/post outcomes. One successful flank cannot hide a sibling still pending; one failed flank cannot erase a successful one.
- Every observed sample belongs to an item, playback generation/edition, source interval, and continuity epoch. Never concatenate across gaps/seeks or label refetched audio as observed playback.
- A committed evidence reference resolves to readable, integrity-checked bytes. Export either includes those bytes or records a deliberate omission; no silent filtering.
- “Ready to share” and “recipient position verified” are different states. Source hashes prove exact-byte identity only when both sides actually hash the relevant full file.
- Raw podcast PCM remains bounded and transient, never in the share package. No microphone capture of speaker output, continuous disk recording, or full sender download solely to obtain fingerprints.

## 4. Capture and durable recovery design

### Production routing and capability contract

Forward both methods through the media route and propagate real results. Test through a protocol-typed router, not only concrete clients. Do not switch routes or play audio as a side effect of a capture request. Speech-only/written/reply paths must have explicit eligibility rules and must not capture unrelated source audio.

Replace ambiguous false-only failure handling with a typed acquisition result/capability boundary: unsupported source, waiting for track, accepted, stale playback generation, or explicit failure. These are proposed semantics, not new command IDs. Select the precise schema/API in the contract packet and update all implementers, validators, and tests together. Avoid optional protocol defaults silently disabling capabilities in composite clients.

### One capture coordinator, bounded workers

Create a coordinator outside `Gate1AppModel` to own capture jobs, retries, and reconciliation. The engine records intent; the playback adapter reports samples/capability; workers derive evidence; the store commits it; UI observes durable state. Neither a share sheet nor an in-memory `Task` owns completion.

Persist jobs keyed by item + session + Margin + window role + attempt generation. Retain the original anchor and producing playback generation. Track waiting, collecting, deriving, committed, retryable failure, and terminal unavailable separately for each flank. Persist the original and latest failure stages, rather than replacing everything with “no local file.” Reject late callbacks from superseded attempts. Key accumulator and diagnostic records with session-qualified identities; current `ij-001`-style IDs are insufficient.

Freeze pre-window eligibility at interruption; do not allow recorder reconfiguration or resumed seeks to redefine the source interval. Reuse the existing bounded 20-second memory ring. Target 12 seconds per flank, using actual source time; retain current 3-second minimum only as a partial-evidence candidate requiring matcher checks. At episode edges use the available flank, never fabricate two-sided coverage.

Attach the tap when tracks become ready and after relevant item replacement; validate actual first-buffer delivery and ongoing source-clock progress. Pause collection during stalls/interruption. Reset the accumulator at discontinuity, retain the original anchor, and record why a fresh window is or is not equivalent. A far-away sample becomes a landmark, not automatically a new local flank.

The audio callback should only perform bounded copying into a preallocated queue and report timing/format. Move signature generation, conversion, allocation-heavy ring management, persistence, and logging off the real-time callback. A full queue produces an explicit gap and invalidates that window; never silently concatenate dropped buffers. Normalize unsupported input formats using an off-callback converter and preserve source-time accounting. Apple documents supported PCM rates and a conversion workflow; do not assume every decoder format is suitable. [Apple conversion guidance](https://developer.apple.com/documentation/shazamkit/generating-a-signature-from-an-audio-buffer).

Initial bounded policy, to calibrate with device evidence: one active acquisition per player, shared copied samples for nearby Margins, at most two reattachments per playback generation, a no-buffer watchdog after five seconds of advancing source playback, and at most three automatic attempts per flank. Pause does not consume usable-audio time. After repeated identical failures, suspend until a meaningful event such as track readiness, resume, exact-file availability, or explicit retry; no polling/reboot loop. A process restart restores jobs, not lost PCM. Reacquire only where edition and interval provenance remain trustworthy.

### Independent recovery and storage

Use this preference order without treating later steps as equivalent provenance:

1. Observed playback pre/post windows.
2. An immutable exact local file bound to the playback edition; derive both flanks independently of ASR.
3. A bounded refetched window as **reference-edition evidence**, with its own provenance and candidates. Never transplant its timestamp into the sender edition without alignment.
4. Bounded transcript context, existing edition-bound transcripts, and sparse landmarks as complementary positioning evidence.

Split source-window acquisition from its two consumers: fingerprinting and ASR. Either may succeed independently. Preserve the September 1 release contract: attempt bounded source ASR whenever source audio is available even when fingerprints succeed, and transport bounded reviewed transcript context. An existing transcript fulfills the text need only; it must not terminate an outstanding acoustic job. Use one shared acquisition rather than duplicate network fetches. Do not run source ASR concurrently with Margin transcription if the service cannot support it.

Write a temporary derivative, validate nonempty/readable signature and digest, atomically rename, then transactionally commit the asset reference and job outcome. Reconcile orphan files/uncommitted jobs after crashes. Keep referenced observed evidence pinned against cleanup until its owning data is explicitly deleted; coordinate with the existing offline ledger. Deduplicate by artifact identity while preserving distinct per-Margin offsets. Preserve a known exact-edition digest when merging evidence lacking one; current assignment can replace it with nil. Do not attach one edition’s hash to evidence from another.

## 5. Sharing and recipient behavior

### Seamless default, explicit exceptions

Saving a Margin immediately resumes listening. Capture/recovery proceeds automatically with a quiet status, not a modal after every recording. Share preparation reads current committed evidence and shows per-Margin readiness. Fresh capture completion updates readiness without discarding the user’s reviewed transcript or voice-cleanup decisions.

At export, take a consistent snapshot of the latest Margin evidence, reviewed content, inclusion choice, and asset pins. Validate files and digests, then assemble and validate the archive before presenting it. Handle a deletion race by recovery or an explicit degraded outcome, not omission. Missing assets must not leave dangling spine references.

If evidence is pending or unavailable, offer **keep preparing** or **share now without automatic positioning assurance** once for the affected selection. Normal sharing needs no additional decision. This is a proposed refinement of current nonblocking-share policy and must be recorded when implementation is authorized. Respect an intentional evidence opt-out and record it distinctly from acquisition failure. A future successful recovery affects a new export; it cannot silently repair an already delivered offline packet.

Transport a minimal versioned per-Margin evidence summary: included roles/provenance, pending/unavailable/omitted outcomes, and safe reason categories. Keep device paths, signed enclosure tokens, full transcripts, and detailed local diagnostic histories out. Extend package contracts compatibly; old packages are `unknown legacy evidence state`, not proof that capture failed. Forwarding and recursive replies must preserve available authorized evidence and original source anchors without relabeling another author’s data.

### Resolution rules

Keep acoustic and transcript candidates separate until fusion. Cache recipient reference windows by exact recipient edition digest, generator version, and interval. The current overlapping 20-minute windows address observed long-reference failures; retain their provenance and benchmark them rather than treating 20 minutes as an Apple guarantee.

Search beyond the first/local candidate before claiming uniqueness: repeated intros, music, ads, and quotations can match elsewhere. Agreement means independently timed evidence; two encodings of the same window are not independent corroboration. Calibrate confidence against correct/incorrect matches rather than averaging heterogeneous scores blindly.

A post-only fingerprint locates that sample; subtracting its sender offset is safe only when the intervening edition relationship is supported. If an ad or passage between the Margin and sample changed, the Margin may be absent. Preserve the current partial-flank safety work; add explicit tests before relaxing it. Use compatible neighboring direct anchors or transcript evidence, reject conflicting candidates, and keep uncertain placements as proposals. Bracketed piecewise-offset recovery must preserve order; no extrapolation or raw duration scaling as verified placement.

For unresolved Margins, schedule bounded recipient transcript windows around credible acoustic/map predictions or the sender timestamp as a **search hint**. Start with approximately 90 seconds before/120 seconds after, then widen once to a five-minute neighborhood; coalesce overlapping jobs. Broader episode search must be chunked, resumable, and resource-budgeted. A unique local text hit is still provisional if global uniqueness has not been checked. Distinguish length failures from recognizer initialization/service failure: allow one supported fallback, then suspend that service instead of repeating the same error in smaller windows. Queue remaining work fairly and preserve completed matches in a partially resolved layer.

Provide direct playback of every imported voice regardless of placement. Exceptional recovery lets the recipient listen around a proposal and confirm a position, stored as **user-confirmed** with recipient edition identity, not acoustic verification. Never require users to learn fingerprints, caches, or ASR to use this flow.

## 6. Work packets and ownership boundaries

Each packet ends with changed-file inventory, source/input identity, tests actually executed, known limitations, and an evidence handoff. Do not overwrite unrelated dirty changes. These describe ownership for a single active implementing agent at a time; they are not live assignments.

| Packet | Work and primary files | Dependencies and acceptance |
| --- | --- | --- |
| A — Reproduce and repair routing | `AudioAdapters.swift`, focused `SessionKitCoreTests.swift`; inspect sender records read-only if available | First. A regression calls both methods through `any AudioPlaybackClient` wrapping a media spy and fails before repair. Verify exact request, return/failure propagation, route isolation, and two sessions with repeated Margin IDs. Establish binary provenance or record inability. |
| B — Agree durable contracts | `Protocols.swift`, `Models.swift`, sharing models, `SQLiteSessionStore.swift`, `Contracts/schemas`, mirrored schemas and validators | After A evidence. Specify state transitions, identities, compatibility, reasons, ownership/retention, transaction boundaries. Migration preserves legacy records; restart reconciliation and out-of-order completion tests pass. No invented IDs without matching runtime/schema/validator coverage. |
| C — Capture coordinator and adapter | `PostResumePodcastEvidenceCapture.swift`, `AudioAdapters.swift`, `SessionEngine.swift`; narrowly integrate app composition | After B. Readiness-driven tap, worker boundary, conversion, continuity, bounded retries, exact-file recovery. Production-routed synthetic audio yields committed evidence; pre/post failures remain independent. |
| D — Decouple recovery consumers | Source-window acquisition/transcription in `AudioAdapters.swift`, recovery integration in `Gate1AppModel.swift` | After B/C interfaces. With ASR forced to fail, acquired source audio still yields fingerprints; stored transcript does not skip acoustic repair. Refetched edition remains visibly distinct. |
| E — Complete export and diagnostics | App sharing seams/model, `SharingFoundation.swift`, `InterjectionPackageArchive.swift`, contracts, focused sharing tests | After B/C. Fresh evidence enters a previously opened draft; missing/corrupt/racing assets produce recovery or explicit omission. Relaunch diagnostics explain every Margin; old packages and forwarding still work. |
| F — Recipient recovery and exceptional UI | `PodcastAnchorEvidence.swift`, recipient app integration/presentation, focused resolver/UI tests | After B/D/E. Bounded ASR, globally checked candidates, conservative partial flanks, edition-bound cache, playable unresolved voices, explicit confirmation. Preserve current dirty resolver repairs. |
| G — Integration and owner handoff | Test fixtures/inventory, evidence under `artifacts/validation/gate-N/`, product/spec docs | After all packets. Full required gates, real-device evidence, adversarial matching corpus, resource measurements, and owner checklist. No flow marked human_validated by an agent. |

Review shared files at each handoff; especially avoid concurrent edits to `Gate1AppModel.swift`, `AudioAdapters.swift`, and `SharingTests.swift`. Do not activate archived parallel-agent roles.

## 7. Verification contract and stopping rules

The priority regression is **engine → production router → media acquisition → durable evidence → export**, with deterministic audio and controlled failures. Direct component tests remain useful but cannot substitute for this chain.

| Scenario | Required observation |
| --- | --- |
| Healthy streamed MP3, no sender download | After sufficient source playback, observed post evidence commits and is included on export without refetch or user action. Pre evidence commits when available. |
| Delayed tracks / failed tap / unsupported transport | Readiness retry succeeds or a specific terminal reason survives restart. Ordinary playback continues; false is never an unexplained capability result. |
| Pause >60s, interruption, route change, rapid Margins | No lost intent, crossed sessions, stale callback commits, or concatenation across gaps; bounded work resumes safely. |
| Seek, speed changes, item switch, episode end | Correct media-time offsets; partial/absent windows remain explicit. Test 0.5×, 1×, 1.75×, and 3× without confusing wall time with source time. |
| ASR unavailable / refetch failure | Acoustic derivation from already available audio remains functional; retries stop on unchanged service failure. |
| Crash between file write and DB commit; low disk; eviction | Recovery reconciles assets/jobs; voice remains saved; no false ready state or dangling export reference. |
| Share opened early; inclusion disabled; file removed during export | Fresh snapshot includes later evidence, or records the exact intentional/degraded outcome. No silent omission. |
| Repeated audio, ads inserted/deleted, wrong episode, absent passage | No false-confident position; conflicting evidence remains unresolved. Single-flank offset inference is specifically challenged. |
| Existing zero-evidence packet | Imports and plays voices; attempts bounded recovery; cannot manufacture missing sender-observed fingerprints. |
| Relaunch and diagnostic export | Version/commit/input identity, per-window attempt/outcome, first failure, and export disposition remain explainable. No sensitive URLs or raw audio. |

Cover supported iPhone/iPad OS versions from the lane, streaming and downloaded sources, foreground/background/lock screen, and representative audio routes. HLS is a separate capability case: Apple documents the existing `AVPlayerItem.audioMix` path as unsupported for HLS; do not generalize its MP3 behavior or silently adopt newer platform APIs across the support matrix. [Apple audioMix documentation](https://developer.apple.com/documentation/avfoundation/avplayeritem/audiomix).

Initial engineering acceptance targets (proposed, not measured promises): 100% expected post captures in deterministic healthy-playback fixtures; zero silent evidence omissions; zero false-confident placements in the adversarial corpus; every failure durably attributable. Measure eligible capture coverage, time to commit, resolution coverage, p95 position error, and false-confident rate separately. Report denominators and exclusions. For real devices, target ≥99% eligible post captures and p95 commit within five wall-clock seconds of receiving the required source samples; do not claim that rate from a handful of trials. Reconcile placement-error thresholds with existing #27 benchmark gates rather than inventing a looser gate.

Keep the existing 20-second PCM bound; measure byte high-water marks, worker backlog, CPU, battery/thermal behavior, playback underruns, and UI responsiveness. Use a single shared normalized ring rather than duplicating 20 seconds per Margin. Derivative evidence takes priority over opportunistic map generation; pause background preparation under resource pressure. If queue/resource limits are reached, retain durable pending intent and an explicit reason.

For implementation run the repository-required `fast`, `app`, `adapters`, and `speech-canary` plans as applicable; scoped `ui` checks for changed recovery/sharing seams and `release` before release handoff. Follow [testing.md](testing.md) for exact selection, toolchain, inventory, and evidence. Missing/skipped required tests or interrupted runs are not passes. Honor the unresolved simulator incident restrictions; no unchanged boot/test loop. Prefer deterministic host checks until an authorized evidence-backed simulator recovery is available.

Stop expanding implementation when required gates and defined acceptance criteria pass. If a supported playback mode still cannot supply samples, document the measured capability gap before proposing a new playback architecture. Do not start a custom decoder, full-file download policy, second fingerprint algorithm, or cloud service merely to add nominal redundancy. Those alternatives have costs and do not repair missing routing, stale export snapshots, or unrecorded failures.

Before owner validation provide build number/commit, devices/OS, in/out-of-scope flows, known issues, reset instructions, seeded items, diagnostic export location, verification summary, and pass/fail checklist. A successful routing probe is **verified dispatch evidence**, not validation of the complete product.

## 8. Reproducing the routing finding

The successful probe used the exact extracted router below, SHA-256 `f8d76a6d6838d101d08052aa88f5dac573ab2e7822afcee72a8861b98da8cc29`. It ran on the host, with no player, microphone, network, simulator, or repository mutation. Run from the repository root; it creates only a temporary executable. After repair, replace the final expectation with both true results and two forwarded calls.

```bash
python3 - <<'PYPROBE'
from pathlib import Path
import subprocess, tempfile
out = Path(tempfile.mkdtemp(prefix="margin-routing-probe-"))
source = Path("Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift").read_text()
router = source[source.index("public final class RoutedAudioPlaybackClient:"):
                source.index("public final class SystemRecordingClient:")]
probe = r"""
final class Spy: AudioPlaybackClient {
    var calls = 0
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func pause() throws {}
    func armPostResumeAudioSample(_ r: PostResumeAudioSampleRequest) -> Bool {
        calls += 1; return true
    }
    func captureBufferedPreInterjectionAudioSample(_ r: PostResumeAudioSampleRequest) -> Bool {
        calls += 1; return true
    }
}
let media = Spy()
let r = PostResumeAudioSampleRequest(interjectionId: "ij", sessionId: "s",
    itemId: "i", anchorMediaTimeMs: 20000, targetDurationMs: 12000)
let routed: any AudioPlaybackClient = RoutedAudioPlaybackClient(speech: Spy(), media: media)
try routed.play(targetId: "i", fromMediaTimeMs: 20000)
print("direct pre=\(media.captureBufferedPreInterjectionAudioSample(r)) post=\(media.armPostResumeAudioSample(r)) calls=\(media.calls)")
media.calls = 0
let pre = routed.captureBufferedPreInterjectionAudioSample(r)
let post = routed.armPostResumeAudioSample(r)
print("routed pre=\(pre) post=\(post) calls=\(media.calls)")
precondition(!pre && !post && media.calls == 0)
"""
(out / "main.swift").write_text("import Foundation\n" + router + probe)
core = sorted(Path("Packages/SessionKit/Sources/SessionKit").glob("*.swift"))
subprocess.run(["xcrun", "swiftc", "-enable-bare-slash-regex", "-module-name", "SessionKit",
                *map(str, core), str(out / "main.swift"), "-o", str(out / "probe")], check=True)
subprocess.run([str(out / "probe")], check=True)
PYPROBE
```
