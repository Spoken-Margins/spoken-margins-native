#!/usr/bin/env bash
# Deploys smserver to the Spoken Margins VPS. Run from the Mac:
#
#   research/B4/deploy/deploy.sh --dry-run root@<vps>   # show every change; change nothing
#   research/B4/deploy/deploy.sh root@<vps>             # apply (after the owner approves the dry run)
#
# Environment: SM_SERVER_PORT (default 8795; 8787 is taken on the box),
# SM_SERVER_ROOT (default /srv/www/spokenmargins-server), SM_SSH_KEY.
#
# It builds a static linux/amd64 binary, uploads it with the templates to a
# temporary directory, and runs remote-install.sh there. That script edits
# only the product's blocks (#3062: spokenmargins.com, www, the web app's
# app.spokenmargins.com whose files come from deploy-web.sh, and the two old
# proximitytoprogress.com hosts, which keep serving the API and redirect the
# rest) and the global log filter; it refuses if the old block isn't the plain one it expects,
# validates the candidate with `caddy validate`, backs up the Caddyfile,
# reloads (never restarts) Caddy, checks the sites and health, and rolls the
# Caddyfile back if a check fails. It copies the old smserver binary and unit
# aside first and puts them back whenever it rolls back. The live Caddyfile never leaves the box
# except as a diff with hashes masked.
set -euo pipefail
IFS=$'\n\t'

dry_run=0
if [[ "${1:-}" == --dry-run ]]; then dry_run=1; shift; fi
[[ $# -eq 1 ]] || { echo "usage: $0 [--dry-run] <ssh-host>" >&2; exit 2; }
host="$1"
port="${SM_SERVER_PORT:-8795}"
server_root="${SM_SERVER_ROOT:-/srv/www/spokenmargins-server}"
site_host="spokenmargins.com"
legacy_site_host="spokenmargins.proximitytoprogress.com"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

stage="$(mktemp -d "${TMPDIR:-/tmp}/smserver-deploy.XXXXXX")"
control="${stage}.ssh"
remote_dir=""
ssh_opts=(-S "${control}")
cleanup() {
  if [[ -n "${remote_dir}" ]]; then ssh "${ssh_opts[@]}" "${host}" "rm -rf '${remote_dir}'" >/dev/null 2>&1 || true; fi
  ssh "${ssh_opts[@]}" -O exit "${host}" >/dev/null 2>&1 || true
  rm -rf "${stage}"
}
trap cleanup EXIT

echo "== build linux/amd64 smserver"
cp "${here}/edit-caddyfile.sh" "${here}/remote-install.sh" "${here}/caddy-global.caddy" "${here}/caddy-site.caddy" \
  "${here}/caddy-legacy-site.caddy" "${here}/caddy-www.caddy" "${here}/caddy-legacy-web.caddy" "${here}/caddy-web.caddy" "${here}/smserver.service" "${here}/journald@smserver.conf" "${stage}/"
(cd "${here}/../server" && go test ./... >/dev/null && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "${stage}/smserver" ./cmd/smserver)
echo "built $(git -C "${here}" rev-parse --short HEAD), tests pass"
if ((dry_run)); then rm "${stage}/smserver"; fi

master=(-M -fnNT -o ControlPersist=120 -o ServerAliveInterval=15)
if [[ -n "${SM_SSH_KEY:-}" ]]; then master+=(-i "${SM_SSH_KEY}" -o IdentitiesOnly=yes); fi
echo "== connecting to ${host}"
ssh "${ssh_opts[@]}" "${master[@]}" "${host}"
remote_dir="$(ssh "${ssh_opts[@]}" "${host}" 'mktemp -d /tmp/smserver-deploy.XXXXXX')"
tar -C "${stage}" -czf - . | ssh "${ssh_opts[@]}" "${host}" "tar -xzf - -C '${remote_dir}'"

if ((dry_run)); then
  ssh "${ssh_opts[@]}" "${host}" "bash '${remote_dir}/remote-install.sh' dry-run '${port}' '${server_root}'"
  echo "== dry run finished. Nothing on ${host} was changed. Rerun without --dry-run once the owner approves."
  exit 0
fi

log="${stage}/apply.log"
ssh "${ssh_opts[@]}" "${host}" "bash '${remote_dir}/remote-install.sh' apply '${port}' '${server_root}'" | tee "${log}"
backup="$(sed -n 's/^BACKUP=//p' "${log}")"
bin_backup="$(sed -n 's/^BIN_BACKUP=//p' "${log}")"
unit_backup="$(sed -n 's/^UNIT_BACKUP=//p' "${log}")"

echo "== checking from this machine"
failed=""
# The old host's API must keep answering (shipped builds use it). The new hosts
# are reported but cannot roll the deploy back: they need DNS and a certificate.
for url in https://proximitytoprogress.com/ "https://${legacy_site_host}/api/v1/health"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${url}" || true)"
  echo "${code} ${url}"
  if [[ "${code}" == 000 || "${code}" -ge 500 ]]; then failed="${url}"; fi
done
for url in "https://${site_host}/" "https://${site_host}/api/v1/health" "https://www.${site_host}/" "https://app.${site_host}/" "https://${legacy_site_host}/"; do
  echo "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${url}" || true) ${url} (not a rollback condition)"
done
if [[ -n "${failed}" ]]; then
  echo "== ${failed} failed from outside; rolling the Caddyfile and smserver back" >&2
  ssh "${ssh_opts[@]}" "${host}" "SM_SERVER_PORT='${port}' bash '${remote_dir}/remote-install.sh' rollback '${backup}' '${bin_backup}' '${unit_backup}'"
  exit 1
fi
echo "== deployed. Backups on the box: Caddyfile ${backup}, smserver ${bin_backup:-none}, unit ${unit_backup:-none}"
echo "   Next: stop smserver, send one /api request, and check that journalctl -u caddy shows no remote_ip or X-SM-."
