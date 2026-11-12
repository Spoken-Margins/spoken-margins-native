# Syncing the Library across a listener's Apple devices (design note)

Issue #1769. Docs only: no app change, and nothing here is built yet. The owner answered the five calls in the last section on 2026-11-12; they are recorded in `docs/decisions.md`. Facts about the code were read on `main` at `5c0ab7a7` (12 November 2026); file names are the way to re-check them, line numbers are left out because they drift.

## Recommendation

1. **Do not start with a whole-Library sync.** Start with the part a listener would miss most and that is cheapest to get right: **the listener's own words (Margins and Spoken Notes) and listening place.** Items with a source address (articles, PDFs, podcast episodes) are brought in on each device by that address, as they are today; sync only tells a device "you also have this item, and these are the Margins and the place". A **Spoken Note is the listener's own writing, so it syncs as an item** (owner, 2026-11-12, quoted under "Decisions for Cole").
2. Use **CloudKit's private database through `CKSyncEngine`** (iOS 17 and later; the app targets iOS 26), with a small sync layer in SessionKit that is host-tested against a fake transport. Do not use `NSPersistentCloudKitContainer`: the Library is not Core Data (see "What exists today").
3. Make it **opt-in, default off, and gated at build time** (standing calls 2026-10-05, 2026-10-17). Encrypt every field that identifies or quotes the listener with CloudKit's `encryptedValues`, so Apple's servers hold only ciphertext, record ids and sizes.
4. **Never sync** feed credentials, tokens, downloaded media, rendered voice audio, caches or diagnostics. **Recordings sync last**, as a separate step with its own size rules and its own owner decision.
5. A **new phone** is already served by iCloud Backup and device-to-device transfer, which restore the whole Library and recordings today (the database and recordings are not excluded from backup; only podcast downloads and rendered audio are). Sync does not replace that, and the first slice should not try to.

What would show this wrong is at the end.

## What exists today

