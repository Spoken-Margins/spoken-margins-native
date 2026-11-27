# Reply mailbox: a browser friend answers through the share link (#4675)

**Status (2026-11-26).** The owner said to build it now, in one session and one PR, with no four-friend file test first ("Why would we do a forefriend test with files? That sounds like the most miserable thing we could possibly subject ourselves to.", 2026-11-26). The design below is the Design comment posted on #4675 on 2026-11-22, kept as written except for the changes listed here. Where the two differ, this list wins.

## Changes since the 2026-11-22 Design

1. **One PR, not eleven.** The "PR plan" below is kept as a map of the pieces; all of them ship in one PR under the 2026-11-23 whole-issue rule. Nothing is hidden behind a merge order: each side ignores the new parts when the other side doesn't have them (an older server ignores the upload headers, an older page never asks for `/l/<id>/reply`, a link with no reply part shows today's Share section).
2. **The shared vector lives with the other sealing vectors**: `research/B4/contracts/fixtures/reply-box-vector.json`, not `Contracts/fixtures/`. It also carries the four upload header values.
3. **`SM_LINK_REPLIES` follows `SM_SHARE_LINK_CREATION`.** It is still a build-time setting (never a value read from the network, 2026-10-17), but `project.yml` sets it to the link-creation value, so any build that makes links makes reply boxes and no upload workflow needs a new input. The server's `replies` switch can only turn the feature off.
4. **The receive-only rule changes** as the owner allowed on 2026-11-26 (`docs/decisions.md`): the web app creates no links and no boxes, and may post a sealed answer into the reply box the sender's phone made for that link.
5. **#4784's intro links.** Only the transport part is covered: links made on the Mac get no box, so persona and intro links never become an inbox. #4784's per-link one-way choice and its wording stay on #4784.

## Wire contract (the pieces every side must agree on)

- **Upload headers** on `POST /api/v1/links`, all four or none: `X-SM-Reply-Id` (32 lowercase hex), `X-SM-Reply-Read-Hash` (64 lowercase hex, SHA-256 of the 32 read-proof bytes), `X-SM-Reply-Post-Hash` (same for the post proof), `X-SM-Reply-Part` (standard base64 of the sealed reply part, at most 1 KiB decoded). Anything malformed, or the `replies` switch off: no box, the link is still made. The `201` body gains `"replyBox": true` only when the box was made.
- **Box secret K**: 32 random bytes on the phone. The id, read proof, post proof and seal key come from it exactly as for a club (`ClubSealing.Credentials`, HKDF-SHA-256, empty salt, `sm-club-*-v1`).
- **Reply part**: JSON `{"v":1,"box":"<32 hex id>","post":"<64 hex post proof>","seal":"<43-char base64url seal key>"}`, sealed with the **link** key as `SMLINK` part 4, additional data the 8-byte header only. Served raw at `GET /l/<id>/reply` with the link's CORS. Unknown keys are ignored.
- **An answer**: an ordinary browser `.spokenmargins` packet, sealed as a club post: `SMLINK` part 2 with the seal key, additional data the header then the 16 box id bytes. Posted raw to `POST /api/v1/clubs/<id>/posts` with `Authorization: Bearer <post proof>`.
- **Close**: `POST /api/v1/clubs/<id>/close` with `Authorization: Bearer <read proof>`, reply boxes only.
- **List, fetch, report, report reason**: the club routes as they are, gated by `replies` instead of `clubs` for a box of kind `reply`.

---

**Design**

A friend who opens a share link in a browser answers with **Send to <sender>**. The browser seals the answer and posts it to a small reply box that the sender's phone made along with the link. The sender's phone picks it up the next time Spoken Margins comes to the front.

The link's address does not change, so every shipped build and page still opens it. Sending as a file stays as the fallback, so the friend never hits a dead end.

The **Decision for Cole** card is a separate comment. Nothing a listener can see merges before his answer.

In the strings below, "<Sender>" is the sender's name as the packet carries it, or "your friend" when it has none.

## Answers to the issue's six questions

1. **CORS.** The club server does not accept posts from a browser today. Club routes have no CORS and no OPTIONS handler (`research/B4/server/internal/api/api.go:260-267`). `link_cors.go:21` says uploads never answer CORS.
   - The design adds CORS to one route only: posts to a reply box (`POST /api/v1/clubs/<id>/posts`) and its preflight.
   - Only the exact web-listener origins already set for links are allowed (`-link-origins`, `cmd/smserver/main.go:139`), with `POST`, `Authorization` and `Content-Type`.
   - The CORS headers are set before any check, as `linkCORS` does (`link_cors.go:29-31`). Without that, a browser reads every `404`, `410` or `429` as "offline".
   - Ordinary clubs keep no CORS.
2. **Limits.**
   - A box takes answers only while its link is live: up to 30 days (`internal/links/store.go:18`), and not after a takedown or hold.
   - The sender's phone can still fetch answers for 7 days after that, so an answer sent on day 29 isn't lost.
   - A box holds at most 20 answers and 50 MB; one answer is at most 10 MB.
   - The clubs' 7-day "no post yet" deletion doesn't apply: a box nobody answers is normal.
   - Writes are limited to 30 an hour per address, as for clubs.
   - Reply boxes count against the clubs' 5 GB pool.
3. **How the sender learns an answer arrived.** No push and no background fetch.
   - The phone checks its open boxes when the app comes to the front, at most every 2 minutes, and on Following's pull-to-refresh. Then it shows one banner.
   - This is enough for the beta. It would be shown wrong if friends' answers sit unheard for days in the hand-counted closed-loop tally (#4679).
   - Push stays its own opt-in design (`club-mailbox.md` section 6).
