> Implementation update: Reader and Raindrop.io are now the selected adapters. The earlier Instapaper preference below is historical: the owner has no approved developer credentials, and current get_text documentation requires an Instaparser key for non-personal use. Raindrop uses a free account’s personal integration token and imports original website text, not paid archives. Live account testing remains pending. See `docs/pkm-workflows.md`.

# Personal knowledge management product plan — September 12, 2026

The product direction is now post-MVP iteration toward personal knowledge management users: consume saved material privately, capture useful thoughts, and get those thoughts into the user's existing notes system. Historical `post-mvp` labels are not a reason to exclude a candidate. The owner requests assessment and planning here; this document does not activate implementation scope, a new branch, distribution, or a paid offering.

The strongest first increment is reliable automatic Markdown delivery, followed by a user-controlled Shortcut → portable item and Listening Map → listening workflow, then read-it-later intake. These extend existing foundations instead of rebuilding them.

Owner clarification, September 12: the user chooses the generation model and may create a Shortcut or adapt a downloadable draft. Local inference is an option, not a restriction on externally generated maps. The portable output must work without background generation in Spoken Margins. Readwise Reader remains first, and a service usable with a free account is also required; the owner plans a Reader trial or month, not indefinite paid testing.

Companion artifacts: [all 56 open issues](pkm-issue-inventory-2026-09-12.md) and [bounded owner test procedure](../artifacts/validation/pkm-audit-2026-09-12/owner-test-procedure.md).

## Evidence and decision model

Audit scope: all 56 open GitHub issues from `uncomposed/spoken-margins-native`, including bodies and comment history, retrieved September 12. “Incomplete” is interpreted as open, including unlabeled issues. Closed issues are used only where current reconciliation records establish accepted dependencies. This is not an audit of every unchecked box in closed issues or unfiled work.

Workspace: `codex/provisional-next`, clean at start, HEAD `ac85375759f2533f320225affef9fb3296bbbf9e`. Current internal binary is 0.1 (27), source `adeb923fc1d081b19dfe9d650b50ac9fb036535a`; external TestFlight is Build 21. [Release lanes](release-lanes.md) and [upload evidence](../artifacts/validation/testflight-external/build-27/build-27-testflight-upload.md) distinguish those audiences. Remote Git publication is blocked independently of the successful internal upload. External TestFlight availability establishes the owner's post-MVP premise; it does not establish a public App Store launch for #113.

| Layer | Constraint or resource | Decision implication |
| --- | --- | --- |
| User job | Saved reading accumulates; capturing and filing thoughts interrupts listening | Judge features by completed save → listen → capture → reuse journeys |
| Resources | One implementation stream; limited owner attention; device battery, memory and storage; no paid Spoken Margins offering | Reuse existing services, bound preparation, avoid recurring hosted inference cost |
| Execution | User-owned Shortcut/model service, share extension, main app, OS-scheduled work, Files provider, optional remote source service | Import a completed portable artifact independently of app generation; prove background behavior separately |
| Content | Source text, canonical chapters, generated scenes, user Margins, generated summaries | Preserve separate identities and provenance; generated summaries are not source quotations |
| Actors | Listener, app, OS, vault provider, optional read-it-later provider | Folder/API failure cannot invalidate a successfully captured Margin |
| Evidence | Code and automated checks establish implementation/verification; only owner use establishes human validation | Split issue scope; do not infer acceptance from a build or an unchecked historical checklist |

Ranking is qualitative: frequency of the user benefit, completion of the core journey, reuse of existing code, absence of service costs, and reversibility. Effort estimates below are relative engineering scope, not calendar promises. Assumption: the initial cohort values reliable retrieval and export more than social collaboration. Test that assumption with actual weekly use before investing in broader knowledge-graph features.

Existing assets verified by source inspection:

