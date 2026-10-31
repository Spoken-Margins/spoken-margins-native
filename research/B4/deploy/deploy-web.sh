#!/usr/bin/env bash
# Deploys the web app (Web/, a static Vite PWA, #3020) to the VPS. Run from the Mac:
#
#   research/B4/deploy/deploy-web.sh --dry-run root@<vps>   # build, then list what would change; change nothing
#   research/B4/deploy/deploy-web.sh root@<vps>             # copy it (after the owner approves the dry run)
#
# Run deploy.sh first: it adds the Caddy block that serves /srv/www/spokenmargins-web as
# https://app.spokenmargins.proximitytoprogress.com (caddy-web.caddy) and creates the folder.
#
# It builds Web/ as committed at HEAD (git archive, so uncommitted edits never ship) in a temporary
# folder, with VITE_RELAY_ORIGIN set to the share-link server, and copies the result with rsync. Files
# are compared by content; new files land together at the end (--delay-updates) and old ones are
# removed after that, so a page mid-load never finds half a build.
#
# Share-link creation stays off in this build: `npm run build` is Vite's production mode, and only
# `--mode share-links-test` turns it on (Web/vite.config.ts). The script also refuses a build that
# carries a test relay origin.
#
# Environment: SM_SSH_KEY, SM_RELAY_ORIGIN (default https://spokenmargins.proximitytoprogress.com).
set -euo pipefail
IFS=$'\n\t'

dry_run=0
if [[ "${1:-}" == --dry-run ]]; then dry_run=1; shift; fi
[[ $# -eq 1 ]] || { echo "usage: $0 [--dry-run] <ssh-host>" >&2; exit 2; }
host="$1"
web_host="app.spokenmargins.proximitytoprogress.com"
web_root="/srv/www/spokenmargins-web"
relay_origin="${SM_RELAY_ORIGIN:-https://spokenmargins.proximitytoprogress.com}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "${here}" rev-parse --show-toplevel)"

die() { printf 'deploy-web: %s\n' "$*" >&2; exit 1; }
# The site deploy rsyncs --delete into /srv/www/spokenmargins and smserver
# owns /srv/www/spokenmargins-server; this must never point at either.
[[ "${web_root}" =~ ^/srv/www/[A-Za-z0-9._-]+$ && "${web_root}" != /srv/www/spokenmargins && "${web_root}" != /srv/www/spokenmargins-server ]] ||
  die "web root ${web_root} must be its own folder under /srv/www"
[[ "${relay_origin}" =~ ^https://[a-z0-9.-]+$ ]] || die "relay origin ${relay_origin} is not https://host"

ssh_cmd=(ssh)
rsync_ssh="ssh"
if [[ -n "${SM_SSH_KEY:-}" ]]; then
  [[ "${SM_SSH_KEY}" != *[[:space:]]* ]] || die "SM_SSH_KEY path must not contain spaces"
  ssh_cmd+=(-i "${SM_SSH_KEY}" -o IdentitiesOnly=yes)
  rsync_ssh="ssh -i ${SM_SSH_KEY} -o IdentitiesOnly=yes"
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/sm-web-deploy.XXXXXX")"
trap 'rm -rf "${stage}"' EXIT

commit="$(git -C "${repo}" rev-parse --short HEAD)"
if [[ -n "$(git -C "${repo}" status --porcelain -- Web)" ]]; then
  echo "note: Web/ has uncommitted changes; they are not deployed"
fi
echo "== build Web/ at ${commit} (relay ${relay_origin})"
git -C "${repo}" archive HEAD Web | tar -x -C "${stage}"
if ! (cd "${stage}/Web" && npm ci --no-audit --no-fund --loglevel=error &&
  VITE_RELAY_ORIGIN="${relay_origin}" npm run build -- --outDir "${stage}/dist" --emptyOutDir) >"${stage}/build.log" 2>&1; then
  tail -30 "${stage}/build.log" >&2
  die "build failed; nothing was copied"
fi
dist="${stage}/dist"
[[ -f "${dist}/index.html" && -f "${dist}/sw.js" && -f "${dist}/manifest.webmanifest" ]] || die "build is missing index.html, sw.js or the manifest"
grep -rqF -- "${relay_origin}" "${dist}/assets" || die "the relay origin is not in the build; VITE_RELAY_ORIGIN was not applied"
! grep -rqE -- 'relay\.test|127\.0\.0\.1:4174' "${dist}" || die "the build carries a test relay origin"
echo "built: $(find "${dist}" -type f | wc -l | tr -d ' ') files, $(du -sk "${dist}" | cut -f1) KB"

rsync_opts=(-rlc --delete-delay --delay-updates --chmod=D755,F644 --itemize-changes -e "${rsync_ssh}")
if "${ssh_cmd[@]}" "${host}" "test -d '${web_root}'"; then
  root_exists=1
else
  root_exists=0
fi
if ((dry_run)); then
  rsync_opts+=(--dry-run)
  if ((!root_exists)); then
    # rsync can't compare against a folder that isn't there; every file would be new.
    echo "== ${web_root} doesn't exist on ${host} yet (deploy.sh creates it), so every file would be new:"
    (cd "${dist}" && find . -type f | sed 's|^\./|  new |' | sort)
    echo "== dry run finished. Nothing on ${host} was changed. Rerun without --dry-run once the owner approves."
    exit 0
  fi
  echo "== would copy to ${host}:${web_root} (>f = new or changed file, *deleting = removed)"
else
  ((root_exists)) || die "${web_root} doesn't exist on ${host}; run deploy.sh first"
  echo "== copying to ${host}:${web_root}"
fi
rsync "${rsync_opts[@]}" "${dist}/" "${host}:${web_root}/"

if ((dry_run)); then
  echo "== dry run finished. Nothing on ${host} was changed. Rerun without --dry-run once the owner approves."
  exit 0
fi
echo "== checking from this machine"
for path in / /sw.js /manifest.webmanifest; do
  echo "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://${web_host}${path}" || true) https://${web_host}${path}"
done
echo "== deployed ${commit} to https://${web_host}/"
