# Interfaces between streams

These are the places where one stream's output is another stream's input. Parallel work breaks at these seams, so each has one **owner**. The owner publishes the seam (a schema in `Contracts/schemas/`, a Swift protocol in SessionKit, or both) with a fixture and a stub, **no later than the first milestone of the owner's that another stream is waiting on**. Consumers can then build against the stub before the real thing exists.

This page sets **what crosses each seam and what must stay true**. It deliberately doesn't set field names or types. The owner decides those, keeping to the invariants.

**Changing a published seam.**
- Within the app, additive changes (new optional fields, new enum cases consumers can ignore) need no one's permission. Land them and mention them on the consuming streams' tracking issues.
- **Anything that travels in a packet is never "just additive".** Build 29's packet reader rejects unknown keys in the manifest, item, source, artifact and asset entries (`validateManifestJSONShape` in `InterjectionPackageArchive.swift`), and the Contracts schemas set `additionalProperties: false`. A packet change needs a test that imports the new packet into the last shipped build, and the owner's OK (I10).
- **Stored records survive, but lossily.** The previous build opens a database with new fields, but drops fields it doesn't know when it re-saves a record (`docs/repo-review-2026-09-24.md` §4). Prefer new record kinds over new fields on existing ones.
- A breaking change needs the owner's OK and a note on every consumer's issue before it merges.

**Everything here inherits the repo-wide rules:** packets exported by a new build import into the last shipped build; the previous build can still open the database; nothing deletes or reseeds the owner's Library.

---

## I1. Link → source resolution

**Owner:** B1 `onboard`. **Plugs in:** B2 `substack`, B3 `youtube`, B4 `bridge`, the existing Spotify and Apple resolvers (`PublicPodcastLinkResolver.swift`), generic feed discovery.

