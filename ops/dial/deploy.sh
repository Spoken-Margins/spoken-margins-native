#!/usr/bin/env bash
# Deploy the dial gate (#589) to the VPS. Usage: ops/dial/deploy.sh <ssh-host> [--dry-run | --install-only | --enable]
#   --dry-run       show what would change on the host; change nothing
#   --install-only  copy the script and units, but leave the timer off (default)
#   --enable        copy, then start the 15-minute timer
# Secrets stay on the host in /etc/sm-dial (github-token, relay-token, relay-url); this never copies or prints them.
#
# A normal (non-root) login works too (#2478, #4848). The files go to a scratch folder as the login; the steps that
# need root (install into /opt and /etc/systemd/system, systemctl, reading the root-only secrets folder) run through
# sudo, which asks for the password at the terminal, the same way research/B4/deploy/deploy.sh does. A root login
# runs them unchanged. So a non-root deploy needs a person at a terminal; an unattended session cannot run it.
set -eu
host=${1:?usage: deploy.sh <ssh-host> [--dry-run|--install-only|--enable]}
mode=${2:---install-only}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../../research/B4/deploy/remote-root.sh
source "$here/../../research/B4/deploy/remote-root.sh"

SM_REMOTE_UID=$(ssh "$host" 'id -u' | tr -d '\r')
case $SM_REMOTE_UID in '' | *[!0-9]*) echo "could not read the login's user id on $host" >&2; exit 1 ;; esac
[ "$SM_REMOTE_UID" = 0 ] || echo "== logged in as uid $SM_REMOTE_UID; root steps run through sudo and will ask for its password"

# root_ssh COMMAND [DIR]: run COMMAND as root on the host (DIR is handed back to the login afterwards).
root_ssh() {
  local flags
  flags=$(sm_remote_root_ssh_flags)
  if [ -n "$flags" ]; then
    ssh "$flags" "$host" "$(sm_remote_root_command "$1" "${2:-}")"
  else
    ssh "$host" "$(sm_remote_root_command "$1" "${2:-}")"
  fi
}

for f in dial_gate.py sm-dial-gate.service sm-dial-gate.timer; do
  case $f in *.py) dest=/opt/sm-dial/$f ;; *) dest=/etc/systemd/system/$f ;; esac
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
# /etc/sm-dial is root-only, so a non-root login would read every secret as missing without sudo.
root_ssh 'for f in github-token relay-token relay-url; do test -s /etc/sm-dial/$f && echo "secret present: /etc/sm-dial/$f" || echo "MISSING: /etc/sm-dial/$f"; done'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }

stage=$(ssh "$host" 'mktemp -d /tmp/sm-dial-deploy.XXXXXX' | tr -d '\r')
case $stage in /tmp/*) ;; *) echo "could not make a scratch folder on $host" >&2; exit 1 ;; esac
trap 'ssh "$host" "rm -rf $stage" >/dev/null 2>&1 || true' EXIT
scp -q "$here/dial_gate.py" "$here/sm-dial-gate.service" "$here/sm-dial-gate.timer" "$host:$stage/"
install_cmd="install -d -m 755 /opt/sm-dial && install -m 755 $stage/dial_gate.py /opt/sm-dial/dial_gate.py && install -m 644 $stage/sm-dial-gate.service $stage/sm-dial-gate.timer /etc/systemd/system/ && systemctl daemon-reload"
root_ssh "$install_cmd" "$stage"
if [ "$mode" = --enable ]; then
  root_ssh 'systemctl enable --now sm-dial-gate.timer && systemctl list-timers sm-dial-gate.timer --no-pager'
else
  echo "installed; timer left off. Try: ssh $host python3 /opt/sm-dial/dial_gate.py --dry-run"
fi
