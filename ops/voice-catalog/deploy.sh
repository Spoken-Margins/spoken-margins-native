#!/bin/sh
# Deploy the weekly voice catalog check (#1818) to the VPS. Usage: ops/voice-catalog/deploy.sh <ssh-host> [--dry-run | --install-only | --enable]
#   --dry-run       show what would change on the host; change nothing
#   --install-only  copy the script, the source list and the units, but leave the timer off (default)
#   --enable        copy, then start the weekly timer (do this only after the first publish: the check requires the mirror)
# The GitHub token that files the issues stays on the host in /etc/sm-voice-catalog/github-token; this never copies or prints it.
set -eu
host=${1:?usage: deploy.sh <ssh-host> [--dry-run|--install-only|--enable]}
mode=${2:---install-only}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
for f in scripts/voice_catalog.py scripts/voice_catalog_tools.py; do
  dest=/opt/sm-voice-catalog/$f
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$repo/$f" || true
  else
    echo "new file: $dest"
  fi
done
for f in sm-voice-catalog.service sm-voice-catalog.timer; do
  dest=/etc/systemd/system/$f
  if ssh "$host" "test -f $dest"; then
    ssh "$host" "cat $dest" | diff -u --label "host:$dest" --label "new:$f" - "$here/$f" || true
  else
    echo "new file: $dest"
  fi
done
echo "source list and licence copies: Contracts/voice-models/ ($(find "$repo/Contracts/voice-models" -type f | wc -l | tr -d ' ') files) -> /opt/sm-voice-catalog/Contracts/voice-models/"
ssh "$host" 'test -s /etc/sm-voice-catalog/github-token && echo "secret present: /etc/sm-voice-catalog/github-token" || echo "MISSING: /etc/sm-voice-catalog/github-token"'
[ "$mode" = --dry-run ] && { echo "(dry run: nothing changed)"; exit 0; }
ssh "$host" 'install -d -m 755 /opt/sm-voice-catalog/scripts /opt/sm-voice-catalog/Contracts/voice-models'
scp -q "$repo/scripts/voice_catalog.py" "$repo/scripts/voice_catalog_tools.py" "$host:/opt/sm-voice-catalog/scripts/"
tar -C "$repo/Contracts" -cf - voice-models | ssh "$host" 'rm -rf /opt/sm-voice-catalog/Contracts/voice-models && tar -C /opt/sm-voice-catalog/Contracts -xf -'
scp -q "$here/sm-voice-catalog.service" "$here/sm-voice-catalog.timer" "$host:/etc/systemd/system/"
ssh "$host" 'chmod 755 /opt/sm-voice-catalog/scripts/voice_catalog.py && systemctl daemon-reload'
if [ "$mode" = --enable ]; then
  ssh "$host" 'systemctl enable --now sm-voice-catalog.timer && systemctl list-timers sm-voice-catalog.timer --no-pager'
else
  echo "installed; timer left off. Try: ssh $host python3 /opt/sm-voice-catalog/scripts/voice_catalog.py --state-dir /var/lib/sm-voice-catalog check --mirror skip"
fi
