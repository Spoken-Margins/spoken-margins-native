# B4 bridge: server (M1)

**Deployed** to the Spoken Margins VPS on 2026-09-28 (details on #190): `https://spokenmargins.proximitytoprogress.com/api/v1/health`. Deploys run from the Mac with the owner's OK, never from a cloud session.

Design and privacy rules: [DESIGN.md](DESIGN.md). Tracking issue #190.

Needs Go 1.24+. No third-party modules.

```bash
cd research/B4/server && go test ./...                      # unit and end-to-end tests
research/B4/scripts/demo.sh                                 # health, one attested request, block one install, kill switch
CADDY=caddy SMSERVER=smserver research/B4/deploy/test-edit-caddyfile.sh   # Caddyfile edit, validate, local routing
research/B4/deploy/deploy.sh --dry-run root@<vps>           # from the Mac: show every change on the box, change nothing
```

`deploy/deploy.sh` without `--dry-run` deploys; the owner approves the dry-run diff first. Admin on the box runs as the service user, e.g. `runuser -u smserver -- smserver switch -public /srv/www/spokenmargins-server attest off`.
