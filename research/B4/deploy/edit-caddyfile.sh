#!/usr/bin/env bash
# edit-caddyfile.sh LIVE CANDIDATE PORT SERVER_ROOT
#
# Writes CANDIDATE: LIVE with (1) the spokenmargins-server global options
# block at the top and (2) five site blocks replaced in place, or added at
# the end when missing (#3062): the product host spokenmargins.com, www
# (redirects to it), the web listener app.spokenmargins.com, and the two old
# proximitytoprogress.com hosts, which keep serving what shipped builds fetch
# and redirect the rest. Every other line is copied unchanged. It refuses
# (exit 2) unless the old site block is either the plain block the site
# deploy script creates, or one this script wrote earlier; unless there is
# no global block yet, or only one this script wrote; and unless each of the
# other four is missing or one this script wrote. Run by deploy.sh on the
# VPS; tested locally by test-edit-caddyfile.sh.
set -euo pipefail

live="$1" candidate="$2" port="$3" server_root="$4"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
marker="# managed-by: spokenmargins-server"
web_marker="# managed-by: spokenmargins-web"

refuse() { echo "edit-caddyfile: refusing: $*" >&2; exit 2; }

[[ "${port}" =~ ^[0-9]{2,5}$ ]] || refuse "port '${port}' is not a number"
[[ "${server_root}" =~ ^/[A-Za-z0-9/._-]+$ ]] || refuse "server root '${server_root}' is not a plain absolute path"

# Keep the local deployment check usable with macOS's Bash 3.2 too.
lines=()
while IFS= read -r line || [[ -n "${line}" ]]; do
  lines+=("${line}")
done <"${live}"
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

# 2. The site blocks. Five are ours (#3062), each exactly one, closed by "}"
# at column 0, and each either absent or written by this script. The
# exception is the old host's block, which must exist and may also be the
# plain block the site deploy script creates.
#   0 old host        spokenmargins.proximitytoprogress.com      caddy-legacy-site.caddy
#   1 product host    spokenmargins.com                          caddy-site.caddy
#   2 www             www.spokenmargins.com                      caddy-www.caddy
#   3 web listener    app.spokenmargins.com                      caddy-web.caddy
#   4 old web host    app.spokenmargins.proximitytoprogress.com  caddy-legacy-web.caddy
opens=("spokenmargins.proximitytoprogress.com {" "spokenmargins.com {" "www.spokenmargins.com {" "app.spokenmargins.com {" "app.spokenmargins.proximitytoprogress.com {")
files=("caddy-legacy-site.caddy" "caddy-site.caddy" "caddy-www.caddy" "caddy-web.caddy" "caddy-legacy-web.caddy")
markers=("${marker}" "${marker}" "${marker}" "${web_marker}" "${web_marker}")
starts=() ends=()
for ((b = 0; b < ${#opens[@]}; b++)); do
  open="${opens[b]}" bs=-1 be=-1
  for ((i = 0; i < n; i++)); do
    if [[ "$(trim "${lines[i]}")" == "${open}" ]]; then
      ((bs < 0)) || refuse "more than one '${open}' block"
      [[ "${lines[i]}" == "${open}" ]] || refuse "'${open}' block is indented; expected it at column 0"
      bs=$i
      for ((j = i + 1; j < n; j++)); do
        if [[ "${lines[j]}" == "}" ]]; then be=$j; break; fi
      done
      ((be >= 0)) || refuse "'${open}' block has no closing brace at column 0"
    fi
  done
  starts+=("${bs}") ends+=("${be}")
  if ((bs >= 0)); then
    body=() managed=0
    for ((k = bs + 1; k < be; k++)); do
      t="$(trim "${lines[k]}")"
      [[ -z "${t}" ]] && continue
      [[ "${t}" == "${markers[b]}"* ]] && managed=1
      body+=("${t}")
    done
    if ((!managed)); then
      if ((b == 0)); then
        expected=("root * /srv/www/spokenmargins" "encode gzip" "file_server")
        [[ "${#body[@]}" -eq 3 && "${body[0]}" == "${expected[0]}" && "${body[1]}" == "${expected[1]}" && "${body[2]}" == "${expected[2]}" ]] ||
          refuse "the site block isn't the plain root/encode/file_server block this script expects; edit it by hand"
      else
        refuse "a '${open}' block exists that this script didn't write; edit it by hand"
      fi
    fi
  elif ((b == 0)); then
    refuse "no '${open}' block"
  fi
done

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
    replaced=0
    for ((b = 0; b < ${#opens[@]}; b++)); do
      if ((i == starts[b])); then
        render "${here}/${files[b]}"
        i=${ends[b]}
        replaced=1
        break
      fi
    done
    ((replaced)) && continue
    printf '%s\n' "${lines[i]}"
  done
  # Blocks not in the file yet go at the end, in table order.
  for ((b = 1; b < ${#opens[@]}; b++)); do
    if ((starts[b] < 0)); then
      echo
      render "${here}/${files[b]}"
    fi
  done
} >"${candidate}"
