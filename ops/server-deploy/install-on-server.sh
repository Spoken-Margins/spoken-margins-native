#!/bin/sh
# One-time install of the deploy tool on the VPS, with ONE sudo password prompt. Usage: ops/server-deploy/install-on-server.sh <ssh-host> <public-key-file> <main-sha>
# Copies the files over ordinary key login (no sudo), then runs bootstrap-root.sh in a single sudo session.
set -eu
host=${1:?usage: install-on-server.sh <ssh-host> <public-key-file> <main-sha>}
pub=${2:?public key file}
sha=${3:?main sha}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$pub" ] || { echo "no such public key: $pub" >&2; exit 1; }
stage=$(ssh "$host" 'mktemp -d /tmp/sm-deploy-install.XXXXXX')
case $stage in /tmp/sm-deploy-install.*) ;; *) echo "could not make a scratch folder on $host" >&2; exit 1 ;; esac
trap 'ssh "$host" "rm -rf $stage" >/dev/null 2>&1 || true' EXIT
scp -q "$here/sm_deploy.py" "$here/sm-deploy-ssh" "$here/sm-deploy.sudoers" "$here/bootstrap-root.sh" "$host:$stage/"
scp -q "$pub" "$host:$stage/deploy_key.pub"
ssh -t "$host" "sudo -p 'sudo password for %p: ' sh $stage/bootstrap-root.sh $stage $sha"
