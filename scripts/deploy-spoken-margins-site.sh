#!/usr/bin/env bash

# Deploys Site/ to the VPS. The normal route is .github/workflows/deploy-site.yml, which runs this after the owner
# approves (#4982); running it from the Mac is the fallback, and the only way to upload the voice mirror.

set -euo pipefail
IFS=$'\n\t'

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
site_directory="${repository_root}/Site"
# `ptp` is an alias in the owner's ~/.ssh/config for the VPS; set SPOKEN_MARGINS_VPS_REMOTE to use another host.
# The alias logs in as the normal deploy user (#2478, smdeploy), which owns the web folder and needs no root for the
# upload. Root login on the box is switched off, so do not name root@ here.
vps_remote="${SPOKEN_MARGINS_VPS_REMOTE:-ptp}"
ssh_key="${SPOKEN_MARGINS_VPS_SSH_KEY:-}"
site_host="spokenmargins.proximitytoprogress.com"
web_root="/srv/www/spokenmargins"

if [[ ! -f "${site_directory}/index.html" || ! -f "${site_directory}/privacy/index.html" || ! -f "${site_directory}/support/index.html" || ! -f "${site_directory}/terms/index.html" ]]; then
  echo "The Site directory is incomplete: ${site_directory}" >&2
  exit 1
fi

control_directory="$(mktemp -d "/tmp/spoken-margins-deploy.XXXXXX")"
control_socket="${control_directory}/ssh-control"

cleanup() {
  ssh -S "${control_socket}" -O exit "${vps_remote}" >/dev/null 2>&1 || true
  rmdir "${control_directory}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh_master_arguments=(
  -M
  -S "${control_socket}"
  -o ControlPersist=60
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
)

if [[ -n "${ssh_key}" ]]; then
  if [[ ! -f "${ssh_key}" ]]; then
    echo "SSH key not found: ${ssh_key}" >&2
    exit 1
  fi
  ssh_master_arguments+=(
    -i "${ssh_key}"
    -o IdentitiesOnly=yes
  )
fi

echo "Opening one SSH connection to ${vps_remote}."
echo "Enter the VPS password at the prompt, or set SPOKEN_MARGINS_VPS_SSH_KEY to an authorized private key."
ssh "${ssh_master_arguments[@]}" -fnNT "${vps_remote}"

remote_uid="$(ssh -S "${control_socket}" "${vps_remote}" 'id -u' | tr -d '\r')"
[[ "${remote_uid}" =~ ^[0-9]+$ ]] || { echo "Could not read the login's user id on ${vps_remote}." >&2; exit 1; }

echo "Preparing ${web_root}."
if [[ "${remote_uid}" == 0 ]]; then
  ssh -S "${control_socket}" "${vps_remote}" "install -d -m 0755 '${web_root}'"
else
  # A normal login can write only into a folder it owns. research/B4/deploy/create-deploy-user.sh hands it over once.
  ssh -S "${control_socket}" "${vps_remote}" "test -d '${web_root}' && test -w '${web_root}'" || {
    echo "${vps_remote} cannot write to ${web_root}. Run create-deploy-user.sh on the server once (see research/B4/README.md, Server access)." >&2
    exit 1
  }
fi

# The voice mirror (#1818) goes up first, so the catalog never points at files that are not there yet. It lives in
# voices/files/ on the server, outside Site/, and is never deleted by the site upload below. `scripts/voice-catalog
# publish --apply` sets SPOKEN_MARGINS_VOICE_MIRROR_DIR to a folder of links to the checked files.
mirror_directory="${SPOKEN_MARGINS_VOICE_MIRROR_DIR:-}"
if [[ -n "${mirror_directory}" ]]; then
  if [[ ! -d "${mirror_directory}" ]]; then
    echo "SPOKEN_MARGINS_VOICE_MIRROR_DIR is not a folder: ${mirror_directory}" >&2
    exit 1
  fi
  echo "Uploading the voice mirror from ${mirror_directory}/."
  ssh -S "${control_socket}" "${vps_remote}" "install -d -m 0755 '${web_root}/voices/files'"
  rsync \
    --archive \
    --copy-links \
    --compress \
    --partial \
    --exclude '.DS_Store' \
    -e "ssh -S ${control_socket}" \
    "${mirror_directory}/" \
    "${vps_remote}:${web_root}/voices/files/"
fi

