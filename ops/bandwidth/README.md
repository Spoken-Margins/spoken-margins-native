# VPS transfer alert

The Hostinger VPS has an 8 TB monthly transfer allowance, and hPanel shows usage but sends no alert. This check emails the owner once the month passes 4 TB, half the allowance, as planned in `research/B4/DESIGN.md` ("Cost ceiling and alert").

- `vnstat` counts traffic on `eth0` (installed 2026-10-31, so October's figure starts that day).
- `sm-bandwidth.timer` runs `bandwidth_check.py` once a day. It pings a Healthchecks.io check every day, and pings its `/fail` URL when the month is past the alert line. Healthchecks emails on `/fail`, and also when the daily ping stops arriving, so a dead check is noticed too.
- vnstat counts calendar months. If Hostinger's cycle starts on a billing day instead, the two figures drift apart; hPanel's Overview is the authority.

Install, from the Mac:

1. On the host, as root, write the check's ping URL (from Healthchecks, check "VPS bandwidth", period 1 day) to `/etc/sm-bandwidth/ping-url`, mode 0600. It is a secret-ish URL: never commit it.
2. `ops/bandwidth/deploy.sh <ssh-host>` (dry run), then `ops/bandwidth/deploy.sh <ssh-host> --enable`.

## Cost and catch

1. Cost per run: one `vnstat` read and one HTTPS request on the VPS; no Mac minutes, tokens or Actions minutes.
2. Runs once a day.
3. Catches transfer heading toward the 8 TB cap (a traffic spike or abuse of the share-link and relay routes) weeks before Hostinger throttles or bills. No past failure yet: usage was 0.08 TB on 2026-10-31.
4. It is waste if it never fires and the owner prefers checking hPanel; remove the timer then.
