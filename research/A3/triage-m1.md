# A3 M1: triage proposal for the open issues

Prepared 2026-09-28 from `next` at `55abf7a`. It covers all 106 open issues, excluding the stream tracking issues #184–#205. **Nothing has been changed on GitHub.** M2 applies only the rows the owner approves.

## How to read this

**States**

- `stream:<id>`: add the `stream:<id>` label. The issue stays open.
- `close-done`: close as completed. The reason cites the commit and the build it shipped in.
- `close-dup-of-#N`: close as a duplicate of #N. Anything left over is folded into #N's thread.
- `close-obsolete`: close as not planned.
- `park`: add a `parked` label. It stays open with no stream.
- `owner-check`: the fix shipped, but the issue waits for your device pass, not a stream (brief: "Issues labeled `status: needs-human-validation` belong to the owner's next device pass"). This state isn't in the brief's four: rows labeled `status: needs-human-validation` can't close without you, and `owner-check*` rows would close without a phone check.
  - A plain `owner-check` means the issue is already labeled `status: needs-human-validation`. No closure is proposed.
  - `owner-check*` means the fix shipped but the issue is unlabeled. M2 would add the label.

**Build facts used for citations**

- Build 29 = tag `testflight/0.1-build-29` (`fcc4974`).
- History was rewritten before Build 28. Work from August shipped in the `testflight/0.1-build-25` to `-27` tags, and its code reaches Build 28/29 through the squashed commit `69f9ce0`.
- For each close-done row I checked with `git grep` that the code is still in the Build 29 tree.
- "On `next`" means merged but not yet shipped (Build 30 candidate).

**Counts**

| State | Issues |
| --- | ---: |
| stream | 49 |
| owner-check (21 labeled + 5 unlabeled) | 26 |
| park | 18 |
| close-dup | 7 |
| close-done | 5 |
| close-obsolete | 1 |
| **Total** | **106** |

Per stream: A2 1 · B1 5 · C1 3 · C2 3 · C4 6 · D1 1 · D3 4 · D4 7 · D5 9 · E3 4 · F1 2 · G1 1 · G2 3.

## Triage table

