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
# Root-only steps run through sudo (#2478): the login is a normal user, so sudo asks for its password at this terminal.
root() { ssh -t "$host" "sudo -p 'sudo password for %p: ' sh -c '$1'"; }
for f in dial_gate.py sm-dial-gate.service sm-dial-gate.timer; do
  case $f in *.py) dest=/opt/sm-dial/$f ;; *) dest=/etc/systemd/system/$f ;; esac
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
root 'for f in github-token relay-token relay-url; do test -s /etc/sm-dial/$f && echo "secret present: /etc/sm-dial/$f" || echo "MISSING: /etc/sm-dial/$f"; done'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }
stage=$(ssh "$host" 'mktemp -d /tmp/sm-dial-deploy.XXXXXX')
case $stage in /tmp/*) ;; *) echo "could not make a scratch folder on $host" >&2; exit 1 ;; esac
trap 'ssh "$host" "rm -rf $stage" >/dev/null 2>&1 || true' EXIT
scp -q "$here/dial_gate.py" "$here/sm-dial-gate.service" "$here/sm-dial-gate.timer" "$host:$stage/"
root "install -d -m 755 /opt/sm-dial && install -m 755 $stage/dial_gate.py /opt/sm-dial/dial_gate.py && install -m 644 $stage/sm-dial-gate.service $stage/sm-dial-gate.timer /etc/systemd/system/ && systemctl daemon-reload"
if [ "$mode" = --enable ]; then
  root 'systemctl enable --now sm-dial-gate.timer && systemctl list-timers sm-dial-gate.timer --no-pager'
else
  echo "installed; timer left off. Try: ssh -t $host sudo python3 /opt/sm-dial/dial_gate.py --dry-run"
fi
