#!/bin/sh
# Deploy the dispatch backstop (#4866) to the VPS. Usage: ops/dispatch-backstop/deploy.sh <ssh-host> [--dry-run | --install-only | --enable]
#   --dry-run       show what would change on the host; change nothing
#   --install-only  copy the script and units, but leave the timer off (default)
#   --enable        copy, then start the 15-minute timer
# The token stays on the host (/etc/sm-dispatch/github-token, or the Dial's /etc/sm-dial/github-token as the fallback);
# this never copies or prints it. It must be able to dispatch workflows (`actions: write`).
set -eu
host=${1:?usage: deploy.sh <ssh-host> [--dry-run|--install-only|--enable]}
mode=${2:---install-only}
here=$(cd "$(dirname "$0")" && pwd)
root() { ssh -t "$host" "sudo -p 'sudo password for %p: ' sh -c '$1'"; }
for f in sm_dispatch_backstop.py sm-dispatch-backstop.service sm-dispatch-backstop.timer; do
  case $f in *.py) dest=/opt/sm-dispatch/$f ;; *) dest=/etc/systemd/system/$f ;; esac
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
root 'for f in /etc/sm-dispatch/github-token /etc/sm-dial/github-token; do test -s $f && echo "token present: $f" || echo "missing: $f"; done'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }
stage=$(ssh "$host" 'mktemp -d /tmp/sm-dispatch-deploy.XXXXXX')
scp -q "$here/sm_dispatch_backstop.py" "$here/sm-dispatch-backstop.service" "$here/sm-dispatch-backstop.timer" "$host:$stage/"
root "install -d -m 755 /opt/sm-dispatch && install -m 755 $stage/sm_dispatch_backstop.py /opt/sm-dispatch/sm_dispatch_backstop.py && install -m 644 $stage/sm-dispatch-backstop.service $stage/sm-dispatch-backstop.timer /etc/systemd/system/ && systemctl daemon-reload"
ssh "$host" "rm -rf $stage"
if [ "$mode" = --enable ]; then
  root 'systemctl enable --now sm-dispatch-backstop.timer && systemctl list-timers sm-dispatch-backstop.timer --no-pager'
else
  echo "installed; timer left off. Try: ssh -t $host sudo python3 /opt/sm-dispatch/sm_dispatch_backstop.py --dry-run"
fi
