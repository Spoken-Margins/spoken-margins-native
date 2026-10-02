#!/usr/bin/env bash
# edit-caddyfile.sh LIVE CANDIDATE PORT SERVER_ROOT
#
# Writes CANDIDATE: LIVE with (1) the spokenmargins-server global options
# block at the top and (2) the spokenmargins.proximitytoprogress.com site
# block replaced. Every other line is copied unchanged. It refuses (exit 2)
# unless the site block is either the plain block the site deploy script
# creates, or one this script wrote earlier; and unless there is no global
# block yet, or only one this script wrote. Run by deploy.sh on the VPS;
# tested locally by test-edit-caddyfile.sh.
set -euo pipefail

live="$1" candidate="$2" port="$3" server_root="$4"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
marker="# managed-by: spokenmargins-server"
site_open="spokenmargins.proximitytoprogress.com {"

refuse() { echo "edit-caddyfile: refusing: $*" >&2; exit 2; }

[[ "${port}" =~ ^[0-9]{2,5}$ ]] || refuse "port '${port}' is not a number"
[[ "${server_root}" =~ ^/[A-Za-z0-9/._-]+$ ]] || refuse "server root '${server_root}' is not a plain absolute path"

mapfile -t lines <"${live}"
n=${#lines[@]}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# 1. Global options block: the first significant line, if it is "{".
global_start=-1 global_end=-1
for ((i = 0; i < n; i++)); do
  t="$(trim "${lines[i]}")"
  [[ -z "${t}" || "${t}" == \#* ]] && continue
  if [[ "${t}" == "{" ]]; then
    global_start=$i
    for ((j = i + 1; j < n; j++)); do
      if [[ "${lines[j]}" == "}" ]]; then global_end=$j; break; fi
    done
    ((global_end >= 0)) || refuse "global options block has no closing brace at column 0"
    found=0
    for ((k = global_start; k <= global_end; k++)); do
      [[ "$(trim "${lines[k]}")" == "${marker}"* ]] && found=1
    done
    ((found)) || refuse "a global options block already exists and wasn't written by this script; merge caddy-global.caddy into it by hand"
  fi
  break
done

# 2. The site block: exactly one, closed by "}" at column 0.
site_start=-1 site_end=-1
for ((i = 0; i < n; i++)); do
  if [[ "$(trim "${lines[i]}")" == "${site_open}" ]]; then
    ((site_start < 0)) || refuse "more than one '${site_open}' block"
    [[ "${lines[i]}" == "${site_open}" ]] || refuse "site block is indented; expected it at column 0"
    site_start=$i
    for ((j = i + 1; j < n; j++)); do
      if [[ "${lines[j]}" == "}" ]]; then site_end=$j; break; fi
    done
    ((site_end >= 0)) || refuse "site block has no closing brace at column 0"
  fi
done
((site_start >= 0)) || refuse "no '${site_open}' block"

body=()
managed=0
for ((k = site_start + 1; k < site_end; k++)); do
  t="$(trim "${lines[k]}")"
  [[ -z "${t}" ]] && continue
  [[ "${t}" == "${marker}"* ]] && managed=1
  body+=("${t}")
done
if ((!managed)); then
  expected=("root * /srv/www/spokenmargins" "encode gzip" "file_server")
  [[ "${#body[@]}" -eq 3 && "${body[0]}" == "${expected[0]}" && "${body[1]}" == "${expected[1]}" && "${body[2]}" == "${expected[2]}" ]] ||
    refuse "the site block isn't the plain root/encode/file_server block this script expects; edit it by hand"
fi

render() { sed -e "s|@PORT@|${port}|g" -e "s|@SERVER_ROOT@|${server_root}|g" "$1"; }

{
  render "${here}/caddy-global.caddy"
  echo
  for ((i = 0; i < n; i++)); do
    if ((global_start >= 0 && i >= global_start && i <= global_end)); then
      # Drop the old managed global block and one blank line after it.
      if ((i == global_end)) && ((i + 1 < n)) && [[ -z "$(trim "${lines[i + 1]}")" ]]; then
        i=$((i + 1))
      fi
      continue
    fi
    if ((i == site_start)); then
      render "${here}/caddy-site.caddy"
      i=${site_end}
      continue
    fi
    printf '%s\n' "${lines[i]}"
  done
} >"${candidate}"
