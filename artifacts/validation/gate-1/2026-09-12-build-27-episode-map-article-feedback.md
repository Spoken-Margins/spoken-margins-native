# Build 27: episode-map collision and Noahpinion reading feedback

## Evidence and scope

Owner reports internal Build 27, not necessarily the newer uncommitted PKM work. Received diagnostics exported at `2026-09-12T21:25:20Z` and the AI handoff for **Get the Middle East out of my politics!**. Attachment originals remain in the Codex task; this record avoids copying the full article or device recording into repository history.

Recorded Build 27 source: `adeb923fc1d081b19dfe9d650b50ac9fb036535a`, tag `testflight/0.1-build-27`. The diagnostics contain `developerBuild=device-diagnostics-20260908-C`, not an immutable installed-source identifier. Build attribution is owner-reported and consistent with the release record, not independently proven by that field.

This is a diagnosis and feedback record. No runtime fix, device-data migration, product acceptance, or distribution is claimed. Existing PKM working-tree changes are preserved.

## 1. Wrong podcast Listening Map — high-priority identity defect

**Owner report:** importing **I Can't Stop Thinking About the End of History** from the followed Ezra Klein Show feed displayed a 21-scene map about AI data centers and backlash. The owner previously generated a full map for an older Ezra Klein/Hard Fork episode and suspects reuse of that map. This concerns a Listening Map, not imported listener Margins.

**Observed diagnostics:** `sourceEntryImport:entry-0a353c15e5bd17f0ec76dea1` points to `item-source-default`; `lastBackgroundSourceLinkImport`, podcast download, and local-audio Skim readiness also identify that item. The attachments do not contain both episode records or the 21-scene map, so its original episode remains unconfirmed.

**Code-supported mechanism:**

1. `Gate1AppModel.importFollowedSourceEntry` sends the playable enclosure URL through source-link import.
2. `PublicPodcastLinkResolver` derives direct-audio titles from the URL filename, without its extension. Distinct URLs ending in `default.mp3` both produce the title `default`.
3. `SessionEngine.resolvedSourceItemId` derives identity from the show/title slug, truncated to 80 characters, without episode URL or feed-entry identity. Those candidates both become `item-source-default`. Long titles sharing the first 80 slug characters can also collide.
4. `importResolvedSourceLinkInBackground` saves the new item under that ID. `SQLiteSessionStore.saveItem` upserts the record; existing maps remain separately indexed by item ID.
5. The app applies the actual feed title only after the initial import. A correct visible episode title therefore does not establish distinct identity. Map loading and episode-map directories use item ID.

**Assessment:** a concrete identity-collision defect exists and fits the diagnostics and reported symptom. Attribution of the 21 scenes to the particular older episode is an inference. Do not describe this as proven semantic/fuzzy matching between similar shows.

**Repair criteria:** establish durable episode identity independently of display titles; preserve repeat-import identity and legitimate metadata updates; prevent reuse of derivatives belonging to another source. Audit sessions, transcript, downloaded audio, private map, and summary assets as separate dependents. Existing collided data needs conservative recovery: do not blindly delete or relabel the old map/Margins when ownership evidence is insufficient.

**Required regressions:** two distinct enclosure URLs with `default.mp3`; title-prefix collisions; two followed feed entries; repeat import of the same episode; first episode with an existing map followed by a second episode without one; persistence/relaunch; preservation of original sessions and derivatives. A fix that only changes the visible title fails this boundary.

## 2. Noahpinion repetition — present in source text

**Owner report at 79%:** the same statistic about reduced sensitivity to oil shocks was spoken twice.

**Confirmed in supplied handoff:** the Blanchard/Gali passage occurs first as one combined block and then again as separate paragraphs. An earlier disengagement quote is also duplicated. Repetition exists in exported source text, independently of any possible playback replay.

**Candidate mechanism:** the native emergency fallback in `AppOwnedReadablePageExtractor.semanticFallbackJavaScript` renders both `blockquote` containers and descendant `p` elements. That can emit a combined quote followed by its paragraphs, matching the observed shape. The bundled JavaScript fallback already skips paragraphs inside blockquotes/list items, but the native fallback does not. The attachment does not identify which extraction path ran, so this remains a candidate cause rather than proof of execution.

**Repair criteria:** test nested quote/list extraction at the actual native fallback boundary and compare with the primary extractor. Preserve intentional repeated prose; global string deduplication is not a sufficient repair. Correcting extraction must not silently rewrite already-anchored article text without preserving Margin positions.

## 3. Noahpinion text damage and incomplete-content signals