- `AddArticleShortcutIntent.swift` accepts URL/title/body and optional metadata, persists a browser handoff, and returns an opening URL intent. Its `openAppWhenRun=false` does **not** establish a silent background preparation workflow: `perform()` returns `OpenURLIntent`.
- `Gate1AppModel.swift` already has `configureBatchExportFolder`, security-scoped bookmark persistence, and manual batch folder export. `SessionMarkdownFileWriter.swift` writes atomic Markdown files with collision suffixes. This is useful manual export, not an idempotent automatic synchronization mechanism.
- `SessionExport.swift`, `LocalFoundationModels.swift`, the local map/Skim paths, `OfflineStorageLedger.swift`, and `AudioPreparationBackgroundController.swift` supply export, local AI, storage, and preparation foundations.
- No direct Reader/Instapaper/wallabag connector or completed ready-notification workflow was established by the scoped runtime search. Treat these as proposed integration work, not claims that no experimental code exists anywhere in history.

The September 12 [final owner acceptance](../artifacts/validation/gate-1/2026-09-12-build-27-acceptance.md) supersedes earlier six-retry notes for the accepted candidate. Do not ask the owner to repeat those unchanged features just because GitHub remains open. The later background callback fix retains its explicit physical-device recheck.

## Recommended feature clusters

| Order | User-visible cluster | Existing issues and proposed delta | Synergy / relative scope |
| --- | --- | --- | --- |
| 1 | Thoughts arrive in my vault | #16 automatic destination delivery; #69 setup; #109 existing scoped workspace | Turns existing capture/export into retained knowledge. Medium: file lifecycle is the hard part |
| 2 | My model makes a listening edition | #88/#89/#90 foundations; portable item/map import; editable Shortcut draft; #115/#116; optional app generation and readiness notification | One model-independent import contract; background generation is a separate experiment. Medium–large |
| 3 | Remember a moment without stopping | #117 lightweight bookmark, then #118 optional headphone command | Uses cluster 1's delivery and cluster 2's anchors; much less physical friction. Medium, with device/accessory verification |
| 4 | My reading queue becomes listening | #76 OPML extension; #69 source setup; Reader connector plus a free-account service (Instapaper first candidate) | Reuses intake, map preparation and export rather than creating service-specific players. Medium per adapter |
| 5 | Technical reading is pleasant | #111 domain narration repair; #105 authored figure descriptions first; #108 remaining organization; #106 gesture refinement | Protects comprehension and navigation. Small–medium for text/UI slices; image understanding is a separate larger spike |
| Later | Find connections among my thoughts | #48 local cross-item links; optionally #80 observed coverage for resuming gaps | Needs reliable, reusable notes first; evidence and resource cost exceed an initial PKM increment |

Sequence is a default, not a rigid dependency chain: fix comprehension defect #111 early when reproduced; #115/#116 can be bounded additions to cluster 2. Keep adapters narrow and share their ingestion machinery; the requested read-it-later increment includes Reader and one free-account option. Do not bundle Watch, classroom workflows, federation, or a second app into the first release.

### 1. Automatic Margin output, Obsidian first

Start with one selected folder, Markdown, and an explicit automatic-export toggle. Reuse the existing bookmark access and canonical exporter. The September 11 #16 proposal supports multiple named profiles; that remains a later breadth increment, while this owner's request supplies the desired automatic behavior.

Proposed experience: Settings → Configure Margin Output → choose a folder → send a sample → confirm it appears in Obsidian → enable automatic delivery. Capture commits locally first. Export runs when the selected text representation is available, and retries independently of playback/recording. Show pending/failed/saved state and last successful delivery; reselecting a revoked folder resumes pending work.

Choose stable per-Margin file identity initially. Include source title/URL, chapter or canonical text/media anchor, creation date, transcript/approved wording, bounded context, provenance, and a supported return link. Keep assistant-turn identity distinct. Do not auto-export raw recordings or full source text by default.

