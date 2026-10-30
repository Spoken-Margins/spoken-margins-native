# Feed metadata for phones, without learning what anyone follows

Design note for #853. Written 2026-10-08 against `next` at `f2e873d`. No code and no new issues. The challenge comes from the owner's 5 October memo; the ideas in it are examples, not requirements.

## The short version

1. **Ask the server as little as possible. Where it has to answer, make every answer the same file for everyone.**
2. **Four layers, cheapest and safest first.**
   - Read what the phone already downloads. Feeds carry a category, a language and episode lengths. The app ignores most of it today.
   - One shared index file that every phone downloads whole. The phone looks up its own feeds in it. The server only learns that a phone downloaded a file.
   - Shared labelling presets ("under 20 minutes", "no sports"), also one file for everyone, applied on the phone.
   - Listening maps are the exception. There are far too many to send to everyone. They need a lookup, and a lookup needs either an opt-in or a relay.
3. **What I would not do:** ask the server about each feed, even in hash buckets; ask Wikidata from the phone; use encrypted lookups (PIR) yet.
4. **Three decisions for you** are in section 5. Your standing rule from 5 October is the test I applied: default on only if even someone with full access to our systems and live logs couldn't tell whose data it is.

## 1. What "metadata" means here

Four kinds, and they are not the same problem.

1. **Facts about a feed:** kind, language, subject, typical length, how often it publishes. Small. Can be sent to everyone.
2. **Labels and tags:** "news", "interview", "work", "long-form". Small per feed. Can be sent to everyone.
3. **Filtering rules:** presets a listener turns on, so nobody has to write a regex. Tiny. Can be sent to everyone.
4. **Listening maps:** scenes and summaries for one episode, up to about 15 KB each (40 scenes at the title and summary limits in `research/B4/DESIGN.md` §10). A typical one is probably a few KB; that part is my estimate. There are millions of episodes. Sending them all is not possible, so a phone has to ask for the ones it plays.

One more thing the shared data can't know: whether a show is "work" **for this listener**. That is one tap per feed, kept on the phone. Shared metadata can pre-fill the suggestion. It can't replace the tap.

## 2. Where we are today

- **The phone already fetches every feed itself,** straight from the publisher. Nothing about follows reaches our server.
- **The feed parser skips the feed's category, language and keywords** (`FeedParser.swift`). It reads titles, authors, dates, audio links, episode length, artwork and the feed's generator, and nothing that says what a show is about. The cheapest metadata there is, is unused.
- **One shared file already exists:** the onboarding catalog (`Site/onboarding/catalog/v1/`). 200 shows, 13 subjects, 150 KB (about 24 KB gzipped), the same bytes for every install, checked against a SHA-256 in `manifest.json`.
- **It only helps those 200 shows.** `SourceCatalog.entry(matchingFeedURL:)` matches a followed feed against them. Any other feed gets no subject, and #485 falls back to the source kind.
- **The server design already says the right thing for follows.** `research/B4/DESIGN.md` §5: "the phone fetches every shard, never only the ones it needs. Fetching only the shards you need would leak follows."
- **Two places contradict that, and need a look:**
  - `docs/workstreams/interfaces.md` I9 says a server lookup should use "a coarse shard or hash prefix and match locally." Section 4 explains why that leaks.
  - #553, the planned map fetch, calls `GET /api/v1/maps/<episodeKey>` and, as written, has no opt-in. The key is a SHA-256 of the episode GUID (`CommunityMapEpisodeKey`). GUIDs are public, so anyone can compute the key for any episode. It is a label, not a disguise. The server's logging rules (hourly counts, no addresses) are a promise, not something the design makes impossible to break. By your 5 October rule, that makes it opt-in.

## 3. The options

Each one says what the server (or a third party) can learn, what it costs the phone, and what it costs us to run. Sizes marked "estimate" are my arithmetic, not measurements.

### Option 1. Read it from the feed, on the phone

The parser starts reading `itunes:category`, `language`, `itunes:explicit`, keywords and episode lengths. For articles it reads the page's own tags, which the phone already fetches. A small table maps Apple's categories onto the 13 catalog subjects. Cadence comes from publish dates, which the parser already reads.

