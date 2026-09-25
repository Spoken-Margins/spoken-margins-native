# Testing audit — September 24, 2026

Owner correction after this audit: the Luna probe used the wrong app and tested nothing in Spoken Margins. Treat it as a failed verifier attempt, not a product startup finding; its target-identification claim is withdrawn. See the corrected probe record.

The owner gate failed. The evidence used to offer this candidate for an owner exercise did not establish the core audible conversation experience. The problem is both implementation defects and a verification process that substituted narrower component successes for complete user outcomes. Product-owner acceptance should be the final judgment, not the first complete exercise of the feature.

## Scope and limits

Reviewed `codex/co-op`, HEAD `34837c6055471297ca0b360c591f734bad5c2c82`, with extensive concurrent uncommitted repairs. Traced the co-op changes from `82e61bc` through `564a16d` (navigation) and `34837c6` (recursive replies, despite its generic redesign commit title), and the current dirty anchor/recipient/two-parent changes. Reviewed production routing, package generation/import, representative app/UI/adapter assertions, benchmark gates, verification runner identity, and September 22–24 handoffs. Also checked the second-edition handoff for the earlier evidence boundary.

This is a detailed audit of the reported failures and the testing methodology, not an exhaustive line-by-line review of every historical feature. Source is changing in another repair task; findings below identify the code as inspected, not a frozen final candidate. No new test suite, build, installation or physical-device interaction was performed by this audit. Asset inspection was read-only. The independent interactive probe is recorded separately.

## Model of the failure

These are separate things to prove:

| Layer | Required claim | Evidence that cannot substitute for it |
| --- | --- | --- |
| Artifact identity | Alex's revision contains Alex's distinct voice and words | Archive CRC or number of graph nodes alone |
| Attribution and selection | The visible author and selected revision identify the actual recording | Packet sender label or transcript displayed in UI |
| Source location | The recipient has a defensible local source position, or usable recovery | Sender timestamp, parent reference, or low error on accepted benchmark matches |
| Playback | Requested audio becomes audible, progresses, completes and advances correctly | `playing` state, an assigned player, or queued names |
| Experience | The ordinary import → select → listen → context → reply path works | Direct app-model calls or an unrelated seeded text flow |
| Candidate/platform | Evidence applies to the installed binary and device state | Reused build number or the current working directory |

Resources are owner attention, account usage, machine time and access to working simulator/audio capture. Actors are the implementation task, an independent interactive verifier and the product owner. The simulator incident restrictions and owner's script-testing stop are constraints. The principal failure mechanism is an incomplete evidence chain: correct packages and plausible app states do not guarantee that the real controls produce the right audible result.

## Findings

### 1. Critical: readiness was offered across an acknowledged runtime gap

The [owner packet handoff](../gate-1/co-op-owner-test-2026-09-24/owner-packet-handoff.md) reported 484/484 app tests and offered the packet for the owner exercise while current audio adapters had executed 0/11. Earlier audio/UI passes used older inputs. Its withdrawal notice now correctly supersedes that readiness claim, but historical ready/pending statements remain below it.

The [earlier demonstration status](../gate-1/co-op-2026-09-22/simulator-demo-status.md) explicitly records that the requested complete co-op demonstration was not delivered and audible Margin completion remained outstanding. The [first-slice handoff](../gate-1/co-op-2026-09-22/handoff.md) also records an intermittent source-progress failure followed by passing runs with no transport repair claimed. This was unresolved reliability evidence, not something a later aggregate count could erase.

### 2. High: the principal conversation tests do not exercise the promised audible sequence

`App/SpokenMarginsAppTests/ConversationNavigationTests.swift`, `testTwoTargetWrittenReplyKeepsCaptureAnchorAndPlaysSharedAncestorOnce` (around line 256), creates local written Cole/Alex/Blair/Casey notes with `NoopAudioPlaybackClient`, asserts Cole is current and the remaining names are queued, then returns. It never proves imported Alex audio starts, the first recording completes, or Casey is heard. It is useful graph/orchestration coverage, but the playback wording and handoff use overstate it.

