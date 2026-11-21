#!/usr/bin/env bash
# Tests for the Dial gate and bandwidth check deploys under a non-root login (#4848, part of #2478). A stand-in `ssh`
# and `scp` log what they are asked and answer the few reads the scripts make; nothing here reaches a server.
#   ops/test-remote-root-deploys.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
pass=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
fail() { echo "FAIL $*" >&2; exit 1; }

for script in dial/deploy.sh bandwidth/deploy.sh; do
  bash -n "${here}/${script}" || fail "${script} does not parse"
done
ok "both deploy scripts parse"

mkdir -p "${work}/shims"
cat >"${work}/shims/ssh" <<'SH'
#!/usr/bin/env bash
# Logs "flags=<leading -options> cmd=<command>"; answers id -u, mktemp, and "is there a file there" (no).
flags=""
while [[ "${1:-}" == -* ]]; do flags+="$1 "; shift; done
host="$1"; shift
cmd="$*"
echo "flags=${flags% } cmd=${cmd}" >>"${SM_TEST_LOG}"
case "${cmd}" in
  'id -u') echo "${SM_TEST_UID}" ;;
  'mktemp -d '*) [[ -n "${SM_TEST_NO_MKTEMP:-}" ]] && exit 1; echo "/tmp/sm-stage.TEST" ;;
  'test -f '*) exit 1 ;;
esac
exit 0
SH
cat >"${work}/shims/scp" <<'SH'
#!/usr/bin/env bash
echo "scp $*" >>"${SM_TEST_SCP}"
SH
chmod +x "${work}/shims/"*

# Anything that installs, reloads or starts a unit, or reads the root-only secrets folders, needs root.
needs_root='install |daemon-reload|enable --now|systemctl start|journalctl|/etc/sm-(dial|bandwidth)/'

run_deploy() { # script uid args... -> sets SM_TEST_LOG / SM_TEST_SCP, returns the script's exit code
  local script="$1" uid="$2"; shift 2
  export SM_TEST_UID="${uid}" SM_TEST_LOG="${work}/log" SM_TEST_SCP="${work}/scp"
  : >"${SM_TEST_LOG}"; : >"${SM_TEST_SCP}"
  PATH="${work}/shims:${PATH}" bash "${here}/${script}" test-host "$@" >"${work}/out" 2>&1
}

check_root_steps() { # script uid mode: every root step goes through sudo with a terminal, and nothing else does
  local script="$1" uid="$2" mode="$3" line
  while IFS= read -r line; do
    local flags="${line#flags=}"; flags="${flags%% cmd=*}"
    local cmd="${line#*cmd=}"
    if [[ "${uid}" != 0 && "${cmd}" =~ ${needs_root} ]]; then
      [[ "${flags}" == "-t" ]] || fail "${script} ${mode} uid ${uid}: a root step went without a terminal: ${cmd}"
      [[ "${cmd}" == "sudo -p "* ]] || fail "${script} ${mode} uid ${uid}: a root step did not go through sudo: ${cmd}"
    else
      [[ -z "${flags}" ]] || fail "${script} ${mode} uid ${uid}: a step that needs no root asked for a terminal: ${line}"
      [[ "${cmd}" != *sudo* ]] || fail "${script} ${mode} uid ${uid}: a step that needs no root used sudo: ${cmd}"
    fi
  done <"${SM_TEST_LOG}"
}

for script in dial/deploy.sh bandwidth/deploy.sh; do
  name="${script%%/*}"
  enable=--enable

  for uid in 0 1001; do
    # A dry run changes nothing and copies nothing; its secret check is the only root step.
    run_deploy "${script}" "${uid}" --dry-run || fail "${script} --dry-run uid ${uid} failed: $(cat "${work}/out")"
    [[ ! -s "${SM_TEST_SCP}" ]] || fail "${script} --dry-run uid ${uid} copied files"
    ! grep -qE 'install -|daemon-reload|enable --now' "${SM_TEST_LOG}" || fail "${script} --dry-run uid ${uid} ran an install step"
    check_root_steps "${script}" "${uid}" --dry-run
    if [[ "${uid}" != 0 ]]; then
      grep -qE "cmd=sudo -p .*/etc/sm-${name}/" "${SM_TEST_LOG}" || fail "${script} --dry-run uid ${uid}: the root-only secret was read without sudo"
    fi

    # An enable run installs through root, from a scratch folder the login owns, and never copies into /opt or /etc.
    run_deploy "${script}" "${uid}" "${enable}" || fail "${script} ${enable} uid ${uid} failed: $(cat "${work}/out")"
    check_root_steps "${script}" "${uid}" "${enable}"
    grep -q 'daemon-reload' "${SM_TEST_LOG}" || fail "${script} ${enable} uid ${uid}: nothing reloaded systemd"
    grep -q 'enable --now' "${SM_TEST_LOG}" || fail "${script} ${enable} uid ${uid}: nothing enabled the timer"
    [[ -s "${SM_TEST_SCP}" ]] || fail "${script} ${enable} uid ${uid}: nothing was copied"
    ! grep -qE ':/(opt|etc)/' "${SM_TEST_SCP}" || fail "${script} ${enable} uid ${uid}: scp wrote straight into /opt or /etc: $(cat "${SM_TEST_SCP}")"
    grep -q 'test-host:/tmp/sm-stage.TEST/' "${SM_TEST_SCP}" || fail "${script} ${enable} uid ${uid}: files did not go to the scratch folder"
    grep -q 'rm -rf /tmp/sm-stage.TEST' "${SM_TEST_LOG}" || fail "${script} ${enable} uid ${uid}: the scratch folder was not removed"
    if [[ "${uid}" != 0 ]]; then
      grep -q 'chown -R .*SUDO_USER.*sm-stage.TEST' "${SM_TEST_LOG}" || fail "${script} ${enable} uid ${uid}: the scratch folder was not handed back to the login"
    else
      ! grep -q sudo "${SM_TEST_LOG}" || fail "${script} ${enable} uid ${uid}: a root login used sudo"
    fi
  done
  ok "${name}: root login runs unchanged; a normal login sends every root step through sudo with a terminal, copies only to a scratch folder, and a dry run changes nothing"

  if run_deploy "${script}" "oops" --dry-run; then fail "${script} went on with an unreadable user id"; fi
  [[ "$(wc -l <"${SM_TEST_LOG}")" == 1 ]] || fail "${script} ran steps after an unreadable user id"
  ok "${name}: an unreadable user id stops the deploy before any step"

  # A failed mktemp must stop the deploy before anything is copied (an empty folder name would send files to /).
  if SM_TEST_NO_MKTEMP=1 run_deploy "${script}" 0 --enable; then fail "${script} went on after mktemp failed"; fi
  [[ ! -s "${SM_TEST_SCP}" ]] || fail "${script} copied files after mktemp failed"
  ok "${name}: a failed scratch folder stops the deploy before any copy"
done

# The two scripts' only other ssh calls are reads (cat, test -f, is-active) or the scratch folder; every root step in the source goes through root_ssh.
for script in dial/deploy.sh bandwidth/deploy.sh; do
  bad="$(grep -nE '^[^#]*\bssh +"?\$host"? +.*(install|systemctl enable|daemon-reload|journalctl|/etc/sm-)' "${here}/${script}" | grep -v 'cat \$dest' || true)"
  [[ -z "${bad}" ]] || fail "${script} has a root step that bypasses root_ssh: ${bad}"
done
ok "no root step bypasses root_ssh in the source"

echo "${pass} passed"
