#!/bin/sh
# Runs as root on the server, once, from install-on-server.sh. Usage: bootstrap-root.sh <stage-dir> <main-sha>
# Installs the deploy tool, its forced-command wrapper, the `smci` user with the deploy key, and a sudoers drop-in
# that lets `smci` run the tool and nothing else. Then redeploys the dispatch backstop through the tool.
set -eu
check=0
if [ "${1:-}" = --check ]; then check=1; shift; fi
stage=${1:?stage dir}
sha=${2:?main sha}
[ "$(wc -l < "$stage/deploy_key.pub" | tr -d ' ')" = 1 ] && grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+( .*)?$' "$stage/deploy_key.pub" || { echo "deploy_key.pub must be exactly one public key line" >&2; exit 1; }
if [ "$check" = 1 ]; then
  # Dry run, no root and no changes: the same inputs are validated so a real run does not fail on them.
  for f in sm_deploy.py sm-deploy-ssh sm-deploy.sudoers bootstrap-root.sh deploy_key.pub; do test -s "$stage/$f"; done
  sh -n "$stage/sm-deploy-ssh"
  sh -n "$stage/bootstrap-root.sh"
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$stage/sm_deploy.py"
  cp "$stage/sm-deploy.sudoers" "$stage/sudoers.check"
  visudo -cf "$stage/sudoers.check"
  command -v useradd install visudo base64 python3 systemctl >/dev/null
  case "$sha" in *[!0-9a-f]*|'') echo "bad sha" >&2; exit 1 ;; esac
  [ ${#sha} -eq 40 ]
  echo "CHECK OK"
  exit 0
fi
install -d -m 755 -o root -g root /usr/local/sbin
install -m 755 -o root -g root "$stage/sm_deploy.py" /usr/local/sbin/sm-deploy
install -m 755 -o root -g root "$stage/sm-deploy-ssh" /usr/local/sbin/sm-deploy-ssh
if id smci >/dev/null 2>&1; then usermod -s /bin/sh -d /home/smci -p '*' smci; else useradd --system --create-home --home-dir /home/smci --shell /bin/sh -p '*' smci; fi
chown root:root /home/smci
chmod 755 /home/smci
install -d -m 755 -o root -g root /home/smci/.ssh
printf 'command="/usr/local/sbin/sm-deploy-ssh",restrict %s\n' "$(cat "$stage/deploy_key.pub")" > "$stage/authorized_keys"
install -m 644 -o root -g root "$stage/authorized_keys" /home/smci/.ssh/authorized_keys
install -m 440 -o root -g root "$stage/sm-deploy.sudoers" /etc/sudoers.d/.sm-deploy.new
visudo -cf /etc/sudoers.d/.sm-deploy.new
mv /etc/sudoers.d/.sm-deploy.new /etc/sudoers.d/sm-deploy
sudo -l -U smci | grep -q sm-deploy
/usr/local/sbin/sm-deploy backstop "$sha"
echo "bootstrap done"
