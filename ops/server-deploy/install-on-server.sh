#!/bin/sh
# One-time install of the deploy tool on the VPS, with ONE sudo password prompt. Usage: ops/server-deploy/install-on-server.sh <ssh-host> <public-key-file> <main-sha>
# One ssh connection, one sudo session: the files travel inside the command as a base64 tar, and root unpacks them
# into its own private folder and runs bootstrap-root.sh there. (A first version used four connections in a row and
# the server reset the sudo session after the password.)
set -eu
host=${1:?usage: install-on-server.sh <ssh-host> <public-key-file> <main-sha>}
pub=${2:?public key file}
sha=${3:?main sha}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$pub" ] || { echo "no such public key: $pub" >&2; exit 1; }
case $sha in *[!0-9a-f]*|'') echo "main sha must be 40 hex characters" >&2; exit 1 ;; esac
[ ${#sha} -eq 40 ] || { echo "main sha must be 40 hex characters" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$here/sm_deploy.py" "$here/sm-deploy-ssh" "$here/sm-deploy.sudoers" "$here/bootstrap-root.sh" "$work/"
cp "$pub" "$work/deploy_key.pub"
payload=$(COPYFILE_DISABLE=1 tar -C "$work" -cf - sm_deploy.py sm-deploy-ssh sm-deploy.sudoers bootstrap-root.sh deploy_key.pub | base64 | tr -d '\n')
remote="d=\$(mktemp -d /tmp/sm-deploy-install.XXXXXX) && echo $payload | base64 -d | tar -xf - -C \$d && sh \$d/bootstrap-root.sh \$d $sha; rc=\$?; rm -rf \$d; exit \$rc"
exec ssh -t "$host" "sudo -p 'sudo password for %p: ' sh -c '$remote'"
