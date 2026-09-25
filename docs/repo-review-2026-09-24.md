# Repository review — September 24, 2026

Read this first if you are resuming work on the co-op branch or planning the next build. It was written from a read-only review of git history, the uncommitted working tree, the GitHub issues, the `codex/desktop` worktree and the agents' own retrospectives. Nothing was built, tested, reverted, committed or deleted while writing it. Recommendations below are proposals for the owner, not authorizations.

## Bottom line

- **Build 28 is the last known-good product.** Treat `47f9d2f` as the baseline. The co-op work on top of it failed the owner's phone test and is not a candidate.
- **Do not try to repair the co-op tree forward.** It layers four playback state machines inside an 18.5k-line model and mixes at least eight initiatives in one uncommitted diff. More patching of that surface is how September 23–24 went wrong.
- **Salvage by hand, onto a fresh lane from `47f9d2f`:** about six small, independent fixes are worth more than the rest of the diff. The best candidate for the "rejoining margins" complaint is among them (audio path rebasing).
- **Snapshot everything before reverting anything.** The co-op tree and the `codex/desktop` companion are both uncommitted. `codex/desktop` has about 11k lines that exist nowhere else.

## 1. What Build 28 actually is

- Commit `47f9d2f` ("build 28", Sep 21) is on `origin/codex/provisional-next`. That commit itself only touched a pbxproj file type.
- The uploaded binary was archived at 10:05 local on Sep 21 with `CFBundleVersion 28`. The bump was made in Xcode and never saved to `project.yml`, so the repo still says `CURRENT_PROJECT_VERSION: "27"` everywhere, including the co-op tree.
  - Evidence: `~/Library/Developer/Xcode/Archives/2026-09-21/`, where a 10:00 archive is build 27 and a 10:05 archive is build 28 and was uploaded.
- There is **no `testflight/0.1-build-28` tag**. The latest tag is `testflight/0.1-build-27` → `eb09f05`. Tags are local only.
- `main` (`0bf1c79`, Sep 4) is **106 commits behind** Build 28. History is a single straight line: `main → testflight-triage (eb09f05) → 47f9d2f → 82e61bc → 564a16d → 34837c6 → dirty tree`.

Proposed hygiene:

- Tag `47f9d2f` as `testflight/0.1-build-28`, noting that the build number was set in Xcode.
- Commit the next build number (29) to `project.yml` before archiving.
- Push tags.

## 2. What happened, Sep 21–24

| When | Commit / state | What | Outcome |
| --- | --- | --- | --- |
| Sep 21 | `47f9d2f` | Build 28 uploaded | Works fairly well on the owner's phone; "rejoining margins" issues |
| Sep 22 09:32 | `82e61bc` "untested QoL" | UI tweaks, PDF references trimmer, speech normalizer v3, about 6k lines of artifacts | Low risk; shared with `codex/desktop` and local `provisional-next` |
| Sep 22 12:56 | `564a16d` | Conversation navigation: Skim to a Margin with a **120 s source lead-in**, New Margins filter, PDF download-stamp filter | The lead-in is the mechanism behind the later 19:08 stall |
| Sep 22 14:25 | `34837c6` (**mislabeled** "Implement second-edition app redesign") | Recursive replies / conversation v1: contribution and revision IDs, `conversation_snapshot` records, +323-line schema | Real second-edition redesign is `c985489` (Sep 11) |
| Sep 23 | dirty tree | Podcast-anchor reliability brief run by manager agents (Astra, then Sol) with an auditor (Luna) | About 3k lines; 45+ handoff and audit docs; brief still incomplete by its own status file |
| Sep 24 AM | dirty tree | Conversation v2 (2–4 parents), Chatterbox Nano synthetic packets, `CoopPacketGenerator` target | 484/484 app tests, 0/11 adapter tests ran; packet called "ready" |
| Sep 24 | owner phone test | Skim stranded the source at 19:08; Margins did not play | **Failed gate** |
| Sep 24 PM | dirty tree | Direct-play Skim, watchdogs, UI rework, import fallback, download recovery, path rebasing, staged seek | Not owner-tested; scripted simulator tests stopped by the owner |

The agents' own summary is honest and worth reading: `artifacts/validation/gate-1/co-op-owner-test-2026-09-24/saga-retrospective-2026-09-24.md`. By their account, usage rose from about 38% to 73% of the weekly allowance across the Sep 24 work, after about 20% before it.

## 3. Salvage map

Each initiative in `47f9d2f..working tree` with a recommendation. Line references are to the current working tree.

