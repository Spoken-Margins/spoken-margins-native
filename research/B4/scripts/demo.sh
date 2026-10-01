#!/usr/bin/env bash
# Runs the B4 M1 skeleton locally and walks the path the brief asks for:
# health check, one attested request from a test client, blocking that one
# install, and the kill switch. Nothing leaves this machine.
#
#   research/B4/scripts/demo.sh            # uses a temporary directory
#   research/B4/scripts/demo.sh WORKDIR    # keeps state and logs in WORKDIR
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
port="${B4_DEMO_PORT:-18787}"
base="http://127.0.0.1:${port}"
mkdir -p "${work}/bin" "${work}/public/bridge/v1"

echo "== build (Go standard library only)"
(cd "${here}/server" && go build -o "${work}/bin/" ./cmd/...)
smserver="${work}/bin/smserver"
smclient="${work}/bin/smclient"

echo "== fake Apple CA, manifest fixture"
"${smserver}" make-test-ca "${work}/ca"
"${smserver}" publish-manifest -public "${work}/public" "${here}/contracts/fixtures/bridge-manifest.example.json"

echo "== start server"
"${smserver}" serve -listen "127.0.0.1:${port}" -state "${work}/state" -public "${work}/public" \
  -attest-root "${work}/ca/test-root.pem" >"${work}/request.log" 2>"${work}/server.err" &
server_pid=$!
trap 'kill ${server_pid} 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  curl -fsS "${base}/api/v1/health" >/dev/null 2>&1 && break
  sleep 0.1
done

echo "== 1. first run: health, config, attest, one attested request"
"${smclient}" -base "${base}" -ca "${work}/ca" -device "${work}/device-a.json" | tee "${work}/run1.txt"
tag="$(sed -n 's/^install tag: //p' "${work}/run1.txt")"

echo "== 2. a second install"
"${smclient}" -base "${base}" -ca "${work}/ca" -device "${work}/device-b.json"

echo "== 3. owner blocks install ${tag}"
"${smserver}" block -state "${work}/state" "${tag}"
echo "-- install A again (expect 403 refused)"
"${smclient}" -base "${base}" -ca "${work}/ca" -device "${work}/device-a.json"
echo "-- install B again (expect 200)"
"${smclient}" -base "${base}" -ca "${work}/ca" -device "${work}/device-b.json"

echo "== 4. kill switch: attest off"
"${smserver}" switch -public "${work}/public" attest off
echo "-- install B (expect 503 disabled; health and config still answer)"
"${smclient}" -base "${base}" -ca "${work}/ca" -device "${work}/device-b.json"
"${smserver}" switch -public "${work}/public" attest on
echo "-- install B after switching back on (expect 200)"
"${smclient}" -base "${base}" -ca "${work}/ca" -device "${work}/device-b.json"

echo "== stop the server (it writes its hourly summary and install records on shutdown)"
kill -TERM "${server_pid}"
wait "${server_pid}" || true

echo "== what the server kept"
echo "-- request log (every line; one per route/status per hour, with a count):"
cat "${work}/request.log"
echo "-- install records:"
for f in "${work}"/state/installs/*.json; do echo "$(basename "$f"): $(cat "$f")"; done
echo "-- block list: $(ls "${work}/state/blocked")"
echo "-- abuse log lines: $(cat "${work}/state/abuse.log" 2>/dev/null | wc -l)"
echo "-- server stderr:"
cat "${work}/server.err"
echo "work directory: ${work}"
