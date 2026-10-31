#!/usr/bin/env bash
# Runs ON THE VPS as root, from the staging directory deploy.sh uploads.
#   remote-install.sh dry-run PORT SERVER_ROOT   show every change, change nothing
#   remote-install.sh apply   PORT SERVER_ROOT   install, reload Caddy, check, roll back on failure
#   remote-install.sh rollback BACKUP [BIN_BACKUP UNIT_BACKUP]
#                                                restore a Caddyfile backup and reload; with the
#                                                server backups, put the previous smserver back too
# Paths can be overridden for local testing (SM_CADDYFILE and friends).
set -euo pipefail
umask 077

stage="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
caddyfile="${SM_CADDYFILE:-/etc/caddy/Caddyfile}"
unit="${SM_UNIT:-/etc/systemd/system/smserver.service}"
jconf="${SM_JOURNALD_CONF:-/etc/systemd/journald@smserver.conf}"
bin="${SM_BIN:-/usr/local/bin/smserver}"
# The product moved to spokenmargins.com (#3062). The old host keeps serving
# the API, link and static machine paths, so it is the one whose answers can
# roll a deploy back: it already has a certificate. The new hosts may still be
# waiting for theirs (DNS, then a certificate, can lag the reload), so they are
# reported, never a reason to roll back.
site_host="spokenmargins.proximitytoprogress.com"
new_site_host="spokenmargins.com"
# The web app's files (#3020): deploy-web.sh fills this folder; Caddy serves
# it as app.spokenmargins.com (caddy-web.caddy).
web_host="app.spokenmargins.com"
web_root="${SM_WEB_ROOT:-/srv/www/spokenmargins-web}"
check_urls=("https://proximitytoprogress.com/")

say() { printf '== %s\n' "$*"; }
die() { printf 'remote-install: %s\n' "$*" >&2; exit 1; }

# Nothing that could be a credential leaves the box in a diff: bcrypt and
# argon2 hashes, and any long token-like run (no slash, so paths survive).
redact() {
  sed -E -e 's/\$2[aby]?\$[0-9]{2}\$[./A-Za-z0-9]{53,}/[redacted hash]/g' \
    -e 's/\$argon2[a-z]*\$[^[:space:]]+/[redacted hash]/g' \
    -e 's/[A-Za-z0-9+=_-]{40,}/[redacted]/g'
}
show_diff() { # show_diff LABEL OLD NEW
  local old="$2"
  [[ -e "${old}" ]] || old=/dev/null
  if diff -q "${old}" "$3" >/dev/null 2>&1; then echo "-- $1: unchanged"; return; fi
  echo "-- $1:"
  diff -u --label "$1 (now)" --label "$1 (after)" "${old}" "$3" | redact || true
}

# status URL: HTTP status as seen from this box, resolving to this box's Caddy.
status() {
  local host
  host="$(sed -E 's|https://([^/]+)/.*|\1|' <<<"$1")"
  curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${host}:443:127.0.0.1" "$1" || true
}

reload_caddy() { systemctl reload caddy && systemctl is-active --quiet caddy; }

# server_healthy PORT: smserver answers ok on loopback within ten seconds.
server_healthy() {
  local _
  for _ in $(seq 20); do
    if curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:$1/api/v1/health" 2>/dev/null | grep -q '"status":"ok"'; then return 0; fi
    sleep 0.5
  done
  return 1
}

# backup_server STAMP: copy the binary and unit aside before they are
# replaced, so a failed check can put the running server back. The new unit
# may pass flags the old binary doesn't know, so the two travel together.
# Prints BIN_BACKUP= and UNIT_BACKUP= (empty on a first install).
backup_server() {
  bin_backup="" unit_backup=""
  if [[ -f "${bin}" ]]; then bin_backup="${bin}.before-smserver.$1"; cp -a "${bin}" "${bin_backup}"; fi
  if [[ -f "${unit}" ]]; then unit_backup="${unit}.before-smserver.$1"; cp -a "${unit}" "${unit_backup}"; fi
  echo "BIN_BACKUP=${bin_backup}"
  echo "UNIT_BACKUP=${unit_backup}"
}

