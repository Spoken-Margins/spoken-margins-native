#!/usr/bin/env bash
# Runs ON THE VPS as root, AFTER the deploy user can log in and use sudo (#2478): switches off root login and password
# login for SSH.
#
#   bash harden-ssh.sh smdeploy
#
# It refuses unless the deploy user exists, is in the sudo group, has a password and a key, and is logged in over SSH
# right now (that is your proof that step 2 worked, and that you keep a way in). It writes one drop-in file, checks
# the settings sshd would really use, and reloads sshd (a reload keeps every open session). If the check fails it
# removes the file and reloads again, so a failed run changes nothing. Keep this session and the deploy user's session open
# until you have logged in once more as the deploy user in a third window.
set -euo pipefail
IFS=$'\n\t'

[[ $# -eq 1 ]] || { echo "usage: $0 <deploy user>" >&2; exit 2; }
user="$1"
dropin="${SM_SSHD_DROPIN:-/etc/ssh/sshd_config.d/00-sm-hardening.conf}"

die() { printf 'harden-ssh: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "run as root"
[[ "${user}" != root ]] || die "the deploy user cannot be root"
id "${user}" >/dev/null 2>&1 || die "user ${user} does not exist; run create-deploy-user.sh first"
command -v sudo >/dev/null 2>&1 || die "sudo is not installed on this server; install it (apt install sudo) and run create-deploy-user.sh again"
# What sudo would really allow, not just a group name: a `wheel` group means nothing on Debian without a sudoers line.
sudo_rights="$(sudo -l -U "${user}" 2>/dev/null || true)"
[[ "${sudo_rights}" == *"(ALL"*ALL* ]] || die "sudo does not give ${user} full rights (sudo -l -U ${user} shows no '(ALL) ALL'); fix sudoers first"
[[ "$(passwd -S "${user}" | awk '{print $2}')" == P ]] || die "${user} has no password, so sudo would fail; run: passwd ${user}"
home="$(getent passwd "${user}" | cut -d: -f6)"
[[ -s "${home}/.ssh/authorized_keys" ]] || die "${home}/.ssh/authorized_keys is empty"
logged_in="$(who | awk '{print $1}')"
grep -qx "${user}" <<<"${logged_in}" || die "${user} is not logged in over SSH right now. Open a second terminal, ssh in as ${user}, run 'sudo -v', then run this again."
# A session alone does not prove the KEY works: with password login still on, ssh falls back to the password. Only a
# server log line says how the session got in, so require "Accepted publickey" for this user. If no log can be read,
# refuse: that is the safe answer.
auth_log="$( { journalctl -q -u ssh -u sshd --since '-2 days' --no-pager 2>/dev/null || true; [[ -r /var/log/auth.log ]] && tail -n 5000 /var/log/auth.log; } 2>/dev/null || true)"
grep -q "Accepted publickey for ${user} " <<<"${auth_log}" ||
  die "found no 'Accepted publickey for ${user}' in the ssh log (or the log is unreadable). Log in as ${user} again with your key (ssh -o PreferredAuthentications=publickey ${user}@<server>), then run this again."

service=ssh
systemctl list-unit-files sshd.service >/dev/null 2>&1 && systemctl cat sshd.service >/dev/null 2>&1 && service=sshd
sshd -t || die "sshd's current configuration does not parse; nothing changed"

revert() {
  rm -f "${dropin}"
  systemctl reload "${service}" || true
}
# From here until the check passes, any exit (an error, ^C, a kill) removes the file again: a drop-in nobody checked must
# not wait for the next reboot or reload.
checked=0
cleanup() { if ((!checked)); then revert; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM

install -d -m 0755 "$(dirname "${dropin}")"
cat >"${dropin}" <<'CONF'
# Written by research/B4/deploy/harden-ssh.sh (#2478). Deploys log in as a normal user and use sudo.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
chmod 0644 "${dropin}"

if ! sshd -t; then revert; die "sshd rejected the new file; removed it, nothing changed"; fi
# Ask as the root user from localhost, so a `Match User root` block that turns root login back on is seen too.
effective="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)" || { die "sshd -T failed; removed ${dropin}, nothing changed"; }
effective_user="$(sshd -T -C "user=${user},host=localhost,addr=127.0.0.1" 2>/dev/null)" || { die "sshd -T failed; removed ${dropin}, nothing changed"; }
for setting in 'permitrootlogin no' 'passwordauthentication no'; do
  grep -qix "${setting}" <<<"${effective}" || die "sshd would still use something other than '${setting}' (another file wins); removed ${dropin}, nothing changed"
done
# The deploy user must still be able to get in by key.
grep -qix 'pubkeyauthentication yes' <<<"${effective_user}" || die "sshd would not accept keys for ${user}; removed ${dropin}, nothing changed"
checked=1
systemctl reload "${service}" || { checked=0; die "sshd would not reload; removed the file"; }

echo "Done. sshd now refuses root login and passwords. Your open sessions are still alive."
echo "Now, in a THIRD terminal on your Mac:"
echo "  ssh ${user}@<this server>     # must still work"
echo "  ssh root@<this server>        # must now be refused (Permission denied)"
echo "If the first fails, use a window that is still open and run: rm ${dropin} && systemctl reload ${service}"