The supplied source repeatedly contains broken phrases such as “The. economy” and “How to fix. foreign policy,” plus “policy (. …)”. `SpeechTextNormalizer.removeLinks` treats dotted abbreviations as bare domains. A local Swift/Foundation execution of the exact current regex produced:

```text
The U.S. economy -> The . economy
policy (i.e. monetary policy) -> policy (. monetary policy)
example.com ->
Claim 2.5 -> Claim 2.5
```

This confirms an abbreviation-deletion mechanism consistent with the attachment. Preserve abbreviations, decimal references, and readable link labels while continuing to handle actual URLs correctly.

The source ends with **Continue reading this post for free in the Substack app**, and that call to action becomes a 99% listening chapter. The session reports 100% of the imported text. That does not establish that the full publisher article was imported. Content completeness and call-to-action filtering need their own extraction checks; this record does not infer access to unavailable publisher text.

## 4. Paragraph pauses — rejected by owner, cause unresolved

**Owner report at 20%:** unacceptable pauses, apparently at paragraph boundaries; asks whether Supertonic render joining is responsible. Diagnostics identify Supertonic M2 at rate 0.88 and article startup readiness `ready_2_of_55`.

Distinguish three candidate causes: silence already present in rendered audio, player transition delays between available chunks, and waiting for the next chunk to finish preparation. None is established by these attachments. The embedded 1,200-event recording spans `12:47:30.765Z`–`12:58:24.115Z`; diagnostics export time is later, and there is no demonstrated correlation to the complained-about boundaries. Do not attribute the pauses to Supertonic alone or treat source-text duplication as their explanation.

Needed evidence: rendered chunk tails/heads and durations, next-chunk readiness, and playback boundary timestamps for the affected article. Compare fully prepared playback with opening-buffer playback. Stop repeating unchanged diagnostics without a boundary trace or audio sample capable of distinguishing those causes. Only the owner can accept the resulting audible flow.

## Current-source comparison and verification boundary

Compared the Build 27 tag against current source: `resolvedSourceItemId`, background resolved-source import, direct-audio filename title derivation, `SpeechTextNormalizer.removeLinks`, and native semantic fallback are unchanged. The newer PKM work therefore cannot be credited with fixing these inspected mechanisms.

Performed read-only source/diagnostic inspection, exact-tag function comparison, and the focused Foundation regex reproduction above. No app/package/release suite was run for this documentation-only record; no runtime was changed. The podcast collision and damaged abbreviations have implementation evidence; extraction-path attribution and audible-pause cause still require focused reproduction. All reported affected product flows remain rejected or pending owner recheck, not human-validated.

## Authorized implementation follow-up

The owner subsequently requested fixes for both the article and podcast. The diagnosis-only statements above describe the earlier pass, not the current implementation.

Implemented on `codex/provisional-next`, base commit `ac85375759f2533f320225affef9fb3296bbbf9e`, alongside the preserved uncommitted PKM work:

- Podcast item identity now hashes the subscription/feed-entry identity for followed imports, or the complete resolved audio URL for ordinary imports. New IDs cannot adopt a legacy title-slug's private map, transcript, session or cached assets. Query-string differences and long shared title prefixes are covered.
- Reimport retains the stored episode and its media edition. Publisher chapters do not overwrite an existing map during import; transcript discovery and feed-description chapters do not attach a different resolved URL's evidence to retained media.
- Native and bundled semantic fallbacks emit only the outermost selected DOM blocks, preventing quote/list descendants from being emitted a second time. Identical sibling passages remain intact. A synthetic nested quote/list fixture executes the actual native JavaScript literal as well as the bundled fallback; it reproduced the old defect in the prior investigation.
- Bare-domain cleanup preserves single-letter dotted abbreviations and their source-offset projection. The Markdown intake regression also checks that `U.S.` survives in the title and body.
- Reimporting changed readable-page text without an explicit target creates a separate content edition. Original text, session position and map remain unchanged; repeated corrected intake returns the same corrected edition. No existing device text or Margins were rewritten.
- Followed-article diagnostics now retain the extractor name to distinguish the three extraction paths in a future report.

### Verification

The first fast attempt stopped on a missing initializer argument in the new test. The focused persistence test then exposed timestamp precision loss in its `Date()` fixture; fixed whole-second fixture dates preserve a strict full-record comparison. Neither failed attempt counts as a pass.

Full fast gate passed: `artifacts/test-runs/20260912-215945-641710-fast/manifest.json`. It executed 296 passing package tests, one explicitly allowed benchmark skip, 12 passing browser tests and 10 passing runner tests; contract, surface and inventory validators passed. Input-content SHA-256: `e6bfd1c2cae9e24eae35fe07b9494e10999a639981b80ed7cbb3a35560c8d932`.