# restore_server PORT BIN_BACKUP UNIT_BACKUP: put the previous binary and
# unit back and restart. With no previous binary (first install) it stops
# the new one instead. Never exits; says what it found.
restore_server() {
  local port="$1" b="$2" u="$3"
  if [[ -z "${b}" || ! -f "${b}" ]]; then
    systemctl stop smserver || true
    echo "no previous smserver to restore; stopped the new one" >&2
    return 0
  fi
  cp -a "${b}" "${bin}"
  if [[ -n "${u}" && -f "${u}" ]]; then cp -a "${u}" "${unit}"; fi
  systemctl daemon-reload || true
  systemctl restart smserver || true
  if server_healthy "${port}"; then
    echo "restored the previous smserver from ${b}; healthy on 127.0.0.1:${port}" >&2
  else
    echo "WARNING: restored the previous smserver from ${b} but it isn't healthy; check it now" >&2
  fi
}

# Tests source this file with __lib to get the functions above.
if [[ "${1:-}" == __lib ]]; then return 0; fi

if [[ "${1:-}" == rollback ]]; then
  backup="${2:?backup path}"
  [[ -f "${backup}" ]] || die "no backup at ${backup}"
  cp "${backup}" "${caddyfile}"
  reload_caddy
  say "restored ${backup} and reloaded Caddy"
  if [[ -n "${3:-}" ]]; then restore_server "${SM_SERVER_PORT:-8795}" "$3" "${4:-}"; fi
  exit 0
fi

mode="${1:?mode}" port="${2:?port}" server_root="${3:?server root}"
[[ "${mode}" == dry-run || "${mode}" == apply ]] || die "mode must be dry-run or apply"
[[ "${port}" =~ ^[0-9]{2,5}$ ]] || die "bad port ${port}"
[[ "${server_root}" =~ ^/srv/www/[A-Za-z0-9._-]+$ && "${server_root}" != /srv/www/spokenmargins ]] ||
  die "server root must be its own directory under /srv/www, not the site's (the site deploy rsyncs --delete there)"
command -v caddy >/dev/null || die "caddy not found"
[[ -f "${caddyfile}" ]] || die "no ${caddyfile}"

say "port ${port}"
listeners="$(ss -ltnpH "sport = :${port}" 2>/dev/null || true)"
if [[ -n "${listeners}" && "${listeners}" != *'"smserver"'* ]]; then
  die "127.0.0.1:${port} is already used by another process: ${listeners}"
fi
echo "free, or already smserver"

say "candidate files"
"${stage}/edit-caddyfile.sh" "${caddyfile}" "${stage}/Caddyfile.candidate" "${port}" "${server_root}"
sed -e "s|@PORT@|${port}|g" -e "s|@SERVER_ROOT@|${server_root}|g" "${stage}/smserver.service" >"${stage}/smserver.service.rendered"
caddy validate --adapter caddyfile --config "${stage}/Caddyfile.candidate" >"${stage}/validate.log" 2>&1 ||
  { redact <"${stage}/validate.log" >&2; die "caddy validate rejected the candidate Caddyfile; nothing changed"; }
echo "caddy validate: candidate Caddyfile is valid ($(caddy version | cut -d' ' -f1))"

say "changes"
show_diff "${caddyfile}" "${caddyfile}" "${stage}/Caddyfile.candidate"
show_diff "${unit}" "${unit}" "${stage}/smserver.service.rendered"
show_diff "${jconf}" "${jconf}" "${stage}/journald@smserver.conf"
id smserver >/dev/null 2>&1 && echo "-- user smserver: exists" || echo "-- user smserver: will be created (system user, no login)"
echo "-- directories: ${server_root}/api/v1 and ${server_root}/bridge/v1 (owner smserver, 0755); state in /var/lib/smserver (systemd StateDirectory, 0700)"
[[ -d "${web_root}" ]] && echo "-- ${web_root}: exists, kept as is ($(find "${web_root}" -type f | wc -l | tr -d ' ') files)" ||
  echo "-- ${web_root}: will be created empty (owner root, 0755); deploy-web.sh fills it, and until then https://${web_host}/ answers 404"
[[ -f "${server_root}/api/v1/config.json" ]] && echo "-- config.json: exists, kept as is" || echo "-- config.json: will be created (attest on, bridge on)"
[[ -x "${bin}" ]] && echo "-- ${bin}: will be replaced" || echo "-- ${bin}: will be installed"
echo "-- then: enable and (re)start smserver, check 127.0.0.1:${port}/api/v1/health, back up ${caddyfile}, install the candidate, reload (not restart) Caddy"
echo "-- then check, resolving to this box: ${check_urls[*]} (must not change), https://${site_host}/api/v1/health and /api/v1/config.json; roll back the Caddyfile if any fails"
echo "-- not a rollback condition, reported: https://${new_site_host}/, its /api/v1/health, https://www.${new_site_host}/ and https://${web_host}/"
for u in "${check_urls[@]}"; do echo "   now: $(status "${u}") ${u}"; done