# voices/files/ is never deleted. A checkout with no Site/voices/ (the voice catalog is committed only after a publish)
# leaves the server's whole voices/ folder alone, because rsync cannot delete a folder that still holds a protected one.
voice_excludes=(--exclude '/voices/files/')
if [[ ! -d "${site_directory}/voices" ]]; then
  voice_excludes=(--exclude '/voices/')
fi

echo "Uploading ${site_directory}/."
rsync \
  --archive \
  --compress \
  --delete \
  --exclude '.DS_Store' \
  "${voice_excludes[@]}" \
  -e "ssh -S ${control_socket}" \
  "${site_directory}/" \
  "${vps_remote}:${web_root}/"

# What scripts/sm_live.py reads to say which commit is live and when it went up (#3872). The rsync above deletes it, so it
# is written after. Site/ is copied from the working tree, so a checkout with local edits says so.
site_commit="$(git -C "${repository_root}" rev-parse --short HEAD)"
if [[ -n "$(git -C "${repository_root}" status --porcelain -- Site)" ]]; then site_commit="${site_commit}-dirty"; fi
printf '{"commit":"%s","deployed_at":"%s"}\n' "${site_commit}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" |
  ssh -S "${control_socket}" "${vps_remote}" "umask 022 && cat > '${web_root}/deploy.json'"

echo "Configuring and validating Caddy."
if [[ "${remote_uid}" != 0 ]]; then
  # Editing and reloading Caddy is root's. When the site's block is already there nothing needs doing; when it is not,
  # that first setup is a server deploy (research/B4/deploy/deploy.sh), run by a person at a terminal.
  if ! ssh -S "${control_socket}" "${vps_remote}" "test -r /etc/caddy/Caddyfile"; then
    echo "${vps_remote} cannot read /etc/caddy/Caddyfile, so it cannot tell whether Caddy serves ${site_host}. The files are uploaded; check by hand." >&2
    exit 1
  elif ssh -S "${control_socket}" "${vps_remote}" "grep -Fqx '${site_host} {' /etc/caddy/Caddyfile"; then
    echo "Caddy already serves ${site_host}; a normal login leaves it alone."
  else
    echo "Caddy has no block for ${site_host} and ${vps_remote} is not root. Run research/B4/deploy/deploy.sh first." >&2
    exit 1
  fi
else
ssh -S "${control_socket}" "${vps_remote}" bash -s -- "${site_host}" "${web_root}" <<'REMOTE_SCRIPT'
set -euo pipefail

site_host="$1"
web_root="$2"
caddy_config="/etc/caddy/Caddyfile"

test -f "${web_root}/index.html"
test -f "${web_root}/privacy/index.html"
test -f "${web_root}/support/index.html"
test -f "${web_root}/terms/index.html"

if ! grep -Fqx "${site_host} {" "${caddy_config}"; then
  caddy_backup="${caddy_config}.before-spoken-margins.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "${caddy_config}" "${caddy_backup}"

  {
    printf '\n%s {\n' "${site_host}"
    printf '  root * %s\n' "${web_root}"
    printf '  encode gzip\n'
    printf '  file_server\n'
    printf '}\n'
  } >> "${caddy_config}"

  if ! caddy validate --config "${caddy_config}"; then
    cp -a "${caddy_backup}" "${caddy_config}"
    echo "Caddy validation failed; restored ${caddy_backup}." >&2
    exit 1
  fi
fi

caddy validate --config "${caddy_config}"
systemctl reload caddy
systemctl is-active --quiet caddy
REMOTE_SCRIPT
fi

echo "Verifying public HTTPS pages."
routes=(/ /privacy/ /support/ /terms/)
if [[ -f "${site_directory}/voices/index.html" ]]; then
  routes+=(/voices/ /voices/v1/manifest.json /voices/v1/catalog.json)
fi
for route in "${routes[@]}"; do
  if ! status_code="$(curl --silent --location --output /dev/null --write-out '%{http_code}' --max-time 30 --retry 5 --retry-delay 2 --retry-all-errors "https://${site_host}${route}")"; then
    echo "Verification failed: could not reach https://${site_host}${route}." >&2
    exit 1
  fi
  if [[ "${status_code}" != "200" ]]; then
    echo "Verification failed: https://${site_host}${route} returned HTTP ${status_code}." >&2
    exit 1
  fi
  echo "HTTP 200 https://${site_host}${route}"
done

echo "Spoken Margins support site deployment succeeded."