The first app build picked up the older standalone `SessionKit.swiftmodule` in its products directory while the rebuilt package module was emitted in `PackageFrameworks`; this reported the new import parameter as unavailable. A scoped `xcodebuild clean` succeeded. The subsequent clean app build and bundle checks passed. Its 420-test execution passed the new feed collision case, but an existing shared-podcast test caught repeat import retaining the trash flag. Fixed explicit reimport to restore a trashed item while preserving its media and maps; the article regression now also checks restoration. The earlier fast result precedes this final recovery correction. Final app-test and build results are recorded below when complete.

### Final checked source

Final fast and app verification passed after the restoration correction:

- Fast: `artifacts/test-runs/20260912-220638-569756-fast/manifest.json` — 296 passing package tests, one declared benchmark skip, 12 browser tests, 10 runner tests, and contract/surface/inventory validators.
- App: `artifacts/test-runs/20260912-220704-579504-app/manifest.json` — 420 app tests passed with no skips or failures, plus build-for-testing and bundle checks, on iPhone 17 Pro / iOS 26.5 simulator (`856FA6EF-5E03-4120-939B-F0EF42A804E8`).
- Both use final input-content SHA-256 `f53f12ddc65c4954895d79777dafe4f5bc156d2b9d87ba2ac7cabaf50ad8822f`; no source changes were made during either run. Documentation-only updates follow separately.
- Speech canary: `artifacts/test-runs/20260912-220835-492762-speech-canary/manifest.json` passed on the same final source and simulator, including exact emoji-article playback, pause/resume and completion. This is regression evidence for speech text handling, not an audible assessment of the Noahpinion article.
- Production `SpokenMarginsApp` generic iOS Simulator and generic iOS device builds both passed (exit 0, `BUILD SUCCEEDED`). Raw integration-build logs are `artifacts/test-runs/20260912-episode-article-builds/simulator.log` and `device.log`; these use the separate `.build/verification/SpokenMarginsEpisodeArticleRepair` DerivedData directory and `-jobs 4`. Deployment target remains iOS 18.0, iPhone/iPad. No Watch or audio-adapter/inference code changed; broad UI/release gates and physical-device acceptance are not claimed.
- Final status: the identity, nested extraction, abbreviation and safe-reimport repairs are **implemented** and **verified**. The owner's exact source-page extraction, legacy-map ownership recovery and audible pause experience remain pending; no **human_validated** status is claimed.

### Recovery and remaining limits

These changes are not installed in the owner's Build 27 binary. The project still declares version 0.1 (27); the dirty source is not the tagged uploaded Build 27. No distribution, commit or device reinstall was performed.

After a candidate containing these changes is installed, import the affected episode again using its episode/audio link (or its followed entry if still offered). The new item should initially have no older private map. Retain the old item and its Margins until map ownership can be established; the fix deliberately does not guess where the 21-scene legacy map belongs. Direct imports and followed imports can be separate items, and a changed direct URL can also create a separate item. A changed feed enclosure does not automatically replace the accepted edition's audio.

Recapture the Noahpinion page using the browser text import route. Corrected text gets a separate edition and freshly prepared narration; the older duplicated text and its Margins remain accessible. No Library reset or deletion is required. The regression fixture is synthetic, not a claim that the exact live publisher page or the owner's authenticated extraction path was exercised.

Paragraph pauses remain unresolved. Inspected code inserts 120 ms at sentence-chunk transitions (50 ms at comma boundaries), uses a fresh AVPlayer for the next rendered chunk, and can wait if its render is unfinished. The renderer separately inserts 300 ms between its internal text chunks. This identifies possible contributors, not the duration or cause of the reported unacceptable pause. No audio-timing or inference code was changed without correlated audio/readiness evidence. Publisher access/truncation and the exported Substack call-to-action chapter also remain separate limitations.

The owner clarified during implementation: **“I only tried it soon after import.”** There is no fully-prepared replay observation yet. This raises the relevance of opening-buffer readiness as a candidate; it does not establish render starvation or rule out silence/player-transition latency. Prioritize the fully-prepared comparison before changing audio timing.

Future owner recheck, once an install is prepared: verify the affected podcast's new item has no unrelated scenes; import two distinct followed episodes and confirm the first map remains isolated; recapture the article and check quotes/statistics occur once and `U.S.` is retained; check that the original Margin context is unchanged. Audible pauses need a separate fully-prepared-versus-opening-buffer comparison and boundary-correlated diagnostic capture. These are pending checks, not product acceptance or a request to test the still-installed older binary.
