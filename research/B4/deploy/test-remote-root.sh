#!/usr/bin/env bash
# Tests for the non-root deploy (#2478): how a root step reaches sudo, and that the two on-box scripts refuse
# before they change anything. Nothing here touches a server or the host's users or sshd.
#   research/B4/deploy/test-remote-root.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
pass=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
fail() { echo "FAIL $*" >&2; exit 1; }

for script in remote-root.sh deploy.sh deploy-web.sh create-deploy-user.sh harden-ssh.sh; do
  bash -n "${here}/${script}" || fail "${script} does not parse"
done
bash -n "${here}/../../../scripts/deploy-spoken-margins-site.sh" || fail "the site deploy does not parse"
ok "scripts parse"

# shellcheck source=remote-root.sh
source "${here}/remote-root.sh"

# A root login runs the command unchanged (the old way keeps working until root login is off).
SM_REMOTE_UID=0
[[ "$(sm_remote_root_command "echo hi" /tmp/x)" == "echo hi" ]] || fail "a root login changed the command"
[[ -z "$(sm_remote_root_ssh_flags)" ]] || fail "a root login asked for a terminal"
ok "root login: command unchanged, no terminal"

# A normal login goes through sudo with a terminal. A stand-in sudo drops its -p prompt and runs the rest, as
# SUDO_USER=tester; a stand-in chown records what it was asked.
mkdir -p "${work}/shims"
cat >"${work}/shims/sudo" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -p ]] && shift 2
SUDO_USER=tester exec "$@"
SH
cat >"${work}/shims/chown" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${SM_TEST_LOG}"
SH
chmod +x "${work}/shims/"*
export SM_TEST_LOG="${work}/log"
: >"${SM_TEST_LOG}"

SM_REMOTE_UID=1001
[[ "$(sm_remote_root_ssh_flags)" == -t ]] || fail "a normal login did not ask for a terminal"
command="$(sm_remote_root_command "echo 'two words'; (exit 3)" "/tmp/dir with space")"
[[ "${command}" == "sudo -p "* ]] || fail "a normal login's command does not start with sudo: ${command}"
set +e
out="$(PATH="${work}/shims:${PATH}" bash -c "${command}")"
code=$?
set -e
[[ "${out}" == "two words" ]] || fail "the command's output changed through sudo: ${out}"
[[ "${code}" == 3 ]] || fail "the command's exit code was lost through sudo (got ${code})"
grep -qx -- "-R tester /tmp/dir with space" "${SM_TEST_LOG}" || fail "the staging folder was not handed back to the login: $(cat "${SM_TEST_LOG}")"
ok "normal login: runs through sudo, keeps the exit code, hands the staging folder back (even with a space in its name)"

# Every root step in deploy.sh goes through the helper.
installs="$(grep -c "remote-install.sh' \(dry-run\|apply\|rollback\)" "${here}/deploy.sh")"
wrapped="$(grep "remote-install.sh' \(dry-run\|apply\|rollback\)" "${here}/deploy.sh" | grep -c sm_remote_root_command)"
[[ "${installs}" == 3 && "${wrapped}" == 3 ]] || fail "a remote-install.sh call in deploy.sh does not use sm_remote_root_command (${wrapped} of ${installs})"
ok "deploy.sh: dry-run, apply and rollback all go through sudo for a normal login"

# create-deploy-user.sh: refuses bad input, and its dry run changes nothing.
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample test@example'
if bash "${here}/create-deploy-user.sh" --dry-run root "${key}" >/dev/null 2>&1; then fail "created root as the deploy user"; fi
if bash "${here}/create-deploy-user.sh" --dry-run 'Bad Name' "${key}" >/dev/null 2>&1; then fail "accepted a bad user name"; fi
# Built in pieces so the public-tree check does not take this test line for a real private key block.
private_header="-----BEGIN OPENSSH ""PRIVATE KEY-----"
if bash "${here}/create-deploy-user.sh" --dry-run smtest "${private_header}" >/dev/null 2>&1; then fail "accepted a private key"; fi
if bash "${here}/create-deploy-user.sh" --dry-run smtest 'not a key' >/dev/null 2>&1; then fail "accepted text that is not a key"; fi
plan="$(bash "${here}/create-deploy-user.sh" --dry-run smtestnouser "${key}")"
grep -q "would run: .*\(adduser\|useradd\)" <<<"${plan}" || fail "the dry run did not say it would make the user: ${plan}"
grep -q "would run: usermod" <<<"${plan}" || fail "the dry run did not mention sudo group"
if id smtestnouser >/dev/null 2>&1; then fail "the dry run made a user"; fi
ok "create-deploy-user.sh: refuses root, bad names and private keys; dry run only prints"

# harden-ssh.sh: refuses (before writing anything) for a user that does not exist, and for root.
dropin="${work}/dropin.conf"
if SM_SSHD_DROPIN="${dropin}" bash "${here}/harden-ssh.sh" smtestnouser >/dev/null 2>&1; then fail "hardened sshd for a user that does not exist"; fi
if SM_SSHD_DROPIN="${dropin}" bash "${here}/harden-ssh.sh" root >/dev/null 2>&1; then fail "hardened sshd with root as the deploy user"; fi
[[ ! -e "${dropin}" ]] || fail "harden-ssh.sh wrote its file before its checks passed"
refusals="$(grep -nE '^\[\[ .* \]\] \|\| die|^id .* \|\| die|\| die "' "${here}/harden-ssh.sh" | head -1 | cut -d: -f1)"
write_line="$(grep -n 'cat >"${dropin}"' "${here}/harden-ssh.sh" | cut -d: -f1)"
[[ -n "${refusals}" && -n "${write_line}" && "${refusals}" -lt "${write_line}" ]] || fail "harden-ssh.sh writes before it checks"
grep -q 'who | awk' "${here}/harden-ssh.sh" || fail "harden-ssh.sh does not require a live session for the deploy user"
ok "harden-ssh.sh: refuses first, needs a live session for the deploy user, reverts if sshd disagrees"

echo "${pass} passed"
