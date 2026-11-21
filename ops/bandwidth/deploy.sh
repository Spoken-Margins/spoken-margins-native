#!/usr/bin/env bash
# Deploy the VPS transfer check. Usage: ops/bandwidth/deploy.sh <ssh-host> [--dry-run | --enable]
#   --dry-run  show what would change on the host; change nothing
#   --enable   copy the script and units, then start the daily timer
# The Healthchecks ping URL stays on the host in /etc/sm-bandwidth/ping-url; this never copies or prints it.
#
# A normal (non-root) login works too (#2478, #4848). The files go to a scratch folder as the login; the steps that
# need root (install into /opt and /etc/systemd/system, systemctl, reading the root-only ping URL, the journal) run
# through sudo, which asks for the password at the terminal, the same way research/B4/deploy/deploy.sh does. A root
# login runs them unchanged. So a non-root deploy needs a person at a terminal; an unattended session cannot run it.
set -eu
host=${1:?usage: deploy.sh <ssh-host> [--dry-run|--enable]}
mode=${2:---dry-run}
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

ssh "$host" 'systemctl is-active vnstat' || { echo "vnstat is not running on $host"; exit 1; }
for f in bandwidth_check.py sm-bandwidth.service sm-bandwidth.timer; do
  case $f in *.py) dest=/opt/sm-bandwidth/$f ;; *) dest=/etc/systemd/system/$f ;; esac
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
# /etc/sm-bandwidth is root-only, so a non-root login would read the URL as missing without sudo.
root_ssh 'test -s /etc/sm-bandwidth/ping-url && echo "ping URL present" || echo "MISSING: /etc/sm-bandwidth/ping-url"'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }
root_ssh 'test -s /etc/sm-bandwidth/ping-url' || { echo "write the ping URL first (see README)"; exit 1; }

stage=$(ssh "$host" 'mktemp -d /tmp/sm-bandwidth-deploy.XXXXXX' | tr -d '\r')
scp -q "$here/bandwidth_check.py" "$here/sm-bandwidth.service" "$here/sm-bandwidth.timer" "$host:$stage/"
install_cmd="install -d -m 755 /opt/sm-bandwidth && install -m 755 $stage/bandwidth_check.py /opt/sm-bandwidth/bandwidth_check.py && install -m 644 $stage/sm-bandwidth.service $stage/sm-bandwidth.timer /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now sm-bandwidth.timer && systemctl start sm-bandwidth.service && journalctl -u sm-bandwidth.service -n 3 --no-pager"
root_ssh "$install_cmd" "$stage"
ssh "$host" "rm -rf $stage" >/dev/null 2>&1 || true