- **Storage.** One SQLite file. Every record is a JSON row in `records(kind, id, session_id, item_id, payload, updated_at)`; `metadata` holds `schema_version` (5). Rows an older build cannot decode go to `quarantined_records` and come back when a build can read them. (`SQLiteSessionStore.swift`, `docs/overview/compatibility.md`.) There is no CloudKit, iCloud sync or ubiquity code. The only iCloud reference is the iCloud Drive share target in `SessionShareFiles.swift`. `docs/overview/offline-and-privacy.md` and `docs/launch/app-store-submission.md` both say "no CloudKit", so those, the privacy label and the policy change if this ships.
- **Ids.** Items, Margins, sessions and collections have string ids, mostly UUIDs made on the device (`Models.swift`, `ItemCollection.swift`). An item's id is **not** the same on two phones that each added the same article, so ids cannot be the match key for items.
- **How the same thing is recognised across phones today.** Shared Margins already do this for packets: by podcast `episodeGUID`, by the exact-edition SHA-256 (`sourceExactEditionSHA256`), by the canonical source and its text digests (`CanonicalSourceModels.swift`, `ItemTextDigests.swift`, `ImportedPodcastPlacementPolicy.swift`). Imports are de-duplicated by `packageDigest`. This is the matching sync should reuse, not a second scheme.
- **Margins.** `Interjection` has `id`, `itemId`, `sessionId`, `createdAt`, an anchor, `audioPath`, transcript fields, `status`, and some private fields (`isStarredForSharing`, `privateSharingNote`, `sharedAs`) that are never exported. It has **no `updatedAt`**. A deleted Margin is kept with `status = "deleted"` (`SessionEngine.deleteInterjection`), so a tombstone half exists for Margins. `audioPath` is relative to Application Support, so a path means the same on another device.
- **Items** have `deletedAt` (a soft delete) and carry full text. Many other record kinds are hard-deleted (`DELETE FROM records`), with no tombstone.
- **Listening place** lives in `Session` (`position`, `completionPercent`, `updatedAt`, `completedAt`), and an item can have several sessions.
- **Collections** have `itemIDs` in the listener's order and an `updatedAt`.
- **Following** (`FeedSubscription`) has the feed address, `etag`, `lastModified`, per-show policy.
- **Watch.** `watch_sync_event`, `watch_audio_package` and the outbox are phone-to-Watch transfer (#75, `docs/gate4-watch-untethered-foundations.md`). That stays; iCloud sync is phone-to-phone and sits beside it.
- **Secrets** (Readwise and Raindrop tokens) are in the Keychain and are not in the database.

## Is CloudKit suitable?

| Option | Fits? | Why |
|---|---|---|
| **A. iCloud Backup only (today)** | Covers "new phone", not "two phones at once" | Free and already there. Restores one device's state; two live devices diverge. |
| **B. CloudKit private DB with `CKSyncEngine`** | **Yes, for metadata and small records** | Same Apple ID only; no server we run; handles push, batching, retries and account changes; private database storage counts against the listener's iCloud quota, not ours. Needs our own record mapping. |
| C. `NSPersistentCloudKitContainer` | No | Needs Core Data. The Library is a generic JSON-row SQLite store, and moving it would break "the previous build still opens the database". |
| D. A folder of `.spokenmargins` packets in iCloud Drive | Weak | Reuses the packet format, but packets are immutable shares, not editable state: no deletes, no progress, no merge. Packet compatibility rules also apply. |
| E. Our own server | No | Contradicts the standing privacy calls and the "server features need consent" work (#2842). |

**Why B, and the caveats to check before building** (Apple's pages, searched 12 November 2026; the numbers vary between pages, so re-read them at build time):

- A record should stay **under about 1 MB** excluding assets ([CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord.md)). Margin text, anchors and a place fit easily. **Full item text may not** (a book or long PDF), which is one reason items are not synced as content.
- An asset (a recording) has a size cap that an archived reference gives as **50 MB** ([Data Size Limits](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html)); forum posts claim more. A spoken Margin is far below 50 MB, so this is not a blocker, but the number must be confirmed.
- Assets are always encrypted and cannot be `encryptedValues` fields ([WWDC21: What's new in CloudKit](https://developer.apple.com/videos/play/wwdc2021/10086/)). Whether Apple's keys or the listener's keys protect an asset is a **thing to verify against the current CloudKit security docs before we say "end to end" in the privacy policy**. Until then the policy words must be what is proven, not what is hoped.
- Private database storage and traffic count against the listener's iCloud quota ([forum answer](https://developer.apple.com/forums/thread/35633)). A listener on the free 5 GB plan with hours of recordings could run out; the design below makes that a plain, non-blocking state.
- A listener who has iCloud turned off, is signed out, or is on a restricted account gets no sync and no error dialog; local use is unchanged.

## What syncs and what never does

| Thing | Sync? | Notes |
|---|---|---|
| **Margin text, transcript, anchor, status, createdAt** | Yes (slice 2) | Encrypted fields. Anchor already holds source terms (char offset, media time, surrounding text). |
| **Margin recording (audio)** | Later, own step (slice 5); decided 2026-11-12: Wi-Fi only, off by default, size shown first | Asset. Needs a quota story. Without it, the other phone shows the Margin with a plain "recording is on your other device" and plays its transcript. |
| **Item identity** (title, source address, canonical key, media type, `episodeGUID`) | Yes (slice 1) | A "have this item" record. Not the text, not the audio. |
| **Spoken Notes** (the item, its title, its transcript text, its takes' text and order) | **Yes (slice 2)** | The listener's own words, not publisher content, so none of the rights concern below applies. Owner, 2026-11-12: "If it is the user's note that they created (Spoken Note) it should sync." Small enough for a record. The item id is already `spoken-note-<noteId>` (`SpokenNoteItem.itemId`), the same on every device, so it is the record key and adding a note on two phones cannot make two rows. The takes' **audio** follows the recordings decision (slice 5): until then the other phone shows the note's text and says the recording is on the other device. |
| **Other item text** (articles, PDFs, pasted text) | **No by default** | Too large for a record and a rights question (see below). The other phone re-fetches an address-based item itself, on the listener's action. Pasted text that is not the listener's own note has no address and stays on one device, until slice 6. |
| **Listening place** | Yes (slice 3) | Per item, small. Rules below. |
| **Collections** (name, ordered item keys) | Yes (slice 4) | Small. |
| **Followed sources** (show, policy) | Yes, **public feeds only** | A feed address with a token, password or user-specific query string is not synced (see below). |
| Private feed addresses and credentials | **Never** | The issue's must-not-break rule: private feed URLs and credentials never leave the phone (#168). |
| Readwise and Raindrop tokens | **Never** | Keychain, stays on the device. |
| Downloaded podcast files, rendered voice audio, caches, models | **Never** | Excluded from backup already; large and re-creatable. |
| Prepared-audio jobs, map jobs, summaries in progress | **Never** | Device-local work. (A finished listening map is its own question; out of scope here.) |
| Diagnostics, hang counts, listening signals file | **Never** | Local by rule. |
| Private curation fields (`privateSharingNote`, `isStarredForSharing`, `sharedAs`) | Open: sync like the Margin they belong to, encrypted | They are the listener's own, but they are "never exported" on purpose. Decision below. |
| Packets imported from a friend, with their sender labels | Yes, as the same item + layer records, encrypted | The friend's name and Margins are someone else's content held privately; keep them encrypted and never merge them into the listener's own Margins. |

**Rights.** Syncing the *text* of an article or the audio of a podcast to Apple's servers copies publisher content, even if it is encrypted and the listener's own. That is a legal question for the lawyer (the same one the sharing work waits on), so the default design syncs addresses and the listener's own words, never publisher content.

## Identity, duplicates and the first sync

- **Item key.** A stable, content-derived key: the note id for a Spoken Note (`spoken-note-<noteId>`), `episodeGUID` + show for podcast episodes, else the canonical source key, else the text digest. It is the CloudKit record name, so two phones that each added the same article create **one** record (CloudKit's "record already exists" is the duplicate guard). Local item ids stay local; a sync table maps `itemKey ↔ local itemId` on each device.
- **Margin key.** The Margin's existing UUID is already unique across devices and is the record name. A Margin belongs to an item key, not to a local item id.
- **No matching item yet.** A Margin that arrives for an item this phone does not have is **kept, hidden-safe, and shown under "On your other device"** with a one-tap "Add this item" that fetches by address. It is never dropped and never auto-fetches a publisher's page (standing call 2026-10-21: only on a listener's action).
- **Two items that look like one** (a re-published article with new text): the key says they differ, so they stay two items. Over-splitting is safe; over-merging would attach Margins to the wrong text.
- **First sync from an existing single-device Library.** Local data is the starting point and is only ever **added to** the cloud. Nothing local is deleted, rewritten or re-keyed. The database schema does not change: sync state (change tags, the map above, pending uploads) lives in its own file or in new record kinds that an older build ignores, so Build 32 and 34 still open the database (rule 2 in `docs/overview/compatibility.md`).

## Merge rules (deterministic, and a Margin is never silently lost)

- **Add wins over nothing.** A Margin that exists on either side exists after sync.
- **Edits to a Margin** (text, cleaned transcript, display text): last-writer-wins **per field**, by a version stamp the sync layer keeps (a hybrid logical clock per device, not the wall clock alone, so a phone with a wrong clock cannot win forever). Because `Interjection` has no `updatedAt`, the stamp is stored in the sync layer, not added to the Margin, which keeps packets and the old decoder untouched. When two edits to the **same text field** race, the loser is not discarded: it is kept as a "Other version" on the Margin until the listener picks.
- **Deletes.** A Margin delete is `status = "deleted"`, which syncs as a normal edit and is the tombstone. A delete beats an edit that happened before it and loses to an **undelete** after it (the engine already supports `deleted → active`). Tombstones are kept at least **90 days** after the last time any device of the account was seen (more than the longest gap we expect a phone to sit unused; a device back after longer is told to re-sync from scratch without deleting local data). Records with no tombstone today (collections, follows) get a `deletedAt` in the sync layer only.
- **Item removal.** Removing an item on one phone does not remove the item or its Margins on another. It syncs as "this item left the Library", which the other phone **asks about once**; its Margins stay (a Margin is the listener's own words, and is kept even if the item goes, as it is on one phone today).
- **Duplicate imports** collapse by the item key and, for friends' packets, by `packageDigest`.
- **Reorders** (collections, queue): store the order as a list of item keys with a version stamp per collection and merge by item: items present on either side stay; the order of the side with the newer stamp wins; an item added on the older side goes at the end. No ordered-relationship tricks.
- **Concurrent Margins on the same spot** are two Margins. Both stay.

## Listening place: the rule the issue asks for

Furthest-wins is wrong because a listener who rewinds on purpose would lose the rewind. Latest-wins is wrong because a phone left paused for a day would overwrite today's listening. The proposed rule:

1. A place record per item holds `{position, source revision key, lastPlayedAt (version stamp), device, how it got there}`.
2. **The most recent *play* wins**, judged by when playback actually advanced the place, not by when the record was saved. A background upload of an old place cannot win over newer listening.
3. A **deliberate seek or rewind counts as a play event**, so an intentional rewind on phone A beats the older furthest place on phone B.
4. **Completion is sticky only within one source revision**: finishing on one phone marks it finished on the other, unless the other phone's place is newer and later than the finish (the listener started it again).
5. **If the source revision differs** (different `sourceExactEditionSHA256`, or text digest changed), the place is **not applied automatically**: a podcast re-cut or an edited article makes a char offset or time point at the wrong spot. The device keeps its own place and may offer "Continue where you were on iPhone" using the Margin anchors' matching code to find the nearest spot.
6. A device that is playing right now is **never moved by an incoming place**. At most it offers "Continue on this phone?" after the listener stops. (This is the rule that stops sync from teleporting a listener around, 2026-11-06.)

## Lifecycle, failure and safety

- **Local first.** Every save writes locally, then queues an upload. A failed, slow or refused sync never blocks saving a Margin, recording, or playback. Sync status is a small, plain state in Settings ("Up to date", "Waiting for Wi-Fi", "iCloud is full", "Signed out of iCloud") with a "Check now" and a "Stop syncing" button.
- **Reinstall, new device, restoring from backup.** The device asks CloudKit for changes since nothing, gets everything, and merges by the rules above. A restore from an older backup does not roll the cloud back: older records lose to newer stamps.
- **Sign out, sign in, account change.** On `accountChanged`, the sync layer stops, **keeps all local data**, and asks "You're using a different iCloud account. Start syncing with it? Your Library on this phone stays as it is." It never uploads one person's Library into another account's zone without that tap, and never deletes local data because an account left.
- **Older client / schema skew.** Every record carries `schemaVersion` and keeps the server's own system fields. A client reads a record it only partly understands, **writes back only the keys it changed**, and leaves the others as the server has them. A record whose version a client cannot read is parked (like `quarantined_records` today), counted, and shown as "Update Spoken Margins to see N items". Tested with a frozen old reader, the way `ShippedReader` tests packets.
- **Storage full** (`quotaExceeded`): uploads pause, metadata keeps priority over recordings, local saving is unaffected, and the status says so.
- **Interrupted or out-of-order delivery.** Every apply is idempotent, keyed by record name and version stamp; applying the same change twice, or a delete before the add, gives the same result. Changes arrive in batches; a Margin whose item has not arrived yet waits in the "On your other device" list.
- **Battery and cost.** Push-driven, no polling. No audio uploads on cellular or in Low Power Mode unless the listener says so (standing call 2026-10-05: nothing default-on that drains the battery).
- **Privacy surface.** CloudKit adds Apple as a processor of ciphertext. The privacy policy, the App Store label, the "no CloudKit" lines in `docs/overview/offline-and-privacy.md` and `docs/launch/app-store-submission.md`, and Notes for Review change in the same release. The feature stays behind a build setting until the lawyer has seen the policy (like share links).

## Slices (split before building)

Each is a separate challenge issue. "Cloud" slices are host-testable in SessionKit on Linux; "Mac" needs an app build and the iCloud entitlement.

1. **Sync core, SessionKit (cloud).** Item key derivation, hybrid-clock version stamps, the merge functions above, a fake transport, and a **convergence simulator**: N replicas, random drops, duplicates, reordering, offline edits, reinstall, a schema-skew replica; asserts every replica ends identical and no user-authored Margin is lost. This is the biggest risk and needs no Apple API. Tests exist before any CloudKit code.
2. **Margins and Spoken Notes sync (Mac + cloud).** `CKSyncEngine` adapter, record mapping, `encryptedValues`, the "On your other device" list, status in Settings, entitlement, build flag. A Spoken Note's text edits merge by the same per-field rule as a Margin (`SpokenNoteItemMerge` already refuses to resurrect a note the listener deleted, which the sync layer must keep).
3. **Listening place (cloud for the rule, Mac for wiring).**
4. **Collections and followed public sources.**
5. **Recordings as assets** (after the owner's decision on quota and cellular).
6. **Pasted text and other item text**, only if the lawyer and the owner agree to syncing publisher content.
7. **Owner validation on two physical devices** (airplane-mode edits on both, then reconnect; rewind on one; delete on one; reinstall one; sign out of iCloud).

**Slice 1 as built (#4152, `Packages/SessionKit/Sources/SessionKit/Sync/`).** The rules above are code now, with no CloudKit in them. Where the build had to choose:

- Every field is a **multi-value register**: a write replaces every version the device holds, and a version the writer had not seen stays beside it (the "Other version"). So the Margin screen must show an "Other version" before it lets the listener edit that field; an edit is then their choice. Edits to different fields never conflict.
- The **place** is two registers (`place`, `completion`) stamped when playback advanced or the listener moved it, not when saved. `ListeningPlaceSync.decide` is a pure rule for what a device does with an arrived place (adopt, keep, offer, defer while playing, mark finished). Applying a place never writes one back.
- A device back after **90 days** is told to start over: it merges the cloud into its own data and pushes its own again. A Margin deleted elsewhere whose marker has since expired comes back on that device. That is the safe failure, and it is a stated cost of "keeps its local data".
- A cloud response that outlived a reinstall or a restore never moves the device's position (`pullCompleted(since:)`).
- Not built here: the CloudKit adapter, the mapping of these records to `CKRecord` and `encryptedValues` (the field list is `SyncFieldSchema`), the "On your other device" list, Settings, and any change to the database. Sync state lives outside it.

Compatibility checks that go with every slice: `scripts/check-build29-database.sh` (the previous builds open the database), packet round trip through `ShippedReader`, and "a failed sync never blocks a local save".

## Decisions for Cole

1. **Start with the listener's own words and place only, no publisher text and no recordings?** Answered (2026-11-12): yes, **and a Spoken Note syncs as well**. Asked as "Margins and listening place only … Cost: a note you typed or pasted in the app has no web address, so it stays on one phone", he replied: "If it is the user's note that they created (Spoken Note) it should sync." Cost of what remains: a new iPhone gets articles and episodes back by address, not by copy, and pasted text that is not a Spoken Note stays on one phone. Alternative still open: sync publisher text too, which waits on the lawyer and a size plan.
2. **Syncing private curation fields** (`privateSharingNote`, starred): answered (2026-11-12): "agree. A", meaning yes, encrypted, because they are the listener's own notes. They stay out of packets and exports.
3. **Recordings over iCloud** (slice 5; this covers a Spoken Note's takes too): answered (2026-11-12): "Agree", to "Sync them later, as a separate step. Wi-Fi only, off by default, with the size shown first, like voice downloads." Cost: recordings use the listener's iCloud storage (the free plan is 5 GB). Until slice 5, the other phone shows the transcript.
4. **Default**: answered (2026-11-12): opt-in, switched on only in a build made for it. He added: "Let's start opt-in and if it is stable we can make it opt-out." Making it default-on later is his stated intent once it is stable; it must still meet the 2026-10-05 battery and privacy bar (not expected for recordings, which stay opt-in by decision 3), and it is a new decision when the time comes.
5. **Tombstone length**: answered (2026-11-12): "agree", to "90 days after a device was last seen. Cost: a phone unused longer than that re-syncs from scratch, and keeps its own data."

None of these touches his Library or the database today: this note changes no code.

## What would show this recommendation wrong

- The convergence simulator (slice 1) cannot reach "every replica identical, no Margin lost" without a design change: then the per-field merge is too weak and a plain "keep both versions" model is needed.
- Apple's docs show that `encryptedValues` data or assets can be read by Apple, or that a record's encrypted values are lost when a listener resets iCloud Keychain: the "encrypted so Apple holds only ciphertext" claim cannot be made, and the owner's end-to-end rule (2026-10-05) then blocks shipping, or means we encrypt with our own key stored in the Keychain.
- Item keys over-split in practice (the same article lands as two items on most pairs of phones): sync then has little to attach to, and the first slice should be item matching, not Margins.
- Testers say the "On your other device" list is more confusing than helpful: then Margins should wait for the item to exist, or the feature needs items synced as content.
- Real listeners have only one device. The Build 36 beta can show this before any code: ask the testers how many devices they listen on.