The current suffix-on-collision writer would create duplicates on retry, so it needs an automation-specific delivery journal keyed by destination, Margin ID and revision. Protect user edits: rewrite only an unchanged app-generated file; if it was edited externally, retain it and surface a new revision/conflict for deliberate handling. Do not delete exported notes automatically when a Margin is deleted. These are proposed product choices, not current behavior.

iOS supports user-selected directory access, security-scoped URLs/bookmarks and coordinated writes. That makes a folder integration feasible; actual provider availability and recovery must be proven on device. [Apple directory access](https://developer.apple.com/documentation/uikit/providing-access-to-directories). Obsidian's iCloud setup uses an Obsidian vault folder; do not assume every vault/sync configuration exposes the same writable location. [Obsidian sync guidance](https://obsidian.md/help/sync-notes). “Private processing” also does not mean “never synchronized”: the user may deliberately select an iCloud-backed folder.

Obsidian URI creation/opening can be a foreground fallback, not a substitute for unattended folder export. [Obsidian URI](https://obsidian.md/help/uri). Generic Files-compatible Markdown folders are the cheapest second destination. Joplin supports Markdown import, but file delivery alone is not live Joplin synchronization. [Joplin import documentation](https://joplinapp.org/help/apps/import_export/). Defer direct Notion/Joplin adapters and any claim of Logseq live compatibility until a real target setup demonstrates ingestion without extra machinery.

Acceptance: capture offline, deliver once, relaunch and retry without duplication, edit the note in Obsidian without losing edits, revoke/reselect access without losing a Margin, and open the source context later. Repeat in one non-Obsidian folder destination. Failure of these tests blocks the automation promise.

### 2. User-owned Shortcut → portable listening edition → Spoken Margins

Primary journey: share readable content → run a user-created Shortcut or an editable downloadable draft → use the user's chosen model to produce a Listening Map, chapter/scene descriptions and summaries → save or hand off the item plus map → import into Spoken Margins → listen. The same file can be created outside Shortcuts and imported later. This path must remain useful even if Spoken Margins never generates a map in the background.

Keep these responsibilities separate:

| Responsibility | Owner and boundary |
| --- | --- |
| Obtain item text | Shortcut/user supplies the actual readable text and source metadata; a URL alone is insufficient for a self-contained offline file |
| Generate map/descriptions/summaries | User-selected model: local, existing AI subscription, or another supported Shortcut action; Spoken Margins does not mandate a provider |
| Assemble output | Shortcut retains the original text and combines it with model output; do not ask the model to reproduce the entire article unchanged |
| Import and validate | Spoken Margins checks structure, source binding and navigable anchors, persists the item and map, and explains repairable errors |
| Render speech | Spoken Margins can render imported text and summaries for playback; completed text/map output does not imply pre-rendered audio |
| Optional in-app generation | A separate Shortcut-callable local generation path, with background execution claims gated on device evidence |

**Proposed exchange format:** one UTF-8 JSON file containing source metadata, unchanged item text, its canonical structure, and a map with anchored chapter/scene titles, descriptions and summaries. JSON is recommended for deterministic parsing; Markdown remains useful as a readable export and could be accepted later through an explicit documented structure. This is a format direction, not a new schema ID or an assertion that today's importer already accepts it. Reconcile it with #88 and the existing browser-text handoff before naming fields; update schema, validator, runtime and tests together. A map-only file should also be able to bind to an already imported exact source revision.

Preserve authored chapters separately from generated scenes. Give the model stable source-block references, then verify its returned anchors exist and are ordered and in range. Do not accept invented narration timestamps for native text; map canonical text positions to media when audio exists. Record supplied generation provenance without claiming to authenticate the provider. Do not silently regenerate or replace a user's imported map. Structurally valid generated summaries remain user-supplied content, not app-certified factual truth; provide preview and replacement/edit paths.

The downloadable Shortcut draft should expose the model step and prompt clearly, with a short output-format example. Apple's Shortcuts model options include On-Device, Private Cloud Compute and ChatGPT. This supports the requested choice of local or external generation. [Apple Shortcuts model options](https://support.apple.com/en-mide/guide/iphone/iph78c41eaf8/ios). The user's ChatGPT subscription route is an explicit acceptance target: verify the installed action, account connection, available model choice, input limits and returned output on device. Do not substitute a separately billed API integration or promise that a particular subscription/model is available through every Shortcut action. Provider selection and any sign-in belong in the user's editable Shortcut.

**Optional background generation experiment:** add a narrowly scoped request using the same durable item/map services. Measure independently (1) importing the article, (2) identifying scenes, (3) generating descriptions and summaries, and (4) preparing speech. Existing background TTS evidence proves neither Foundation Models execution while suspended/locked nor completion of this entire chain. Compare foreground, home-screen background, locked device, cold invocation, interrupted/relaunched work and unavailable local model using a short and a long article. Record which stages actually run, termination/expiration and elapsed time. If it only queues until foreground, describe it that way and preserve the external-file route. No runtime experiment was executed during this plan correction.

Keep the first intent surface narrow: import item/map, optionally request generation, inspect status/open result. Pass a file or durable handoff reference rather than large URL query parameters. Generated output should be reusable as the same portable artifact whichever execution route produced it.

Readiness remains explicit: imported, map available, playable opening, fully prepared offline. Notify only for the completed level requested, once per request; tap opens the exact item from cold launch. Permission denial leaves in-app status. Importing a completed Shortcut result must not wait for speculative app generation. Speech may prepare on opening if background rendering has not occurred. #115 previews the same Skim destination that executes; #116 reports compatible committed audio.

Acceptance: import externally generated JSON with app generation disabled; import a saved file after the Shortcut has finished; exercise one local-model Shortcut and the owner's subscription-based ChatGPT route; preserve original text and imported summaries; reject broken/mismatched anchors without losing the item; retry without duplicate imports; open/listen and Skim; distinguish text readiness from audio readiness. Include a long article and map-only reimport. Separately test the optional app-generated background route, notification denial and cold-launch notification tap. External generation must not be blocked on that experiment succeeding.

### 3. Lightweight capture

#117 supplies a non-recording bookmark at the source position; context enrichment can happen later. Save it first without pausing or taking over the audio session. Cluster 1 makes even a brief walk produce useful vault notes.

#118 depends on that same bookmark model. It explicitly targets system media commands, not raw AirPods gestures; opt-in remapping must be reversible and limited to when Spoken Margins owns Now Playing. Validate actual accessories and preserve ordinary transport when disabled. Do not make this depend on Watch #96/#75. Those have dormant components and materially different capture/synchronization costs.

### 4. Read-it-later intake

| Service | Feasibility and constraints | Recommendation |
| --- | --- | --- |
| Readwise Reader | Document-list API, token auth, pagination, incremental updates and optional HTML content; Reader is the full-content product, distinct from Readwise highlight export | First direct adapter; owner uses a trial/month for bounded account-specific checks |
| Instapaper | Full API supports bookmark listing/content; OAuth 1.0a/xAuth and human-reviewed app credentials add integration work | Preferred required free-account companion, subject to current app approval and free-account content retrieval proof |
| wallabag | Documented API with instance-specific endpoints; self-hosted deployment fits users who want control | Fallback if Instapaper access fails; self-hosted software does not mean free managed hosting |
| Readeck | Official site could not be retrieved in this audit (403); endpoint/auth compatibility not established | Keep as an investigation candidate, no effort/compatibility promise |
| RSS/OPML and browser sharing | Existing source/import paths; OPML seeds subscriptions, not saved articles | Ship portable entry paths independently of any paid service |

Reader implementation proposal: direct device-to-Reader requests; token in Keychain and excluded from diagnostics; fetch a bounded selection such as Later or a chosen tag; filter out child highlight/note records; preview and explicitly add items through canonical intake. Persist provider ID, source URL, revision and cursor; commit cursor only after complete successful ingestion. Use HTML when supplied, sanitize it, and preserve source attribution. Do not claim every PDF/EPUB record contains usable full content. Handle missing text, 401, 429, interruption and duplicate pages visibly. Avoid deleting local Margins when a remote item disappears. [Reader API](https://readwise.io/reader_api).

Both initial adapters should be read-only: no automatic archive, progress writeback or export of private Margins. A connector can be free in Spoken Margins while the user's Reader subscription remains paid. [Reader pricing](https://readwise.io/pricing/reader). Readwise highlight upload is a separate optional outbound feature; it is unnecessary for direct vault export.

Instapaper's old 2011 paid-API restriction was superseded by its 2015 announcement opening the API to all users. Current developer docs still require app credential review and signed requests; prove access with an actual permitted test account before scheduling the adapter. [Policy update](https://blog.instapaper.com/post/121774203371), [API documentation](https://old.instapaper.com/developers/v1/full-api). wallabag requires per-instance API/auth handling and maintenance rather than a promise of free managed hosting. [wallabag API](https://doc.wallabag.org/developer/api/).

Testing split: build the shared import/deduplication/recovery checks using local captured or synthetic fixtures. Use the owner's Reader trial/month for token, pagination, real HTML retrieval and end-to-end playback checks rather than the full generic test matrix. Prove the free-account service independently with list, full-content retrieval, duplicate sync, disconnect and playback tests; do not claim that Reader success verifies its adapter. Instapaper is the preferred candidate because its published policy permits free-account API access; current approval and real free-account retrieval are a prerequisite. A self-hosted wallabag installation is a fallback, not automatically a zero-cost consumer service.

No provider account was connected and no private library was accessed in this audit. Feasibility above is documentation-backed, not an executed integration test.

## Positioning, audit and stopping rules

Assume “Snipped” refers to Snipd. Its current pricing page already lists headphone capture and PKM export among core features, with limited free AI episodes. “Free export” alone is therefore a weak differentiation. The hypothesis to test is a private workflow across saved articles, books and podcasts, with user-chosen navigation generation, private in-app processing and user-owned thoughts automatically filed. [Snipd feature comparison](https://www.snipd.com/pricing).

Compare three alternatives in a small owner-led pilot: existing manual export, automatic folder delivery, and adding a Reader queue on top. Count completed end-to-end journeys, export correction time, lost/duplicate notes, source-return success, preparation waits, and whether users return to their notes after a week. Keep pilot records local or voluntarily supplied; no analytics backend is needed.

Proposed stopping criteria: zero lost captures or overwritten user edits; zero false ready notifications in the acceptance corpus; invalid source anchors rejected; app-generated summaries checked for grounding and imported summaries clearly treated as user-supplied; no hidden provider switch. If automatic export does not materially reduce filing effort against the manual baseline, fix its workflow before expanding destinations. If people do not consume imported Reader items, reconsider queue design before expanding beyond the two requested providers. If local generation has unacceptable wait/quality on supported hardware, ship authored chapters and optional map generation while measuring the limitation.

Omission check: every open issue appears once in the inventory, but mixed issues explicitly distinguish shipped foundations from proposed extensions. Historical partial Watch/co-op/browser work is quarantined from “ready to test.” Developer measurement obligations stay separate from owner experience checks. #114's paid second-app proposal conflicts with the owner's no-paid-offering direction and should be reframed or parked; #51 hosted AI is unnecessary for this local-first loop. Classroom/co-op/registry/federation #19/#22–26/#70/#80/#82 remain optional later markets, not rejected merely for their labels.

Before implementation, record the chosen issue slice in `docs/release-lanes.md` under an explicit product-owner release decision. This planning artifact is intentionally not a competing lane plan. Verification for this documentation work is inventory completeness, source/acceptance reconciliation, referenced paths, and diff inspection; no new app tests or product-validation claims are made.
