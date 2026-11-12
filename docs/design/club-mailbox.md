# Club mailbox: what the server stores and logs (F1 M3, #1799 step 1)

Status: **the owner agreed to both questions in section 1 (2026-11-07, #1799).** Slice 1 of section 10, the server (`research/B4/server/internal/clubs`, `internal/api/clubs.go`), is built, switched off by default (`smserver switch ... clubs on` turns it on). Slice 2, the phone's sealing and client (`ClubSealing.swift`, `ClubClient.swift` in `Packages/SessionKit`), is built and host-tested on Linux (sealing, wire calls, cursor); no app screen uses it yet, and the test that merges fetched packets through the importer on real SQLite comes with slice 5, because the importer's tests run only on a Mac. The other slices are not. Part of #1799 (Done when 1). The stream brief is [F1-coop.md](../workstreams/streams/F1-coop.md); the server rules it must meet are in [research/B4/DESIGN.md](../../research/B4/DESIGN.md), sections 2, 3, 5, 11 and 14.

## 1. Questions for the owner

Both are yes or no. Silence is not an answer: the build waits for it.

1. **Is "anyone with the invite link is a member" fine for the closed beta?** The only way to remove someone is to make a new club and invite the others again. There is no member list and no admin. Pick: **yes**, because the beta is friends who already know each other (2026-10-17, #1799). Other option: per-member keys with a creator who can remove people. It costs a second design and a member list on the server, which is a name we would hold.
2. **Delete a club's whole mailbox after 90 days with no post and no read?** Pick: **yes.** Posts stay for the club's life, so a friend who joins in week five still hears the first four weeks. If he says no, the other option is to delete each post after 30 days, like a share link. It is smaller on disk, but a late joiner misses the start of the book.

## 2. What a club is, in plain words

A club is a **box of locked packets**. A member puts a packet in. Every other member's phone takes it out, unlocks it and merges it with the importer that already exists (#468: any order, no duplicates). The server holds the box. It never holds the key.

- **A packet in the box is an ordinary `.spokenmargins` packet**, sealed the way a share link's packet is (`SMLINK` header, AES-256-GCM, [`links/sealed.go`](../../research/B4/server/internal/links/sealed.go)). Once a phone has unsealed it, it is an ordinary packet that Build 32 and 34 import by file. Nothing new is required of a packet.
- **The key is one random 32-byte secret, `K`, made on the creator's phone.** It lives only in the invite link's `#` part, which a browser never sends to a server. Share links work the same way (#805).
- **The invite link is** `https://spokenmargins.proximitytoprogress.com/c/<clubId>#<K>`. The path part is public; the `#` part is the secret.
- **From `K` the phone derives four values with HKDF-SHA-256** (salt empty; info strings `sm-club-id-v1`, `sm-club-read-v1`, `sm-club-post-v1`, `sm-club-seal-v1`; 16, 32, 32 and 32 bytes). Slice 2 pins them with a shared test vector next to `share-link-sealing-vector.json`, checked by the Go and Swift tests. The server gets the club id and the *hashes* of the two proofs when the club is made. It never gets `K` or the sealing key; the four outputs are independent, so none gives away another.
- **The read and post proofs are both known to every member**, and the server sees one whenever it is used. Splitting them protects little. It only means a leaked read proof does not by itself let someone post. It is kept because it is free.
- **The phone checks that the id in the link's path equals the id derived from `K`**, and refuses the link if not.
- **Sealing reuses the `SMLINK` header with a new part value for the club header (3); posts are packets (part 2).** The club id goes in as GCM associated data (after the 8-byte header), so the server cannot move a post to another club or pass a post off as the header. **The post's number is not in it** (slice 2, Default taken on #1799): the server hands out numbers when a post arrives, so a phone cannot know its post's number when it seals it, and two members posting at once would seal for the same number. A moved or reordered post is the same packet at another place, and the importer takes packets in any order and once (#468), so nothing is lost. Byte-for-byte values are in `research/B4/contracts/fixtures/club-sealing-vector.json`. `links.Sealed` gains the new part value; it still checks only the 8-byte header and the minimum length.
- **A phone that cannot open a post skips it and still moves its cursor on.** One bad post must not block the club.
- **A club's name and the creator's chosen label are in a sealed header**, the first item in the box. The server stores the bytes and cannot read them.

## 3. What the server stores

For each club, and only this:

| Item | Why the server needs it | Kept |
| --- | --- | --- |
| Club id (random, from `K`) | The folder name. | Until the club expires or is taken down |
| SHA-256 of the read proof, SHA-256 of the post proof | To tell a member from a stranger without knowing `K`. | Same |
| The sealed header | So a joiner can see the club's name after unlocking it. | Same |
| Each post: a sequence number, its sealed bytes, its size | The box itself. Sequence numbers let a phone ask "everything after 17". | Same |
| Created day, last-active day, **day precision** | The 90-day idle expiry. File times, post files included, are set to midnight, as install records are (B4 section 2). | Same |
| Reports, if any: club id, post number, category, written reason, reference number | The report path (section 7). The owner reads them with `smserver reports`; they are never about content, which no one reads. | 90 days |
| In an abuse-material report only: the full invite link, **key included** | The CyberTipline hold (section 7). This is the one place `K` reaches the server, as it is for a held share link (#2235). | One year, restricted store |
| A "disabled" mark | A takedown or a hold stops serving the club without reading it (as `links` does). | Same |

**Not stored, and not knowable:** how many members a club has, who they are, any name or account, any IP address, any install key, who posted which packet, when in the day a post arrived, what a packet holds, how long a Margin is. The server sees sizes. A size says "a big packet" and nothing more; share packets already shrink at share time (#3218).

**Caps, so one club or one visitor cannot fill the box** (a number is a starting point; the host tests pin it):

- A post is at most 20 MB, the same as a share-link packet.
- A club holds at most 200 posts and 200 MB. A full club answers `409 club_full`; the app says "This club is full" and offers to start a new one.
- **A club with no post in its first 7 days is deleted.** Nobody can fill the disk for 90 days with empty clubs.
- **Clubs have their own cap of 5 GB, separate from share links**, so neither can crowd out the other. Past it, a new club or post gets `503 full`, which the app already treats as "couldn't right now" (the share-link rule).
- **Per hashed network address, in memory only:** 30 requests an hour (as link uploads), and at most 200 MB of posts an hour. One address cannot fill 5 GB in less than a day.
- Post uploads share the busy slot link uploads use, so a flood of uploads cannot starve memory (`linkSlots`).

## 4. What the server logs

Nothing new in kind. It follows B4 section 5 line for line, and each row below becomes a test.

| Where | What | Kept |
| --- | --- | --- |
| Caddy access log | Nothing (the site block has no `log` directive). | n/a |
| Caddy error log | Method and host, with the club path cut to `/api/v1/clubs/*` and `/c/*`, as maps and links already are. **New filter lines go in `deploy/caddy-global.caddy`.** The IP is stripped as today. | journald default |
| smserver request log | The hourly summary, route `/api/v1/clubs/*` or `/c/*`, status, count. Never a club id, a proof or a post number. | 14 days |
| Abuse log | Hour, reason, count. Clubs add **no install tag**, because club requests carry no install identity (section 5). **A club report counts toward the abuse log under its own key with no id in it.** Today's link report path writes the link id there (`linkReports` in `api.go`); club reports must not reuse it. | 30 days |
| Rate limiter | IPs hashed with a random per-process secret, in memory, reset hourly. | 1 hour, never on disk |

**Tests that must exist before the server is switched on:**

1. An end-to-end test fails if a club id, a proof, a post number or the sealed bytes appear in either log or in the abuse log, including after a report.
2. A test that the club folder holds exactly the declared files (the way `TestInstallRecordFileHoldsExactlyTheDeclaredFields` does for installs).
3. A test that a request with a wrong or missing proof gets the same `404` as an unknown club, and that a disabled or held club gives that same `404` until the proof is checked. (Share links answer `410` to anyone; clubs must not.)

## 5. Who can ask for what

**Default taken: club requests carry no install identity.** No App Attest key id, no anonymous token. They work like share-link uploads today (`uploadLink` asks for no identity), and the proof is the only credential.

- Options: (a) no identity, rate limit by hashed network address (picked); (b) App Attest on every club request; (c) a Privacy Pass token per post (B4 section 11).
- Why (a): B4 section 3 says a request that reveals interest must not carry the install's key id, and "F1 should decide that deliberately". With (b) a modified server could learn "this install is in that club". With (a) it cannot. (c) is stronger against abuse but the phone has no blind-signature code yet, and the closed beta does not need it. (c) is the upgrade if abuse appears: the token's purpose would be `clubs`.
- Cost of (a): one person can fill the per-club cap or make clubs up to the rate limit. The caps in section 3 bound that, and the owner can disable one club or all of them (section 7).
- What would show this is wrong: the hourly request log shows many `429` answers on the club routes.

Read and post work like this:

1. **Create:** `POST /api/v1/clubs` with the club id, the two proof hashes and the sealed header. `201`. A repeat with the same id and the same hashes answers `200`, so a retry after a lost answer works; the same id with other hashes is `409`. The id is 128 bits, so a `409` tells a stranger nothing they could not already guess.
2. **Post:** `POST /api/v1/clubs/<id>/posts` with the post proof as a bearer value and the sealed packet as the body. `201` with the sequence number.
3. **Fetch:** `GET /api/v1/clubs/<id>/posts?after=<n>` with the read proof returns the list `[{seq, size}]`; `GET /api/v1/clubs/<id>/posts/<seq>` returns the bytes. A phone remembers the last number it merged. It also remembers which posts it applied, because a re-send is harmless but pointless: the importer is idempotent by digest.
4. **No delete by members** in the first version. A poster who regrets a post asks the owner or leaves it. (Follow-up if wanted: a per-post delete key returned at post time.)

The server compares proofs in constant time and keeps no list of who presented one.

**The wire format, as built (slice 1; slice 2's Swift client and fixtures follow it).** Hashes, ids and proofs are lowercase hex. A proof is the 32 bytes the phone derived (64 digits) and its hash is the SHA-256 of those 32 bytes. Sealed bytes are the `SMLINK` header (version 1) plus nonce, ciphertext and tag, as for share links; the header's part is 3, a post's is 2.

| Call | Credential | Body | Answers |
| --- | --- | --- | --- |
| `POST /api/v1/clubs` | none | JSON `{"id", "readHash", "postHash", "header"}`, header as standard base64, at most 16 KiB sealed | `201`, `200` (repeat), `409 id_in_use`, `400 bad_request` or `bad_packet`, `413 too_large`, `429 rate_limited`, `503 disabled` or `full` |
| `POST /api/v1/clubs/<id>/posts` | `Authorization: Bearer <post proof>` | the sealed packet, at most 20 MB | `201 {"seq": n}`, `409 club_full`, `400 bad_packet`, `413`, `429`, `503 busy`, `full` or `disabled` |
| `GET /api/v1/clubs/<id>/posts?after=n` | `Bearer <read proof>` | none | `200 {"posts": [{"seq", "size"}]}` for every post after n |
| `GET /api/v1/clubs/<id>/posts/<seq>` | `Bearer <read proof>` | none | the sealed bytes, unchanged. **`seq` 0 is the sealed header**, the first item in the box; posts start at 1 with no gaps. |

A wrong or missing proof, an id that never existed and a malformed id all answer the same `404 not_found`. A member with the right proof whose club ended or was disabled gets `410 expired_or_removed`, so the app can say the club is gone; everyone else still gets the `404`. An ended club keeps only a tombstone (`meta.json`, state `gone`), so its id cannot be made again. Writes (creates and posts) are limited to 30 an hour and 200 MB of posts an hour per hashed network address, with the 30 counted whether or not the proof was right (the bytes only for a body that was read, which needs a right proof); reads are not counted, as share-link reads are not.

## 6. When the phone talks to the server

- **Nothing is sent until the listener creates or joins a club.** Joining is the opt-in (2026-10-10). Creating or joining a club asks first, with the same consent step that #2842 adds before the first share link leaves the phone (Apple agreement 3.3.3). The wording names the club mailbox.
- **No push notifications in the first version.** A push needs a device token, which ties a device to a club. The phone checks the box **when the app opens** and when the listener pulls to refresh. "A friend finished and left Margins" shows as a card the next time they open the app. Push stays a separate opt-in toggle, designed on its own.
- **No background polling.** A background fetch would tell the server "this address is in this club" every few hours. The first version does not do it.
- **The feature is gated like share-link creation:** a build setting (`SM_CLUB_CREATION`, name to be confirmed) turns on the create and join screens, and the server's `clubs` switch in `config.json` can only turn them *off* (the rule from 2026-10-17, as in #3281). A club that exists keeps working for a phone whose build has the flag.

## 7. Reports, hiding and takedown (Apple agreement 10(v), guideline 1.2)

The server cannot read a club, so every safety step starts on the phone or works blind. This follows the share-link rules in #2239 and #2846.

1. **Hide this sender, on the phone.** Each member's packets carry the random sender id from #1729 item 14: one id per club per install, never shared across clubs. A listener hides one sender in one club, locally. Nothing is sent.
2. **Report a post or the club.** The Report form (#2239) takes the club id and a post number. A report **disables that post at once, blind**, and the reporter gets a reference number. A category is always required; the second report in 7 days needs a written reason, as for links. A post-level report must carry the read proof, so someone who only saw a club id in a link preview cannot silence posts; a whole-club report needs only the id, as a link report does, and disables nothing but that club.
3. **Abuse-material reports** carry the full invite link, key included, exactly as for links (#2235). The server forwards it unread to the CyberTipline and **holds the club's ciphertext for a year** in the restricted store (`links/hold.go`; the hold code gains a club case). The club is disabled while held.
4. **The owner can disable one post, one club or all clubs.** `smserver reports` already lists reports; the club ids get the same treatment. Switching off `clubs` in `config.json` stops every club at once.
5. **No strike ladder for clubs in the first version, and this is flagged for counsel.** The ladder counts reported links per sender, which needs the server to know the sender. Club posts carry no sender identity (section 5), and a closed-beta club is a handful of friends, not the public. If #2239's sender side ships and the owner wants clubs inside it, a club post would carry the same keyed hash of the install key. That is a question for the attorney list (17 U.S.C. 512(i), `docs/legal/attorney-questions.md` question 4).

## 8. Honest limits

1. **A leaked invite link is a new member.** Whoever has the link can read the whole club and post to it. There is no way to cut one person off except a new club.
2. **A member can pass as another.** Every member holds `K`, so a post cannot prove who sent it. The sender id in a packet is a label, not a signature. Signing Margins is out of scope (F1 brief, #22).
3. **The server can hold back, repeat or reorder posts.** It cannot forge or change one without the sealing key, because each is authenticated. It can refuse to deliver one. A phone cannot tell a missing post from a post nobody made.
4. **The server sees sizes and the order of posts.** It also sees the hashed address that made each request, for up to an hour, in memory. It does not write it down.
5. **No forward secrecy.** Someone who later gets `K` can open every post they also got the bytes of. Breaching the server alone gives them no key.

## 9. The privacy page and breach note

When this is built, the same PR must update:

- **B4 section 14**, "If the server were breached". Add: *a club's mailbox is ciphertext, a club id and two hashes of proofs. The key is in the invite link and never reaches the server. There is no member list.* And: *a stolen club id with no key opens nothing.* And the exception: *a club reported as abuse material is held with its invite link, key included, for a year in the restricted store, the same as a held share link.*
- **The privacy page text (B4 section 7)**, one sentence: "A club is a box of locked packets. We keep the box and cannot open it. It is deleted after 90 days with no use."
- **`docs/legal/privacy-policy-draft.md`** and the App Store answers, with the wording the owner has already approved for share links as the base.

## 10. How it gets built (slices, in order)

Each is one PR with one issue. The first two are cloud work with host tests.

1. **Built (#1799): server package `internal/clubs`** and the API routes, the `clubs` switch, the caps, and the log and file tests in section 4. Go, Linux. Done when a **10-member simulated club** test passes: one creates, nine join with only the link, each posts three packets (spread over test time, since the per-address limit is 30 an hour), each fetches, and all ten end with the same 30 posts and no duplicate. (This is #1799's Done when 2 on the server side.)
2. **Built, except the importer test (#1799): SessionKit `ClubSealing` and `ClubClient`:** the HKDF derivation, link parsing and building, sealing and opening a packet, the cursor, fixtures shared with the server's test, and merging through the existing importer. Host tests on real SQLite. Packets exported by this build must still import into Build 32 and 34.
3. **Report and takedown for clubs:** the form's club case, the hold case in `hold.go`, `smserver` listing. Depends on #2239's rules package, which is merged.
4. **Web landing page `/c/<id>`:** "Open in Spoken Margins", no JavaScript needed for the button. Nothing here can read the key.
5. **App screens:** create, join, post "my new Margins", the club's list, Hide this sender. Needs the Mac and the lane, and the consent step from #2842 (PR #3306) to be in first. Touches `Gate1AppModel*` only through a focused type.
6. **Test Desk run and the owner's one phone step** (Done when 3): join a club the Test Desk made and hear a member's Margin.

Order on the board: after the five backbone items on #203, as the 2026-10-21 call says. Slices 1 and 2 touch no app file and no file another thread is using.

## 11. What I did not decide

- The exact caps (200 posts, 200 MB, 5 GB). They are starting points sized for ten friends.
- Whether a club needs a per-post delete key. Left out to keep the first version small.
- The attorney's view on section 7 point 5.
- The build flag's name.