| # | Title | Proposed | Reason |
| --- | --- | --- | --- |
| 183 | Low Power/charging switches narration to system voice | stream:C2 | C2 M1; `allowsRendering` refuses Supertonic in Low Power Mode with no explanation in the UI. |
| 182 | Skim to next Margin or chapter, skippable lead-in | stream:D5 | D5 M2 (needs A2 M2 coordinator); keeper for #137. |
| 181 | Level spoken Margins to source loudness | stream:D5 | Listed in D5; loudness measure is host-testable in SessionKitAudio. |
| 180 | Native text stuck starting after second Margin | stream:D5 | Listed in D5; reproduced at `a2d4275` (Build 29 + export-only commits), so Build 29 likely has it. Candidate for A2 M2 coordinator tests. |
| 179 | Feed parser drops episodes without `<link>` | stream:B1 | Guard still at `FeedParser.swift:212` on next; small host-testable quick win. |
| 178 | Recover private-feed shared Margin by pasting own feed | stream:C4 | Recipient side of private feeds; needs #177 first. No brief names it yet. |
| 177 | App never stores episode GUID for matching | stream:C4 | README assigns #177 to C4 after #168. |
| 176 | Rank and categorize followed sources from signals | stream:D3 | D3 outcome. |
| 175 | App Store submission checklist | stream:G2 | Listed in G2; mostly owner tasks. |
| 174 | Invite-only beta with PKM creators | stream:G2 | Listed in G2. |
| 173 | Legal setup before public release | stream:G2 | Listed in G2; owner-only tasks. E3 depends on its answers. |
| 172 | Send Margins to Readwise as highlights | stream:D4 | Listed in D4. |
| 171 | Spoken Margins to notes folder as Markdown | stream:D4 | Listed in D4; beta slice of #16. |
| 170 | Background refresh of followed feeds | stream:B1 | B1 brief: B1 does it or hands it to D3 with a note. |
| 169 | Share Margins as app/install links | stream:D4 | Listed in D4; needs B4 M1 server. |
| 168 | Shared packets can leak private feed URLs | stream:D4 | D4 M0. Fix `c862be4`/`a2d4275` is on next, not shipped. Close when Build 30 ships. |
| 167 | Preview next Margin on playback screen | stream:D5 | Listed in D5; one experience with #182/#115. |
| 166 | Clock freezes after shared Margin on streamed podcast | stream:C4 | Not fixed; `cef86bc` (on next) only adds stall logging. Keep until a freeze is caught. |
| 165 | Mini player shows open item's title | owner-check | Fixed in Build 29 (`72466db`). |
| 163 | Mic-denied banner says "interjections" | owner-check | Fixed in Build 29 (`2c69c9b`). |
| 162 | PDF download stamp read with page number | owner-check | Fixed in Build 29 (`643ec38`, `82c115d`). |
| 161 | Main thread freezes every ~17 s | owner-check | Fixed in Build 29 (`f2203d4`, `373c05a`). |
| 160 | Stream resume after Margin takes 2.6–9.3 s | owner-check | Fixed in Build 29 (`650e235`, `2a1aed0`). |
| 159 | "Play this moment": lead-in, Margin, continue | stream:D5 | `47db6e2` on next, simulator-verified; close after your Build 30 check. D5 builds on it. |
| 158 | Tap shared Margin in Timeline plays its moment | stream:C4 | Anchor slice 6; `ad67a52` on next. Close after your Build 30 J5 check. |
| 157 | Omny packet import fails "ambiguous" | owner-check | Fixed in Build 29 (`47e27a9`). |
| 156 | Source-context transcription fails on streamed podcasts | stream:C4 | `c6f73f9` on next, simulator-verified; close after your Build 30 check. |
| 155 | Capture diagnostics overwritten, colliding, lost | owner-check | Fixed in Build 29 (`6525cf9`); goes to C4 if the check fails. |
| 153 | Following "Paste a feed link" doesn't paste | owner-check | Fixed in Build 29 (`dc878a8`). |
| 152 | URL fields have autocorrect on | owner-check | Fixed in Build 29 (`b6cd5ad`). |
| 151 | Tap targets under 44 pt; cramped mini player | stream:D5 | D5 acceptance (44 pt, reach); D1 carries the rule into the look. |
| 150 | Recipient test session button in release builds | owner-check | Fixed in Build 29 (`3838918`). |
| 149 | Item page: Start listening out of reach | stream:D5 | D5 acceptance (#148/#149/#151). |
| 148 | Recording: Save within reach, guard double tap | stream:D5 | D5 acceptance (#148/#149/#151). |
| 147 | Share Margins: skip extra screen, pin buttons | stream:D4 | D4 outcome "two taps to share"; carries what's left of #125. |
| 146 | Following: discoverable swipes, undo, unfollow, scroll | stream:D3 | Listed in D3; already absorbed #143. |
| 145 | Paste & go: one bottom clipboard button | stream:B1 | B1 reach item; its dependency #144 shipped in Build 29. |
| 144 | Link field rejects article URLs | owner-check | Fixed in Build 29 (`d0de194`); D6 owns the stale Help text. |
| 142 | End-of-episode screen: no voice Margin option | stream:D4 | Still written-only on next (`Gate1RootView.swift` ~2236); finish → share flow. |
| 141 | Following: feed management pushes items below fold | stream:D3 | Listed in D3. |
| 140 | Browser demo web app with good TTS | park | Later; no stream owns a web client. |
| 139 | Desktop quick-listen companion | park | Later; prototype is parked on `codex/desktop`. |
| 138 | PDF citation/footnote markers read literally | stream:C1 | Build 29 (`82e61bc`) handles `[n]` only; plain `(17)` remains, so the corpus should judge. |
| 137 | One-tap skip to next chapter | close-dup-of-#182 | Button shipped in Build 29 (`82e61bc`); your 09-26 comment folded it into #182. |
| 136 | Shortcuts can't launch spokenmargins URL scheme | owner-check | Fixed in Build 29 (`19d25da`), same fix as #133; close both after one Shortcut run. |
| 135 | Pasted formatted text generates no chapters | owner-check* | Shipped in Build 29 (`82e61bc`), never checked: paste text with headings, expect chapters. |
| 134 | Highlight current chapter in Listening Map | owner-check* | Shipped in Build 29 (`82e61bc`); D5 restyles it if needed. |
| 133 | Shortcut → ChatGPT → import flow | owner-check | Fixed in Build 29 (`19d25da`). |
| 130 | More interesting way to filter items | close-obsolete | One-line pointer to Digest; the D3 brief now carries the idea in full. |
| 126 | Create Margin on playing item via Siri | park | Later; see synergy list. |
| 125 | Item-level share on Margins screen | owner-check | Group Share shipped in Build 29 (`82e61bc`); rest is in #147. |
| 124 | PDF bibliography becomes listening-map chapters | stream:C1 | Build 29 `82e61bc` trims only new imports, conservatively; C1's corpus should include this PDF. |
| 123 | Mark Complete banner doesn't dismiss, too tall | owner-check* | 10 s auto-dismiss shipped in Build 29 (`82e61bc`); banner height not addressed (→ D1/D2 if it still matters). |
| 122 | Memory kill: shared-Margin podcast → native text | stream:A2 | Releasing the previous item belongs to the M2 coordinator's teardown; needs your device repro first. |
| 121 | Watch gestures for Margin capture | close-dup-of-#96 | Sub-question of #96 (review §8 group #75/#96/#121). |
| 120 | Onboarding recordings as beta QA gate | stream:G1 | G1's regenerated guides are this. |
| 118 | Headphone remote remap for bookmarks | close-dup-of-#117 | Depends on #117 and is one capture path of it (§8 pair). |
| 117 | Lightweight bookmarks with Lock Screen capture | park | Needs A2 M2 first so capture isn't another playback path. |
| 116 | Render frontier on the scrubber | owner-check* | Shipped in Builds 28–29 (`69f9ce0`, `preparedFraction`). |
| 115 | Show Skim destination before skipping | stream:D5 | "Skim to 18:42" shipped (`69f9ce0`); percent, Live Activity and VoiceOver remain for the redesign. |
| 114 | "Unplugged" local-only edition | park | Owner product decision, not stream work. |
| 113 | Post-launch email to margin.fm founder | park | Owner to-do gated on App Store launch (§8 calls it not software; close-obsolete if you track it elsewhere). |
| 111 | TTS mangles defanged domain lists | owner-check* | Shipped in Builds 28–29 (`93f97e1`, SpeechTextNormalizer); needs a listening check. |
| 109 | Margins as actionable scoped workspace | owner-check | Build 29 repairs (`13fad72`); leftovers go to D2/D4 after the check. |
| 108 | Library hierarchy, filters, compact Now Playing | owner-check | Icon repair in Build 29; unbuilt additions (default filter, sort by Margins) go to D2 after. |
| 107 | Item Detail hierarchy and actions | owner-check | Accepted in Build 27 except scrolling, which #93 tracks. |
| 106 | Swipe navigation doesn't track the finger | stream:D1 | Navigation-direction question; listed in D1. |
| 105 | Narrate meaningful PDF figures | stream:C1 | Keeper for figures (§8 group #105/#124/#138); listed in C1. |
| 97 | Quick Add main-thread hitches | close-dup-of-#93 | You accepted Quick Add in Builds 26/27; only profiling remains, which #93 covers. |
| 96 | Watch Margin capture with iPhone locked | park | No stream owns Watch; keeper of the Watch-capture group. |
| 93 | Scrolling jank under realistic load | owner-check | Build 29 recheck requested 09-25. |
| 89 | Generate Skim scenes, summaries, eligibility | stream:E3 | On-device scenes seen in Build 27; eligibility gates feed E3 maps. |
| 88 | Portable Listening Map scenes contract | stream:E3 | Proposal transport shipped (`f96194a`, Builds 25–27); the full contract is E3's seam. |
| 87 | Sleep timer, timed and end-of-chapter | close-done | Shipped in Build 25 (`9caf7d0`, `SleepTimerState`); in Build 29's `PlaybackScreen` (Extend 15 min, End of Chapter). |
| 83 | Native text unresumable after AirPod pause | stream:C2 | Fix `e0bcff9` shipped in Builds 21–27; remaining risk is the fallback voice dropping speed silently (C2 M1). |
| 82 | Classroom assignment and return packets | close-dup-of-#70 | Package-only pilot slice of #70 (§8 pair). |
| 80 | App-observed source coverage ledger | park | Classroom-only; see synergy list. |
| 78 | Canonical PDF chapters and front matter | owner-check | `05199c8` shipped in Builds 21–27; C1's corpus can supply the evidence. |
| 77 | Engagement-based follow suggestions | stream:D3 | Suggestions shipped (`318a22f`, Build 25); the rest is ranking acceptance. |
| 76 | Feed subscriptions, inbox, OPML | stream:B1 | Your 09-25 scope: OPML from onboarding (B1). The per-feed inbox setting goes to D3. |
| 75 | Untethered Apple Watch playback and sync | park | No Watch target in Build 29; no stream owns Watch. |
| 74 | Background preparation only while charging | close-dup-of-#64 | Shipped in Build 25 (`318a22f`, `31eab6a`); only device measurements remain, folded into #64. |
| 73 | Power-aware TTS preparation window | close-dup-of-#64 | Accepted in Builds 26/27 (`9caf7d0`); only measurements remain, folded into #64. |
| 72 | One offline-storage budget for all media | close-done | Shipped in Build 25 (`31eab6a`), accepted in Build 27; `OfflineStorageLedger` in Build 29. The Watch part stays in #75. |
| 70 | Classroom assignments and participation receipts | park | Epic with no stream; see synergy list. |
| 69 | Onboarding: starter podcasts, guided tour | stream:B1 | B1's outcome; the tour shipped, the starter board didn't. |
| 68 | Tell apart my, shared and source Timeline entries | owner-check | `0b077f1` (Build 27) plus later repairs; recheck on Build 29. |
| 64 | Durable prepared audio, Lock Screen scrubbing | stream:C2 | Keeper for the remaining prepared-audio evidence matrix (absorbs #73, #74). |
| 61 | DRM-free EPUB import with chapters | close-done | Shipped in Build 25 (`9caf7d0`, `2abe191`, SessionKitEPUB); still in Build 29. Open a new bug if a book fails. |
| 56 | On-device summary rejects 9-Margin session | owner-check | `35b1436`, `a368bc7` (Builds 19–27); recheck on Build 29. |
| 51 | Spike: server-hosted AI Listening Maps | stream:E3 | E3 brief names it as the earlier spike. |
| 49 | Desktop browser extension for web Margins | park | Post-MVP; desktop is parked. |
| 48 | Semantic links and cross-item maps | park | E1 lists #48 as out of scope until after E1 M3. |
| 35 | Bring Spoken Margins to Android | park | iOS-only for now; its scope is stale (mentions OpenAI streaming). |
| 34 | Remove Kokoro/MLX; Supertonic render identity | close-done | Shipped in Build 25 (`9caf7d0`, `318a22f`); `git grep -i kokoro` finds nothing in App/Packages at Build 29 (docs only). |
| 27 | Resolve shared podcast anchors across editions | stream:C4 | The anchor plan's own issue; effectively C4's tracker. |
| 26 | AI synthesis across co-op Margin layers | stream:F1 | Essentially F1 M4. |
| 25 | ActivityPub as a shared-Margin transport | park | B4 and F1 mention it only as optional. |
| 24 | Curated creator commentary editions | park | E3 lists it as out of scope. |
| 23 | Register connection claims, recurrence receipts | park | Needs a server; no stream. |
| 22 | Spike: biometric signing for sharing | park | F1 lists #22 as out of scope for now. |
| 21 | Anchor Margins to external audio via mic | park | Post-MVP spike; see synergy list. |
| 19 | Layered asynchronous co-op conversations | stream:F1 | F1's core outcome; reply lineage exists only on parked branches. |
| 18 | Import and listen to another person's layer | close-done | Recipient flow accepted in Build 25 and again in Build 27 (`0b077f1`); `SharedMarginRow` in Build 29. Leftovers are tracked in #68 and #93. |
| 16 | Export Margins as Markdown for PKM | stream:D4 | Listed in D4; export shipped, "Configure Margin Output" profiles remain. |
| 14 | Excerpt rights, attribution, sharing policy | stream:E3 | Direct sharing accepted 09-12; what's left is the community-server rights gate for E3 M3. |

## Stale issues with real synergy (15)

These stay in the state given above. M2 would add one comment to each, pointing at the stream, and a one-line note on that stream's tracking issue.

| # | Helps | How |
| --- | --- | --- |
| 80 | D3 | Its seek-aware, no-double-count listening semantics are a ready spec for the engagement signals D3 M2 must log. |
| 51 | E3 | Its precedence (publisher chapters, then existing map, then generated) and "never expose full transcripts" rule are ready acceptance rules for E3's server maps. |
| 26 | F1 | Its risk list (misattribution, disagreement laundered into consensus, excluded layers leaking to a provider) is F1 M4's acceptance checklist. |
| 25 | B4 | Its threat model (addressing isn't encryption, server retention, best-effort deletion) feeds B4 M1's privacy wording decision. |
| 114 | B4 | Its "no developer-controlled data plane" wording and allowed-hosts policy are a privacy baseline for the bridge server. |
| 70 | F1 | Shaping F1's reply packets so one "assignment" parent can have many returns keeps classrooms cheap later. |
| 23 | E1 | E1's structured "claim" is the payload a later claim registry would consume unchanged, so export claims in a stable shape. |
| 48 | E1 | E1's claim, question and referent forms are the natural nodes for cross-item links. Note it on E1's tracker instead of reopening the research. |
| 21 | B3 | When B3 can't find the podcast for a YouTube link, "external listening" by mic buffer is the honest fallback to offer later. |
| 117 | E2 | Cheap bookmarks are low-cost Margin signals for the weekly review, once A2 M2 lands. |
| 126 | D5 | Once A2 M2 gives "the playing item" one owner, a Siri App Intent for "add a Margin here" is a thin wrapper. |
| 140 | G2 | A no-install web demo is a candidate acquisition channel for G2 to test. C2's fallback voice is its prerequisite. |
| 24 | G2 | One owner-made commentary packet is a cheap inbound-content test of creator editions. |
| 113 | G2 | margin.fm is a comparable and partner lead for G2's early-adopter map. |
| 120 | G1 | Its walkthrough list (Spotify follow, Apple follow, article add, Margin, share) is G1's first guide set and acceptance checklist. |

## Notes for M2

- **Needs your say before closing:**
  - The 21 labeled `owner-check` rows can't close without you.
  - Seven fixes shipped in Build 29 were never labeled (#111, #116, #123, #134, #135, plus #124 and #138, which are partial and go to C1). If you approve, M2 adds `status: needs-human-validation` to the five full fixes.
- **Close on Build 30:** #156, #158, #159 and #168 are fixed on `next` and stay with their stream until Build 30 ships and you check them.
- **Long bodies that stay open (>~4,000 characters)** get a short current-state comment in M2, without editing your text:
  - #14, #16, #19, #21, #27, #49, #64, #69, #70, #75, #76, #77, #78, #83, #88, #89, #93, #96, #107, #108, #109, #111, #114, #117, #183.
  - Also #22 and #116, which are borderline.
- **Missing briefs:**
  - No brief names #178; C4 or D4 should list it.
  - #122 (memory kill) has no brief home; this table puts it in A2 M2.
- **§8 pairs kept as two issues, not duplicates:**
  - #88/#89: contract vs pipeline, both E3.
  - #48/#51: #51 goes to E3, #48 is parked.
  - #133/#136: one fix; close both after one Shortcut run.
  - #129, #131, #132 and #143 from §8 are already closed.
