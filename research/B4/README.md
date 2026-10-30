# B4 bridge: server (M1)

**Deployed** to the Spoken Margins VPS on 2026-09-28 (details on #190): `https://spokenmargins.proximitytoprogress.com/api/v1/health`. Deploys run from the Mac with the owner's OK, never from a cloud session.

Design and privacy rules: [DESIGN.md](DESIGN.md). Tracking issue #190.

Needs Go 1.24+. No third-party modules.

```bash
cd research/B4/server && go test ./...                      # unit and end-to-end tests
research/B4/scripts/demo.sh                                 # health, one attested request, block one install, kill switch
CADDY=caddy SMSERVER=smserver research/B4/deploy/test-edit-caddyfile.sh   # Caddyfile edit, validate, local routing
research/B4/deploy/test-server-rollback.sh   # deploy keeps the old smserver and puts it back on rollback
research/B4/deploy/deploy.sh --dry-run root@<vps>           # from the Mac: show every change on the box, change nothing
```

`deploy/deploy.sh` without `--dry-run` deploys; the owner approves the dry-run diff first. Admin on the box runs as the service user, e.g. `runuser -u smserver -- smserver switch -public /srv/www/spokenmargins-server attest off`.

Listening maps (#551, DESIGN.md §10) stay off until the owner, on the box: puts `ANTHROPIC_API_KEY=...` in `/etc/smserver/maps.env` (owner root, mode 0600), restarts the service, and runs `smserver switch ... maps on`. `-minimum-build N` (before the service name) also sets that service's `minimumBuild` in the same serial bump; leaving it out keeps the current value and `0` removes it. `smserver takedown-map -state /var/lib/smserver KEY` removes one map at once.

Anonymous tokens (#737, DESIGN.md §11) stay off until the owner runs `smserver switch ... tokens on`. Nothing in the app uses them yet. Their keys and spent records live under `/var/lib/smserver/tokens/`; deleting that folder voids every token issued so far and is otherwise harmless.

Map uploads can require one of those tokens (#743, DESIGN.md §10): `smserver switch ... mapUploadToken on`, with `tokens` also on. Leave it off until an app build sends tokens with its uploads; until then it would refuse every upload.

## Share links (#486)

The `links` service is off by default. Deployment and enabling it stay with the
owner. Set `serve -links-install-url https://testflight.apple.com/join/INVITATION`
(or the app's real `https://apps.apple.com/.../id...` listing); without a valid
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

Privacy-page wording is an unpublished HTML-comment draft in
`Site/privacy/index.html`. No server deployment or site publication is part of
this change.
