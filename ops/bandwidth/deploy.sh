#!/bin/sh
# Deploy the VPS transfer check. Usage: ops/bandwidth/deploy.sh <ssh-host> [--dry-run | --enable]
#   --dry-run  show what would change on the host; change nothing
#   --enable   copy the script and units, then start the daily timer
# The Healthchecks ping URL stays on the host in /etc/sm-bandwidth/ping-url; this never copies or prints it.
set -eu
host=${1:?usage: deploy.sh <ssh-host> [--dry-run|--enable]}
mode=${2:---dry-run}
here=$(cd "$(dirname "$0")" && pwd)
ssh "$host" 'systemctl is-active vnstat' || { echo "vnstat is not running on $host"; exit 1; }
for f in bandwidth_check.py sm-bandwidth.service sm-bandwidth.timer; do
  case $f in *.py) dest=/opt/sm-bandwidth/$f ;; *) dest=/etc/systemd/system/$f ;; esac
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
ssh "$host" 'test -s /etc/sm-bandwidth/ping-url && echo "ping URL present" || echo "MISSING: /etc/sm-bandwidth/ping-url"'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }
ssh "$host" 'test -s /etc/sm-bandwidth/ping-url' || { echo "write the ping URL first (see README)"; exit 1; }
ssh "$host" 'install -d -m 755 /opt/sm-bandwidth'
scp -q "$here/bandwidth_check.py" "$host:/opt/sm-bandwidth/bandwidth_check.py"
scp -q "$here/sm-bandwidth.service" "$here/sm-bandwidth.timer" "$host:/etc/systemd/system/"
ssh "$host" 'chmod 755 /opt/sm-bandwidth/bandwidth_check.py && systemctl daemon-reload && systemctl enable --now sm-bandwidth.timer && systemctl start sm-bandwidth.service && journalctl -u sm-bandwidth.service -n 3 --no-pager'