4. **A link older builds still open.**
   - The address stays `/l/<id>#<key>`. Today's parsers reject any query and anything extra after the key: Swift `ShareLinkSealing.swift:45-55`, web `Web/src/app/logic/share-link.ts:62` and `share-link-open.mjs:30-45`.
   - So the box's details travel as a small sealed part beside `preview` and `packet`, served from `GET /l/<id>/reply`. Old apps and pages never ask for it.
   - The phone sends the box in request **headers** on the existing upload. An older server ignores unknown headers and makes the link as today, whereas it refuses an unknown multipart part with `400` (`links.go:98-101`).
   - The packet format is unchanged.
5. **When the box is closed, full or ended,** the friend sees one neutral line, "This link can't take answers any more", plus today's way to send a file. The line never says the sender stopped them, which is the usual practice for a block. The friend's Margins stay in the browser whatever happens.
6. **Closed-loop measure.** An owner command, `smserver replies count`, prints two numbers worked out from the store when it runs: "reply boxes" and "with at least one answer".
   - It stores nothing new, names no box, and isn't reachable over HTTP.
   - It covers about the last 37 days, because boxes end with their links.

## Flow

1. **Sender, Share Margins sheet, review step** (`tour-light-18-share-review`): taps **Share link**.
   - If this is their first link, the existing "Share as a link?" consent comes first. Its words now include answers (screen A).
   - The phone uploads the link as today, with the reply box in headers.
2. **Friend, browser, arrival page then Now Playing:** opens the link. This is unchanged. In parallel, the page fetches `GET /l/<id>/reply`.
3. **Friend, Now Playing:** hears the Margins and records or writes an answer. This is unchanged. New answers start ticked (`Web/src/app/logic/reply-back.ts:123`).
4. **Friend, Share section:** ticks what goes and taps **Send to <sender>**.
5. **Friend, Share section:** sees "Sent to <sender>", and **Sent** on each row that went. After the first send, #4671's "Get the iPhone app" invitation shows once.
6. **Sender's phone comes to the front:** each open box is fetched.
   - An answer to the shared item is imported quietly: no screen change and no playback change.
   - Anything else is dropped.
