"""The required checks of the "protect main" ruleset, and how to start one that never ran on a head (#4867).

A check added to the ruleset's required set after a PR's head was pushed has no run on that head, so GitHub shows the
PR pending for a check nobody will schedule (#4843: six armed PRs held for an audit no job was going to run; #4666 sat
37 hours). Two callers read the one set kept here, so a new required check can't be added in only one place:

- scripts/dispatch_required_check.py <workflow> starts the workflow on every open PR head that has no run of it.
- scripts/merge_policy.py --start starts any dispatchable required workflow that has no run on the head it judges.

The set mirrors the ruleset (`gh api repos/Spoken-Margins/spoken-margins-native/rulesets/19241264`); a host test keeps
it equal to scripts/ci_model.py's SNAPSHOT of the required checks and to the jobs the workflow files really define.

Stdlib only: merge-policy.yml runs it with the runner's python3.
"""
from __future__ import annotations

# Required check name -> the workflow file whose job reports it.
REQUIRED_CHECKS = {
    'hosted fast: scope': 'hosted-portable.yml',
    'hosted fast: portable': 'hosted-portable.yml',
    'hosted fast: Mac rest': 'hosted-portable.yml',
    'hosted web: build and Playwright': 'hosted-web.yml',
    'merge policy': 'merge-policy.yml',
}

# A dispatchable workflow -> the dispatch inputs the dispatcher fills (`base` = the PR's base branch, so the run
# tests the head merged onto it and records that, as the lane runner's own re-dispatch did). A host test keeps this
# equal to each workflow's workflow_dispatch inputs.
DISPATCH_INPUTS = {
    'hosted-portable.yml': ('base',),
    'hosted-web.yml': (),
}

# A required workflow that can't be started this way, and why. merge-policy.yml takes a `pr` input but a check from
# its dispatch run does not satisfy the PR's required check (ci_model.py A4, merge-policy.yml:15-17); it runs on the
# PR's own opened/synchronize/labeled events instead.
NOT_DISPATCHABLE = {
    'merge-policy.yml': "a dispatched run doesn't satisfy a required check; it runs on the PR's own events "
                        '(push, or add and remove a label)',
}

NOT_FINISHED = ('queued', 'in_progress', 'waiting', 'requested', 'pending')

RUNNING = 'running'
RAN = 'ran'
NOT_STARTED = 'not started'
CANCELLED = 'cancelled'


def workflows() -> list[str]:
    """Every workflow that produces a required check."""
    return sorted(set(REQUIRED_CHECKS.values()))


def dispatchable() -> list[str]:
    return [workflow for workflow in workflows() if workflow not in NOT_DISPATCHABLE]


def checks_of(workflow: str) -> list[str]:
    return [name for name, file in REQUIRED_CHECKS.items() if file == workflow]


FAILED_JOB = ('failure', 'timed_out')


def head_state(runs: list[dict], jobs_of=None) -> str:
    """Where a workflow stands on one head, from its runs on that head (the Actions API's `workflow_runs`).

    running: a run is queued or in progress, so wait. ran: a run finished with a verdict (success, failure, skipped,
    timed out, anything but a cancel): a failure stays a failure and is not restarted. cancelled: every run was
    cancelled, which is no verdict, so start one. not started: no run at all, so start one.

    A run that ended `cancelled` can still hold a verdict: hosted-portable.yml's `stop-macs-on-red` cancels its own run
    when the `portable` job fails, so GitHub records the run as cancelled while `hosted fast: portable` stays red. With
    <jobs_of> (run id -> that run's jobs) a cancelled-only head whose jobs include a failure is `ran`, never restarted.
    """
    if not runs:
        return NOT_STARTED
    if any(run.get('status') in NOT_FINISHED for run in runs):
        return RUNNING
    if any(run.get('conclusion') != 'cancelled' for run in runs):
        return RAN
    if jobs_of and any(job.get('conclusion') in FAILED_JOB for run in runs for job in jobs_of(run.get('id'))):
        return RAN
    return CANCELLED


def needs_start(state: str, restart_cancelled: bool = False) -> bool:
    """Whether a head in <state> gets a run. A cancelled-only head is restarted only when asked: the sweep a person runs
    on purpose does, the merge policy (which runs again on every label change) doesn't, so a run an operator cancelled
    on purpose, or that a newer dispatch's concurrency group cancelled, is not started again behind their back."""
    return state == NOT_STARTED or (restart_cancelled and state == CANCELLED)


def missing(github, head: str, restart_cancelled: bool = False) -> list[str]:
    """The dispatchable required workflows with no run (or, with <restart_cancelled>, only cancelled runs) on <head>.

    Limit: this looks at workflows, not check names. A new job added to a workflow that already ran on a head has no
    check there and is not found; dispatch that workflow by hand (test-lane.md)."""
    return [workflow for workflow in dispatchable()
            if needs_start(head_state(github.workflow_runs(workflow, head), github.run_jobs), restart_cancelled)]


STALE_BRANCH_HINT = ('if the PR branch predates the workflow it has no such file to dispatch: push to it or merge main '
                     "into it, and the PR's own run starts")


def failure_hint(error: object) -> str:
    """Words to add to a failed dispatch. A 404 or 422 from the dispatches endpoint is what a branch that predates the
    workflow file (or its inputs) answers, which is the case a late-added required check is made of."""
    text = str(error)
    return f'; {STALE_BRANCH_HINT}' if ('404' in text or '422' in text) else ''


def inputs_for(workflow: str, base: str) -> dict[str, str]:
    return {name: base for name in DISPATCH_INPUTS[workflow] if name == 'base'}


def start(github, workflow: str, ref: str, base: str) -> None:
    """Start <workflow> on branch <ref>, whose tip is the PR's head, so its check runs report on that head."""
    github.dispatch(workflow, ref, inputs_for(workflow, base))
