#!/usr/bin/env bash
# Tests edit-caddyfile.sh against a stand-in for the VPS Caddyfile (made up
# here; the real one holds a basic-auth hash and never leaves the box).
#   CADDY=/path/to/caddy research/B4/deploy/test-edit-caddyfile.sh
# With CADDY set it also runs `caddy validate` on every candidate and serves
# the candidate locally in front of a real smserver to check the routes. With
# neither set those parts are skipped, and the last line says so. What stays
# checked without Caddy: the text of the privacy log filter in the candidate.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "${work}"' EXIT
pass=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
die() { echo "FAIL $*" >&2; exit 1; }

cat >"${work}/live" <<'CADDY'
# stand-in for /etc/caddy/Caddyfile
proximitytoprogress.com {
	route {
		handle /private/* {
			basic_auth {
				owner $2a$14$notARealHashJustAPlaceholderForTheTestXXXXXXXXXXXXXXXXXX
			}
			respond "private"
		}
		handle {
			respond "home"
		}
	}
}

spokenmargins.proximitytoprogress.com {
  root * /srv/www/spokenmargins
  encode gzip
  file_server
}

other.proximitytoprogress.com {
	reverse_proxy 127.0.0.1:8787
}
CADDY

edit() { "${here}/edit-caddyfile.sh" "$1" "$2" 8795 /srv/www/spokenmargins-server; }
validate() {
  [[ -n "${CADDY:-}" ]] || return 0 # reported as skipped at the end
  "${CADDY}" validate --adapter caddyfile --config "$1" >"${work}/validate.log" 2>&1 || { cat "${work}/validate.log"; die "caddy validate $1"; }
}

edit "${work}/live" "${work}/c1" || die "plain block refused"
grep -q '^{$' <(head -1 "${work}/c1") || die "global block not first"
# The privacy filter: without Caddy to run it, check that the candidate's
# global block (up to its closing brace) still names every field it must
# strip, so deleting one is noticed even where Caddy isn't installed.
global_block="$(sed -n '1,/^}$/p' "${work}/c1" | sed 's/^[[:space:]]*//')"
for filter_line in \
  'log default {' 'format filter {' 'wrap json' \
  'request>remote_ip delete' 'request>remote_port delete' 'request>client_ip delete' \
  'request>headers delete' 'request>tls delete' \
  'request>uri regexp (^/api/v1/maps/|^/l/|[?]).* $1*'; do
  grep -qxF -e "${filter_line}" <<<"${global_block}" || die "log filter line missing from the global block: ${filter_line}"
done
grep -q 'reverse_proxy 127.0.0.1:8795' "${work}/c1" || die "port not rendered"
grep -q 'root \* /srv/www/spokenmargins-server' "${work}/c1" || die "server root not rendered"
grep -q 'handle /l/\*' "${work}/c1" || die "share link routing missing"
grep -Fq 'request>uri regexp (^/api/v1/maps/|^/l/|[?]).* $1*' "${work}/c1" || die "share link, episode and query privacy filter missing"
# Everything outside the managed blocks is byte-for-byte unchanged.
diff <(sed -n '/^proximitytoprogress.com {/,/^}/p;/^other.proximitytoprogress.com {/,/^}/p' "${work}/live") \
  <(sed -n '/^proximitytoprogress.com {/,/^}/p;/^other.proximitytoprogress.com {/,/^}/p' "${work}/c1") >/dev/null ||
  die "other site blocks changed"
validate "${work}/c1"
ok "plain site block becomes the managed one; other sites untouched"

edit "${work}/c1" "${work}/c2" || die "rerun refused"
cmp -s "${work}/c1" "${work}/c2" || { diff -u "${work}/c1" "${work}/c2"; die "rerun is not idempotent"; }
ok "rerun on its own output changes nothing"

"${here}/edit-caddyfile.sh" "${work}/c1" "${work}/c3" 8796 /srv/www/spokenmargins-server
grep -q '127.0.0.1:8796' "${work}/c3" && ! grep -q '127.0.0.1:8795' "${work}/c3" || die "port change not applied"
ok "rerun with another port replaces the managed blocks"

# The managed site blocks (#3062): the product host, www, the web listener
# and the old web host are added at the end once, exactly as their templates
# have them; the old host's block is replaced in place.
block() { awk -v open="$1 {" '$0 == open { on = 1 } on { print } on && $0 == "}" { exit }' "$2"; }
render_old() { sed -e 's|@PORT@|8795|g' -e 's|@SERVER_ROOT@|/srv/www/spokenmargins-server|g' "$1"; }
for pair in "spokenmargins.com:caddy-site.caddy" "www.spokenmargins.com:caddy-www.caddy" \
  "app.spokenmargins.com:caddy-web.caddy" "app.spokenmargins.proximitytoprogress.com:caddy-legacy-web.caddy"; do
  name="${pair%%:*}" template="${pair#*:}"
  [[ "$(grep -cxF -e "${name} {" "${work}/c1")" == 1 ]] || die "${name} block not added exactly once"
  cmp -s <(block "${name}" "${work}/c1") <(render_old "${here}/${template}") || die "${name} block differs from ${template}"
done
cmp -s <(block spokenmargins.proximitytoprogress.com "${work}/c1") <(render_old "${here}/caddy-legacy-site.caddy") || die "old host block differs from caddy-legacy-site.caddy"
grep -q '^other.proximitytoprogress.com {$' "${work}/c1" || die "other site lost when the blocks were added"
! block app.spokenmargins.com "${work}/c1" | grep -qE '^[[:space:]]*log' || die "web app block must not write an access log"
# Old host: what a shipped build or Apple fetches is served, never redirected;
# only human pages redirect, to the new host with the path kept.
old_block="$(block spokenmargins.proximitytoprogress.com "${work}/c1")"
for served in 'handle /l/\*' 'handle /api/\*' 'handle @smpublic' 'handle @machine' '@aasa path /.well-known/apple-app-site-association'; do
  grep -q -e "${served}" <<<"${old_block}" || die "old host must still serve: ${served}"
done
grep -qF '@machine path /api/* /l/* /bridge/* /onboarding/* /voices/* /assets/* /.well-known/*' <<<"${old_block}" || die "old host machine paths changed"
grep -qF 'redir https://spokenmargins.com{uri} permanent' <<<"${old_block}" || die "old host must 301 other paths to spokenmargins.com with the path kept"
grep -qF 'redir https://spokenmargins.com{uri} permanent' <(block www.spokenmargins.com "${work}/c1") || die "www must 301 to spokenmargins.com"
grep -qF 'redir https://app.spokenmargins.com{uri} permanent' <(block app.spokenmargins.proximitytoprogress.com "${work}/c1") || die "old web host must 301 to app.spokenmargins.com"
# The product host serves the same machine routes and never redirects.
new_block="$(block spokenmargins.com "${work}/c1")"
for served in 'handle /l/\*' 'handle /api/\*' 'handle @smpublic'; do
  grep -q -e "${served}" <<<"${new_block}" || die "product host must serve: ${served}"
done
! grep -q 'redir' <<<"${new_block}" || die "product host must not redirect"
sed 's|max-age=31536000|max-age=1|' "${work}/c1" >"${work}/web-old"
edit "${work}/web-old" "${work}/web-new" || die "managed web block refused"
cmp -s "${work}/c1" "${work}/web-new" || { diff -u "${work}/c1" "${work}/web-new"; die "managed web block not replaced in place"; }
ok "managed blocks: new hosts added once, old hosts keep machine paths and redirect the rest, rerun replaces in place"

# A deployed pre-move Caddyfile (old site and old web blocks written by the
# previous script) migrates in place: the old blocks become the legacy ones.
cat >"${work}/premove" <<'OLD'
proximitytoprogress.com {
	respond "home"
}

spokenmargins.proximitytoprogress.com {
	# managed-by: spokenmargins-server (research/B4/deploy/deploy.sh)
	encode gzip
	file_server
}

app.spokenmargins.proximitytoprogress.com {
	# managed-by: spokenmargins-web (research/B4/deploy/deploy.sh)
	root * /srv/www/spokenmargins-web
	file_server
}
OLD
edit "${work}/premove" "${work}/postmove" || die "pre-move managed blocks refused"
[[ "$(grep -c '^app.spokenmargins.proximitytoprogress.com {$' "${work}/postmove")" == 1 ]] || die "old web block duplicated by the move"
grep -qF 'redir https://app.spokenmargins.com{uri} permanent' "${work}/postmove" || die "old web block not turned into a redirect"
grep -q '^spokenmargins.com {$' "${work}/postmove" && grep -q '^www.spokenmargins.com {$' "${work}/postmove" || die "new hosts not added"
ok "a deployed pre-move Caddyfile migrates in place"

# A refusal is exit status 2 with the "refusing:" message and no candidate
# file; a crash (any other status) or a half-written candidate is a failure.
expect_refusal() {
  local name="$1" file="$2" status=0
  rm -f "${work}/out"
  edit "${file}" "${work}/out" 2>"${work}/err" || status=$?
  [[ "${status}" -eq 2 ]] || die "${name}: exit status ${status}, want 2 (refused): $(cat "${work}/err")"
  grep -q '^edit-caddyfile: refusing: ' "${work}/err" || die "${name}: no refusal message: $(cat "${work}/err")"
  [[ ! -e "${work}/out" ]] || die "${name}: refused, but a candidate file was written"
  ok "refuses: ${name} ($(sed 's/^edit-caddyfile: refusing: //' "${work}/err"))"
}
sed 's|^  file_server$|  file_server\n  header X-Extra 1|' "${work}/live" >"${work}/extra"
expect_refusal "site block with an extra directive" "${work}/extra"
{ printf '{\n\temail owner@example.com\n}\n\n'; cat "${work}/live"; } >"${work}/global"
expect_refusal "an existing global block it didn't write" "${work}/global"
grep -v '^spokenmargins' "${work}/live" | sed '/^  root \* \/srv\/www\/spokenmargins$/,/^}$/d' >"${work}/nosite"
expect_refusal "no site block" "${work}/nosite"
{ cat "${work}/live"; printf '\nspokenmargins.proximitytoprogress.com {\n  file_server\n}\n'; } >"${work}/twice"
expect_refusal "two site blocks" "${work}/twice"
{ cat "${work}/live"; printf '\napp.spokenmargins.com {\n\trespond "someone else"\n}\n'; } >"${work}/webforeign"
expect_refusal "a web app block it didn't write" "${work}/webforeign"
{ cat "${work}/live"; printf '\nspokenmargins.com {\n\trespond "someone else"\n}\n'; } >"${work}/siteforeign"
expect_refusal "a product host block it didn't write" "${work}/siteforeign"
{ cat "${work}/c1"; printf '\n'; cat "${here}/caddy-web.caddy"; } >"${work}/webtwice"
expect_refusal "two web app blocks" "${work}/webtwice"
rm -f "${work}/out"
status=0
"${here}/edit-caddyfile.sh" "${work}/live" "${work}/out" '8795; rm -rf /' /srv/x 2>"${work}/err" || status=$?
[[ "${status}" -eq 2 ]] && grep -q '^edit-caddyfile: refusing: port' "${work}/err" && [[ ! -e "${work}/out" ]] || die "bad port: exit ${status}: $(cat "${work}/err")"
ok "refuses: a port that isn't a number"
status=0
"${here}/edit-caddyfile.sh" "${work}/live" "${work}/out" 8795 '/srv/x; rm -rf /' 2>"${work}/err" || status=$?
[[ "${status}" -eq 2 ]] && grep -q '^edit-caddyfile: refusing: server root' "${work}/err" && [[ ! -e "${work}/out" ]] || die "bad server root: exit ${status}: $(cat "${work}/err")"
ok "refuses: a server root that isn't a plain absolute path"

if [[ -n "${CADDY:-}" && -n "${SMSERVER:-}" ]]; then
  # Serve the candidate on loopback: same blocks, site address swapped.
  root="${work}/server-root" site="${work}/site" web="${work}/web"
  mkdir -p "${site}" "${web}/assets"
  echo "site index" >"${site}/index.html"
  echo "web index" >"${web}/index.html"
  echo "self.x=1" >"${web}/sw.js"
  echo "a=1" >"${web}/assets/index-abc123.js"
  "${SMSERVER}" switch -public "${root}" attest on >/dev/null
  sed -e 's|^spokenmargins.com {|http://127.0.0.1:18443 {|' \
    -e "s|/srv/www/spokenmargins-server|${root}|" -e "s|root \* /srv/www/spokenmargins\$|root * ${site}|" \
    -e 's|^proximitytoprogress.com {|http://127.0.0.1:18444 {|' -e 's|^other.proximitytoprogress.com {|http://127.0.0.1:18445 {|' \
    -e 's|^app.spokenmargins.com {|http://127.0.0.1:18446 {|' -e 's|^spokenmargins.proximitytoprogress.com {|http://127.0.0.1:18447 {|' \
    -e 's|^www.spokenmargins.com {|http://127.0.0.1:18448 {|' -e 's|^app.spokenmargins.proximitytoprogress.com {|http://127.0.0.1:18449 {|' -e "s|/srv/www/spokenmargins-web\$|${web}|" \
    -e 's|^{$|{\n\tadmin off|' "${work}/c1" >"${work}/local"
  "${CADDY}" run --adapter caddyfile --config "${work}/local" >"${work}/caddy.log" 2>&1 &
  sleep 1.5
  code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
  [[ "$(code http://127.0.0.1:18443/api/v1/config.json)" == 200 ]] || die "config.json not served while smserver is down"
  [[ "$(code http://127.0.0.1:18443/)" == 200 ]] || die "site root not served"
  # The old hosts: machine paths served, pages and the old web host redirected with the path kept.
  [[ "$(code http://127.0.0.1:18447/api/v1/config.json)" == 200 ]] || die "old host must still serve config.json"
  [[ "$(code http://127.0.0.1:18447/privacy/)" == 301 ]] || die "old host must 301 a page"
  curl -sI http://127.0.0.1:18447/privacy/ | grep -qi '^location: https://spokenmargins.com/privacy/' || die "old host redirect lost the path"
  [[ "$(code http://127.0.0.1:18447/l/8badf00d8badf00d8badf00d8badf00d)" == 502 ]] || die "old host must proxy /l/, not redirect it"
  curl -sI http://127.0.0.1:18448/privacy/ | grep -qi '^location: https://spokenmargins.com/privacy/' || die "www must 301 with the path kept"
  curl -sI http://127.0.0.1:18449/x?y=1 | grep -qi '^location: https://app.spokenmargins.com/x?y=1' || die "old web host must 301 with path and query"
  [[ "$(curl -s http://127.0.0.1:18446/)" == "web index" ]] || die "web app not served"
  curl -sI http://127.0.0.1:18446/sw.js | grep -qi '^cache-control: no-cache' || die "sw.js must be no-cache"
  curl -sI http://127.0.0.1:18446/assets/index-abc123.js | grep -qi '^cache-control: public, max-age=31536000, immutable' || die "hashed assets must be immutable"
  ! curl -sI http://127.0.0.1:18446/ | grep -qi '^server:' || die "web app sends a Server header"
  curl -s -X POST -H 'X-SM-Key-Id: SECRETKEYID' http://127.0.0.1:18443/api/v1/ping >/dev/null
  linkid=8badf00d8badf00d8badf00d8badf00d
  [[ "$(code http://127.0.0.1:18443/l/${linkid})" == 502 ]] || die "link should 502 with smserver down"
  mapkey=5ec2e7a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  [[ "$(code http://127.0.0.1:18443/api/v1/maps/${mapkey})" == 502 ]] || die "map fetch should 502 with smserver down"
  [[ "$(code http://127.0.0.1:18443/api/v1/health)" == 502 ]] || die "api should 502 with smserver down"
  relayurl='https%3A%2F%2Ffeeds.example%2Fprivate%3Ftoken%3DRELAYSECRET'
  [[ "$(code "http://127.0.0.1:18443/api/v1/relay?url=${relayurl}")" == 502 ]] || die "relay should 502 with smserver down"
  "${SMSERVER}" serve -listen 127.0.0.1:8795 -state "${work}/state" -public "${root}" >/dev/null 2>&1 &
  sleep 0.5
  [[ "$(curl -s http://127.0.0.1:18443/api/v1/health)" == *'"status":"ok"'* ]] || die "health not proxied to smserver"
  sleep 0.5
  grep -q 'http.log.error' "${work}/caddy.log" || die "expected a 502 error line to inspect"
  ! grep -qE 'SECRETKEYID|remote_ip|client_ip|"headers"' "${work}/caddy.log" || die "Caddy error log leaked IP or headers"
  ! grep -q "${linkid}" "${work}/caddy.log" || die "Caddy error log leaked a share link id"
  grep -q '"uri":"/l/\*"' "${work}/caddy.log" || die "share link not logged as /l/*"
  ! grep -q "${mapkey}" "${work}/caddy.log" || die "Caddy error log leaked an episode key"
  grep -q '"uri":"/api/v1/maps/\*"' "${work}/caddy.log" || die "map fetch not logged as /api/v1/maps/*"
  ! grep -qE 'RELAYSECRET|url=' "${work}/caddy.log" || die "Caddy error log leaked a relay URL"
  grep -q '"uri":"/api/v1/relay?\*"' "${work}/caddy.log" || die "relay not logged as /api/v1/relay?*"
  grep 'http.log.error' "${work}/caddy.log" | head -1 | grep -q '^{' || die "error log is not JSON"
  ok "served locally: config.json with smserver down, site, /api proxied, error log JSON without IP, headers, episode keys or relay URLs"
fi
if [[ -z "${CADDY:-}" ]]; then
  echo "SKIPPED caddy validate of every candidate (set CADDY)"
fi
if [[ -z "${CADDY:-}" || -z "${SMSERVER:-}" ]]; then
  echo "SKIPPED serving the candidate locally: routes, and the error log's lack of IPs, headers and episode keys (set CADDY and SMSERVER)"
  echo "${pass} checks passed, but not the Caddy ones above"
else
  echo "${pass} checks passed"
fi