`App/SpokenMarginsAppUITests/Gate1FlowUITests.swift`, `testConversationSkimUsesExistingControlsAndSecondTapReachesMargin` (line 18), launches `--ui-testing`, creates one written Margin on seeded `item-pill`, skips context, checks text and takes screenshots. It does not import the delivered podcast packets or listen through them.

There IS real adapter coverage: `MediaPlaybackInterruptionTests.swift:129` exercises real AVPlayers and advancing clocks. It directly inserts an already-resolved single Margin and uses generated PCM files without distinct spoken identities. It proves useful transport properties, not participant attribution, real podcast alignment or the multi-person import flow. Calling all existing tests fake would be inaccurate; their scope was insufficient for the readiness claim.

### 3. High: confirmed author-label defect can present Cole's recording as Alex

At inspection, `SharingExperience.swift:132`, `ImportedCommentaryPrompt.senderLabel`, used `layer.displayLabel`. `Gate1RootView.swift:2532` displayed that label during playback. However, `ExperienceModels.swift:364` already preferred the individual conversation author for rows. Thus two screens can disagree about the same recording.

The exact delivered Alex archive contains both Cole's 141.375-second forwarded recording and Alex's separate 29.080-second TTS recording. Their actual bytes have different SHA-256 values and match the manifest. Alex bytes also match the separately recorded generated-preview hash. See [packet-inspection.json](packet-inspection.json). The generator intentionally includes Cole first; a forwarded Cole recording is not itself corruption. Labeling it Alex is a defect.

This is a supported explanation for seeing Alex while hearing Cole, NOT proof of the whole device failure. The exact selected revision, stored asset path, audible output and completion transition still require runtime evidence. The archive does not support the claim that Alex content was omitted from the package. All three AI voice assets exist and are distinct; this audit has not independently listened to them.

### 4. High: source-position certainty gates unrelated conversation listening

At inspection, `Gate1AppModel.playConversationMargin(SharedMarginRow, withContext:)` (around line 5056) rejected `withContext: true` when source position was unresolved, before building the known parent chain. A valid reply relationship and a playable saved voice do not require a verified podcast timestamp. Source context and parent-Margin context have been coupled in this path.

`CoopPacketGenerator/main.swift:60` explicitly uses `original.anchor.withoutMachineEvidence` for synthetic replies. In the actual packets Cole has two acoustic assets; Alex, Blair and Casey each have zero. This does not prove they can never resolve through another method, but it means those fixtures do not establish equivalent source-position reliability for the AI replies.

`listenAroundImportedPodcastPosition` does invoke a real local source transport/seek; the owner's report that it fails remains a required reproduction. The evidence available here does not establish its exact runtime cause. Do not report the Skim repair as proof that this separate action works.

### 5. Critical: a playing flag concealed a stalled transport

The [failed device incident](../gate-1/co-op-owner-test-2026-09-24/failed-device-run/incident.md) and its preserved event ring show an accepted seek to 19:08 followed by more than two minutes at the same media time while status remained playing. The prior lead-in waited for source progress to reach the destination without a no-progress bound. That prevented the Margin from starting.

The ongoing repair changes explicit Skim to direct voice playback and adds an eight-second no-progress fallback for optional context. These are relevant implementation changes, not yet proof that the owner's device flow is repaired. The imported player path also sets UI playback state before AVPlayer has demonstrated audible progress; asynchronous playback failure/stall needs explicit observation, not just a synchronous `catch`.

### 6. High: benchmark accuracy was not availability

The [held-out result](../sharing-next/podcast-anchor-benchmark-result.json) has 226 eligible anchors. Acoustic matching accepts 215 and declines 11; fused monotonic matching accepts 210 and declines 16. Zero false-confident matches and 4 ms p95 error describe accepted matches. `SharingTests.swift:1599–1603` gates false confidence and error, without a minimum accepted-eligible rate. The corpus is one held-out audiobook chapter with controlled transformations; it is not the owner's actual podcast/device/speech-service path.

Keeping uncertain placement is appropriate. Promising that unmatched positions are impossible was not supported. Measure both safe placement and availability, and separately demonstrate direct listening and a working recovery path when matching declines. Do not repair this by treating an unverified sender timestamp as a confident recipient location.