7. **Sender, top banner:** names the friend and the item, with **Open**.
   - **Open** goes to the item screen, which already offers "Skip to <friend>'s replies" (journey J14 step 6). Each answer plays after its parent Margin (#3257).
   - The Following friend row shows "N new", and the Library row shows its new-Margins dot.
8. **Sender, the answer's friend card, About** (optional): **Stop answers through this link** or **Report this answer**.

**Fallback.** When the link has no reply part, the friend sees today's section unchanged. That covers:
- a link from an older phone build
- a link made on the Mac
- a box the server didn't make
- a failed or slow fetch
- the `replies` switch being off
- a page whose origin isn't allowed, such as the Android shell if it isn't in `-link-origins`

## Screens

### A. Share Margins sheet and first-link consent (iPhone)

Capture: `tour-light-18-share-review`, commit `0539b4b`.

- **Caption** under **Send as a file**, when links are offered and this build has reply boxes on: "A link opens in any browser, and your friend can answer through it. Your friend needs Spoken Margins to open a file."
  - With reply boxes off it stays "Your friend needs Spoken Margins to open a file. A link opens in any browser." (`ShareFileMessage.caption(linksOffered:)`, `ShareFileMessage.swift:24`).
- **Share link** works exactly as today. If the server doesn't make the box, the link is still made, the phone stores no box, and the friend gets the file path.
- No toggle and no extra step.
- **Consent.** `ShareLinkConsentCopy.message` (`ServerSendConsent.swift:54`) gains a paragraph after its first one: "Your friend can answer through the link. Their answers are locked the same way, wait on our server until your phone collects them or the link ends, and only your phone can open them."
  - `ServerSendConsent.disclosureVersion` goes from 2 to 3. People who already agreed are asked once more, as the comment on that type requires when the code sends more.
  - Both the paragraph and the version bump apply only in a build with `SM_LINK_REPLIES` on. A build without it keeps version 2 and today's words, because the copy "says only what the code does today" (`ServerSendConsent.swift:44-47`). This lands in PR 10.

### B. Web listener, Share section of Now Playing

The section is `ShareMargins`, `Web/src/app/screens/NowPlaying.tsx:447-612`. There is no capture of it in the tour; the Test Desk takes one (PR 9).

When the link has a reply part:

| Part | Words |
| --- | --- |
| Legend | Unchanged: "Share replies with <sender>" or "Share your Margins with <sender>" (`reply-back.ts:107`) |
| Caption, replacing "Share them as a file. …" | "They go back through this link. Only <sender> can hear them." With no name: "They go back through this link. Only the person who sent it can hear them." |
| Primary button | "Send to <sender>" or "Send to your friend" |
| Secondary, text-style button | "Send as a file instead". It opens the share sheet, today's `sendFile`. Where the browser can't share files it reads "Save as a file instead" (`downloadFile`). In the Android app it reads "Save or send instead" (`saveFile`). Each is today's code with today's results. |
| Name field | Unchanged: "Your name (optional)" |
| Saved card (`reply-back.ts:255`) | "Your Margin is saved. Send to <sender> sends it back. You pick which of your Margins go." |

States:

- **Ready.** As above. With nothing ticked, today's line: "Tick at least one Margin above to send it." (`reply-back.ts:161`).
- **Sending.** The primary button reads "Sending…" and every button is disabled, as today's `busy` state does (`NowPlaying.tsx:457`).
- **Sent.**
  - Status line: "Sent to <sender>. They'll get it the next time they open Spoken Margins." With no name: "Sent. Your friend gets it the next time they open Spoken Margins."
  - Each sent row gets a **Sent** tag, in the same tag style and place as "Reply" and "Starred" (`NowPlaying.tsx:562-563`).
  - Sent rows start unticked from then on. A later Margin starts ticked as usual.
  - When every Margin has been sent, the why-not line reads "Everything here has been sent."
  - The mark is a `sentThrough: <link id>` field on the Margin in the web's own store (`Web/src/app/data.tsx`), set after a `201` by a new store method `markSentThrough(marginIds, linkId)`. It merges on edit the way `shared-as.ts` does. It is not a separate `localStorage` key.
  - After a box send the page also calls the existing `addSharedAs` with the written packet's facts, as a file send does, so an answer to an answer still threads (#4174).
- **Fetching the reply part.** Nothing is shown. The Share section draws once the packet has opened and the reply fetch has settled. A fetch that hasn't answered in 5 seconds counts as no reply part. The fetch never delays the first play.

Errors. The friend's Margins stay in the browser in every row.

| Server answer | Line in `#share-why-not` | Buttons |
| --- | --- | --- |
| `410 expired_or_removed`, `409 club_full`, `404 not_found`, `503 full`, `503 disabled` | "This link can't take answers any more. Send them to <sender> as a file instead." | The file button becomes primary, with its own label as above. Send is hidden. |
| `413 too_large` | "These are too big to send through the link. Untick a long recording, or send them as a file." | Send stays, and so does the file button. |
| Network error, `429 rate_limited`, `503 busy` | "Couldn't send. Check your connection, then try again." | "Try again" (primary) and the file button. |

### C. Arrival banner (iPhone)

There is no capture of a banner. This uses the existing top banner (`UserFeedbackBanner`, `AppTopBanners.swift:65,85`) with one button.

- **One friend, one item:** "<Name> answered you on <Title>", with **Open**.
  - <Title> is the sender's own Library title for the shared item, never a title from the packet.
  - <Name> is the name the friend typed, or "A friend" (`FollowingFriends.swift:46`).
  - **Open** shows the item screen (`showImportedItem`) and starts nothing.
- **Several friends:** "New answers from <N> friends".
- **One friend on several items:** "<N> new answers from <Name>".
  - In both, **Open** goes to the Following tab.
- **Timing.**
  - While a Margin is being recorded or written, the banner waits until it ends. The import coordinator already does this (`SpokenMarginsPackageImportCoordinator.swift:528`).
  - Pickup does not run while the Terms sheet is on screen, or before the listener agreed to links that take answers. The on-device voice Terms are not a condition: a podcast-only sender never sees them and "Use iOS Voice" declines them (Test Desk run on #5397, 2026-11-26).
  - A check that finds nothing, or fails, shows nothing.

### D. Friend card on the item screen, for an answer that came through your reply box

The card is `Build23ImportedMarginPresentation.swift`, inside **About**. It is partly visible in `tour-light-20-arrival`; there is no capture of its About part.

- **Report this answer** replaces "Report this link" (`:245-252`) for these answers only. The friend made no link, and a link report would point at the sender's own link.
- **Stop answers through this link** is new.
  - Confirm dialog title: "Stop answers through this link?"
  - Message: "<Name> can still listen. New answers through this link won't reach you."
  - Buttons: **Stop Answers** (destructive) and **Cancel**.
  - Done: banner "Answers through this link are stopped." The answers already here stay.
  - Offline or failed: "Couldn't stop answers. Check your connection and try again."
  - A box that has already ended counts as done.
  - Once stopped, the row reads "Answers through this link are stopped" and is disabled.
- **About** gains one line: "Names on answers are typed by whoever sends them." The name is a label, not proof.
- "Hide this sender" stays absent, as today when a layer has no `senderId`. Browser packets carry none (`Web/src/packet/write.ts:237`).
- "Hide this Margin" stays.

### E. Report this answer sheet (iPhone, new)

The sheet is a standard SwiftUI `Form` in a sheet with a navigation bar.

- **Title:** "Report this answer".
- **Bar buttons:** **Cancel** on the leading side. **Send Report** on the trailing side, disabled until a category is chosen.
- **Section "What is wrong?"**: six rows with a checkmark on the chosen one, in the web form's words and order (`research/B4/server/internal/links/preview.go:52`):
  1. "Intimate content shared without consent" (`intimate_images`)
  2. "Child sexual abuse material" (`abuse_material`)
  3. "Harassment or defamation" (`harassment`)
  4. "Hateful conduct" (`hateful_conduct`)
  5. "Copyright" (`copyright`)
  6. "Other" (`other`)
- **Section "What happened?"**: a multi-line field, "Optional".
  - When the server answers `reasonOutstanding: true` (a second report within 7 days), the sheet stays open. The footer reads "Please say what happened, then send again." The report is finished with `POST /api/v1/clubs/<boxId>/report/reason`.
- **Toggle:** "Also stop answers through this link". On by default.
- **Sends** `POST /api/v1/clubs/<boxId>/report` with these form fields:
  - `category`
  - `post=<seq>`
  - `reason`
  - the header `Authorization: Bearer <read proof>`
  - for "Child sexual abuse material" only, also `link=https://<host>/c/<boxId>#<K>`, so the hold keeps a key (`club-mailbox.md` section 7 point 3)
- **After a `200`:**
  - The answer's Margins are hidden on this phone, through the existing Hide-this-Margin store.
  - If the toggle is on, the box is closed. A close that fails doesn't undo the report.
  - Banner: "Report sent. Reference <ref>." If the close failed, the banner adds "Couldn't stop answers. Try again from the card."
- **After a `404`** (the box ended more than 7 days ago, so nothing is left on the server): the answer is hidden. Banner: "Hidden on this phone. The link has ended, so nothing of it is left on our server."
  - An abuse-material report still answers `200` on an ended box, so its link is still held (`club-mailbox.md:105`).
- **Offline or failed:** the sheet stays open with the footer "Couldn't send the report. Check your connection and try again." Nothing is hidden or closed.

## Around it

- **Before.** Making a link: journey J12 steps 1-3, the share review (#4603) and the sender check (#4134). Unchanged.
  - The box rides the same `POST /api/v1/links` request as headers.
  - Any answer but `201` leaves today's errors in place.
  - A `201` without `"replyBox": true` (an older server, the switch off, bad box headers) means no box is stored and the link works as today.
- **The friend's arrival** (#3247, `Arrival.tsx`) and playback: unchanged.
- **The friend's other exits:** "Send as a file", "Save as a file" and the Android app's "Save or send" (`Web/src/app/download.ts:23-31`) keep working in every state. #4671's invitation also fires on the new `sent` outcome (`app-invite.ts:58`), still only for a reply.
- **After.** Hearing answers (J14 step 6, "Skip to <friend>'s replies") and J9's new-Margins offer: unchanged.
  - An answer is an ordinary web packet through the existing importer, which is idempotent by digest (#468). A re-fetch or a second send never duplicates.
  - **Same item playing.** If the answer lands on the item that is playing right now, playback is not paused, sought or restarted. Answers whose parent is still ahead play after it in place, like any friend Margin. Answers whose parent is behind show as new on the item screen.
- **Only answers to the shared item get in.** The phone imports a fetched packet only when the importer places it on the item that was shared, the `itemId` kept in the box record.
  - If its `margin-conversation` part names a parent, the parent's `parentPackageDigest` must also be the digest of the package the link carried.
  - Anything else is dropped. A packet that would need the review sheet (`SharedPacketArrival.route` → `.review`) is dropped too.
  - Each drop writes a Diagnostics line, `reply_box.dropped` with a reason and no content, and the cursor moves on.
  - So someone who has a forwarded link can't add other items to the sender's Library or put a made-up title in the banner.
- **Takedown.** A box takes posts only while its link is live. The post handler asks the link store, so a reported, held or expired link stops posts with no separate hook. The owner's `smserver club` disable and takedown commands work on reply boxes as on clubs.
- **The receive-only rule.** The web bundle still creates no link and no box.
  - `Web/src/app/no-link-creation.test.ts` gains a check that the bundle never holds the string `/api/v1/clubs'` or `/api/v1/clubs"` (club creation has no id after it). It may hold `/api/v1/clubs/${`.
  - The browser sealer is named `sealAnswer`, not `sealPart`.
- **Switches.**
  - Reply boxes have their own server switch, `replies`, off by default. For a box of kind `reply`, every club route checks `replies` instead of `clubs`: post, list, fetch, report, report reason and close. So reply boxes work fully with `clubs` off, and club creation (`POST /api/v1/clubs`, which takes no credential) stays closed.
  - On the phone, a build-time setting, `SM_LINK_REPLIES`, follows the `SM_SHARE_LINK_CREATION` pattern (a Swift condition plus an Info.plist key, `project.yml:26-39`). It does nothing unless link creation is also on.
  - The server switch can only turn the feature off, never on (2026-10-17).
- **iCloud sync** (`docs/design/icloud-library-sync.md`): box records stay on the phone that made the link.
- **Privacy** (`club-mailbox.md` section 9): PR 8 updates the B4 breach note, the privacy page and the App Store review notes.
  - What the server learns: this link has a reply box, and how many answers of what size arrived.
  - While upload permits are on, the link is tied to the sender's install handle (`links.go:156`), so the box is too. It is no longer true that box requests carry no install identity at creation.

## Honest limits

1. **A forwarded link lets anyone answer.** The sender's remedy is to stop answers on that link. Names on answers are typed by the sender of each answer and prove nothing.
2. **Boxes come only from app installs only once upload permits are required.** Until then (#4134, `-links-require-permit` off), anyone can call the upload, rate-limited, as for links today.
3. **Anyone who has the link can disable the whole box with a report that needs no proof** (`club-mailbox.md:104`), as for a link today. Answers not yet collected are then lost.
4. **Box keys live on one phone.** After a reinstall the answers can't be fetched; the friend was still told "Sent", which was true when they sent.
5. **One check sends one list request per open box,** at most 20: the ones checked longest ago, so every open box gets its turn. In that burst the server could tie together the boxes, and so the links, that one address checks. It holds the hashed address in memory for an hour at most and writes none of it down (`club-mailbox.md` section 8).
6. **"Sent" means the answer reached the box, not the sender.** A delivered receipt is #3902.

## Outcomes

| Asked for (quoted) | Where the design meets it |
| --- | --- |
| "How might a friend who answers in the browser get their reply back to the sender as a link, not a file?" (issue) | Screen B, **Send to <sender>**; flow steps 6-7 |
| "I really like the idea of being able to send Margins back through the link." (owner, 2026-11-18) | The whole flow |
| "it stays with our rule of not generating links from the web browser" (owner) | The browser creates no link and no box; the bundle test enforces it. Boxes come only from the phone's link upload. |
| "the person generating the links knows who they sent it to. So if they're getting abuse from them, they can at the very least stop doing that." (owner) | Screen D, **Stop answers through this link**, keyed to the read proof only the sender's phone holds. Forwarding weakens "knows who": honest limit 1. |
| "And of course, they can still report it." (owner) | Screen E |
| Accounts "for as long as I can get away with" (owner) | No account anywhere. Posts and reads carry no identity. |
| "add a close call keyed to a proof only the sender holds" (issue) | `POST /api/v1/clubs/<id>/close` with `Bearer <read proof>` |
| "whether a reply box is created with the attested share-link upload (so only app installs make boxes)" (issue) | Yes, it rides `POST /api/v1/links`. App-only from the day permits are required (honest limit 2). |
| "What the friend sees if the box is closed, full or expired: fall back to today's file, never a dead end." (issue) | Screen B errors |
| "Whether reply counts can give the closed-loop measure as a server-side aggregate … with no attribution." (issue) | Answer 6, `smserver replies count` |
| Answers to questions 1-6 (issue) | "Answers to the issue's six questions" above |
| Starting states: first run, arrived by link, arrived by file, an item already heard (issue, #4102) | "Starting states" below |
| "Recipient Margins stay private/local unless the recipient deliberately selects and sends them" (#4784) | Nothing leaves without the tap; only ticked rows go; **Sent** marks show what went |
| "Public persona/marketing links do not become an unsolicited reply inbox" (#4784) | Links made on the Mac (`Web/src/cli/link-sealing.ts`) get no box. A per-link one-way choice stays #4784's to design, on top of this transport. |
| "a draft, queued send, and failed send remain distinguishable" (#4784) | Screen B: unticked or ticked rows, "Sending…", **Sent** tags and the error lines |

## Device conditions

- **`network`**
  - Phone offline at a check: nothing shown, cursor unmoved, the next check fetches.
  - Browser offline at Send: "Couldn't send…", and the retry succeeds.
  - Server `429` and `503 busy` on both sides.
  - An upload answered `201` with no `replyBox` stores no box.
- **`web-packet`**
  - A fetched answer is browser-shaped: sender clock only, no fingerprint, no `senderId`, possibly `itemTransport: recipient_supplied` (`write.ts:240`).
  - Assert it lands after its parent on the shared item, under the typed name.
  - A packet for another item, or with another parent digest, is dropped.
- **`relaunch`**
  - Box records and cursors live in SQLite.
  - Kill the app between the fetch and the import, then relaunch: exactly one import, nothing skipped.
  - The cursor moves only after the import commits.
- **`background`**
  - The app is left mid-check: the check stops, the cursor stays put for anything not imported, and nothing runs in the background.
- **`burst`**
  - Two "became active" events within 2 minutes give one check.
  - Two friends posting at once both arrive.
  - A double tap on **Send to <sender>** gives one post.
- **`store`**
  - A check while the store isn't open waits for it. It never reads an empty box list and never drops a box.

`lock`, `route`, `live-activity`, `hot`, `long-source` and `main-thread` don't apply. The check is network I/O off the main actor, and the import already runs off it.

## Starting states

| State | Expected |
| --- | --- |
| Friend, `first-run` in the browser | Screen B as written. New answers start ticked. #4671's invitation shows once after the first send. |
| Friend arrived by **file** | No link, so no reply part. Today's section, unchanged. |
| Friend with the iPhone app opens the link | The app's own path, unchanged ("Share replies with <friend>" makes a link back). This design covers the browser only. |
| Friend reopens the same link later (`returning`) | **Sent** marks come back from the web store; unsent Margins are offered |
| Link forwarded to a second person | Both can send. Each answer appears under its typed name or "A friend". Honest limit 1. |
| Sender, `first-run` (first link ever) | The consent sheet with the new paragraph, then the box is made. The first check finds nothing and shows nothing. |
| Sender `returning`, agreed to version 3 of the consent | Asked once more (version 4) at their next link |
| Sender, `already-heard` or `finished`: the answer lands on an item at 100% or marked complete | Imported as new Margins. The banner names the item. **Open** reaches it even when "Completed hidden" hides its Library row. Each answer plays after its parent (#3257). Where Continue starts follows `SessionContinuation`, unchanged. |
| Sender, `other-item-playing`: another item plays, is paused or records during a check | Playback is untouched, and the item that was playing still is. The banner waits while a Margin records or is written. |
| Sender, the same item is playing when its answer arrives | See "Same item playing" in "Around it" |
| Sender deleted the shared item since sharing | Answers don't match a Library item, so they're dropped with a Diagnostics line. The friend still saw "Sent". |
| Sender reinstalled or moved phones | Honest limit 4 |
| Sender stopped answers, then a friend sends | "This link can't take answers any more. Send them to <sender> as a file instead." |

## PR plan

**PR 0 (docs) is safe in all three of Cole's options.** It adds `docs/design/reply-mailbox.md`, holding this comment's design, which meets the issue's done-when. After he answers, it records his answer in `docs/decisions.md`.

**Builds.** Each build PR gets its own issue, `Part of #4675`, filed after his answer. PRs 1-8 are hidden: no listener sees a change until PR 9 and PR 10 are both live. A SessionKit change that alters an enum the app switches on goes in an app PR, never a SessionKit-only one.

**Wire formats** (shared by PRs 1, 3, 5 and 8):

- **Upload headers** on `POST /api/v1/links`, all four or none:
  - `X-SM-Reply-Id`: the box id, 32 lowercase hex
  - `X-SM-Reply-Read-Hash`: SHA-256 of the read proof, 64 lowercase hex
  - `X-SM-Reply-Post-Hash`: SHA-256 of the post proof, 64 lowercase hex
  - `X-SM-Reply-Part`: the sealed reply part, standard base64, at most 1 KiB decoded
  - Anything malformed means no box. The link is still made.
- **Reply part, unsealed:** JSON `{"v":1,"box":"<32 hex>","post":"<64 hex post proof>","seal":"<43-char base64url seal key, no padding>"}`. Unknown keys are ignored when read.
  - It is sealed with the link key, `SMLINK` header part 4 as associated data, the same as `preview` (part 1) and `packet` (part 2).
  - Add `reply = 4` to the part constants in Go (`internal/links/sealed.go`, next to `PartClubHeader = 3`), in Swift (`ShareLinkSealing`) and on the web (`PART` in `Web/src/packet/share-link.ts`).
- **An answer post:** the club post format (`club-mailbox.md` section 2): `SMLINK` part 2, box id as associated data, sealed with the seal key.
- **Shared vector:** `Contracts/fixtures/reply-box-vector.json`. It holds a fixed K, the derived values, a fixed link key, the sealed reply part and one sealed answer. Swift, web and Go tests all read it.

**Hidden pieces.** Each merges alone.

1. **Server: reply-box store** (`research/B4/server/internal/clubs`).
   - `CreateReply(id, readHash, postHash, linkID, postsUntil)` writes metadata `kind: "reply"`, `linkId` and `postsUntil`. `readsUntil` is `postsUntil` plus 7 days.
   - No header: `seq 0` answers `404` for reply boxes.
   - Reply limits as constants: 20 posts, 50 MB per box, 10 MB per post.
   - The sweep ends a reply box at `readsUntil` and skips the 7-day and 90-day rules.
   - A new state, `closed`. Posts to a closed box get `410 expired_or_removed`. Reads, and report and report reason with the read proof, still work until `readsUntil`. Strangers still get `404`.
   - `Close(id, readProof)`.
   - Tests (`go test ./...` through `scripts/research_tests.py`):
     - caps: the 21st post gets `409`; 10 MB plus one byte gets `413`
     - no 7-day deletion
     - posts stop at `postsUntil` while reads work until `readsUntil`
     - closed behaviour, including a post-level report with the read proof on a closed box
     - the folder holds exactly the declared files
     - the section 4 log tests extended to reply boxes
2. **Server: link upload and routes** (`internal/api/links.go`, `clubs.go`, `club_reports.go`, new `reply_cors.go`, `internal/links` (store), `config.go`, `cmd/smserver/club.go`).
   - Read the four headers.
   - **Order:**
     1. Put the link as today (`links.go:146`).
     2. Bind the sender as today (`:152-157`). If that fails and takes the link down, no box is made.
     3. Create the box with the new link's id and `expiresAt`.
     4. Store the sealed part as a `reply` file in the link's folder, through a new `links` store call. It is swept and taken down with the link.
     5. Answer `"replyBox": true` in the `201`.
   - If step 3 or 4 fails, the half-made box is removed and the link is answered with `replyBox` false.
   - `GET /l/{id}/reply`: the sealed part, under the link's CORS (`link_cors.go`). Register `OPTIONS /l/{id}/reply` next to the existing preflights (`api.go:268-269`). It answers `404` when there is none, and the same as `/packet` for an expired or removed link.
   - Every club route, for a box of kind `reply`: post, list, fetch, report, report reason and close.
     - It checks `replies` instead of `clubs`.
     - The post route also asks the link store whether `linkId` is live, and treats an ended link as ended.
   - The post route sets CORS for exact `-link-origins` before every check, error answers included, and answers `OPTIONS` (POST, `Authorization`, `Content-Type`).
   - `POST /api/v1/clubs/{id}/close` with `Bearer <read proof>`: reply boxes only. A post proof or a stranger gets `404`.
   - `smserver replies count` prints `reply boxes: N` and `with at least one answer: M`.
   - Tests:
     - a link with and without headers
     - malformed headers make a link with no box
     - `replies` off makes a link with no box
     - `clubs` off with `replies` on: post, list, fetch, report and close all work on a reply box
     - `POST /api/v1/clubs` stays `503` with `clubs` off
     - a takedown stops posts
     - a preflight from an allowed origin passes; another origin gets no CORS; an ordinary club gets no CORS
     - a `410` body is readable from a browser origin
     - close with the read proof works; with the post proof it gets `404`
     - the count output names no id
3. **SessionKit: the box, the sealed part and the record.**
   - New `Packages/SessionKit/Sources/SessionKit/ReplyBox.swift`:
     - make K
     - derive the values through `ClubSealing.Credentials` (`ClubSealing.swift:83`)
     - build the four headers and the reply part
     - give `ClubInvite(key:)` (`:240`) for `ClubClient.fetchNew`
   - Widen the share-link part enum with `reply`.
   - `ShareLinkUpload.makeLink` takes an optional `ReplyBox`. With nil, the request is byte-for-byte today's. It reads `replyBox` from the `201`.
   - `SessionKitPersistence`: a `reply_box` record kind, on the `follow_list` pattern (`SQLiteSessionStore.swift:1635-1675`, `columns()` case at `:328`). It holds:
     - linkId and boxId
     - K
     - itemId
     - sharedPackageDigest
     - expiresAt
     - cursor
     - closed
     - `answers: [{seq, layerId}]`
   - K is kept in that record, protected like the rest of the database. It opens only answers sent to this phone.
   - No change to any existing record.
   - Tests:
     - the vector round-trips
     - the record survives a relaunch on real SQLite
     - a database written by this build opens in the shipped build's reader (the #4309 pattern, `Build29PersistedShapeTests`)
     - nil box means an unchanged request
4. **SessionKit: pickup.** New `ReplyBoxPickup`.
   - An injected clock gives the 2-minute throttle.
   - Each check takes up to 20 boxes with `now < expiresAt + 7 days`, the ones checked longest ago first (a `lastChecked` field in the record).
   - It lists each box's new posts, then fetches them one at a time, so no more than one 10 MB answer is held in memory.
   - It hands each opened packet to an injected importer. After the importer reports done or dropped, it saves `ClubClient.Cursor(lastPost: seq)` itself.
   - Unopenable posts are skipped, and the cursor moves past them. A `410` marks the box ended.
   - **Retention:** a record is kept until `expiresAt + 7 days`. After that it is kept while any of its `answers` layers is still in the Library, so Report keeps working, and deleted once none is.
   - Tests on a fake transport and real SQLite cover the `network`, `relaunch`, `background`, `burst` and `store` rows.
5. **SessionKit: words and requests.**
   - `ReplyArrivalWords`: banner C from `[(senderLabel: String?, itemTitle: String, itemId)]`, and the strings of D and E.
   - `ReplyBoxRequests`: build close, report and report-reason requests from a record and a seq.
   - `ShareFileMessage.caption(linksOffered:repliesOffered:)`. No caller passes `true` until PR 10.
   - Unit tests for every string branch, and for the request bodies, including the abuse-material `link`.
6. **Web logic, no UI.** `Web/src/app/logic/reply-box.ts` and its tests.
   - Fetch `GET ${origin}/l/${id}/reply` (the link's own origin, as `openSharedPacketWithExpiry` uses), with a 5-second ceiling. Open it.
   - `sealAnswer`.
   - Post to `${origin}/api/v1/clubs/${box}/posts`.
   - Map status plus the body's `error` string to screen B's three rows.
   - Check against `reply-box-vector.json`.
   - Extend `no-link-creation.test.ts`.
   - Tests: `npm run test:web`.
7. **App: quiet pickup and banner** (6a).
   - A focused `ReplyBoxCoordinator`, called from `handleAppBecameActive` (`Gate1AppModel.swift:1009`; one line, nothing added to the model) and from `pullToRefreshFollowing`.
   - Runs only once the listener agreed to links that take answers, and not while the Terms sheet is up.
   - Packet bytes go to a temporary file in Caches.
   - `SpokenMarginsPackageImportCoordinator.stage` gains `quiet: true`. The "only answers to the shared item" check runs before `confirm`. A quiet import skips the review queue (`queue.offer`) and shows nothing of its own. It suppresses:
     - the waiting message
     - the duplicate-open (`:232`)
     - `presentImportedItem` (`:567-584`)
     - `confirm`'s banners (`:527-532`)
     - the open-failure sheet (`presentOpenFailure`); a rejection is a silent drop with a Diagnostics line
     - `.restoreAudio`
     Banner C is its only output.
   - Banner C.
   - With no `reply_box` records, nothing fetches or shows.
   - App-hosted tests (run by `main-t3`), with a seeded record and a fake transport:
     - a quiet import raises banner C
     - another item's packet is dropped
     - `already-heard`, `finished`, `other-item-playing` and the same-item-playing case
8. **App: card actions and report sheet** (6b).
   - The card shows D only for layers in some record's `answers`.
   - Sheet E.
   - Close and report through `ReplyBoxRequests`. Hide through the existing Hide-this-Margin store.
   - App-hosted test: Report with the toggle hides the answer and closes the box; with a failing close it still reports.
   - Also in this PR, the privacy update in the "Around it" privacy item above:
     - B4 section 14
     - the privacy page sentence: "Answers through a link wait on our server, locked, until the sender's phone collects them, and are deleted at the latest a week after the link ends."
     - the App Store review notes
   - The site deploy is Cole's.

**Visible parts.** Each merges whole.

9. **Web: Send to <sender>.** Files: `NowPlaying.tsx` `ShareMargins`, `reply-back.ts`, `data.tsx` (`sentThrough`) and `app-invite.ts` (`ShareEnd` gains `sent`).
   - The new section turns on only when a link carries a reply part. Every other link shows today's section.
   - Extend `Web/e2e/link-stub-server.ts` to answer `GET /l/<id>/reply`, `POST`/`OPTIONS` on the box route, and one seeded box id per error row.
   - `Web/e2e/reply-box.spec.ts` covers:
     - send, then **Sent**
     - each error row, with its line and the file button
     - no reply part, so today's section
     - reopening, with the marks restored
     - the first play not waiting on a slow reply fetch
   - **After the PR is armed, the lane or the Test Desk** captures the section at phone width, light and dark, before and after.
   - The web deploy is Cole's (#2086).
10. **App: make the box with the link.** It waits on Cole's "go", on PRs 1-2 deployed with `replies` on, and on PR 9 deployed.
    - The `SM_LINK_REPLIES` build setting.
    - `ShareLinkSender` passes a fresh `ReplyBox` to `makeLink`, and stores the record (with itemId and the uploaded package's digest) only when the answer has `replyBox: true`.
    - The new caption, plus the consent paragraph and `disclosureVersion = 3`, both behind `SM_LINK_REPLIES` (screen A).
    - `docs/journeys.md` gains:
      - a browser variant of J12 steps 6-7
      - a J10 step: with the server unreachable, a check stays silent and the next one collects
    - Host test: the caption by flag; a record only on `replyBox: true`.
    - If the session can't build, the PR says "Not checked: not built, no journey run".
    - **After it is armed, the Test Desk runs the browser J12** on a test simulator and Playwright WebKit:
      1. make a link
      2. open it in the browser
      3. record and send
      4. bring the app to the front and see banner C
      5. **Open**
      6. hear the answer after its parent
      7. Stop answers
      8. send again and see the neutral line
      9. report, and see the answer hidden
      - It takes captures of A, C, D and E.
    - The real-use proof goes on the build issue: a real iPhone link, a real phone browser, a real send, the banner on the phone.

## Defaults taken

Veto any of these by number.

1. **The box's details travel as a sealed part fetched from `GET /l/<id>/reply`, and are uploaded as headers.**
   - Weighed:
     - a longer `#` part, which breaks every shipped parser ("This link is incomplete or damaged.")
     - a query parameter, which the web refuses
     - a field in the packet or preview, which touches packet compatibility and travels into saved files
     - a multipart part, which an older server refuses, so no link could be made at all
   - Headers are ignored by any server that doesn't know them.
2. **The link carries the post proof and seal key, derived on the phone, not K.** The friend can post but never read, and the browser needs no HKDF. Weighed: carrying K, which would let every holder of the link read every answer.
3. **Close is keyed to the read proof.** Weighed: a fifth derived value, which adds a derivation and no safety.
4. **Every link made from the iPhone share sheet gets a box when the build flag is on; links made on the Mac get none.** No per-link toggle.
   - Weighed: a toggle on the review sheet. That is one more choice per share, for the case #4784 is still designing.
   - Persona links are made on the Mac (#4679), so they never become an inbox.
5. **Limits:** 20 answers, 50 MB per box and 10 MB per answer. Posts stop with the link; reads go on 7 more days. These are starting points that the host tests pin.
6. **Pickup happens on coming to the front (at most every 2 minutes) and on Following's pull-to-refresh**, for up to 20 open boxes per check, the ones checked longest ago first. No push and no background fetch (`club-mailbox.md` section 6).
7. **Answers import quietly with one banner,** never a screen change. Weighed: opening the item like a tapped file, which would take over what the sender was doing.
8. **Only answers placed on the shared item are imported;** everything else is dropped. Weighed: holding the rest for review, which would let anyone with a forwarded link put items in front of the sender.
9. **Banner Open goes to the item** for one friend and one item, and to Following otherwise.
10. **One neutral line for closed, full and ended.** It doesn't tell a friend they were stopped.
11. **Wording follows the industry standard.** New strings use "answer"; existing "reply" strings are untouched.
12. **The report sheet is in the app** and uses the club report route with the read proof and the web form's six categories. Weighed: a web form, which doesn't exist for a club post, and the link form would report the sender's own link.
13. **Report hides the answer locally and stops the box by default.**
14. **No "it reached them" receipt.** "Sent" means it is in the box; #3902 stays open.
15. **K lives in the SQLite record, not the Keychain, and isn't synced.** It is short-lived and opens only answers to this phone.
16. **A reply fetch over 5 seconds counts as none,** so the friend can always act.
17. **The iPhone friend's path is unchanged.**
18. **Reply boxes get their own `replies` switch**, so `clubs` (whose create call takes no credential) can stay off.
19. **The consent version is bumped,** so everyone who agreed before is asked once more, because the code sends more than they agreed to.

**Checked:**

- **Captures:** tour `1794897834-0539b4b`, files `tour-light-18-share-review`, `-20-arrival`, `-05-margins`, `-06-following` and `-01-library`.
- **What `main` changed since:** `main` is at `e47e93958`. Since `0539b4b`, the web Share section gained #4614's length note and #4671's invitation, and the item card dropped its own "From <friend>" (#4597). Screens A and D are otherwise as captured.
- **No capture of:** the web Share section, banner C, card D's About part, or sheet E.
- **Docs:**
  - `docs/design/club-mailbox.md`
  - `docs/decisions.md`: 2026-10-17, 2026-10-30, 2026-11-02, 2026-11-05 (receive-only), 2026-11-09, 2026-11-10, 2026-11-12
  - `docs/journeys.md`: J9, J10, J12, J14 and "Starting state"
  - `docs/workstreams/device-conditions.md`
  - `docs/areas.md` (Pass it on)
  - `Design/proposals/four-tabs.md`
  - `docs/design/first-run.md` section 2
- **Code:**
  - Server: `research/B4/server/internal/api/{links.go,clubs.go,link_cors.go,api.go}`, `internal/clubs/clubs.go:52-62` and `internal/links/preview.go:52`
  - SessionKit: `Packages/SessionKit/Sources/SessionKit/{ShareLinkSealing,ClubSealing,ClubClient,SharedPacketArrival,ShareFileMessage,ServerSendConsent,FollowingFriends,MarginConversation}.swift`
  - Web: `Web/src/app/logic/{share-link,reply-back,share-send,app-invite}.ts`, `Web/src/app/{download.ts,data.tsx}`, `Web/src/app/screens/NowPlaying.tsx`, `Web/src/packet/write.ts` and `Web/src/app/no-link-creation.test.ts`
  - App: `App/.../SpokenMarginsPackageImportCoordinator.swift` and `Build23ImportedMarginPresentation.swift`
  - `project.yml:26-39`
- **Issues:** #4675 (body and comments), #4679, #4784, #3902, #3784 and #4671.
