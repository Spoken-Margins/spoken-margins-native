#!/usr/bin/env bash
# Tests for the Dial gate and bandwidth check deploys (#4848, part of #2478): every root step goes through sudo with a
# terminal, files are copied only to a scratch folder, and a failed scratch folder stops the deploy. A stand-in `ssh`
# and `scp` log what they are asked; nothing here reaches a server.
#   ops/test-remote-root-deploys.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
pass=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
fail() { echo "FAIL $*" >&2; exit 1; }

for script in dial/deploy.sh bandwidth/deploy.sh; do
  sh -n "${here}/${script}" || fail "${script} does not parse"
done
ok "both deploy scripts parse"

mkdir -p "${work}/shims"
cat >"${work}/shims/ssh" <<'SH'
#!/usr/bin/env bash
# Logs "flags=<leading -options> cmd=<command>"; answers mktemp, and "is there a file there" (no).
flags=""
while [[ "${1:-}" == -* ]]; do flags+="$1 "; shift; done
host="$1"; shift
cmd="$*"
echo "flags=${flags% } cmd=${cmd}" >>"${SM_TEST_LOG}"
case "${cmd}" in
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

run_deploy() { # script args... -> sets SM_TEST_LOG / SM_TEST_SCP, returns the script's exit code
  local script="$1"; shift
  export SM_TEST_LOG="${work}/log" SM_TEST_SCP="${work}/scp"
  : >"${SM_TEST_LOG}"; : >"${SM_TEST_SCP}"
  PATH="${work}/shims:${PATH}" bash "${here}/${script}" test-host "$@" >"${work}/out" 2>&1
}

check_root_steps() { # script mode: every root step goes through sudo with a terminal, and nothing else does
  local script="$1" mode="$2" line
  while IFS= read -r line; do
    local flags="${line#flags=}"; flags="${flags%% cmd=*}"
    local cmd="${line#*cmd=}"
    if [[ "${cmd}" =~ ${needs_root} ]]; then
      [[ "${flags}" == "-t" ]] || fail "${script} ${mode}: a root step went without a terminal: ${cmd}"
      [[ "${cmd}" == "sudo -p "* ]] || fail "${script} ${mode}: a root step did not go through sudo: ${cmd}"
    else
      [[ -z "${flags}" ]] || fail "${script} ${mode}: a step that needs no root asked for a terminal: ${line}"
      [[ "${cmd}" != *sudo* ]] || fail "${script} ${mode}: a step that needs no root used sudo: ${cmd}"
    fi
  done <"${SM_TEST_LOG}"
}

for script in dial/deploy.sh bandwidth/deploy.sh; do
  name="${script%%/*}"

  # A dry run changes nothing and copies nothing; its secret check is the only root step.
  run_deploy "${script}" --dry-run || fail "${script} --dry-run failed: $(cat "${work}/out")"
  [[ ! -s "${SM_TEST_SCP}" ]] || fail "${script} --dry-run copied files"
  ! grep -qE 'install -|daemon-reload|enable --now' "${SM_TEST_LOG}" || fail "${script} --dry-run ran an install step"
  check_root_steps "${script}" --dry-run
  grep -qE "cmd=sudo -p .*/etc/sm-${name}/" "${SM_TEST_LOG}" || fail "${script} --dry-run: the root-only secret was read without sudo"

  # An enable run installs through root, from a scratch folder the login owns, and never copies into /opt or /etc.
  run_deploy "${script}" --enable || fail "${script} --enable failed: $(cat "${work}/out")"
  check_root_steps "${script}" --enable
  grep -q 'daemon-reload' "${SM_TEST_LOG}" || fail "${script} --enable: nothing reloaded systemd"
  grep -q 'enable --now' "${SM_TEST_LOG}" || fail "${script} --enable: nothing enabled the timer"
  [[ -s "${SM_TEST_SCP}" ]] || fail "${script} --enable: nothing was copied"
  ! grep -qE ':/(opt|etc)/' "${SM_TEST_SCP}" || fail "${script} --enable: scp wrote straight into /opt or /etc: $(cat "${SM_TEST_SCP}")"
  grep -q 'test-host:/tmp/sm-stage.TEST/' "${SM_TEST_SCP}" || fail "${script} --enable: files did not go to the scratch folder"
  grep -q 'rm -rf /tmp/sm-stage.TEST' "${SM_TEST_LOG}" || fail "${script} --enable: the scratch folder was not removed"
  ok "${name}: every root step goes through sudo with a terminal, files go only to a scratch folder that is removed, and a dry run changes nothing"

  # A failed mktemp must stop the deploy before anything is copied (an empty folder name would send files to /).
  if SM_TEST_NO_MKTEMP=1 run_deploy "${script}" --enable; then fail "${script} went on after mktemp failed"; fi
  [[ ! -s "${SM_TEST_SCP}" ]] || fail "${script} copied files after mktemp failed"
  ok "${name}: a failed scratch folder stops the deploy before any copy"

  # A failed install still removes the scratch folder (the EXIT trap).
  cp "${work}/shims/ssh" "${work}/ssh.orig"
  sed -i "s|^esac|  'sudo '*install*) exit 1 ;;\nesac|" "${work}/shims/ssh"
  if run_deploy "${script}" --enable; then fail "${script} went on after the install failed"; fi
  grep -q 'rm -rf /tmp/sm-stage.TEST' "${SM_TEST_LOG}" || fail "${script}: a failed install left the scratch folder behind"
  cp "${work}/ssh.orig" "${work}/shims/ssh"
  ok "${name}: a failed install still removes the scratch folder"
done

echo "${pass} passed"
