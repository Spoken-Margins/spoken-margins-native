#!/usr/bin/env bash
# Tests that remote-install.sh keeps the previous smserver binary and unit
# and puts them back when a deploy rolls back (#486). systemctl and curl are
# stand-ins that record calls; the binary, unit and Caddyfile are real files.
#   research/B4/deploy/test-server-rollback.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
pass=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
fail() { echo "FAIL $*" >&2; exit 1; }

# Stand-ins on PATH: systemctl logs its arguments; curl answers health ok
# unless SM_TEST_UNHEALTHY is set; sleep returns at once.
mkdir -p "${work}/shims"
cat >"${work}/shims/systemctl" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${SM_TEST_LOG}"
SH
cat >"${work}/shims/curl" <<'SH'
#!/usr/bin/env bash
if [[ -n "${SM_TEST_UNHEALTHY:-}" ]]; then exit 7; fi
echo '{"status":"ok"}'
SH
printf '#!/usr/bin/env bash\n' >"${work}/shims/sleep"
chmod +x "${work}/shims/"*

fresh() { # fresh NAME: a box with an old binary, unit and Caddyfile
  box="${work}/$1"
  mkdir -p "${box}"
  echo old-binary >"${box}/smserver"
  echo old-unit >"${box}/smserver.service"
  echo old-caddy >"${box}/Caddyfile"
  : >"${box}/systemctl.log"
}

run_lib() { # run_lib SNIPPET: source the script's functions against ${box}
  SM_BIN="${box}/smserver" SM_UNIT="${box}/smserver.service" SM_CADDYFILE="${box}/Caddyfile" \
    SM_TEST_LOG="${box}/systemctl.log" PATH="${work}/shims:${PATH}" \
    bash -c "source '${here}/remote-install.sh' __lib; $1"
}

# backup_server copies both files aside and names them.
fresh backup
out="$(run_lib 'backup_server STAMP')"
[[ "$(cat "${box}/smserver.before-smserver.STAMP")" == old-binary ]] || fail "binary not backed up"
[[ "$(cat "${box}/smserver.service.before-smserver.STAMP")" == old-unit ]] || fail "unit not backed up"
grep -qx "BIN_BACKUP=${box}/smserver.before-smserver.STAMP" <<<"${out}" || fail "BIN_BACKUP line missing: ${out}"
grep -qx "UNIT_BACKUP=${box}/smserver.service.before-smserver.STAMP" <<<"${out}" || fail "UNIT_BACKUP line missing: ${out}"
ok "backup_server copies the binary and unit and prints both paths"

# A first install has nothing to back up and says so.
fresh first
rm "${box}/smserver" "${box}/smserver.service"
out="$(run_lib 'backup_server STAMP')"
grep -qx "BIN_BACKUP=" <<<"${out}" && grep -qx "UNIT_BACKUP=" <<<"${out}" || fail "first install printed ${out}"
ok "backup_server on a first install prints empty paths"

# restore_server puts both back, reloads systemd and restarts the service.
fresh restore
run_lib 'backup_server S >/dev/null; echo new-binary >"$SM_BIN"; echo new-unit >"$SM_UNIT"; restore_server 8795 "$bin_backup" "$unit_backup"' 2>"${box}/err"
[[ "$(cat "${box}/smserver")" == old-binary ]] || fail "binary not restored"
[[ "$(cat "${box}/smserver.service")" == old-unit ]] || fail "unit not restored (the old binary can't read the new unit's flags)"
grep -qx "daemon-reload" "${box}/systemctl.log" && grep -qx "restart smserver" "${box}/systemctl.log" || fail "systemctl calls: $(cat "${box}/systemctl.log")"
grep -q "healthy on 127.0.0.1:8795" "${box}/err" || fail "no health confirmation: $(cat "${box}/err")"
ok "restore_server restores the binary and unit, reloads and restarts, and confirms health"

# An unhealthy restore warns and doesn't abort the caller's own rollback.
fresh unhealthy
SM_TEST_UNHEALTHY=1 run_lib 'backup_server S >/dev/null; echo new-binary >"$SM_BIN"; restore_server 8795 "$bin_backup" "$unit_backup"; echo after' >"${box}/out" 2>"${box}/err"
grep -q "WARNING: restored the previous smserver" "${box}/err" || fail "no warning: $(cat "${box}/err")"
grep -qx after "${box}/out" || fail "restore_server exited the caller"
ok "restore_server warns when the restored server isn't healthy, and returns"

# With no previous binary, a failed deploy stops the new one.
fresh nobackup
run_lib 'restore_server 8795 "" ""' 2>"${box}/err"
grep -qx "stop smserver" "${box}/systemctl.log" || fail "new server not stopped: $(cat "${box}/systemctl.log")"
ok "restore_server with no previous binary stops the new one"

# deploy.sh's outside-check rollback: the rollback mode restores the
# Caddyfile and, given the server backups, the binary and unit too.
fresh rollback
cp "${box}/Caddyfile" "${box}/Caddyfile.bak"
cp "${box}/smserver" "${box}/smserver.bak"
cp "${box}/smserver.service" "${box}/smserver.service.bak"
echo new-caddy >"${box}/Caddyfile"; echo new-binary >"${box}/smserver"; echo new-unit >"${box}/smserver.service"
SM_BIN="${box}/smserver" SM_UNIT="${box}/smserver.service" SM_CADDYFILE="${box}/Caddyfile" \
  SM_TEST_LOG="${box}/systemctl.log" PATH="${work}/shims:${PATH}" \
  bash "${here}/remote-install.sh" rollback "${box}/Caddyfile.bak" "${box}/smserver.bak" "${box}/smserver.service.bak" >/dev/null 2>&1
[[ "$(cat "${box}/Caddyfile")" == old-caddy ]] || fail "rollback mode didn't restore the Caddyfile"
[[ "$(cat "${box}/smserver")" == old-binary ]] || fail "rollback mode didn't restore the binary"
[[ "$(cat "${box}/smserver.service")" == old-unit ]] || fail "rollback mode didn't restore the unit"
grep -qx "reload caddy" "${box}/systemctl.log" && grep -qx "restart smserver" "${box}/systemctl.log" || fail "systemctl calls: $(cat "${box}/systemctl.log")"
ok "rollback mode restores the Caddyfile, binary and unit"

# The older two-argument rollback still touches only the Caddyfile.
fresh caddyonly
cp "${box}/Caddyfile" "${box}/Caddyfile.bak"; echo new-caddy >"${box}/Caddyfile"; echo new-binary >"${box}/smserver"
SM_BIN="${box}/smserver" SM_UNIT="${box}/smserver.service" SM_CADDYFILE="${box}/Caddyfile" \
  SM_TEST_LOG="${box}/systemctl.log" PATH="${work}/shims:${PATH}" \
  bash "${here}/remote-install.sh" rollback "${box}/Caddyfile.bak" >/dev/null 2>&1
[[ "$(cat "${box}/Caddyfile")" == old-caddy && "$(cat "${box}/smserver")" == new-binary ]] || fail "Caddyfile-only rollback changed the binary"
ok "rollback with only a Caddyfile backup leaves smserver alone"

echo "${pass} passed"
