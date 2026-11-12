# B4 bridge: server (M1)

**Deployed** to the Spoken Margins VPS on 2026-09-28 (details on #190): `https://spokenmargins.proximitytoprogress.com/api/v1/health`. The product moved to `spokenmargins.com` (#3062): `deploy.sh` now serves the site, `/l/`, `/api/` and the bridge manifest on `https://spokenmargins.com` (`www` redirects to it), and keeps the old host serving everything a shipped build, Apple or an old share link fetches (`/api/`, `/l/`, `/bridge/`, `/onboarding/`, `/voices/`, `/assets/`, `/.well-known/`, which are served, not redirected, because the app pins that host and follows no redirects and a redirected cross-origin fetch can fail CORS) while its human pages answer a 301 to the new host with the path kept (`deploy/caddy-legacy-site.caddy`). The app's own server host (`ProductServer.productionHost`) is still the old one until a later build moves it. Deploys run from the Mac with the owner's OK, never from a cloud session.

Design and privacy rules: [DESIGN.md](DESIGN.md). Tracking issue #190.

Needs Go 1.24+. No third-party modules.

```bash
cd research/B4/server && go test ./...                      # unit and end-to-end tests
research/B4/scripts/demo.sh                                 # health, one attested request, block one install, kill switch
CADDY=caddy SMSERVER=smserver research/B4/deploy/test-edit-caddyfile.sh   # Caddyfile edit, validate, local routing
research/B4/deploy/test-server-rollback.sh   # deploy keeps the old smserver and puts it back on rollback
research/B4/deploy/deploy.sh --dry-run root@<vps>           # from the Mac: show every change on the box, change nothing
research/B4/deploy/deploy-web.sh --dry-run root@<vps>       # from the Mac: build Web/ and list what would change, change nothing
```

The web app (`Web/`, #3020) is served by the same Caddy from `https://app.spokenmargins.com` (the old `app.spokenmargins.proximitytoprogress.com` answers a 301 to it, `deploy/caddy-legacy-web.caddy`): `deploy.sh` adds that site block (`deploy/caddy-web.caddy`, no access log) and an empty `/srv/www/spokenmargins-web`, and `deploy-web.sh` builds the committed `Web/` with `VITE_RELAY_ORIGIN` set to this server and copies it there. The unit lists both app origins, new and old, in `-relay-origins` and `-link-origins` during the move; the relay still answers 503 until `smserver switch ... relay on`.

`deploy/deploy.sh` without `--dry-run` deploys; the owner approves the dry-run diff first. Admin on the box runs as the service user, e.g. `runuser -u smserver -- smserver switch -public /srv/www/spokenmargins-server attest off`.

Listening maps (#551, DESIGN.md §10) stay off until the owner, on the box: puts `ANTHROPIC_API_KEY=...` in `/etc/smserver/maps.env` (owner root, mode 0600), restarts the service, and runs `smserver switch ... maps on`. `-minimum-build N` (before the service name) also sets that service's `minimumBuild` in the same serial bump; leaving it out keeps the current value and `0` removes it. `smserver takedown-map -state /var/lib/smserver KEY` removes one map at once.

Anonymous tokens (#737, DESIGN.md §11) stay off until the owner runs `smserver switch ... tokens on`. Nothing in the app uses them yet. Their keys and spent records live under `/var/lib/smserver/tokens/`; deleting that folder voids every token issued so far and is otherwise harmless.

Map uploads can require one of those tokens (#743, DESIGN.md §10): `smserver switch ... mapUploadToken on`, with `tokens` also on. Leave it off until an app build sends tokens with its uploads; until then it would refuse every upload.

## Club mailbox (#1799)

`/api/v1/clubs/*` is the club mailbox: a box of sealed packets that members of a club read and add to, with the club's key only in the invite link (`docs/design/club-mailbox.md`, section 5 has the wire format). Nothing is stored but the club id, two hashes of proofs, the sealed header and the sealed posts, in `<state>/clubs/`, with every file time at midnight UTC. It is off until `smserver switch -public DIR clubs on`, and answers 503 `disabled` until then. The request log names every club path as one route, `/api/v1/clubs/*` (and `/c/*` for the invitation page, `GET /c/<id>`: one shell for every well-formed id, never a lookup, no key), and Caddy's error log reduces those paths to the same names (`deploy/caddy-global.caddy`), so deploy that before switching clubs on. The daily sweep ends clubs with no post in their first 7 days or no use in 90, and a disabled club 30 days after it was disabled. `POST /api/v1/clubs/<id>/report` (and `.../report/reason`) reports a club or one post: a post-level report carries the read proof and disables that post (its bytes move to `disabled/<n>`, its place stays as an empty file so numbers keep no gaps); a whole-club report needs only the id and disables the club; an abuse-material report holds the club's ciphertext and the reported invite link for a year in `<state>/clubs-held/` and ends the club (`smserver club ...`, `docs/legal/cybertipline-runbook.md`, "Clubs").

## Feed relay (#2985)

`GET /api/v1/relay?url=<http(s) URL>` fetches one feed or page for the web app when the publisher sends no CORS header, and keeps nothing: no URL in any log (the request log names the route only), no cache, and no cookies or listener headers in either direction. It answers the upstream body with its content type, or `{"error": code}`. It needs both `serve -relay-origins https://<web app origin>[,…]` (the origins that get `Access-Control-Allow-Origin`; a request with any other `Origin`, or none, is refused before the hourly limit counts it, so a cross-site `<img>` can't drive the relay, and the web app must be served from a listed origin other than this host) and `smserver switch ... relay on`; with either missing it answers 503 `disabled`. Limits, all in `internal/relay`: ports 80 and 443, public addresses only after resolution (the checked address is the one dialed, and every redirect is re-checked, at most 5), 10 s, 5 MB, feed and HTML types only, 4 fetches in flight, and 120 per client per hour. Caddy already proxies `/api/*`. Its error log (a 502 while smserver is down) drops every query string, so the fetched URL never reaches journald; that filter is in `deploy/caddy-global.caddy`, so deploy it before switching the relay on.

## Share links (#486)

The `links` service is off by default. Deployment and enabling it stay with the
owner. Set `serve -links-install-url /join/` (the join guide on the page's own host,
#3783), a TestFlight invitation such as `https://testflight.apple.com/join/INVITATION`, or the
app's real `https://apps.apple.com/.../id...` listing; without a valid
install URL the link routes fail closed with 503. Existing config files missing
`links` remain off; `smserver switch -public DIR links on|off` adds the entry.

`POST /api/v1/links` accepts `multipart/form-data` with exactly two parts,
`packet` (at most 20 MiB) and `preview` (at most 16 KiB), in either order. Both
are sealed on the phone (#805, SessionKit's `ShareLinkSealing`): each is
`"SMLINK"`, version 1, the part number (1 preview, 2 packet), a 12-byte nonce,
the AES-256-GCM ciphertext and its 16-byte tag, under a key that travels only in
the link's `#` part. The server checks only that header and the minimum length,
and stores both parts unread; a readable or swapped part is refused (400
`bad_preview` or `bad_packet`). Extra or duplicate parts are rejected. The
response is 201 with `id` (16 random bytes in lowercase hex), `path` (`/l/<id>`)
and `expiresAt` (UTC deadline). Upload attempts are limited to 30 per client
address per hour in memory. The sealing vector both sides test against is
`contracts/fixtures/share-link-sealing-vector.json`.

### Sender side of the strike ladder (#2239)

A reported link counts against the install that made it, so the ladder in
`internal/reportrules` (two reported links in 90 days is a strike; pauses of a
week, a month, then permanent) has someone to pause. The flow:

1. The app asks `POST /api/v1/links/sender`, an attested request with no body. The
   answer is `sharingAllowed`, `sharingEnded`, `sharingPausedUntil` when a pause is
   running, `notice` once after a takedown (always "A link you shared was taken down
   after a report", never a category), and, when sharing is allowed, a one-use
   `permit` good for ten minutes (held in memory).
2. The upload carries it as `X-SM-Link-Permit`. The upload stays unattested, so the
   attested request says nothing about what is shared. A bad, spent or stale permit
   is 403 `bad_permit`; a sender struck since the check is 403 `sharing_paused`.
3. The server ties the new link to `HMAC-SHA-256(server key, install key id)` in
   `state/senders/bindings` until the link expires or is reported. The key is made once in
   `state/senders/key` (mode 0600) and has to persist: a pause must outlive a
   restart. A report of that link (`reportLink`, after the takedown) records it in
   the sender's file in `state/senders/senders` and deletes the tie: keyed hashes of link
   ids with times, the ladder step and a "tell them" flag. No category, reporter, content or install key id is kept.
4. A link made without a permit is not attributed and counts against nobody. That is
   today's behaviour and the default, so the app that exists keeps working. With
   `serve -links-require-permit` an upload with none is 403 `permit_required`. The
   app sends permits since #4130, but don't turn it on yet: older builds, phones
   without App Attest and any phone whose sender check fails send none, and the app
   shows that refusal as "busy". #4134 lists what has to land first.

DeviceCheck (#1728) keeps the ladder step across a reinstall. Off by default; start
`serve -devicecheck-key AuthKey_XXXX.p8 -devicecheck-key-id XXXX` (the team id is read
from `-app-id`; `-devicecheck-development` for debug builds) to turn it on. Do not turn it on yet: once someone has been struck, an app that does not send the token gets no permit (and reads the answer as "busy", see #4134). Until some
sender has been struck, nothing changes and nobody is asked for anything (the marker is
the empty file `state/senders/ladder`). After the first strike, a sender check with no
token is answered `{"deviceCheckWanted": true}` and nothing else, no permit. The app
repeats it with `{"deviceCheckToken": "<base64>"}` in the signed body; the server reads
the device's two bits at Apple and, bit 0 the low one, 00 clean, 01 strike 1, 10 strike 2,
11 ended: bits above this install's step raise it (a reinstall cannot skip a step, and 11
stays ended), and a step above the bits is written (a failed write is tried again at the
next check). The token is used for those calls and dropped: not stored, not logged, not
in an error. Apple unreachable or refusing the server's own key: the check is answered
from this server's record and counted as `devicecheck_unavailable` in the abuse log; a
token Apple refuses is 400 `bad_device_token`. The 11 bits end link sharing only; the
reporter rule in #1728's 2026-11-05 comment (turn off *receiving*, not reporting) has no
bit and is not built. Known limits: the bits are written at the struck install's next check (the server has no token when a report arrives), so a struck listener who reinstalls before that install checks again starts clean; once any sender is struck, every sender check is asked for a token and read at Apple (one call each); Apple's reply for a bad token is taken as a 400, and a plain-text 200 that is neither bits nor "Failed to find bit state" fails open (not checked against Apple's live error table). A pause is a second record here, not in the bits, so a reinstall
clears a running pause but not the strike.

What this does not do: the server-signed "sharing paused until" token is the app's
side; a reinstall makes a new install key and so a new sender here. The app does not
yet ask for or send a device token (Swift, a Mac slice), and sealed-sender tags
(#1728, 2026-11-05) are not built. The daily sweep deletes ties past link expiry, drops reported links
past 90 days, and deletes a clean sender's file; a sender on the ladder keeps theirs.

`GET /l/<id>` serves a page shell with the install link and the report form,
and no Margin, title or excerpt. Its module (`/l/share-link-page.mjs`, with
`/l/share-link-open.mjs`, both embedded in the binary) fetches the sealed bytes
from `GET /l/<id>/preview`, opens them with the key from `location.hash`, and
shows the Margins as text. The page checks what the server can no longer read:
a source title, at least one Margin, and the excerpt ceilings of 500 code points
before a Margin and 120 after it (the app's `ExcerptCapRule`, #2237). It leaves
out a source URL with a query, credentials or fragment. `GET /l/<id>/packet`
downloads the unchanged sealed packet, which the app opens with the same key.
No source audio is served or fetched.

A web app on another origin reads the packet and preview only if the server is
started with `serve -link-origins https://web.example.com[,…]` (#3013). Empty,
the default, sends no CORS headers anywhere. A listed origin, matched exactly as
the browser sends it, gets `Access-Control-Allow-Origin` on those two GET routes
(errors included, so the app can tell 410 from a network failure), and their
`OPTIONS` preflight allows `GET` with no extra headers. Every answer on them says
`Vary: Origin`. Credentials are never allowed, and uploads, reports and the page
itself never answer CORS. A bad entry (a wildcard, a path, upper case, a default
port, `null`) stops the server rather than being skipped.
The report form posts one fixed reason (`privacy`, `copyright`, `harmful`, `spam`
or `other`) to `/l/<id>/report`; reports join the existing hourly abuse log with
an `id` field, without a reporter address. Request logs use `/l/*` for all link
paths, including packet downloads and reports. Caddy does the same on errors.

Expiry is exactly 30 days after creation. Reads answer 410 at the deadline;
the existing daily sweep deletes the packet and preview, retaining only expiry
metadata to continue answering 410. `smserver takedown -state DIR ID` removes a
link immediately. Data files are private (0600 under 0700 directories), separate
from the public web root. Pending uploads are unpublished and cleaned on failure;
the daily sweep also removes interrupted uploads older than an hour.

`smserver reports -state DIR [-since 24h] [-category C]` lists the filed report
records (reference, date, category, link id, what the link is now, written reason)
so the owner can see them; it flags a reported link that is `STILL SERVED`, never
opens content, and shows a pasted key as `[link removed]` (#2846).

A link reported to the CyberTipline is the one exception to the 30 days (#2235):
`smserver hold -state DIR -report REPORTID [-link-file FILE|-] ID` takes it down,
moves its packet, preview and the reported full link into `links-held` beside the
links folder (0700, no read call in the server), and the daily sweep deletes it one
year later, logging each event without content in `links-held/access.log`.
`smserver show-reported-link -state DIR ID` prints only the reported links of a held link (never the packet or preview) and logs the read (#3120).
`smserver release-hold -state DIR -reason TEXT ID` ends a hold early. The owner's
steps are in `docs/legal/cybertipline-runbook.md`.

The report form is public, so holds are bounded (#3120): a held link keeps up to
five different reported links (`reported-link`, `reported-link-2` ...), and the
form's holds are capped at 500 items, 5 GiB, 50 a UTC day and 5 a day per client
network. Past a cap the link is disabled (`Store.Disable`: dark at once, content
and the reported link kept for 30 days), the server log says `HOLD CAP REACHED` and
`links-held/access.log` gets a `cap` line, and the owner runs `smserver hold`,
which the caps do not limit.

Privacy-page wording is an unpublished HTML-comment draft in
`Site/privacy/index.html`. No server deployment or site publication is part of
this change.
