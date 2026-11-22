# Agent identity on the Mac (#4915 step 2)

Local agent jobs (the Claude worker, the integration run, `sm-gh`) reach GitHub through `sm-agent-env`. This folder holds the versioned copy of that wrapper and `sm_app_token.py`, which mints a token for the GitHub App `spoken-margins-agent` (App ID 5876250, installation 184718081). That way agent comments, labels and PRs show as `spoken-margins-agent[bot]` instead of the owner's login.

## How it switches

- **`SM_AGENT_AS_APP=1`**: act as the App. `sm-agent-env` runs `sm-app-token`, which reads the App key from the Keychain, signs a 9-minute JWT with `openssl`, and trades it for a 1-hour installation token scoped to this repository. The token is cached at `~/Library/Caches/spoken-margins/agent-app-token.json` (mode 0600) and reused while it has more than 10 minutes left. If minting fails the command does not run: it never quietly falls back to the owner's login.
- **Flag unset (the default, and the rollback):** the earlier narrow token in the Keychain item `sm-agent-gh`, exactly as before.

## Install (maintainer's Mac)

The App key lives in the Keychain as one line of base64 of the downloaded PEM file (generic password, service `sm-agent-app-key`). It is stored that way because `security -w` prints multi-line secrets as hex. After storing it, delete the downloaded file.

The installed copies are `~/.claude/bin/sm-agent-env` and `~/.claude/bin/sm-app-token`, copied from this folder. Check with `SM_AGENT_AS_APP=1 ~/.claude/bin/sm-agent-env /usr/bin/python3 ~/.claude/bin/sm-app-token --check`. It prints the installation, its expiry and its repositories, never the token.

## Limits

- The token can only do what the App's installation permissions allow. Pushing a change under `.github/workflows/` also needs the App's `workflows` permission.
- An org installation token can't reach the owner's personal Projects board (`sm_project_sync.py`, `area_labels.py`). Leave the Claude worker without the flag until that moves.
- A bot-authored comment that @mentions the owner still notifies him.
