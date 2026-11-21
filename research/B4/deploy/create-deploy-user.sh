#!/usr/bin/env bash
# Runs ON THE VPS, once, as root: makes the normal login that deploys use instead of root (#2478).
#
#   bash create-deploy-user.sh --dry-run smdeploy 'ssh-ed25519 AAAA... comment'   # say what it would do
#   bash create-deploy-user.sh           smdeploy 'ssh-ed25519 AAAA... comment'   # do it
#
# The key is the owner's PUBLIC key (the .pub line); nothing secret is passed. The script:
#   1. makes the user (bash shell) if it does not exist, and adds it to the sudo group;
#   2. installs the public key for it;
#   3. hands it the two web folders, so the site and web deploys need no root;
#   4. asks for the user's password (for sudo only; SSH password login is switched off later by harden-ssh.sh).
# It does not touch sshd, so nothing here can lock anyone out. Safe to run again.
set -euo pipefail
IFS=$'\n\t'

dry_run=0
if [[ "${1:-}" == --dry-run ]]; then dry_run=1; shift; fi
[[ $# -eq 2 ]] || { echo "usage: $0 [--dry-run] <user> '<public key line>'" >&2; exit 2; }
user="$1"
key="$2"
web_roots=("${SM_WEB_ROOTS_SITE:-/srv/www/spokenmargins}" "${SM_WEB_ROOTS_WEB:-/srv/www/spokenmargins-web}")

die() { printf 'create-deploy-user: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
act() { if ((dry_run)); then say "would run: $*"; else "$@"; fi; }

[[ "${user}" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || die "user name ${user} must be lower-case letters, digits, - or _"
[[ "${user}" != root ]] || die "the deploy user cannot be root"
[[ "${key}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com)\ [A-Za-z0-9+/=]+(\ [^[:cntrl:]]*)?$ ]] ||
  die "that is not a public key line (it must start ssh-ed25519, ssh-rsa or ecdsa-sha2-, and be the .pub file, never the private key)"
[[ "${key}" != *PRIVATE* ]] || die "that looks like a private key; pass the .pub line"
((dry_run)) || [[ "$(id -u)" == 0 ]] || die "run as root (the dry run needs no root)"

if id "${user}" >/dev/null 2>&1; then
  say "user ${user} exists"
else
  say "making user ${user}"
  if command -v adduser >/dev/null 2>&1; then act adduser --disabled-password --gecos '' --shell /bin/bash "${user}"; else act useradd --create-home --shell /bin/bash "${user}"; fi
fi

sudo_group=sudo
getent group sudo >/dev/null 2>&1 || sudo_group=wheel
say "adding ${user} to ${sudo_group} (sudo asks for the user's password)"
act usermod -aG "${sudo_group}" "${user}"

home="$(getent passwd "${user}" | cut -d: -f6 || true)"
[[ -n "${home}" ]] || home="/home/${user}"
say "installing the public key in ${home}/.ssh/authorized_keys"
if ((dry_run)); then
  say "would run: install -d -m 0700 -o ${user} -g ${user} ${home}/.ssh; add the key line once; chmod 0600"
else
  install -d -m 0700 -o "${user}" -g "${user}" "${home}/.ssh"
  touch "${home}/.ssh/authorized_keys"
  grep -qxF -- "${key}" "${home}/.ssh/authorized_keys" || printf '%s\n' "${key}" >>"${home}/.ssh/authorized_keys"
  chown "${user}:${user}" "${home}/.ssh/authorized_keys"
  chmod 0600 "${home}/.ssh/authorized_keys"
fi

for dir in "${web_roots[@]}"; do
  if [[ -d "${dir}" ]]; then
    say "handing ${dir} to ${user}"
    act chown -R "${user}:${user}" "${dir}"
  else
    say "${dir} does not exist yet (deploy.sh makes the web folder); skipped"
  fi
done

status="$(passwd -S "${user}" 2>/dev/null | awk '{print $2}' || true)"
if [[ "${status}" == P ]]; then
  say "${user} already has a password"
elif ((dry_run)); then
  say "would run: passwd ${user} (you type the sudo password; it is not shown or stored anywhere else)"
else
  say "Choose ${user}'s password now. It is only for sudo."
  passwd "${user}"
fi

say
say "Done. Now, from your Mac, in a NEW terminal window (keep this one open):"
say "  ssh ${user}@<this server>"
say "  sudo -v        # asks for the password you just chose; it must succeed"
say "Only after both work: bash harden-ssh.sh ${user}"
