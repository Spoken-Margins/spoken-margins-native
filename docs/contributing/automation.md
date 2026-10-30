# The maintainer's automation

The maintainer runs agents, a test lane, scheduled jobs and a few pacing tools against this repository (`scripts/lane-runner.py`, `ops/`, `.github/workflows/`). They are how the maintainer's own work gets merged. They are optional for everyone else.

- **You don't need any of it** to build, test, run or fork the app. [BUILDING.md](../../BUILDING.md) and the Verification section of [AGENTS.md](../../AGENTS.md) are the whole path: host tests, a plain `xcodebuild`, and the journeys.
- **Labels and comments from outsiders do nothing.** Automation acts only on text from the owner, members and collaborators (GitHub's `author_association`) and from `github-actions[bot]`. A comment that looks like a lane report or an audit verdict from anyone else is ignored.
- **Pull requests** from non-collaborators are not accepted for now (see [CONTRIBUTING.md](../../CONTRIBUTING.md)).
- **Private notes.** The maintainer keeps priorities, planning decisions and personal tooling in a private overlay to `AGENTS.md`. Agents working for the maintainer read it too (`CLAUDE.md` imports it when it exists). It adds to this guide and never replaces it.

Where the automation lives and how it is meant to move out of this repository is in [docs/open-source/private-ops-plan.md](../open-source/private-ops-plan.md). The jobs are listed in [docs/scheduled-jobs.md](../scheduled-jobs.md).