### 7. High: the candidate is difficult to identify on-device

The handoffs reuse app version 0.1/build 27 for multiple dirty candidates, including a TestFlight build with older behavior. The test runner does hash tracked and untracked implementation inputs; that is a useful control. But `DeveloperDiagnosticRecording.swift:8` still uses the static `device-diagnostics-20260908-C` identifier. Neither that string nor build 27 binds a recording to the tested changes.

For the next candidate, include commit, dirty-input digest, built app digest, device/OS, packet hashes and build timestamp. Freeze implementation inputs during the recorded proof. This is a proposed improvement; no app metadata implementation was changed in this audit.

### 8. Lower priority, confirmed: redundant playback copy

`Gate1RootView.swift:2538` renders both the paused label and the speed explanation the owner rejected. Removing these is a clear UI requirement. It does not warrant broad simulator regression reruns. The active repair task was sent the exact location and has acknowledged it.

## OpenAI guidance and its application

OpenAI's [iOS simulator debugging guidance](https://learn.chatgpt.com/use-cases/ios-simulator-bug-debugging) recommends that Codex inspect the screen, perform the actual reproduction steps, gather evidence, make a small fix and repeat the same path. It also recommends one bug per run. This directly supports agent-driven reproduction here. The continuous video-with-audio requirement is the owner's stronger project-specific rule, not a quoted OpenAI mandate.

OpenAI's [Codex best practices](https://learn.chatgpt.com/guides/best-practices) combines relevant tests, confirmation of requested behavior and review; it recommends encoding repeated lessons and completion criteria in AGENTS.md. Accordingly, the script-testing stop is now recorded in AGENTS.md, docs/testing.md and docs/release-lanes.md.

OpenAI's [evaluation best practices](https://developers.openai.com/api/docs/guides/evaluation-best-practices) recommends task-specific, realistic evaluation cases and calibration against human feedback; it warns against unrepresentative tests and unsupported impressions of success. That document addresses AI evaluations, not native AVPlayer certification. Applying its evidence principles to our engineering verifier is an inference. It does not recommend abandoning every deterministic test, nor establish Luna Max as the best simulator/audio verifier.

## Recommended recovery method

1. Keep this candidate failed. Stop feature expansion until the failing listening path is demonstrated. Preserve the owner's Library and original recordings.
2. Use one implementation writer and one bounded independent interactive verifier, as the owner requested. The verifier receives expected words/authors and ordinary user goals, not a suggested successful tap sequence or injected model state. Start with Luna Max as a trial; keep it only if it reliably detects known failures and supplies reviewable evidence. Do not scale parallel agents or promise usage savings without measurements.
3. Finish one vertical slice first: import the exact Alex packet through the app, select Alex's specific Margin, hear Alex's expected opening and complete response, pause/resume it, and return to source with advancing audio. Record screen AND system audio. Then exercise Play with Context, Listen around suggested position, and the Casey chain.
4. Bind every recording to the installed candidate and packet hashes. Record expected result, observed result, video timestamps, actual audible words, route, latency and pass/fail/blocked for each claim. Keep raw evidence locally; a clipped demonstration must retain a link to the uncut recording. An agent unable to inspect audio must mark audio identity unverified. Non-silent audio alone is insufficient.
5. Keep host-only package/contract/data-integrity checks as supporting evidence. All scripted simulator tests remain stopped, including simulator-hosted app XCTest. Do not smuggle those back through a composite release command. Compilation is permitted but is not playback evidence.
6. After the smallest slice passes, cover a populated Library, repeated imports, child-before-parent, relaunch, real media, mixed local/imported voices, and unavailable alignment/audio. Use a coverage ledger tied to claims rather than one total suite count. Run supported-device layout/OS variants only after the core path works and incident restrictions permit them.
7. Only then provide the owner a short acceptance checklist and exact candidate. Simulator proof does not establish physical iOS 27 audio routing, Bluetooth or background behavior; those remain separately identified device checks. Do not request another installation or reset under this audit.

### First recovery scorecard