if [[ "${mode}" == dry-run ]]; then
  say "dry run: nothing was changed"
  exit 0
fi

say "apply"
declare -A before
for u in "${check_urls[@]}"; do before["${u}"]="$(status "${u}")"; done

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_server "${stamp}"
id smserver >/dev/null 2>&1 || useradd --system --home-dir /var/lib/smserver --no-create-home --shell /usr/sbin/nologin smserver
install -d -o smserver -g smserver -m 0755 "${server_root}" "${server_root}/api" "${server_root}/api/v1" "${server_root}/bridge" "${server_root}/bridge/v1"
install -d -m 0755 "${web_root}"
install -m 0755 "${stage}/smserver" "${bin}.new" && mv -f "${bin}.new" "${bin}"
install -m 0644 "${stage}/smserver.service.rendered" "${unit}"
install -m 0644 "${stage}/journald@smserver.conf" "${jconf}"
if [[ ! -f "${server_root}/api/v1/config.json" ]]; then
  # The unit's sandbox makes this root read-only to the service, so the
  # first config is written here, as smserver, outside the sandbox.
  # umask 022 as well: this script runs under 077, and Caddy (another user)
  # must be able to read what's written here. The binary also sets 0644
  # itself; this covers an older binary.
  (umask 022 && runuser -u smserver -- "${bin}" switch -public "${server_root}" attest on)
fi
# Caddy serves this root as its own user, so every file must be world-readable
# and every directory world-traversable. Check before Caddy is touched; the
# first deploy rolled back on a 0600 config.json.
unreadable="$(find "${server_root}" \( -type f ! -perm -o=r \) -o \( -type d ! -perm -o=rx \) 2>/dev/null | head -5)"
[[ -z "${unreadable}" ]] || die "not readable by Caddy (fix with chmod 0644 files / 0755 dirs); Caddy was not touched: ${unreadable}"
systemctl daemon-reload
systemctl try-restart systemd-journald@smserver.service || true
systemctl enable --quiet smserver
systemctl restart smserver
if ! server_healthy "${port}"; then
  journalctl -u smserver -n 20 --no-pager >&2 || true
  restore_server "${port}" "${bin_backup}" "${unit_backup}"
  die "the new smserver didn't answer on 127.0.0.1:${port}. Caddy was not touched."
fi
echo "smserver healthy on 127.0.0.1:${port}"

backup="${caddyfile}.before-smserver.${stamp}"
cp -a "${caddyfile}" "${backup}"
echo "BACKUP=${backup}"
cp "${stage}/Caddyfile.candidate" "${caddyfile}"
rollback() {
  echo "check failed: $*; rolling back the Caddyfile" >&2
  cp "${backup}" "${caddyfile}"
  reload_caddy || echo "WARNING: Caddy reload after rollback failed; check it now" >&2
  restore_server "${port}" "${bin_backup}" "${unit_backup}"
  exit 1
}
reload_caddy || rollback "caddy reload"

sleep 1
for u in "${check_urls[@]}"; do
  now="$(status "${u}")"
  [[ "${now}" != 000 && "${now}" -lt 500 ]] || rollback "${u} answered ${now}, was ${before[${u}]}"
  [[ "${now}" == "${before[${u}]}" ]] || rollback "${u} answered ${now}, was ${before[${u}]}"
  echo "ok ${now} ${u}"
done
body="$(curl -s --noproxy '*' --max-time 15 --resolve "${site_host}:443:127.0.0.1" "https://${site_host}/api/v1/health" || true)"
[[ "${body}" == *'"status":"ok"'* ]] || rollback "health answered '${body}'"
echo "ok 200 https://${site_host}/api/v1/health"
[[ "$(status "https://${site_host}/api/v1/config.json")" == 200 ]] || rollback "config.json not served"
echo "ok 200 https://${site_host}/api/v1/config.json"
# Not a rollback condition: the web app's certificate may still be on its way,
# and its folder is empty until deploy-web.sh runs.
for u in "https://${new_site_host}/" "https://${new_site_host}/api/v1/health" "https://www.${new_site_host}/" "https://${web_host}/" "https://${site_host}/"; do
  echo "new hosts (not checked for rollback): $(status "${u}") ${u}"
done
say "deployed"
