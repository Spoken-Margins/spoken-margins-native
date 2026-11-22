# Server deploys from GitHub (#4866)

A merge to `main` that touches a server tool's files installs that tool on the VPS, with no one at a terminal. Run it by hand from the Actions tab (`server-deploy`, pick a target) when needed.

Targets: `backstop`, `dial`, `bandwidth`, `voice-catalog`. The table of files and destinations is `TARGETS` in `sm_deploy.py`; a test keeps it in step with the workflow's trigger paths and the older `ops/*/deploy.sh` scripts.

## How it works

1. `.github/workflows/server-deploy.yml` runs in the `server-deploy` environment and connects as `smci` with a deploy key kept as three environment secrets: `DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_KNOWN_HOSTS` (the pinned host key). The environment has no required reviewer.
2. That key's `authorized_keys` line forces one command, `/usr/local/sbin/sm-deploy-ssh`, with `restrict` (no shell, no forwarding). The key can run nothing else.
3. `sm-deploy-ssh` runs `sudo -n /usr/local/sbin/sm-deploy <target> <sha>`. The sudoers drop-in lets `smci` run that one file and no other command.
4. `sm-deploy` (root-owned, installed by hand) accepts exactly a target name and a 40-hex sha. It checks the sha is already on `main` through GitHub's compare API, fetches only the table's files from that commit, and writes them atomically. It reloads systemd and restarts a timer only when that timer is already enabled and its unit changed. It never enables a timer, never reads or writes `/etc/sm-*` secrets, and logs to `/var/log/sm-deploy.log`.

## What a stolen key can do

It can re-install code that has already merged into `main` onto the four fixed targets, including an older `main` commit. It cannot run a command, pick a file, or deploy a branch that has not merged. It cannot change `sm-deploy` itself: updating the tool needs the sudo password once (below), by design. To revoke, delete the key line in `/home/smci/.ssh/authorized_keys` (root-owned) and the three secrets.

## One-time install, or after changing the tool itself

```sh
ops/server-deploy/install-on-server.sh ptp <public-key-file> <main-sha>
```

It copies the files over normal key login, then runs `bootstrap-root.sh` in one sudo session (one password prompt): installs the tool and wrapper, creates `smci`, writes the key line, installs the sudoers drop-in after `visudo -cf`, and redeploys the backstop through the tool.

## Adding a target

Add it to `TARGETS`, the workflow's trigger paths and the dispatch choices, and its older `deploy.sh`; the drift test fails until all agree. Updating the tool on the server is the one-time install above.
