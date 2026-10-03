#!/bin/sh
# Deploy the dial gate (#589) to the VPS. Usage: ops/dial/deploy.sh <ssh-host> [--dry-run | --install-only | --enable]
#   --dry-run       show what would change on the host; change nothing
#   --install-only  copy the script and units, but leave the timer off (default)
#   --enable        copy, then start the 15-minute timer
# Secrets stay on the host in /etc/sm-dial (github-token, relay-token, relay-url); this never copies or prints them.
set -eu
host=${1:?usage: deploy.sh <ssh-host> [--dry-run|--install-only|--enable]}
mode=${2:---install-only}
here=$(cd "$(dirname "$0")" && pwd)
for f in dial_gate.py sm-dial-gate.service sm-dial-gate.timer; do
  case $f in *.py) dest=/opt/sm-dial/$f ;; *) dest=/etc/systemd/system/$f ;; esac
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
ssh "$host" 'for f in github-token relay-token relay-url; do test -s /etc/sm-dial/$f && echo "secret present: /etc/sm-dial/$f" || echo "MISSING: /etc/sm-dial/$f"; done'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }
ssh "$host" 'install -d -m 755 /opt/sm-dial'
scp -q "$here/dial_gate.py" "$host:/opt/sm-dial/dial_gate.py"
scp -q "$here/sm-dial-gate.service" "$here/sm-dial-gate.timer" "$host:/etc/systemd/system/"
ssh "$host" 'chmod 755 /opt/sm-dial/dial_gate.py && systemctl daemon-reload'
if [ "$mode" = --enable ]; then
  ssh "$host" 'systemctl enable --now sm-dial-gate.timer && systemctl list-timers sm-dial-gate.timer --no-pager'
else
  echo "installed; timer left off. Try: ssh $host python3 /opt/sm-dial/dial_gate.py --dry-run"
fi