- **Covers:** kind, language, a publisher-chosen subject, typical length, cadence. Works for **any** feed, including ones nobody has heard of and private feeds.
- **Doesn't cover:** subjects the publisher chose badly, cross-show knowledge ("shows like this"), maps.
- **Who learns what:** nobody learns anything new. The publisher sees the phone fetch its feed, as today.
- **Phone cost:** a few extra XML elements per refresh. No new download, no battery cost worth measuring.
- **Our cost:** none.
- **Default on?** Yes.

### Option 2. One shared index that every phone downloads whole

Your memo's first idea, tightened. We publish one index file. Each row is a short hash of a feed's normalized URL (the same normalization `SourceCatalog.feedKey` uses) plus a few labels. Every phone downloads the same bytes and looks up its own feeds locally. Nothing about the request depends on what the phone follows.

- **Covers:** curated subjects and tags, a spoken-word type (news, interview, story), better labels than the publisher's own. Only for feeds in the index.
- **Who learns what:** the server sees that an install downloaded one file. Every install gets the same bytes and the same ETag (the B4 precedent, §5). Caddy keeps no access log. With full access to our systems and live logs, you'd learn "an address fetched the index". You would not learn a single follow.
- **Phone cost (estimate):** about 18 bytes a feed: an 8-byte key and 10 bytes of labels. 10,000 feeds is 0.2 MB. 50,000 is 0.9 MB. 100,000 is 1.8 MB. After the first download, a weekly update that changes 3% of rows is about 54 KB at 100,000 feeds. Download on Wi-Fi in the background. A lookup is a binary search.
- **Our cost (estimate):** static files on the VPS. For 10,000 installs on a 100,000-feed index: 18 GB once, when every phone first downloads it. After that, about 2 to 3 GB a month if phones fetch weekly patches (54 KB each, 10,000 phones, about 4 weeks). Up to about 77 GB a month if every phone re-downloads the whole file every week. B4 estimated 30 GB a month for the manifest at the same install count. **The VPS plan's transfer allowance is still unknown** (B4 §9 item 2). Without that number I can't say which of these is comfortable.
- **If the index outgrows about 2 MB:** split by popularity tier, never by what a phone wants. Every phone downloads tier 1. Tier 2 is one more all-or-nothing download ("better labels for niche shows"). The phone never picks shards, which is the rule B4 already wrote.
- **Default on?** Yes. It costs the listener nothing and is airtight on privacy.

### Option 3. Shared labelling presets

Your memo's third idea. One small file of named presets, the same for everyone: "Under 20 minutes", "No sports", "Interviews only". Each is declarative data (matches on category, subject, length, words in the title, domain), applied on the phone. It is the sharable end of the ranking policy file D3 M3 already plans (I5).

- **Covers:** "15 minutes, work only" without anyone writing a regex. Length comes from Option 1. "Work" comes from the listener's one-tap tag, or from a subject preset like "Business and tech".
- **Who learns what:** same as Option 2. One file, same bytes.
- **Phone cost (estimate):** 20 to 50 KB. Rules are evaluated while a list is built.
- **Our cost:** negligible.
- **Must hold:** presets are data, never code (App Store Guideline 2.5.2, the same rule B4 set for recipes). Invalid files are rejected with the reason. "Reset to default" stays visible, as D3 already requires.
- **Default on?** The file downloads by default. The presets only apply when the listener turns one on.

### Option 4. Anonymous lookups through a relay (for maps)

A map lookup is a question about one episode, so it can't be hidden by sending everything. The fix is to hide **who** asks. Oblivious HTTP (RFC 9458) puts a relay between the phone and our server. The relay sees the phone's address but only scrambled bytes. The server sees the question but no address.

- **Covers:** listening maps for any episode, including the long tail. The same route could carry a feed-label lookup for feeds that aren't in the index.
- **Who learns what:** our server learns "someone asked for episode X". With no address and no install key on the request, that is an anonymous count. The relay learns an address asked for something, not what. They'd need to collude, or the service would need to be so quiet that timing gives a listener away. Anonymous tokens (#737, #748) can cap abuse without naming anyone, as B4 §3 already intends.
- **The relay must not be us.** If we ran both, nothing would be hidden. Cloudflare and Fastly both run OHTTP relays (found by search; I did not check their pricing, terms or how a small project signs up).
- **Phone cost (estimate):** a few KB a lookup, only when an episode with no map opens. The phone needs HPKE and the binary HTTP format (RFC 9292). I believe CryptoKit provides HPKE from iOS 17, but I haven't checked.
- **Our cost:** possibly a relay bill (unknown), and an OHTTP gateway on the server. B4's server is standard-library Go only, so the gateway needs HPKE written or imported, which relaxes B4's no-dependencies rule. They hand-wrote blind RSA to keep it, so this is a call, not a blocker.
- **Default on?** Yes, once it exists. Our own systems, even with full access, can't tell whose a lookup is. Only the relay operator and our server working together could, and I'd say so in the privacy page.