- **Crosses:** a pasted or shared link (or a search query) goes in. Zero or more **source candidates** come out: what kind of source it is (podcast feed, article feed, Substack, bridged site, podcast found from a YouTube link), the followable feed if one exists, display metadata, a confidence level, and a human-readable reason ("matched by title and publish date").
- **Invariants:**
  - A candidate is never presented as certain when the resolver isn't. This is the same principle as podcast anchors: an honest "is this it?" beats a confidently wrong follow.
  - Each resolver is independent and testable on the host with recorded responses. Adding a resolver doesn't mean editing the others.
  - Feed URLs that carry a private token (paid Substack, private podcast feeds) are marked private and never leave the device, including in packets (#168).

## I2. Followed source and catalog entry

**Owner:** B1 `onboard`. **Consumers:** D3 `following`, D2 `home`, B4 `bridge`.

- **Crosses:** what a followed source is (builds on `Contracts/schemas/followed-source.schema.json`), plus a **catalog entry** for sources the user hasn't followed yet (the onboarding "top podcasts" list, suggestions). Includes category and kind tags so D3 can filter.
- **Invariants:** the catalog can be refreshed without an app update (#69), and the app works offline with a bundled snapshot. Following never downloads episodes by itself.

## I3. Bridge manifest and fetch recipes

**Owner:** B4 `bridge`. **Consumer:** the app's following/refresh code (B4 app milestone, then D3).

- **Crosses:** server → phone. A cacheable list of bridged sources with their latest items (link, title, date, a change marker) and, per source, a **fetch recipe**: declarative hints for how the phone should fetch and extract the item itself.
- **Invariants:**
  - **Recipes are data, never code.** No scripts, no JavaScript, nothing interpreted as a program. App Store Review Guideline 2.5.2 prohibits downloading executable code, and it keeps the attack surface small.
  - The server never serves article bodies. The phone fetches content from the publisher itself.
  - The server can't learn a user's follow list. The phone fetches the whole manifest, or a coarse shard of it, and filters locally.
  - With the server down or gone, the app still works; bridged sources just stop updating, and the UI says so.
  - Versioned. Old apps ignore fields they don't understand.

## I4. Engagement signals

**Owner:** D3 `following`. **Consumers:** D2 `home`, E2 `reflect`.

- **Crosses:** an on-device, append-only record of what the listener did: time listened per item and source, Margins recorded (kind and length), shares and exports, packets imported from others, items dismissed or finished.
- **Invariants:** it never leaves the device (#176). It's cheap to write from the playback path, so no main-thread I/O per tick (see #161). It can be pruned or deleted by the user, and the previous build still opens the database.
- **Where it's called from:** D3 publishes a small recorder API. Listening time is recorded from a single thin call site in today's playback path. When A2 M2 lands, the playback coordinator becomes the caller, and A2 moves that call site. Source kinds come from I2; D3 doesn't define its own.

## I5. Ranking policy file

**Owner:** D3 `following`. **Consumers:** D2 `home` (suggestions), the user's own AI.

- **Crosses:** a human- and AI-editable file (YAML is the owner's preference) that says how the Following inbox is ranked and filtered: signal weights, per-source boosts or mutes, keyword and regex filters, time-of-day preferences. The owner's `Digest` repo already prototypes this loop (patch schema, preview, trial, accept, reject, rollback). Carry the ideas over, not the TypeScript.
- **Invariants:** an invalid file is never applied; the user sees why. Before applying, the user sees what would change. **Reset to default is always one tap away** and always works. Every ranked item can explain itself ("high because you've made 12 Margins on this show").

## I6. Home cards

**Owner:** D2 `home`. **Providers:** resume (existing), D3 suggestions, B1 "follow something" nudge, E2 week in review, F1 book club, recent Margins.

- **Crosses:** each provider offers zero or more cards (what to show, why it's relevant now, and what tapping it does). Home decides order and layout.
- **Invariants:** a provider adds a card without editing Home's layout code. A provider that fails or is slow doesn't block Home from rendering.

## I7. Structured Margin record

**Owner:** E1 `structure`. **Consumers:** E2 `reflect`, F1 `coop` (clustering many people's Margins), D2 `home`.

- **Crosses:** for each Margin, a derived record: what kind of statement it is (claim, question, reaction, to-do, quote, and so on), what in the source it refers to (anchor span and nearby source text), the entities it mentions, links to other Margins, scenes or notes, which producer made it (on-device model and version, or deterministic rules and version), and a confidence.
- **Invariants:**
  - **Derived and rebuildable.** The Margin itself (`interjection.schema.json`) stays the source of truth. Deleting every structured record loses nothing the user made.
  - On-device only. Never a server call. With no on-device model, a deterministic producer still fills the record, with lower confidence where it has to be.
  - Not in packets unless the owner decides otherwise. That decision needs a packet-compatibility check first.

## I8. Listening map extensions (scenes, entities, provenance)

**Owner:** E3 `maps`, with E1 `structure` for the entity fields. **Consumers:** Skim, the player, E2 `reflect`, F1 `coop`.

- **Crosses:** additions to the existing listening map (`listening-map.schema.json`, and `portable-listening-map-proposal.schema.json` for the shareable form): per-scene people, places and topics, and where the map came from (on-device model, community server, deterministic, or imported).
- **Invariants:** additive to the current schema; a map without the new fields still works everywhere. Portable maps travel in packets, so I10 applies to any field added there. The source of a map is always shown, because a community map can be wrong.

## I9. Episode identity

**Owner:** C4, the anchors work (`docs/podcast-anchor-plan.md`). It takes #177 once branch `private-feed-urls` (the #168 fix, `ShareableLinkPolicy`) is merged, since #177 builds on it. **Consumers:** E3 `maps` (lookups), F1 `coop` (joining packets from many people), D4 `share`.

- **Crosses:** a way to say "these two copies are the same episode" across listeners, even when their audio differs: the episode GUID (#177: the app doesn't store it yet, although the packet manifest already has an `episodeGUID` field), the normalized enclosure, feed plus title plus date, and acoustic landmarks.
- **Invariants:** a server lookup by episode shouldn't reveal a listener's library in the clear. Use a coarse shard or hash prefix and match locally.

## I10. Packet evolution

**Owner:** F1 `coop` for group features; any stream that changes sharing follows the same rule.

- **Crosses:** `.spokenmargins` packets (`spoken-margins-package.schema.json`, `shared-commentary-layer.schema.json`).
- **Invariants (from `AGENTS.md`, restated because co-op broke this last time):**
  - A packet from a new build imports into the last shipped build.
  - Build 29 rejects unknown keys in the manifest and its entries, so a new manifest field breaks import just like a new required capability does. New information goes in a new *optional* artifact, which old readers skip, or waits until the owner accepts the break.
  - A new required manifest capability is added only when the packet actually uses the feature.
  - Keep a test that feeds packets from the new build to the last shipped build's reader.

## I11. Server client and device attestation

**Owner:** B4 `bridge` (server foundation milestone). **Consumers:** E3 `maps`, later F1 `coop`.

- **Crosses:** how the app talks to any Spoken Margins server: base URL and kill switch, anonymous per-install attestation (Apple App Attest or equivalent), rate limits, and a way for the server to refuse one install that keeps submitting junk.
- **Invariants:** no accounts, names or emails. The server can block an install without knowing who it is. Every server feature degrades gracefully when the server is unreachable or switched off. The app's privacy label and privacy page (`Site/privacy`) are updated before anything ships.

## I12. Notes destination

**Owner:** D4 `share`. **Consumers:** E2 `reflect` (week-in-review note), E1 `structure` (reading a vault to find related notes), existing Markdown export (#16, #171).

- **Crosses:** a user-chosen folder (an Obsidian vault, an iCloud Drive folder) that the app can write Markdown into and, only if the user separately allows it, read from.
- **Invariants:** read access is a separate opt-in from write access. Vault contents never leave the device and are never run through AI, on-device or otherwise (the owner's explicit requirement). Matching against a vault is lexical, deterministic and cheap enough to run on battery.

## I13. Structured document (PDFs and long text)

**Owner:** C1 `pdf`, published in C1 M1. **Consumers:** the speech path (C2 `voice`), the listening map for PDFs (#124), the player (showing a figure while its caption is read), text anchors for written Margins.

- **Crosses:** extracted text as segments with a role (body, heading, caption, footnote, reference, table, header or footer), plus references to figures and tables with their page and position so they can be shown.
- **Invariants:**
  - **Existing Margins keep their place.** Written Margins anchor into extracted text (journey J7). Changing extraction changes that text. Version the extraction, and either keep an item on the version its Margins were made against or migrate its anchors with a test that proves they still land.
  - Roles are advisory to the speech path. The voice stream decides how a role sounds (skip, announce, lower priority).

## I14. Speech engine selection

**Owner:** C2 `voice`, published in C2 M1. **Consumers:** every narration path, and C1 M3.

- **Crosses:**
  - which engine and voice will render, and **why** (user choice, thermal state, Low Power Mode, model unavailable);
  - a single effective-rate rule;
  - how each I13 role is spoken: skipped, announced ("Figure 2: …"), or read, and how citation and footnote markers sound.
- **Invariants:** power state alone never silently changes the voice (#183). Any fallback has a visible, loggable reason, and the chosen voice comes back when the reason clears. Rate is one number: the app's rate is never multiplied by the system accessibility rate. Chunk boundaries never show as pause/resume.

## I15. Stable UI identifiers

**Owner:** A2 `seams`. **Consumers:** G1 `guides`, the Test Desk's journeys, any UI test.

- **Crosses:** accessibility identifiers for the controls that core workflows touch (add a source, follow, play, record a Margin, share, import a packet).
- **Invariants:** a visual redesign keeps the identifiers, or updates them and the guide scripts in the same PR.

## I16. Lane request and report

**Owner:** A1 `lane`. Defined in [test-lane.md](test-lane.md).
