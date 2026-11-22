#!/bin/sh
# Runs as root on the server, once, from install-on-server.sh. Usage: bootstrap-root.sh <stage-dir> <main-sha>
# Installs the deploy tool, its forced-command wrapper, the `smci` user with the deploy key, and a sudoers drop-in
# that lets `smci` run the tool and nothing else. Then redeploys the dispatch backstop through the tool.
set -eu
stage=${1:?stage dir}
sha=${2:?main sha}
install -d -m 755 -o root -g root /usr/local/sbin
install -m 755 -o root -g root "$stage/sm_deploy.py" /usr/local/sbin/sm-deploy
install -m 755 -o root -g root "$stage/sm-deploy-ssh" /usr/local/sbin/sm-deploy-ssh
id smci >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/smci --shell /bin/sh -p '*' smci
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