### Option 5. Encrypted lookups (PIR)

Private information retrieval lets the phone ask "do you have a map for this episode?" in a form the server can answer without learning which episode. Apple uses it for Live Caller ID Lookup in iOS 18 and open-sourced the library as `swift-homomorphic-encryption` (Apache-2.0). Apple's own write-up says sending the whole database "is only feasible for small databases with infrequent updates" and PIR is their answer for large ones.

- **Who learns what:** nothing, even about which episode. Strongest property of any option.
- **Phone cost:** unmeasured. The phone encrypts each query and decrypts each answer, and I found no figures for how large or slow that is on an iPhone.
- **Our cost:** high and unmeasured. The server does work on every query. I found no numbers for a box as small as the VPS (#551 calls it a $2.50 server). The library is Swift and B4's server is Go with no third-party code, so this would be a second server. The page I read says the library aims to support every platform Swift does, without naming Linux.
- **My view:** worth a spike later if map lookups grow and relays prove unworkable. Not now.
- **Default on?** Only if it ever ships and the phone cost measures small.

## 4. What I would not do, and where your three ideas landed

1. **Hash-prefix buckets (what I9 describes today).** The phone asks for "all episodes starting with `3fa`" and picks its own. One lookup hides among the bucket. But one phone makes many lookups from one address, and the real ones repeat while nothing else does. Intersecting a month of buckets narrows a listener down fast, and for an obscure show it is nearly a name. It looks private and isn't. I would change I9's wording; I have not edited it. *Phone cost:* one bucket per lookup, tens of KB (estimate). *Our cost:* small.
2. **Decoys or a random sample (the second half of memo idea 1).** The same weakness. Real requests persist, decoys don't, so the real set shows through within days. Only a fixed set that **everyone** downloads is safe. That is Option 2. *Phone cost:* every decoy is a download, so cost grows with how well it hides. *Our cost:* the same multiplier in transfer.
3. **Wikimedia or Wikidata as the runtime source (memo idea 2).** From the phone it moves the log, it doesn't remove it. Wikimedia's privacy policy treats IP addresses as personal information, deleted or de-identified after 90 days "in most instances", and a lookup for a feed says exactly what the listener follows. Fetching Wikidata dumps to the phone is not practical. **As a build-time input for our own index it is fine.** Wikidata's data is CC0. I did not check how many podcasts it covers. *Phone cost:* a small request per feed, which is the leak. *Our cost:* none, because the load falls on Wikimedia; I did not check its limits on this kind of use.
4. **Memo idea 1** (download everything) is Option 2. **Memo idea 3** (publish labelling rules) is Option 3.

## 5. Decisions for you

1. **Feed metadata only ever travels as a file that is the same for everyone. Never a per-feed lookup.** Options 1 to 3 on by default. **My pick: yes.** It gives you the filters you asked for with the strongest privacy property available, and no new server. Blocks the build issues in section 7.
2. **Map lookups (#553) are opt-in until a relay exists.** A Settings switch beside the upload one, off by default, with one plain sentence: "To look up a map, your phone tells the Spoken Margins server which episode it is playing. The server can see your phone's internet address while it answers, and does not keep it." **My pick: yes.** It is what your 5 October rule says today, and it adds one small slice to #553. Blocks #553.
3. **Spike the relay (Option 4), costing nothing until you approve a price.** A thread reads the relay operators' pricing and sign-up terms and tries an OHTTP gateway on the VPS. It makes no account and spends nothing. **My pick: yes.** Opt-in maps will reach few people, and this is the route to default-on without PIR. Money and a third party are yours to approve.

Reversible defaults I'm taking (veto any):
- Index rows are keyed by an 8-byte hash of the normalized feed URL. Eight bytes puts a false match at about one in 18 trillion per lookup, even at a million feeds.
- The index refreshes weekly and lives on the VPS next to the catalog, not on a CDN.
- Private feeds are never looked up and never listed. They get Option 1 only (`ShareableLinkPolicy`, #168).
- The index and presets use the catalog's checks: size cap, SHA-256 in a manifest, https only, newer schema versions ignored.
- If the index is missing or stale, the app uses Option 1 and nothing breaks.

## 6. Building the shared files without learning anything

The index and presets are made by us from **public** sources. No listener data goes in.
- Apple's charts and the iTunes lookup, already recorded as provenance kinds in the catalog.
- The Podcast Index dump. The catalog schema already has a `podcast_index` provenance kind and a `podcastIndexId` field. I found the dump's size and weekly update (about 1.8 GB compressed) but not its terms, so check them first.
- Wikidata, build time only.
- You review subjects before they ship. The first thing on the list is the 200-show catalog.

One consequence to accept: **we can't rank by what listeners follow, because we don't know.** Popularity comes from public charts only.

For a feed that isn't in the index, the options are Option 1 (always), your own tag, and an optional "suggest this show" request. That request would go over the anonymous-token route B4 §3 already plans for "bridge this site". The request carries no install key. Until the relay in Option 4 exists, the server still sees the sender's address while it answers, though it keeps none. The curator sees a count per feed and no names.

## 7. If you agree: the build issues

Not filed. After your answers they split like this. Size is S or M, as in the other design docs. "Cloud" means buildable and testable without the Mac. Tier is how much testing the change needs, from `docs/workstreams/test-lane.md`: T0 is docs only, T1 is host tests, T3 adds app tests.

| # | Slice | Stream | Size | Where | Tier |
|---|---|---|---|---|---|
| 1 | Read category, language, keywords and cadence from feeds and pages; map them to catalog subjects | D3 | S | Cloud | T1 (T3 if stored in the database) |
| 2 | Fix I9's wording in `interfaces.md`; add the "fetch it all" rule for lookups | E3 | S | Cloud | T0 |
| 3 | Index format, builder script, and `FeedIndex` reader in SessionKit with host tests | D3 | M | Cloud | T1 |
| 4 | Presets file and the preview, on top of the I5 policy file | D3 | M | Cloud | T1 |
| 5 | #553 gains the opt-in switch and disclosure | E3 | S | Cloud + Mac | T3 |
| 6 | OHTTP relay spike (decision 3) | B4 | M | Cloud | T0 |

Slice 1 changes what is stored per feed, so Build 29 must still open the database. Slice 3 adds no database change.

## Sources checked

Repo, on `next` at `f2e873d`: the owner overlay to `AGENTS.md` (2026-10-05 standing calls); `research/B4/DESIGN.md` §§3, 5, 9, 10, 11; `docs/workstreams/interfaces.md` I8, I9, I11; `docs/workstreams/streams/E3-maps.md` and `D3-following.md`; `Site/onboarding/catalog/v1/` (sizes measured); `Packages/SessionKit/Sources/SessionKit/SourceCatalog.swift`, `CommunityMapUpload.swift`, `ServerConfig.swift`; `Packages/SessionKit/Sources/SessionKitFeeds/FeedParser.swift`; issues #485, #552, #553, #737, #748, #805.

Outside, read on 2026-10-08:
- [Announcing Swift Homomorphic Encryption](https://swift.org/blog/announcing-swift-homomorphic-encryption/): Live Caller ID Lookup uses PIR; the quote on sending the whole database.
- [apple/swift-homomorphic-encryption](https://github.com/apple/swift-homomorphic-encryption): Apache-2.0, a `PrivateInformationRetrieval` library. The page did not mention Linux.
- [RFC 9458, Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html): roles of relay and gateway. Cloudflare and Fastly as relay operators came from a search summary only.
- [Wikidata licensing](https://www.wikidata.org/wiki/Wikidata:Licensing): structured data is CC0.
- [Wikimedia privacy policy](https://foundation.wikimedia.org/wiki/Policy:Privacy_policy): IP addresses as personal information, deleted or de-identified after 90 days "in most instances".
- [James Cridland on the Podcast Index dump](https://james.cridland.net/blog/2026/podcast-index-sql-data-mining/): weekly, about 1.8 GB compressed. Terms not stated there.

Not checked: relay pricing and sign-up; CryptoKit HPKE availability; PIR server cost; Wikidata's podcast coverage; the Podcast Index dump's terms; the VPS transfer allowance.
