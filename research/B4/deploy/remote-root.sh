#!/usr/bin/env bash
# Sourced by deploy.sh (and read by the tests). How a deploy gets root on the VPS without logging in as root (#2478).
#
# The deploy user is a normal account that owns the two web folders (so the site and web deploys need no root) and
# has sudo WITH a password. The few steps that need root (smserver, the Caddy global block, systemd, journald) run
# through `sudo`, which asks for that password at the terminal. A stolen SSH key alone is then not root. The cost: a
# server deploy needs a person at a terminal to type the password, so an unattended session cannot run one.
#
# SM_REMOTE_UID is what `id -u` printed on the box. 0 means the login is root (the old way); the command then runs
# unchanged, so a deploy still works before the new user exists.

# Single-quote a string for a POSIX shell, so it survives one trip through ssh.
sm_squote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# sm_remote_root_command COMMAND [DIR]
# Prints the one string to hand to ssh so COMMAND runs as root on the box. With a DIR, the files root left there are
# handed back to the login afterwards, so the deploy's own cleanup (rm -rf) can remove them without root.
sm_remote_root_command() {
  local command="$1" dir="${2:-}"
  if [[ "${SM_REMOTE_UID:-0}" == 0 ]]; then
    printf '%s' "${command}"
    return
  fi
  local inner="${command}; rc=\$?"
  if [[ -n "${dir}" ]]; then
    inner+="; chown -R \"\$SUDO_USER\" $(sm_squote "${dir}") 2>/dev/null"
  fi
  inner+="; exit \$rc"
  printf "sudo -p 'sudo password for %%p: ' bash -c %s" "$(sm_squote "${inner}")"
}

# The ssh flags a root command needs: a terminal for sudo's password prompt, unless the login is root.
sm_remote_root_ssh_flags() {
  if [[ "${SM_REMOTE_UID:-0}" == 0 ]]; then printf ''; else printf '%s' '-t'; fi
}
