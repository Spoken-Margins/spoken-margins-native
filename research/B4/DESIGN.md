# B4 M1: server foundation design

Stream B4 `bridge`, seams I3 (bridge manifest and recipes) and I11 (server client and attestation). Tracking issue #190. E3 `maps` and F1 `coop` inherit this shape, so the privacy rules below are written as rules for any Spoken Margins server, not only the bridge.

## The shape in one paragraph

The server has two doors. The **public door** serves two static documents, the kill-switch config and the bridge manifest. They are identical for every install, need no identity, and are served by Caddy straight from disk. The **attested door** is for anything an app *sends*: site requests, and later E3 maps and F1 clubs. It requires an Apple App Attest key, which proves a genuine Spoken Margins install without saying whose. Following a bridged site uses only the public door. The phone downloads the whole manifest, keeps the sources the listener follows, and fetches each article from the publisher itself. So the server never learns a follow list and never touches an article body.

```
phone ──GET config.json, manifest.json (no identity, same bytes for all)──▶ Caddy (static files)
phone ──GET article (as today)────────────────────────────────────────────▶ publisher
phone ──POST attested request (App Attest key id + assertion)──▶ Caddy ──▶ smserver (loopback)
```

## 1. Hosting and cost

**Decided (owner, 2026-09-28): the existing VPS, behind the Caddy that already serves the site. Deployed 2026-09-28** from `5d844ac`; health, the kill switch while smserver is stopped, and the Caddy error-log filter were checked on the box (#190). The server is one Go binary using only the standard library, with no database and no third-party code. Measured locally: a 9.6 MB binary using about 5–10 MB of RAM idle, and state is one small file per registered install. Static documents are served by Caddy, so they, and the kill switch, keep working if the service is stopped.

| | Existing VPS (recommended) | Fly.io machine | Google Cloud Run |
| --- | --- | --- | --- |
| Monthly cost for B4 | $0 extra (flat-rate plan) | ~$2–4 (shared-cpu-1x, 256 MB, 1 GB volume) | ~$0 within the free tier |
| Runaway-bill risk | None: the bill is flat. Only the transfer allowance is metered | Low; per-second billing, no hard cap | Budgets only *alert*; a hard cap needs extra automation |
| Operations | Owner's box: OS updates are the owner's job already | Managed | Managed, but the install store needs Firestore or similar |
| Kill switch while service is down | Yes (static file) | Only if the static files are hosted separately | Same |

The Fly.io and Cloud Run prices are approximate list prices from memory, not checked today; check them before choosing either.

**Traffic estimate.** A 20-site manifest with 20 items each is about 110 KB raw, 25–30 KB gzipped. Apps check at most every 6 hours with `If-None-Match`, so most checks are a ~300-byte 304. Budgeting four full downloads per install per day gives about 3 GB/month per 1,000 installs, or 30 GB per 10,000. Attested traffic is negligible. The watcher that fetches the 20 sites hourly (M2) adds under 1 GB/month.

**Cost ceiling and alert.** The owner set a **$10/month ceiling for all Spoken Margins servers**, once there are users. Still open: the uptime monitor and the transfer alert below, which need the plan's transfer allowance. B4 alone costs $0 extra on the VPS. "Hard budget alert" on a flat-rate box means watching the one metered thing, plus liveness, from off the box:
- A free external monitor (Healthchecks.io or UptimeRobot free tier) polls `https://spokenmargins.proximitytoprogress.com/api/v1/health` every 5 minutes and emails the owner on failure.
- A daily cron on the VPS reads `vnstat` and pings a second Healthchecks check *only* when monthly transfer passes 50% of the plan's allowance. That check alerts if it gets pinged.
- If the owner picks a metered host instead, set that provider's budget alert at 50% and 90% of the ceiling.

**Deploy** (`deploy/deploy.sh <ssh-host>`, run from the Mac with the owner's OK; `--dry-run` first). smserver listens on `127.0.0.1:8795` (8787 is taken on the box; `SM_SERVER_PORT` changes it). Its public documents live in their own root, `/srv/www/spokenmargins-server`, because the site deploy's `rsync --delete` into `/srv/www/spokenmargins` would otherwise delete the kill switch. Caddy serves those two paths from that root inside the site block's `route`. The script edits only the `spokenmargins.proximitytoprogress.com` block and a new global log block, refusing if either isn't what it expects. It runs `caddy validate` first, backs up the Caddyfile, reloads Caddy (never restarts it), checks the sites and health, and rolls back on any failure. The first real run did roll back: the install-time `smserver switch` inherited the script's `umask 077`, so `config.json` came out `0600` and Caddy answered 403. Public files are now always written `0644` (with `0755` for new directories) whatever the umask, and the script refuses before touching Caddy if anything under the public root isn't world-readable. `deploy/test-edit-caddyfile.sh` tests the Caddyfile edit against Caddy 2.10.2, the box's version.

## 2. Attestation, and blocking one install

- **What:** Apple App Attest (`DCAppAttestService`). On first need, the app generates a Secure Enclave key, asks the server for a one-time challenge, and has Apple certify the key (`attestKey`). The server checks the certificate chain against Apple's App Attestation Root CA (embedded, fingerprint pinned in a test), the challenge nonce, our App ID `J8SWC6J3VY.com.spokenmargins.native`, the environment, a zero counter, and that the key id matches. After that, every attested request carries an assertion over `method, path, time, SHA-256(body)` (exact bytes: `api.ClientData`). The server rejects any assertion whose counter hasn't increased, so a captured request can't be replayed.
- **What the server keeps per install:** the public key, the counter, the environment, and the created and last-seen dates *at day precision*. That's all: no IP, device model, receipt, or anything Apple's fraud metric could link. Records change in memory and are written in one hourly batch, and each file's times are then set to midnight of its last-seen day. So neither the record nor its file times say when a request happened. A crash loses at most an hour of counter updates. The key is random per install and dies with the app. Apple does not tell us which device made it.
- **Blocking one install:** the owner runs `smserver block TAG` on the box, where the tag is 16 hex characters derived from the key id. Blocks live in their own directory, which only the CLI writes, so they survive record expiry and can't be raced by a request in flight. A blocked install gets a vague `403 refused`. Where the owner gets a tag from: the **abuse log**, which records hour, tag and reason only when an install exceeds its rate limit, and is pruned after 30 days. Admin is CLI-only on the box; there is no remote admin endpoint.
- **Expiry:** records unused for 90 days are deleted daily. An app told `unknown_key` simply attests a new key, so losing or purging the store is harmless and needs no backups.
- **Lazy, not at launch:** the app attests only when it first uses an attested feature. An install that never sends anything never appears on the server. This also stays within Apple's guidance to ramp `attestKey` calls gradually.
- **Where App Attest is unavailable** (Simulator, a few older devices): attested features are hidden. Following bridged sites still works, because it uses only the public door.
- **Honest limits.** A reinstall gets a new key, so a blocked abuser can come back. DeviceCheck's two per-device bits would survive reinstall, but they are a per-device marker, and I don't recommend using them unless abuse actually happens. Also, the server necessarily sees a key id and an IP on the same attested request. The code never stores that pair, but a *modified* server could. Section 3 is how we keep interest-revealing content off that request altogether.

## 3. Rule for anything an app submits: identity and content travel separately

A request that reveals what a listener is interested in must never carry the install's key id. Examples: "please bridge example.org" (B4 M3), a listening map for an episode (E3), a club post (F1). The brief already asks for this: site requests should queue "without identifying the requester". The mechanism is **unlinkable tokens** (Privacy Pass, RFC 9578, with RFC 9474 blind RSA signatures):

1. Attested: the app asks for a small batch of tokens (say 10 a day). The server checks the assertion, the block list and the quota, then *blind*-signs them, so it never sees the token values it signed.
2. Later, on a separate request with no key id: the app sends the site request plus one token. The server checks the signature and that the token isn't spent, and queues the request for the owner's review.

Blocking then means "stop issuing tokens to that install". Junk that gets through is capped by the quota, and every new site already goes through the owner's approval. The app should spend tokens at a random delay after issuance, not immediately. Blind RSA needs either a small `math/big` implementation or Cloudflare's BSD-licensed `circl`. That work belongs to B4 M3 or E3 M2, whichever submits first. M1's only attested endpoint, `ping`, carries no content.

F1 club membership is linked by nature; a member of a club is known to that club. F1 should decide that deliberately, not inherit it by accident.

## 4. Kill switch

`/api/v1/config.json` is one static file, and the service reads the same file:

```json
{ "schema": "spokenmargins.server-config", "version": 1, "serial": 3, "checkAfterSeconds": 21600,
  "services": { "attest": { "enabled": true }, "bridge": { "enabled": true, "minimumBuild": 30 } } }
```

- **Owner:** `runuser -u smserver -- smserver switch -public /srv/www/spokenmargins-server attest off` (or `bridge off`). This bumps `serial`. Attested endpoints return `503 disabled` immediately, while health and the public documents keep answering. `minimumBuild` switches a feature off for one misbehaving build.
- **App rules (B4 M3 builds these):**
  - Fetch the config at most every `checkAfterSeconds`, and only when about to use a server feature. Use an ephemeral `URLSession`: no cookies, no custom headers except `If-None-Match`. Pin the host, require https, and cap the size (16 KB), the same pattern `GuidedOnboardingCoordinator` already uses.
  - Ignore a document whose `serial` is lower than the cached one.
  - **Fail closed:** use a feature only if a config fetched within the last 7 days says it's on, and the build is at least `minimumBuild`. A missing service means off. A `503 disabled` means off until the next check.
  - When off, unreachable or gone, bridged sources show "Not updating", attested features hide, and *nothing else changes*. Library, playback, other feeds and recordings don't touch this server.

## 5. What is logged, and why it can't reconstruct follows or reading

| Where | What | Kept |
| --- | --- | --- |
| Caddy access log | Nothing. The site block has no `log` directive; keep it that way | — |
| Caddy error log | Method, host, URI of a failed request, with listening-map paths reduced to `/api/v1/maps/*`. The IP, headers and TLS fields are stripped by the global filter in `deploy/caddy-global.caddy` (JSON, matching the box's journald format). Checked locally: without the filter, a 502 logged the request's key-id header | journald default |
| smserver request log | An hourly summary, written once an hour: `{"hour":"2026-09-28T12","method":"POST","route":"/api/v1/ping","status":200,"latency":"under50ms","count":4}`. Unknown paths log as `"other"`. Nothing is written per request, so even the journal's own timestamps only mark the hour | 14 days (own journal namespace, files closed daily so the limit applies, no syslog forwarding) |
| smserver abuse log | Hour, install tag, reason, count. Only for installs over their rate limit, also written hourly | 30 days |
| Install records | Public key, counter, environment, two day-precision dates. Written hourly, file times set to midnight | Until 90 days idle |
| Rate limiter | IPs HMAC'd with a per-process random secret, in memory only, reset hourly | 1 hour, never on disk |

Why this can't reconstruct a listener's follows or reading:
- **Follows never reach the server.** Every install downloads the same manifest bytes. Caddy's ETag is built from the file's modification time and size, so every install gets the same one and it can't act as a per-install cookie. Whether a shared link is bridgeable is matched *on the phone* against each source's `match.hosts`/`pathPrefixes`. Nothing is fetched from our server per source: no icons, no per-source feeds. The manifest gate refuses any such field.
- **Reading never reaches the server.** The phone fetches articles from publishers directly, as it does today.
- **A bad manifest can't redirect phones.** The gate requires item URLs to be https on the source's `match.hosts`, and refuses any Spoken Margins domain as a host. But the manifest sets those hosts itself, so the real boundary is on the phone. **App rule (B4 M3, must not break):** at follow time the app records the host of the link the listener actually shared. It fetches only items on that host, and asks the listener before accepting a source whose hosts changed. Otherwise a compromised manifest could add a tracker as a host and learn which IPs follow a source.
- **Manifest downloads carry no identity.** No attestation and no cookies. Even an IP log, which we don't keep, would only say "an install exists".
- **Sharding, if the manifest ever gets big:** the phone fetches every shard, never only the ones it needs. Fetching only the shards you need would leak follows. The gate caps the manifest at 4 MB, roughly 700 sources at 20 items each; past that, shard.
- Tests enforce the logging rules. An end-to-end test fails if a key id, install tag, `127.0.0.1` or the Go user agent appears in either log. Adding the peer address to the log line made it fail, as intended.

## 6. Manifest and recipe (I3 v1)

Fixture: `contracts/fixtures/bridge-manifest.example.json`. The publish gate is `internal/manifest`.

```json
{ "schema": "spokenmargins.bridge-manifest", "version": 1, "generatedAt": "…",
  "sources": [{
    "id": "example-essays", "title": "Example Essays", "homepage": "https://essays.example.org/",
    "match": { "hosts": ["essays.example.org"], "pathPrefixes": ["/p/"] },
    "status": "active", "checkedAt": "…", "updatedAt": "…",
    "items": [{ "url": "https://essays.example.org/p/on-margins", "title": "On margins",
                "publishedAt": "…", "firstSeenAt": "…" }],
    "recipe": { "version": 1, "extract": "selectors", "content": ["article .post-body"],
                "remove": [".subscribe-box"], "title": "h1.post-title",
                "published": { "selector": "time[datetime]", "attribute": "datetime" } } }] }
```

- **Items are links, not content.** An item has only `url`, `title`, `publishedAt` and `firstSeenAt`. The gate refuses unknown fields, so `content`, `summary`, `html` and `icon` can't be published by accident. This holds only if every write goes through the gate. `smserver publish-manifest` (`manifest.Publish`) validates, then replaces the file atomically, and leaves the live file untouched when validation fails. The M2 watcher and any deploy script must publish through it, never by copying a file into place. `updatedAt` is the per-source change marker.
- **Recipes are data (Guideline 2.5.2).** `extract` is `"readable"` (the Defuddle script bundled in the app) or `"selectors"` (CSS selector lists applied with `querySelectorAll`). There are no scripts, regexes, templates or expressions. Every behavior is code already in the reviewed app binary, and the recipe only picks which parts of the page to keep. Apple's own Safari content-blocker rules are the precedent: JSON with CSS selectors, downloaded and applied by shipped code. The gate also refuses selectors containing `{ } ; < \` `` ` ``, comments, `url(`, `expression(`, `javascript:` or `@import`, caps lists at 10 selectors of 200 bytes each, and allows only https item URLs on the source's own hosts.
- **App-side rule (B4 M3, must not break):** selectors reach the page only as *arguments* to `callAsyncJavaScript(_:arguments:in:contentWorld:)` in an isolated content world, never spliced into a JavaScript string. Splicing would turn a selector into code. The server gate is defense in depth, not the boundary.
- **Versioning:** the server's gate is strict, and the app's decoder ignores unknown fields. A recipe whose `version` is newer than the app understands falls back to `"readable"`. Adding a field never breaks an old build.
- **Where it lives:** `research/B4/` for now. At M3 the manifest schema and fixtures move to `Contracts/` with the app's host tests.

## 7. Privacy page text (draft for `Site/privacy`, to publish before anything ships)

Replace the sentence "Spoken Margins has no developer-operated account system or backend and includes no advertising, analytics, or tracking service." with:

> Spoken Margins has no accounts and includes no advertising, analytics, or tracking service. A small developer-operated server supports optional features that need one, described below.

Add a section:

> **The Spoken Margins server**
>
> *Following sites without a feed.* For some websites that don't publish a feed, a Spoken Margins server checks the site's public pages for new articles and publishes a list of article links and titles. Your device downloads the whole list, the same list every device gets, and picks out the sites you follow on the device. The server never learns which sites you follow or which articles you read. Your device retrieves each article directly from the publisher, as it does for any other link.
>
> *Sending something to the server.* Some features send something to the server, such as asking for a new site to be supported. The first time you use one, your device creates a random key for this installation of the app, and Apple confirms to our server that the key belongs to a genuine copy of Spoken Margins. Apple does not tell us who you are or which device you use. The server stores that key's public half, a counter, and the dates it was created and last used. We use it only to prevent abuse, and it is deleted after 90 days without use. Deleting the app deletes the key. Requests that reveal your interests, like a site suggestion, are sent without that key, so they can't be connected to your installation.
>
> *What the server records.* The server does not keep IP addresses. Its logs are an hourly count of which services were used and whether they worked, and are deleted after 14 days. If an installation sends more requests than the service allows, the server notes that installation's random key for 30 days so repeated abuse can be blocked.
>
> *If the server is unavailable.* Everything else in Spoken Margins keeps working. Sites that depend on the server show "Not updating" until it's back.

**App Store privacy label (owner decision; my recommendation):** once an attested feature ships, declare *Identifiers → Device ID*, **not linked to you**, **not used for tracking**, purpose *App Functionality* (Apple lists fraud prevention there). The random per-install key is stored longer than one request, so declaring it is the safe reading. The bridge read path alone collects nothing.

## 8. Where the code lives

`research/B4/server/` is a Go module using the standard library only, so there is no dependency supply chain to audit. That includes the AI provider call in `internal/maps`, which is one plain HTTPS request:

- `internal/appattest`: the App Attest verifier, plus `fakeattest`, a test CA in Apple's certificate shape.
- `internal/cbor`: a minimal CBOR codec.
- `internal/api`: the HTTP surface.
- `internal/store`: install records and the block list.
- `internal/config`: the kill switch.
- `internal/manifest`: the I3 gate.
- `internal/maps`: listening maps made from uploaded transcripts (§10).
- `internal/tokens`: anonymous blind-signed tokens (§11).
- `cmd/smserver`: serve plus the admin CLI, including `publish-manifest`.
- `cmd/smclient`: the test client.
- `scripts/demo.sh`: runs the whole M1 path locally.

It's deployed from `research/B4/` today. Before M2 adds the watcher, I suggest moving it to a top-level `Server/` beside `Site/`, with `deploy/` alongside it.

## 9. Decisions for the owner

1. ~~**Hosting**~~: decided, the existing VPS; deployed 2026-09-28.
2. ~~**Monthly ceiling**~~: decided, $10/month once there are users. **Still needed:** the VPS plan's monthly transfer allowance, so the 50% alert has a number.
3. **How new sites get bridged:** the owner approves each one (the brief's recommendation, and the design above assumes it).
4. **Privacy page and label:** approve the draft text in §7 and the Device ID declaration. They publish before any attested feature ships, and they're not needed for a bridge that only reads.
5. **Unlinkable submissions:** confirm §3 (tokens, blocking at issuance) as the rule E3 and F1 inherit, rather than linking submissions to install keys. *Default taken 2026-10-03 (#737): the tokens are built, switched off, and nothing requires them yet, so this stays open until a feature asks for a token. #736 proposes them as the way a paid tier works without accounts.*

## 10. Listening maps (#551)

An opted-in phone uploads one episode's transcript to `POST /api/v1/maps/transcripts`. The server asks an AI provider for a map of the episode's scenes, keeps the map, and drops the transcript, which only ever sat in memory. Anyone can fetch the map at `GET /api/v1/maps/<episodeKey>`. The `maps` switch in `config.json` is off until the owner turns it on.

- **The upload carries no install key.** Per §3, it reveals what the listener plays, so it is not an attested request. Abuse is bounded by 30 uploads per client address per hour (in memory, like §5), at most 4 uploads at once, at most 8 transcripts waiting, and the spending cap. Waiting transcripts are held in memory (at most 2 MB of JSON each, so a few tens of MB when the queue is full, against the service's 128 MB limit; not measured under load), and the worker maps one at a time.
- **Transcripts are never served, and never written to disk (#1730).** A transcript waits in memory for the worker, which drops it as soon as its map is made or dropped. A sweep every hour drops any older than 2 hours, and a restart drops them all, so a phone that opted in simply uploads the episode again next time. The first start after this change also deletes any transcript file the earlier file-backed queue left. Only maps are kept.
- **First upload wins.** An episode that has a map gets no new work. `smserver takedown-map KEY` deletes a map at once and withdraws the key, so phones that play the episode again don't bring it back. Deleting `/var/lib/smserver/maps/withdrawn/KEY` allows a new map.
- **Two stages: breaks first, then each scene (#2075).** The offline bench (`research/B4/eval/results.md`) found the single call made a map for only 3 of 18 episodes, so the worker now works in two stages:
  1. **Breaks.** Code scores every segment start by how much the words change across it (a TextTiling-style depth score over two minutes each side). An episode gets one scene per 5 minutes, 3 to 40. The model sees the transcript and the best 3×(K−1) candidates, at least 45 seconds apart, and picks K−1 through structured output whose `enum` holds only the offered ids, so it can't invent a break. Unknown or repeated ids are dropped; more than K−1 keeps the best-scored; fewer than 2 means the pick is unusable, and code's own top breaks stand in (the bench's code-only breaks were nearly as good).
  2. **Scenes.** One small call per scene, given only that scene's text, asks for a 3-to-6-word title and a 12-to-20-word summary (below the limits, so a little over target still passes). Each answer must keep a title within 80 characters and 8 words, a summary within 25 words and 300 characters, every name in the summary in that scene's own text, and no run of 8 or more words copied from anywhere in the transcript. A scene that fails gets one retry whose prompt adds a fixed sentence naming the broken rule, never answer or transcript text. A scene that fails twice on a name gets its title as summary, if the title passes; otherwise it is folded into the scene before it (or after, for the first). Fewer than 3 scenes left, and the transcript is dropped.
- **Names, by language.** A capitalised word mid-sentence counts as a name, the phone's `ListeningMapSummaryValidator` rule; an acronym also matches its dotted form ("AI" and "A.I."), the initials of words in a row, or its singular. German (and Swiss German, Luxembourgish, Bavarian) capitalises every noun, so there only acronyms and words with an inner capital ("YouTube", "McKinsey") are checked. The plain rule refused 151 of 159 German bench scenes, nearly all for role nouns like "Gast"; the cost of the narrower rule is that an invented ordinary German name passes.
- Calls run one at a time, so the cap check before each never interleaves with another. Logs say which stage, scene number and rule fired, or how many scenes were repaired or folded, never the text or the name.
- **Hard monthly cap.** After each call the server adds its cost (tokens times the per-token prices set by `-maps-input-usd-per-mtok` and `-maps-output-usd-per-mtok`) to `/var/lib/smserver/maps/ledger.json`. Before each call, and at each upload, it adds a deliberately high estimate of that call's cost to the month's spend. If the total would pass `-maps-cap-usd` (default 10), it makes no call, and uploads get `503 {"reason":"monthly_cap"}` until the next UTC month. A call whose answer is lost (a timeout, or the server stopping mid-call) may still have been billed, so it counts at the estimate and isn't retried. A ledger that can't be read or written stops all calls. Switching `maps` off stops calls at once, too: the worker checks the switch before every call and drops what is waiting. These settings are flags in `smserver.service`, never in `config.json`.
- **The API key** is read from `/etc/smserver/maps.env` (root, 0600) through `EnvironmentFile=`, removed from the environment once read, and never logged, even when the provider echoes it in an error. Without it the server starts, serves stored maps and refuses uploads.
- **Logs** name the route `/api/v1/maps/*`, never an episode key. The worker's log lines say what failed (an HTTP status, a check that didn't pass), never which episode or file. Caddy's error log, which records the path of a failed request, rewrites map paths to `/api/v1/maps/*` too (`deploy/caddy-global.caddy`, checked by `test-edit-caddyfile.sh` against Caddy 2.10.2).
- **Cost:** with Claude Haiku 5.5 (owner decision, 2026-10-18) at $0.10 and $0.50 per million input and output tokens for prompts up to 100,000 tokens, the bench measured the two stages at $0.025 to $0.03 per episode (about 2 cents per audio hour; German cost more there because the old name rule retried nearly every German scene), against $0.012 for the single call, which made few maps. The pick call is 16 to 26 percent of it. An upload is refused at the cap if the pick plus one call per scene could pass it; the worker checks again before every call. A prompt over 100,000 tokens (roughly 5 to 6 hours of speech) is billed at $0.50 and $2.50, and the ledger's flat prices would undercount it; an upload whose prompt text passes 180,000 bytes (about 3 hours of English speech) is refused, so a call stays under that line.
- **Known limit:** because uploads are anonymous, the first uploader of an episode decides its map, and a bad actor could upload a misleading transcript first. The checks keep a map short and in the provider's own words; takedown is the remedy. If this happens in practice, the next step is §3's unlinkable tokens.
- **Requiring a token (#743, off).** The `mapUploadToken` switch makes every upload carry one of §11's tokens, made for the `maps` purpose, as `Authorization: PrivateToken token="…"` (RFC 9577). Without one, or with a forged or spent one, the upload gets `401` with a `WWW-Authenticate: PrivateToken challenge="…", token-key="…"` naming this month's key. The token proves "a genuine install within its daily quota", never which one, so a bad actor gets at most 10 uploads a day per install and blocking an install stops its tokens. The token is checked before the body is read but spent only when the transcript is queued, so an upload answered "already mapped", "withdrawn", "busy" or "over the cap" costs the phone nothing. If `tokens` is off while `mapUploadToken` is on, uploads get `503 disabled`: the server fails closed. It is a service of its own rather than a field on `maps` so an app that doesn't know it reads it as off. Turn it on only once an app build sends tokens; until then it refuses every upload.

## 11. Anonymous tokens (#737)

§3's tokens, built and switched off (`tokens` in `config.json`). Map uploads can require one (§10, #743, also off); the other planned user is a paid tier without accounts (#736).

- **Scheme.** Privacy Pass token type 2 (RFC 9578): `token_type, nonce, challenge_digest, token_key_id, authenticator`, signed with RSABSSA-SHA384-PSS-Deterministic (RFC 9474) and a 2048-bit key. The key id is SHA-256 of the key's SubjectPublicKeyInfo with the id-RSASSA-PSS algorithm and its parameters spelled out, as RFC 9578 §6.5 requires (not the plain rsaEncryption encoding), so other Privacy Pass code computes the same id. `internal/tokens` implements all of it on the standard library and reproduces RFC 9474's and RFC 9578's test vectors byte for byte. The app's side (blind, then finalize) is a later slice; `tokens.Pending` is the Go reference for its bytes.
- **Purpose.** The challenge digest names this issuer and a purpose such as `maps`, so a token made for one feature can't be spent on another.
- **Issuing.** `POST /api/v1/tokens` is attested and takes up to 10 blinded messages, plus the key id the phone blinded against (`409 stale_key` if that isn't this month's). An install gets at most 10 tokens a UTC day; the count is in memory and forgotten when the day ends, and going over writes the install's tag to the abuse log like any other limit. A blocked install gets `403 refused`, which is how blocking works with tokens: it stops issuance. The server signs values it can't read and keeps nothing about which install got which signature.
- **Keys.** One per UTC month, made on first use (`/var/lib/smserver/tokens/keys/YYYY-MM.pem`, mode 0600). A month's key signs during that month; its tokens spend until the end of the next. `GET /api/v1/tokens/keys` returns the same document to everyone, so phones can compare notes and notice a key made just for them. A key file that can't be read is an error and is never replaced, since replacing it would void every token already out.
- **Spending.** `Issuer.Check` answers the same questions without spending, for a caller that only pays when it does the work. `Issuer.Redeem` checks the key, the purpose and the signature, then records the nonce under `tokens/spent/YYYY-MM/` with an exclusive create, synced to disk with its folder, so a token spends once even across two racing requests, a restart or a power cut. The daily prune deletes keys and spent records once their month's tokens have expired.
- **Timing.** `math/big` isn't constant-time, so signing blinds the private-key operation with a fresh random value and checks its own result before answering (RFC 9474 §7.1, §4.3).

## 12. Private map delivery (plan, owner decision 2026-10-18)

Today `GET /api/v1/maps/<episodeKey>` tells the server which episode a listener opened, and the lookup is opt-in for that reason (#553). The plan, in order:

1. **Popular pack.** A daily static file of the most requested maps, the same bytes for everyone. The phone looks up locally and sends nothing. Size is the cost; maps are a few KB each.
2. **Fixed buckets.** For everything else, the phone asks for a bucket: the first bytes of the episode key, always the same bucket for the same episode, so repeated requests can't be intersected the way fresh random decoys can. The bucket width must follow the catalog size so each bucket holds many episodes.
3. **Homomorphic-encryption PIR, later.** An encrypted query over the whole catalog, so the server cannot tell which map was asked for (Apple's open-source swift-homomorphic-encryption, used in Live Caller ID Lookup). Open question: whether the server side can run in Go on the VPS or needs a Swift service.
4. **An anonymous relay (Oblivious HTTP)** hides the phone's address from the server. It needs a third-party relay, so the privacy page would have to name it.

Falsifier: if the catalog stays small, the pack alone is enough and 2 to 4 are not worth building.

## 13. Open gap: chapters that need summaries (owner intent, 2026-10-18)

Tracked in uncomposed/spoken-margins-native#2060.

The owner wants Haiku to write summaries for episodes that already have publisher chapters, treating each chapter as its own item (like a book's chapters), and to find scenes inside long chapters. The upload rule in #552 skips episodes with publisher chapters, so this is not covered. It needs an upload that carries the chapter boundaries and a prompt that writes summaries for them instead of choosing scenes.


## 14. If the server were breached (#2842 item 5)

Plain statement, to check against the code before each new server feature ships. It is an engineering note, not legal advice; whether any law or contract requires a notice is a question for counsel, and nothing here promises a notice.

**What an attacker would get from the server's disk and logs** (sections 2, 5, 10, 11 and the share-link pages on the site):

- Per install: the public half of a random key, a counter, and the dates it was made and last used (deleted after 90 days unused). No name, account, email, device model, phone number or IP address. Deleting the app deletes the private half.
- Hourly request counts per route, kept 14 days; the abuse log (hour, install tag, reason), kept 30 days. No IPs and no per-request lines.
- Listening maps made from public episodes. Transcripts are held in memory only and never written to disk.
- Token signing keys (one per month) and spent-token nonces. A token carries no install identity, so the keys cannot be used to link a token back to an install.
- Share links: ciphertext only. The key travels in the part of the link after the `#`, which the server never receives, so a breach of the server alone does not reveal what a link held.

**What the server does not hold:** listeners' names, accounts, Libraries, Margins, recordings, reading or listening history, or the key that opens a share link.

**So whom would we notify?** There is no list of people to notify: the server holds no identities, and a stolen install record names nobody. If the server were breached anyway, the steps are:

1. The owner stops `smserver` and takes the box off the network (the kill switch keeps the static documents up), then rotates the token keys and the maps API key.
2. Every install key becomes untrusted: delete the install store. Apps told `unknown_key` simply attest a new key, so this costs listeners nothing.
3. Post a dated notice on the Support page and the privacy page saying what was exposed (from the list above) and what was done. The app shows a short banner pointing to it on next launch (not built yet; a follow-up if a feature needs it).
4. Anyone who sent a copyright notice or a report in the past 90 days wrote to the designated agent's mailbox, not to the server; if that mailbox were involved, its senders are the one group we could email directly.

**Check on change:** a feature that makes the server hold anything linkable to a person (an email address, an account, an IP, content in the clear) must update this section in the same PR, and it needs the owner's call first (AGENTS.md "Default on only when it costs the listener nothing").


## 15. Proof that the server checks App Attest itself (#2842 items 3 and 4)

The server does not trust the app's word that a key is genuine. `appattest.Verifier.VerifyAttestation` runs Apple's nine validation steps on a new key, and `appattest.VerifyAssertion` checks every attested request. Where each is tested (`go test ./internal/appattest/ ./internal/api/`):

| Claim | Test |
| --- | --- |
| Chain to Apple's root, nonce bound to our challenge, key id, App ID, zero counter, environment, credential id | `TestRejectsBadAttestations` (ten wrong objects, each refused), `TestValidAttestationAndAssertions` |
| The pinned Apple root is the real one | `TestAppleRootIsEmbedded` (fingerprint) |
| A malformed object is refused, not half read: wrong format, missing or reordered certificates, non-DER, short or altered `authData`, bad key id, empty challenge | `TestRejectsMalformedAttestationObjects` |
| Every request is signed by an attested key, once: wrong body, wrong path or time, another key, another app, a replayed counter, a damaged or missing signature | `TestValidAttestationAndAssertions`, `TestRejectsMalformedAssertions`, `TestSkeletonEndToEnd`, `TestAssertionIsBoundToItsPathAndTime`, `TestAssertionTimestampMustBeWithinFiveMinutesEitherWay` |
| A challenge works once | `TestChallengeIsSingleUse` |
| A reinstall is a new key that registers as a stranger, a block on the old key does not follow it, and the two records share no key id or public key | `TestReinstallGetsAFreshKeyThatNothingLinksToTheOldOne` |
| An install record holds exactly the declared fields, with days not times | `TestInstallRecordFileHoldsExactlyTheDeclaredFields` |

**What this does not prove.** Every one of these tests runs against `fakeattest`, which is written from the same reading of Apple's documentation as the verifier. A misreading shared by both would pass. The one test that uses bytes Apple produced, `TestVerifierAcceptsARealDeviceCaptureUnderApplesRoot`, skips until `testdata/device-capture.json` exists (#1593, needs the owner's phone). Until it passes, section 5.2 of Apple's agreement is met in code and tests but not yet checked against a real device.

**Still open on #2842:** the consent step before the first server contact, the key being created after it, and the wording in the privacy policy, App Store answers, Terms section 5 and the permission prompts. Those need the app, the owner's words and counsel.
