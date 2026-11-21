#!/bin/sh
# Deploy the VPS transfer check. Usage: ops/bandwidth/deploy.sh <ssh-host> [--dry-run | --enable]
#   --dry-run  show what would change on the host; change nothing
#   --enable   copy the script and units, then start the daily timer
# The Healthchecks ping URL stays on the host in /etc/sm-bandwidth/ping-url; this never copies or prints it.
set -eu
host=${1:?usage: deploy.sh <ssh-host> [--dry-run|--enable]}
mode=${2:---dry-run}
here=$(cd "$(dirname "$0")" && pwd)
# Root-only steps run through sudo (#2478): the login is a normal user, so sudo asks for its password at this terminal.
root() { ssh -t "$host" "sudo -p 'sudo password for %p: ' sh -c '$1'"; }
ssh "$host" 'systemctl is-active vnstat' || { echo "vnstat is not running on $host"; exit 1; }
for f in bandwidth_check.py sm-bandwidth.service sm-bandwidth.timer; do
  case $f in *.py) dest=/opt/sm-bandwidth/$f ;; *) dest=/etc/systemd/system/$f ;; esac
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
root 'test -s /etc/sm-bandwidth/ping-url && echo "ping URL present" || echo "MISSING: /etc/sm-bandwidth/ping-url"'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }
root 'test -s /etc/sm-bandwidth/ping-url' || { echo "write the ping URL first (see README)"; exit 1; }
stage=$(ssh "$host" 'mktemp -d /tmp/sm-bandwidth-deploy.XXXXXX')
scp -q "$here/bandwidth_check.py" "$here/sm-bandwidth.service" "$here/sm-bandwidth.timer" "$host:$stage/"
root "install -d -m 755 /opt/sm-bandwidth && install -m 755 $stage/bandwidth_check.py /opt/sm-bandwidth/bandwidth_check.py && install -m 644 $stage/sm-bandwidth.service $stage/sm-bandwidth.timer /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now sm-bandwidth.timer && systemctl start sm-bandwidth.service && journalctl -u sm-bandwidth.service -n 3 --no-pager"
ssh "$host" "rm -rf $stage"