| # | Initiative | Size | Depends on | Recommendation |
| --- | --- | --- | --- | --- |
| e | **Download replacement recovery**: a failed re-download no longer marks a complete saved episode failed; recovered at launch | ~36 lines, `PodcastDownloadCoordinator.swift:195,282,337,485,499` + tests | nothing | **Salvage** |
| f | **Margin audio path rebasing**: route Margin audio through the existing `resolvedApplicationSupportAssetURL` rebasing | ~25 lines, `Gate1AppModel.swift:15553` | nothing (the helper exists at 47f9d2f:13560) | **Salvage first.** Build 28's `resolvedInterjectionAudioURL` fails on absolute paths from an old container, so Margins stop playing after an update or restore. #109 describes exactly this. Top candidate for "rejoining margins". |
| — | **Staged paused seek**: stage the destination when no media player exists yet | `SessionEngine.swift:620`, `Gate1AppModel.swift:5273–5285` | nothing | **Salvage.** Also wire it into Build 28's `completeSkimBridge`/`cancelSkimBridge`, which have the same `media_seek_player_unavailable` failure on a restored paused session. |
| g | **Shortcut import #133/#136**: intent fix, model bridge, Listening Edition JSON normalization and clearer errors | `AddArticleShortcutIntent.swift:171–189`, `SpokenMarginsApp.swift:58–60`, `Gate1AppModel.swift:10995–11003`, `ListeningEdition.swift:75–152` | nothing | **Salvage** |
| — | **PDF download-stamp filter** (from `564a16d`) | `PDFStructuredTextExtractor.swift:85–92, 372–375` | nothing | **Salvage** |
| — | `82e61bc` QoL commit | small source diff | nothing | **Keep** (already the base of `codex/desktop`). Owner may want to validate first; the commit title says "untested". |
| c | **Packet import creates the podcast** when the publisher page resolver fails (uses the packet's enclosure) | ~60 lines, `Gate1AppModel.swift:9340–9408` | nothing (`acquirePodcastForImportedPackage` exists in Build 28) | **Salvage, optionally.** Caveat: it trusts a sender-supplied enclosure URL. |
| — | Margin player **no-progress watchdogs** (10 s) | `Gate1AppModel.swift:7978–7993, 8330–8346` | co-op state | Re-implement on Build 28's simpler flow if wanted; don't cherry-pick. |
| a | **Podcast-anchor reliability**: capture windows, evidence export, recipient transcript recovery, reconcilers, speech queue | ~3k+ lines across SessionKit and ~960 lines of the model | threads through record/finish/export | **Park on its own branch.** Serious work with good tests, but unshippable as is: see §4. |
| b | Conversation v2 (multi-parent) | ~400 lines | `34837c6` | **Revert** (park with co-op) |
| d | Co-op playback repairs and UI (direct Skim, Margin progress, skip-to-end, familiar-local) | ~300 lines of app code, +423 lines of tests | `564a16d`, `34837c6` | **Revert** (park); reuse the ideas, not the code |
| h | `CoopPacketGenerator` executable and `.syntheticTTS` case in the shipping builder | 127 lines + `Package.swift` | — | **Revert.** Test-fixture tooling in the production package. |
| — | `564a16d` conversation navigation, `34837c6` conversation v1 | ~1.3k lines of source | — | **Revert** (park). See the compatibility note in §4. |

## 4. Why not ship the co-op tree

**Compatibility.** Build 28 users would be affected.

- From `34837c6` on, exports attach conversation metadata. Per the reviewer, every export does. The manifest then requires `spoken-margins.conversation.v1`.
  - Build 28's archive reader only accepts the layer and embedded-text capabilities (`InterjectionPackageArchive.swift` at `47f9d2f`, line 91).
  - So **Build 28 recipients reject every packet a co-op build exports.** Two-parent packets additionally require v2.
- `currentSchemaVersion` stays 5, so a downgrade opens the database. But Build 28 drops the new Interjection JSON fields (`conversation`, capture windows, evidence checksums) when it re-saves a Margin.
  - After re-upgrade, a new random contribution ID is minted. That forks identity, and recipients' replies show "not received yet".
- Dirty binaries were installed reporting build 27. A binary from `34837c6` decodes v2 `parents` as nil.

**Anchor initiative defects** found in review, to fix before it ships anywhere:

- It hashes a ~100 MB episode with SHA-256 on the main actor: `Gate1AppModel.swift:8119, 8234, 8259`.
- The export gate treats empty evidence as degraded (`:15046`, `:15181`). Every older podcast Margin export therefore hits "positioning is still preparing".
- It reads `asset.localPath` without rebasing, so evidence goes "unreadable" after a container move.
- The real-time audio tap allocates a buffer and takes a lock per callback (`PostResumePodcastEvidenceCapture.swift:~222`).
- One recognizer failure suspends source ASR for the whole process (`SpeechRecognitionQueue.swift:~92`).
- A DEBUG probe branch still compiles into release (`:1004`, `:8194`).

**Architecture.** `Gate1AppModel.swift` grew from 16,268 lines (Build 28) to 18,526, with about 88 new stored vars and 93 new functions. `performSkim` went from 14 lines to six ordered branches.

Four playback state machines now share one `interjectionAudioPlayer`:

- summary bridge
- conversation navigation (lead-in / current / return point / cursor / thread queue)
- imported-commentary cue auto-play
- local recording playback

They carry four separate "should the source resume" flags. `returnFromConversation` (return to original position) has no UI entry point left. The 19:08 stall (seek accepted, snapshot `playing`, media clock frozen) was **bounded, never explained**. One unverified suspect: Margin playback reconfigures `AVAudioSession` (`.duckOthers`, `setActive`) on the main thread and nothing restores the source's session before `engine.resumePlayback()`.

## 5. Recommended recovery sequence

The owner decides; none of this has been done.

1. **Snapshot, don't discard.** Commit the entire co-op working tree, including untracked files, to a parking branch such as `park/co-op-2026-09-24`. Commit the `codex/desktop` worktree to its own branch as well; it is 62 untracked files. Push both.
2. **New lane from `47f9d2f`** for Build 29. Record it in `docs/release-lanes.md` (see §7).
3. **Port by hand, one commit each:**
   1. path rebasing (f)
   2. download recovery (e)
   3. staged seek, including the summary-bridge seek sites
   4. Shortcut #133/#136 (g)
   5. PDF stamp filter
   6. optionally `82e61bc` and packet-import fallback (c)

   Each should be a small diff reviewed on its own. Use `git diff 47f9d2f -- <file>` from the parking branch as the reference, not `git cherry-pick` of mixed commits.
4. **Set build 29 in `project.yml`, archive, and have the owner re-test rejoining margins on the phone.** This is the cheapest path to a better build than 28.
5. **Only then reconsider co-op**, and do it in a different order:
   1. Extract a single playback coordinator out of `Gate1AppModel` that owns source vs. Margin audio and the audio session.
   2. Reproduce and explain the frozen-clock seek on device.
   3. Build the smallest vertical slice: import one packet → hear one other person's Margin → podcast resumes at the right place. Have the owner try it before adding replies, multi-parent graphs, or synthetic packets.
   4. Make conversation metadata opt-in in exports (emit the capability only when a reply link exists) so older recipients can still import.

## 6. Structural problems to fix regardless of co-op

- **`Gate1AppModel.swift` is 18.5k lines**, about 37% of all app source, and `Gate1RootView.swift` is 5.6k. Every feature lands there, so every agent must read and patch it, and state machines collide. Splitting out playback/navigation is the highest-leverage refactor.
- **Artifacts are committed to git.** 9,009 of 9,643 tracked files, and 636 MB of the 657 MB tree, are under `artifacts/`. `.git` is 824 MB, including IPAs, dSYMs, `.xcresult` bundles and simulator log archives. Since Sep 1, commits touched 8,832 artifact files against 501 source files.
  - Proposed: `.gitignore` binary evidence (`*.xcresult`, `*.ips`, `*.logarchive`, `*.ipa`, `*.xcarchive`, screenshots and recordings). Keep only short markdown handoffs, or move evidence to the external drive used for `artifacts/test-runs`.
  - A history rewrite is optional and separate.
- **Governance documents have become a directive log.**
  - `docs/release-lanes.md` is 90 KB and opens with about 20 stacked "Owner … direction" blockquotes that supersede each other: usage floors of 85%, 80%, 75% and 70%, and "defer testing" versus "run full testing" on the same day.
  - `docs/staged-github-issues.md` is 103 KB and `docs/book-club-repository-protocol-plan.md` is 78 KB.
  - The podcast-anchor folder alone holds more than 45 handoff and audit files.
  - Agents spend a large share of usage reading and writing these. Proposed: rewrite `release-lanes.md` as a one-page current state (active lanes, current authorization, baseline) and move the directive history to an archive file.
- **Tests pass without exercising the product path.** The audit (`artifacts/validation/testing-audit-2026-09-24/audit.md`) is right that the conversation tests use a no-op audio client and assert queues, not audible playback. XCTest also stalled repeatedly before connecting, which led to 0-test "runs".
  - The owner's stop on scripted simulator testing is a reasonable response, but host tests alone will not catch audio-session or transport bugs.
  - For playback work, the working evidence is the owner (or an agent with real audio capture) on a device.

## 7. Guidance for future agents

- Start from this file, `AGENTS.md`, and the **top table** of `docs/release-lanes.md`. Do not read the directive preamble or the historical handoffs unless a task needs them.
- One agent, one small change, one reviewable diff. Do not run manager/implementer/auditor chains. The Sep 23–24 record shows they multiplied documentation and correction cycles without closing the owner's journey.
- Do not call something ready until the exact user journey has run once on the exact candidate. Counts like "484/484" are not readiness.
- Do not add owner-directive blockquotes to `release-lanes.md`. Update the lane table and one "current authorization" paragraph instead.
- Do not commit binary evidence. Write at most one short handoff per task.
- Anything touching Margin/source playback must name the audio-session and player ownership it assumes, and must not add another "resume source" flag to `Gate1AppModel`.
- Keep the package compatibility rule: a new build's exports must import into the last shipped build unless the owner explicitly accepts a break.

## 8. GitHub issues

130 issues: 76 open, 54 closed.

- **Labeling stopped around #52.** Owner-voiced issues #123–#143 are short and clear but untriaged.
- **No issue tracks "rejoining margins" or Build 28 feedback.** The nearest are:
  - #109 (open): context recovery fails because the source path goes missing after a container move. It matches fix (f).
  - #110, #71, #85 (closed; fixed in Build 27).
  - #122 (memory kill after a shared-Margin podcast).
  - #83 (remote resume while rendering).
  - Proposed: open one issue for Build 28 rejoining failures with the owner's exact steps.
- **Probable duplicates:**
  - #133/#136
  - #64/#73/#74
  - #70/#82
  - #88/#89 and #48/#51
  - #117/#118
  - #75/#96/#121
  - #93/#97/#131
  - #132/#141/#143
  - #129/#142
  - #105/#124/#138
- **Closable:**
  - #128 (test issue)
  - #130 (vague)
  - #81 (reconciled in comments)
  - #41 (screenshots obsolete after redesign)
  - #113 (not software)
- **Implemented locally but still open, awaiting owner validation (Sep 21 QoL):** #111, #123, #124, #125, #127, #129, #132, #134, #135, #137, #138.
- **Nine stale open PRs** from June–July: #1–#7 and #20. There have been no PRs since #50 (Aug 3).
- Several issues are 5–14k-character agent walls (#64, #70, #76, #84, #88–#91, #93) with "Build 27 owner reconciliation" preambles. Consider trimming each to a short current-state summary.

## 9. Branches and worktrees

- **`codex/desktop`** (`/Users/colemiller/.codex/worktrees/spoken-margins-desktop/spoken-margins-native`, at `82e61bc`):
  - Contents: a macOS menu-bar companion (`App/SpokenMarginsDesktop`), a Safari extension, build scripts, three docs and about 11k lines of Swift. Almost all of it is **untracked**; only `release-lanes.md` and one line in `SupertonicNarrationRenderer.swift` are tracked edits.
  - It is independent of co-op, but it should be rebuilt against whichever SessionKit survives. **Commit it before any cleanup.**
- **Local `codex/provisional-next`** is `82e61bc`, one ahead of `origin` (unpushed).
- **Fully merged into Build 28, safe to delete:**
  - testflight-triage (after the Build 28 tag)
  - external-testflight-readiness
  - gate1-validation-readiness
  - gate2-validation-closure
  - gate3-watch-from-main
  - gate4-foundations
  - gate5-validation
  - import-export-conveniences
  - interactive-onboarding
  - legacy-ios16-app-target
  - playback-spine-refactor
  - spotify-numbered-episode-resolution
  - steward-surface-contract-scaffold
- **Unmerged but historical:** the two `archive-*-mixed-before-cleanup` branches, `gate3-watch-validation` and `rescue-mixed-gate-work` (the same June Watch commits), plus `sharingV1`. Tag, then delete.
- **Review before deleting:** `watch-capture-next`, `mvp-local-foundation-models`, `issue-38-article-shortcut`.
- **Remote:** about eight one-commit June/July contract branches are unmerged and stale.
- **Stray root files** committed in `564a16d`: `spoken_margins_issue_history_2026-09-22.docx` and `spoken-margins-field-notes-2026-09-22.md`.

## 10. Open questions for the owner

1. Is co-op paused, or should it restart after the playback refactor? This determines whether conversation v1 (`34837c6`) is parked or revived.
2. Should podcast-anchor reliability continue as its own lane? It is the most substantial parked work, and #27 is a real product problem.
3. May the next lane be created from `47f9d2f`, with the parking branches pushed first?
4. Should binary artifacts leave git going forward, and should history be rewritten to shrink the 824 MB repository?
