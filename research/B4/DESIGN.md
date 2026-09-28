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

**Recommendation: the existing VPS, behind the Caddy that already serves the site.** The server is one Go binary using only the standard library, with no database and no third-party code. Measured locally: a 9.6 MB binary using about 5–10 MB of RAM idle, and state is one small file per registered install. Static documents are served by Caddy, so they, and the kill switch, keep working if the service is stopped.

| | Existing VPS (recommended) | Fly.io machine | Google Cloud Run |
| --- | --- | --- | --- |
| Monthly cost for B4 | $0 extra (flat-rate plan) | ~$2–4 (shared-cpu-1x, 256 MB, 1 GB volume) | ~$0 within the free tier |
| Runaway-bill risk | None: the bill is flat. Only the transfer allowance is metered | Low; per-second billing, no hard cap | Budgets only *alert*; a hard cap needs extra automation |
| Operations | Owner's box: OS updates are the owner's job already | Managed | Managed, but the install store needs Firestore or similar |
| Kill switch while service is down | Yes (static file) | Only if the static files are hosted separately | Same |

The Fly.io and Cloud Run prices are approximate list prices from memory, not checked today; check them before choosing either.

**Traffic estimate.** A 20-site manifest with 20 items each is about 110 KB raw, 25–30 KB gzipped. Apps check at most every 6 hours with `If-None-Match`, so most checks are a ~300-byte 304. Budgeting four full downloads per install per day gives about 3 GB/month per 1,000 installs, or 30 GB per 10,000. Attested traffic is negligible. The watcher that fetches the 20 sites hourly (M2) adds under 1 GB/month.

**Cost ceiling and alert (owner decision).** I suggest a **$10/month ceiling for all Spoken Margins servers** through E3 and F1. B4 alone costs $0 extra on the VPS. "Hard budget alert" on a flat-rate box means watching the one metered thing, plus liveness, from off the box:
- A free external monitor (Healthchecks.io or UptimeRobot free tier) polls `https://spokenmargins.proximitytoprogress.com/api/v1/health` every 5 minutes and emails the owner on failure.
- A daily cron on the VPS reads `vnstat` and pings a second Healthchecks check *only* when monthly transfer passes 50% of the plan's allowance. That check alerts if it gets pinged.
- If the owner picks a metered host instead, set that provider's budget alert at 50% and 90% of the ceiling.

Deploy templates are in `deploy/` (Caddy snippet, systemd unit, journald retention). **Nothing is deployed.** Deploying is an owner decision and a Mac/VPS step.

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

- **Owner:** `smserver switch -public /srv/www/spokenmargins attest off` (or `bridge off`). This bumps `serial`. Attested endpoints return `503 disabled` immediately, while health and the public documents keep answering. `minimumBuild` switches a feature off for one misbehaving build.
- **App rules (B4 M3 builds these):**
  - Fetch the config at most every `checkAfterSeconds`, and only when about to use a server feature. Use an ephemeral `URLSession`: no cookies, no custom headers except `If-None-Match`. Pin the host, require https, and cap the size (16 KB), the same pattern `GuidedOnboardingCoordinator` already uses.
  - Ignore a document whose `serial` is lower than the cached one.
  - **Fail closed:** use a feature only if a config fetched within the last 7 days says it's on, and the build is at least `minimumBuild`. A missing service means off. A `503 disabled` means off until the next check.
  - When off, unreachable or gone, bridged sources show "Not updating", attested features hide, and *nothing else changes*. Library, playback, other feeds and recordings don't touch this server.

## 5. What is logged, and why it can't reconstruct follows or reading

| Where | What | Kept |
| --- | --- | --- |
| Caddy access log | Nothing. The site block has no `log` directive; keep it that way | — |
| Caddy error log | Method, host, URI of a failed request. The IP, headers and TLS fields are stripped by the global filter in `deploy/Caddyfile.snippet`. Checked locally: without the filter, a 502 logged the request's key-id header | journald default |
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

`research/B4/server/` is a Go module using the standard library only, so there is no dependency supply chain to audit:

- `internal/appattest`: the App Attest verifier, plus `fakeattest`, a test CA in Apple's certificate shape.
- `internal/cbor`: a minimal CBOR codec.
- `internal/api`: the HTTP surface.
- `internal/store`: install records and the block list.
- `internal/config`: the kill switch.
- `internal/manifest`: the I3 gate.
- `cmd/smserver`: serve plus the admin CLI, including `publish-manifest`.
- `cmd/smclient`: the test client.
- `scripts/demo.sh`: runs the whole M1 path locally.

It stays under `research/B4/` until the owner picks hosting. At the first real deploy (M2), I suggest moving it to a top-level `Server/` beside `Site/`, with a deploy script modeled on `scripts/deploy-spoken-margins-site.sh`.

## 9. Decisions for the owner

1. **Hosting:** the existing VPS, behind the current Caddy (recommended), or a managed host.
2. **Monthly ceiling:** $10/month for all Spoken Margins servers (recommended); B4 alone is $0 extra on the VPS. Also confirm the VPS plan's monthly transfer allowance, so the 50% alert has a number.
3. **How new sites get bridged:** the owner approves each one (the brief's recommendation, and the design above assumes it).
4. **Privacy page and label:** approve the draft text in §7 and the Device ID declaration. They publish before any attested feature ships, and they're not needed for a bridge that only reads.
5. **Unlinkable submissions:** confirm §3 (tokens, blocking at issuance) as the rule E3 and F1 inherit, rather than linking submissions to install keys.
