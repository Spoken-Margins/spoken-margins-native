# Runner guard: no fork code on the owner's machines (#1719)

`refuse-fork-jobs.sh` runs on each self-hosted runner before every job. It fails the job, before any
of its steps run, when the job's pull request comes from another repository (a fork), when it was
started by an event anyone can trigger (`issue_comment` and similar), or when the event can't be read.

## Why the workflows' own guards aren't enough

Every workflow that runs on a self-hosted runner checks
`github.event.pull_request.head.repo.full_name == github.repository`. That stops fork PRs only while
the workflow files are ours. A `pull_request` run uses the workflow files from the PR's merge commit,
so in a public repo a fork's PR could delete the check, or add a new workflow with
`runs-on: [self-hosted]`. GitHub's runner groups, which could limit runners to chosen workflows, exist
only for organizations; this repo belongs to a personal account. This hook lives on the runner, so a
PR can't change it.

It is one of three layers. The other two are repository settings changed when the repo goes public
(listed on #1719): fork PR workflows need approval, and only collaborators can open PRs (#1393).

## Install (owner's machines, at flip time)

On each runner (the Mac's `sm-lane*` runners, the VPS's `sm-vps`, and `sm-vps-t1` if it is still registered), add one line to
the `.env` file in the runner's folder, then restart the runner service:

```
ACTIONS_RUNNER_HOOK_JOB_STARTED=/absolute/path/to/ops/runner-guard/refuse-fork-jobs.sh
```

Point it at a copy the runner's jobs can't overwrite: the ops checkout, not a job's `_work` folder.
The runner prints the hook's output in a "Set up runner" step at the top of every job.

## Cost and catch

- **Cost:** one `python3` start per job, about 50 ms, on every self-hosted job.
- **Catches:** a fork PR, or a stranger's comment, starting a job on the owner's VPS or Mac. That
  can't happen while the repo is private, so there is no past failure; the evidence is GitHub's own
  warning that self-hosted runners on public repos run fork code.
- **Waste signal:** none needed: it refuses nothing a collaborator does. If it ever refuses a
  same-repo job, that's a bug (the job fails at "Set up runner" with `Runner guard: refused`).

Tests: `python3 -m unittest discover -s ops/runner-guard` (also run by `--plan fast`).