| Scenario | Required observable result | Failure designed to catch |
| --- | --- | --- |
| Alex directly | Label says Alex; captured speech starts “Cole, I agree…” and completes | Wrong author, wrong asset, no audible start |
| Cole forwarded in Alex packet | Cole is labeled Cole and plays Cole's words | Packet sender substituted for recording author |
| Alex with parent context | Cole then Alex each plays completely once; unresolved podcast location does not suppress known voice context | Queue asserted but never executed; source/parent coupling |
| Casey with context | Cole, Alex, Blair, Casey each once in declared traversal; correct labels and audible words | Duplicate ancestor, skipped child, wrong completion routing |
| Suggested source position | Downloaded source audibly starts/progresses; review can confirm or decline; errors are visible | Accepted seek with frozen transport; inert recovery control |
| Interruption/relaunch | Pause freezes requested voice, resume continues it; reopening preserves revisions without mixing recordings | UI state detached from player; stale identity/persistence |
| Missing or unmatchable source | Direct saved voice remains usable; no false confident seek | Accuracy achieved by making the feature unusable |

### Auditability, alternatives and stopping rules

Compare three options: more of the existing suites preserves their blind spots; click-only video without audio/identity can repeat the same false confidence; a claim-based combination of interactive audiovisual proof and host data checks covers both visible behavior and hidden invariants. A rewrite before reproducing these boundaries risks recreating the same defects under the same weak completion criteria. The evidence presently supports targeted recovery first, not a conclusion that the entire app must be discarded.

Calibrate the verifier against retained known-failing evidence and distinct named audio. A verifier that approves Cole audio under an Alex label fails calibration. For host assertions, use counterexamples such as swapped asset references, a missing ancestor, or stale revisions; do not mutate the owner's app data to inject faults. Omission review must ask: did every voice actually complete, did source playback resume, did the app survive reopening, and were both ready and degraded paths exercised?

Stop a flow immediately on wrong audio, data loss, crash or confidently wrong seek. Preserve the first failure and make one evidence-backed correction before retry. For setup/capture blockers, report the exact missing capability; do not substitute a passing compile or retry unchanged infrastructure. Track machine execution separately from account usage; reuse unchanged evidence and rerun only affected claims. The owner's estimate of 30% usage is not independently attributable from repository evidence.

## Actions in this audit

- Stopped active simulator runner PID 36080 and its xcodebuild PID 36676 at the owner's instruction. The owning repair task acknowledged termination; the final run is interrupted, not passed. Its `20260924-134644-598800-app/manifest.json` still says `running` after termination, so this audit records the interruption explicitly rather than treating that stale status as live work. Read-only inspection also confirmed the earlier 484-test candidate manifest is `verified` and its same-input adapter manifest is `failed_or_incomplete` with zero completed tests.
- Recorded the override in the three authoritative guidance files and notified the active repair task. No implementation files were edited by this audit.
- Independently inspected actual delivered archive bytes and saved the compact identity report.
- Sent confirmed label/context/copy findings to the active repair task; its ongoing changes are not declared verified here.
- Dispatched the requested bounded Luna Max interactive probe. Its result is separate from the static findings and must not be represented as owner acceptance.

The probe initially looked for the conventional Simulator app, which is absent. A follow-up checked Device Hub, the UI used by the earlier repository demonstration, and successfully displayed the already-booted iPhone 17 Pro/iOS 26.5. Luna used Device Hub's Record control and opened the existing Spoken Margins icon. The observed result was a white app screen with a visible status bar and no accessible Margin controls. The installed binary's source identity is not established, so this is a failed/blocked interactive attempt on the existing installation, not proof of a regression in the newly edited candidate. No Alex playback or audible identity claim is supported. The agent reports selecting the branded “Spoken Margins” accessibility element, distinct from the UI test runner. A sampled recording frame shows the Home screen, and the agent reported a stale accessibility tree after the tap, so the precise launch outcome remains uncertain. The saved [recording](interactive-probe/launch-attempt.mp4) is 66.61 seconds and contains only an H.264 video stream (independently checked with ffprobe), with no audio. It cannot close a playback claim. See the [probe record](interactive-probe/blocked-probe.md) for capture details and limits.
