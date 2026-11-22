#!/usr/bin/env bash
# Sets up SSH for a gated deploy job (deploy-web.yml, deploy-site.yml, #4982) on a hosted Linux runner.
#
# Reads SSH_KEY (private key), KNOWN_HOSTS (the server's known_hosts line) and HOST (user@host) from the environment,
# all from the job's GitHub environment. Writes the key to ~/.ssh/sm_deploy (mode 600) and the host key to
# ~/.ssh/known_hosts, and makes every ssh and rsync in the job check the host key strictly and never prompt. Prints
# neither the key nor the host: GitHub masks the secrets, and the host's address alone is masked here too, since an
# error message can print it without the user name.
set -euo pipefail

[[ -n "${SSH_KEY:-}" && -n "${KNOWN_HOSTS:-}" && -n "${HOST:-}" ]] || {
  echo "::error::The environment is missing SM_DEPLOY_SSH_KEY, SM_DEPLOY_KNOWN_HOSTS or SM_DEPLOY_HOST."
  exit 1
}
[[ "${HOST}" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.:-]+$ ]] || { echo "::error::SM_DEPLOY_HOST is not user@host."; exit 1; }
echo "::add-mask::${HOST#*@}"

umask 077
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
printf '%s\n' "${SSH_KEY}" >"${HOME}/.ssh/sm_deploy"
chmod 600 "${HOME}/.ssh/sm_deploy"
printf '%s\n' "${KNOWN_HOSTS}" >"${HOME}/.ssh/known_hosts"
chmod 644 "${HOME}/.ssh/known_hosts"
cat >"${HOME}/.ssh/config" <<'EOF'
Host *
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
  BatchMode yes
  IdentitiesOnly yes
  IdentityFile ~/.ssh/sm_deploy
EOF
chmod 600 "${HOME}/.ssh/config"
echo "SSH is set up: strict host key checking, no prompts."
