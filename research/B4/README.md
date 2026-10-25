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

`POST /api/v1/links` accepts `multipart/form-data` with exactly two parts:
`packet` (opaque, nonempty, at most 20 MiB) and `preview` (UTF-8 JSON, at most
16 KiB), in either order. Preview shape:

```json
{"source":{"title":"Episode title","show":"Show name","url":"https://publisher.example/episode"},"margins":[{"text":"My Margin","before":"Source excerpt before","after":"Source excerpt after"}]}
```

The excerpt before a Margin is limited to 500 Unicode code points and the one after it to 120 (the app's `ExcerptCapRule`, #2237). At least one Margin and a
source title are required. Unknown fields, trailing JSON, extra or duplicate
parts are rejected. The response is 201 with `id` (16 random bytes in lowercase
hex), `path` (`/l/<id>`) and `expiresAt` (UTC deadline). Upload attempts are
limited to 30 per client address per hour in memory. This contract stores the
preview as readable JSON as requested by #486; it does **not** wire #805's sealed
preview/browser decryption. Resolve that privacy difference before enabling it.

`GET /l/<id>` serves an escaped, self-contained HTML page, and
`GET /l/<id>/packet` downloads the unchanged bytes. No source audio is served or
fetched. Source URLs containing queries, credentials or fragments are omitted.
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
