#!/usr/bin/env python3
"""A timed, fault-injecting harness over the offline CI model (#4937): every combination, checked against invariants.

`scripts/ci_model.py` runs one PR through the real workflow files with every run finishing at once. That missed the
faults that reached live PRs on 2026-11-20..22 (#4929, #4849, #4888, #4752, #4735: `docs/workstreams/ci-model.md`
has the replay). This harness keeps ci_model's static model, expression evaluator and the repository's own decision
code (label bridge, dequeue notifier, merge policy, audit eligibility, dispatch backstop), and adds what was missing:

1. **Time.** Each job takes a duration (DURATIONS), its check is created when the job is queued and finishes later,
   and its decision code runs at the end of the job against the state at that moment.
2. **Concurrency groups as GitHub runs them** (G1-G3 in GITHUB_RULES): one running and one pending entry per group, a
   newer pending entry cancels the older one, `cancel-in-progress` cancels the running one. Runs created in the same
   instant enter their groups in an order GitHub does not promise (observed: PR #4898, 2026-11-22), so a scenario runs
   once with each order (`admission`).
3. **The newest check decides** (G4): a required check reads the newest check run of that name on the commit; a newer
   cancelled one blocks even when an older one passed (observed: #4929).
4. **Mac jobs as black boxes** (the owner's call, 2026-11-22): every job on a macOS runner can be scripted, per
   attempt, to pass, fail, hang to its `timeout-minutes` (which ends `cancelled`, G5), be cancelled, run past the
   queue's 120-minute timeout, or never get a runner.
5. **Faults outside the files:** an external download host down for a window, a write token answering 403, schedules
   dropped, and the VPS dispatch backstop on or off.
6. **Invariants** (`violations()`), checked on every combination of PR kind, arming pattern, fault and admission
   order (`sweep()`):
   - `merged-broken`: a defect a required check catches reached main;
   - `silent-stuck`: an armed PR did not merge and nothing told anyone (no `needs-fix` with a comment, no "not queued"
     comment, not waiting on the owner's tap);
   - `needs-person`: a fault that was not the PR's own (a runner hang, an outage that ended) left a clean PR needing a
     person to re-arm it;
   - `slow`: a clean PR with no fault, or a fault that clears, took longer than SLOW_MINUTES to merge;
   - `loop`: the PR went round the merge queue MAX_GROUPS times.
   KNOWN lists each violation the current tree is known to have, with its issue; `--check` fails on any violation not
   in it, and on a KNOWN entry that no longer happens (so the list cannot rot).

Run:
  .venv/bin/python scripts/ci_harness.py --check            # the gate: every combination, exit 1 on a new violation
  .venv/bin/python scripts/ci_harness.py --list             # every violation, grouped by class
  .venv/bin/python scripts/ci_harness.py --one sessionkit rearm-burst none reversed   # one combination's event log
  .venv/bin/python scripts/ci_harness.py --diff origin/main # violations that a branch adds or removes
  .venv/bin/python scripts/ci_harness.py --check-snapshot   # ci_model.SNAPSHOT's ruleset against the live one

`--diff <ref>` imports and runs that tree's scripts on your machine, so never point it at an untrusted branch.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import dataclasses
import heapq
import importlib.util
import io
import itertools
import json
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if 'ci_model' in sys.modules:
    M = sys.modules['ci_model']
else:
    _spec = importlib.util.spec_from_file_location('ci_model', SCRIPTS / 'ci_model.py')
    M = importlib.util.module_from_spec(_spec)
    sys.modules['ci_model'] = M  # dataclasses look the module up by name
    _spec.loader.exec_module(M)

ROOT = M.ROOT

# --- GitHub's rules this harness adds to ci_model.ASSUMPTIONS ------------------------------------------------------------

GITHUB_RULES = {
    'G1-group-one-running-one-pending': {
        'basis': 'documented',
        'text': 'A concurrency group holds at most one running and one pending run or job. A new entry cancels the '
                'pending one and waits; with cancel-in-progress it cancels the running one too and starts.',
        'source': 'docs.github.com "Control the concurrency of workflows and jobs"'},
    'G2-skipped-job-joins-no-group': {
        'basis': 'documented',
        'text': 'A job whose `if:` is false is skipped before it reaches its job-level group, so it replaces nothing; '
                'a workflow-level group is joined by every run the trigger starts, skipped jobs or not.',
        'source': 'stated in claude-audit.yml and merge-queue-label-bridge.yml job-level groups; docs on concurrency'},
    'G3-same-instant-order': {
        'basis': 'observed',
        'text': 'Runs created in the same second enter their group in either order: the newer run can be the one '
                'cancelled.',
        'source': 'PR #4898 re-arm 2026-11-22T03:04:41Z: merge-policy run 44978946430 succeeded and the newer run '
                  '44978946511 was cancelled (check runs on the PR head, read 2026-11-22)'},
    'G4-newest-check-decides': {
        'basis': 'observed',
        'text': 'A required check reads the newest check run of that name on the commit; a newer cancelled run blocks '
                'even when an older one passed, and re-running the cancelled one unblocks.',
        'source': '#4929: #4898, #4871, #4830 sat blocked with an older success and a newer cancelled run; a re-run of '
                  'the cancelled run (44978946511 attempt 2, 05:11Z) let #4898 into the queue'},
    'G5-timeout-is-cancelled': {
        'basis': 'observed',
        'text': 'A job stopped by its timeout-minutes ends with conclusion `cancelled`, not `timed_out`.',
        'source': '#4752 commit message: #4746 and #4684, "hosted fast: portable" at its 30-minute limit, 2026-11-20'},
    'G6-token-rerun-runs': {
        'basis': 'observed',
        'text': 'A re-run requested with GITHUB_TOKEN runs (ci_model A6 was inferred).',
        'source': 'merge-policy run 44986035608 attempt 2, triggering actor github-actions[bot], success, '
                  '2026-11-22T04:39:49Z'},
    'G7-api-check-runs-latest': {
        'basis': 'documented',
        'text': '`commits/<sha>/check-runs` returns the latest check run per name by default (filter=latest), which is '
                'what the audit and the dequeue notifier read.',
        'source': 'docs.github.com REST "List check runs for a Git reference", parameter filter'},
}

# --- durations and black boxes ---------------------------------------------------------------------------------------

# Minutes per job, from the step budgets and run histories quoted in the workflow headers; anything not listed takes
# DEFAULT_LINUX or DEFAULT_MAC. Only the order of magnitude matters: what the harness looks for is overlap.
DURATIONS = {
    ('hosted-portable.yml', 'scope'): 0.5,
    ('hosted-portable.yml', 'portable'): 25,
    ('hosted-portable.yml', 'mac-rest'): 30,
    ('hosted-portable.yml', 'app-compile'): 15,
    ('hosted-web.yml', 'changes'): 0.3,
    ('hosted-web.yml', 'web'): 12,
    ('merge-policy.yml', 'policy'): 0.4,
    ('merge-queue-label-bridge.yml', 'bridge'): 0.2,
    ('merge-queue-dequeued.yml', 'dequeued'): 0.3,
    ('claude-audit.yml', 'audit'): 12,
    ('signoff-check.yml', 'signoff'): 0.3,
    ('main-t3.yml', 't3'): 90,
    ('hosted-app-macos.yml', 'app'): 40,
}
DEFAULT_LINUX = 0.5
DEFAULT_MAC = 30
ADMIT = 0.001     # a run reaches its concurrency group this long after it is created
OUTCOMES = ('pass', 'fail', 'hang', 'cancel', 'slow', 'never')
SLOW_EXTRA = 150  # 'slow' runs this much longer: past the queue's 120-minute check timeout

# Jobs that fetch from a host outside GitHub at run time, with no cache that covers a cold start. An outage fault fails
# them while it lasts. Kept by hand from the audit of 2026-11-22 (#4937); test_ci_harness checks each job exists.
EXTERNAL_DOWNLOADS = {
    ('hosted-portable.yml', 'mac-rest'): 'download.onnxruntime.ai (SwiftPM binary targets), Homebrew casks, Git LFS',
    ('hosted-portable.yml', 'app-compile'): 'download.onnxruntime.ai (SwiftPM binary targets), Git LFS',
    ('hosted-portable.yml', 'portable'): 'PyPI, github.com (Caddy), Docker Hub (swift image)',
    ('hosted-web.yml', 'web'): 'Playwright CDN, Hugging Face (speech model)',
    ('main-t3.yml', 't3'): 'download.onnxruntime.ai, Homebrew (xcodegen), Git LFS',
    ('hosted-app-macos.yml', 'app'): 'download.onnxruntime.ai, Homebrew casks, Git LFS',
}

SLOW_MINUTES = 240
HORIZON = 24 * 60


@dataclasses.dataclass
class Case(M.Scenario):
    """A ci_model scenario plus the faults and orderings the harness adds."""
    mac: tuple = ()                   # per-attempt outcomes for every macOS job, e.g. ('hang', 'pass')
    jobs: dict = dataclasses.field(default_factory=dict)  # (workflow, job) -> per-attempt outcomes
    outage: tuple | None = None       # (start minute, end minute) when EXTERNAL_DOWNLOADS hosts fail
    token_403: frozenset = frozenset()  # secret names whose writes answer 403
    token_401: frozenset = frozenset()  # secret names that are expired or revoked: every call answers 401
    admission: str = 'created'        # 'created' | 'reversed': the order same-instant runs enter a group
    backstop: bool = True             # the VPS dispatch backstop (ops/dispatch-backstop) runs every 15 minutes
    owner_tap_at: int | None = None   # when the owner adds `owner-tap` (an owner-tap PR)
    expect: str = 'merge'             # 'merge' | 'told': what a correct pipeline does with this case
    transient: bool = False           # the fault clears by itself, so a person should not be needed


class TimedWorld(M.World):
    """ci_model.World with runs that take time, concurrency groups, black-box Mac jobs and injected faults."""

    def __init__(self, case: Case, tree):
        super().__init__(case, tree)
        self.c = case
        self.check_ids = itertools.count(1)
        self.rows: list[dict] = []          # every check run: id, name, file, sha, event, status, conclusion, run
        self.group_running: dict[str, dict] = {}
        self.group_pending: dict[str, dict] = {}
        self.attempts: dict[tuple, int] = {}
        self.mac_jobs = 0
        self.behaviours = {**M.BEHAVIOURS, ('rerun-cancelled.yml', 'rerun'): b_rerun_cancelled}
        if case.schedule_mode == 'dropped':
            self.s.schedule_mode = 'dropped'

    # ci_model's World keeps one check per (name, workflow); here every check run is a row, and `checks` is the view
    # the Actions API gives (the latest per name, G7).
    @property
    def checks(self):
        view: dict[str, dict] = {}
        for row in sorted(self.rows, key=lambda r: r['id']):
            view.setdefault(row['sha'], {})[(row['name'], row['file'])] = {
                'name': row['name'], 'conclusion': row['conclusion'], 'run': row['run'], 'event': row['event'],
                'status': row['status']}
        return view

    @checks.setter
    def checks(self, value):
        pass

    # events: (minute, tie, id); `admit` events break ties by the scenario's admission order (G3)
    def post(self, at, kind, cause=None, tie=0, **payload):
        event = {'id': next(self.seq), 'at': at, 'kind': kind, 'cause': cause, **payload}
        self.events[event['id']] = event
        heapq.heappush(self.queue, (at, tie, event['id'], event))
        return event

    def seed_schedules(self):
        if self.s.schedule_mode != 'dropped':
            super().seed_schedules()
        if self.c.backstop:
            for at in range(7, self.s.horizon + 1, 15):
                self.post(at, 'backstop', None)

    def simulate(self) -> dict:
        self.seed_schedules()
        for minute, *action in self.s.steps:
            self.post(minute, 'action', None, action=tuple(action))
        for minute, paths, defects in self.s.pushes:
            self.post(minute, 'action', None, action=('push', paths, defects))
        if self.c.owner_tap_at is not None:
            self.post(self.c.owner_tap_at, 'action', None, action=('label', 'owner-tap', 'user'))
        self.post(0, 'pr', None, action='opened', label=None, token='user')
        while self.queue:
            at, _, _, event = heapq.heappop(self.queue)
            if at > self.s.horizon:
                break
            if self.merged_at is not None and event['kind'] in ('schedule', 'backstop') \
                    and event.get('workflow') != 'main-t3.yml':
                continue
            self.step(event)
            if len(self.log) > 4000:
                self.note(None, 'log limit reached; the harness stops this case')
                break
        return self.outcome()

    # the API views the repository's decision code reads
    def run_status(self, run) -> str:
        return 'completed' if run.get('status') in ('completed', 'cancelled') else 'in_progress'

    def bridge_github(self, job, cause):
        world = self
        secret = job['token'][len('secret:'):] if job['token'].startswith('secret:') else None

        expired = bool(secret and secret in world.c.token_401)
        refused = expired or bool(secret and secret in world.c.token_403)
        module = world.tree.module('bridge', 'scripts/merge_queue_label_bridge.py')
        # The script's own fallback policy: which kinds of call it retries with the workflow's GITHUB_TOKEN, and only
        # if the workflow passes that token. A tree from before FALLBACK_KINDS fell back for comments alone.
        passes_fallback = 'FALLBACK_GH_TOKEN' in world.tree.yaml_text('merge-queue-label-bridge.yml')
        kinds = set(getattr(module, 'FALLBACK_KINDS', {'comment'})) if passes_fallback else set()

        def gate(kind, what):
            """Raise the script's Failed when the token is refused for this call and the script does not fall back."""
            if not (expired if kind in ('read', 'label') else refused):
                return
            if kind in kinds:
                world.note(cause, f'bridge: {what} with the fallback GITHUB_TOKEN')
                return
            code = 401 if expired else 403
            world.note(cause, f'bridge: {what} refused, HTTP {code} ({secret})')
            raise module.Failed(f'HTTP {code}')

        class Bridge(M.FakeBridgeGitHub):
            def pull(self, number):
                gate('read', 'PR read')
                return super().pull(number)

            def open_pulls(self):
                gate('read', 'PR list read')
                return super().open_pulls()

            def comments(self, number):
                gate('read', 'comments read')
                return super().comments(number)

            def remove_label(self, number, name):
                gate('label', f'`{name}` removal')
                return super().remove_label(number, name)

            def merge(self, number):
                if refused:
                    code = 401 if expired else 403
                    world.note(cause, f'bridge: `gh pr merge` refused, HTTP {code} ({secret})')
                    return 1, f'HTTP {code}: ' + ('Bad credentials' if expired else
                                                   'Resource not accessible by personal access token')
                return super().merge(number)

            def comment(self, number, body):
                gate('comment', 'comment')
                return super().comment(number, body)
        return Bridge(self, job['token'], cause)

    def red_on_head(self) -> list[str]:
        """Required checks whose newest run on the PR head failed (not cancelled): a red X the author and the hourly
        dispatcher's red-check sweep see. A cancelled newest run shows grey and nobody's sweep reads it."""
        red = []
        for name in M.SNAPSHOT['ruleset']['required_checks']:
            rows = [r for r in self.rows if r['sha'] == self.head and r['name'] == name and r['event'] == 'pull_request']
            if rows and max(rows, key=lambda r: r['id'])['conclusion'] in ('failure', 'timed_out'):
                red.append(name)
        return red

    # required checks (G4)
    def required_state(self, sha):
        missing, failed = [], []
        for name in M.SNAPSHOT['ruleset']['required_checks']:
            rows = [r for r in self.rows if r['sha'] == sha and r['name'] == name
                    and r['event'] in ('pull_request', 'merge_group')]
            if not rows:
                missing.append(name)
                continue
            newest = max(rows, key=lambda r: r['id'])
            if newest['status'] != 'completed':
                missing.append(name)
            elif newest['conclusion'] not in ('success', 'skipped', 'neutral'):
                failed.append(name)
        if failed:
            return 'failed', failed
        if missing:
            return 'missing', missing
        return 'ok', []

    # runs
    def context(self, file, event_name, payload):
        ctx = {'github': {'event_name': event_name, 'event': payload, 'repository': M.REPO,
                          'ref_name': 'main', 'ref': 'refs/heads/main', 'token': 'github_token',
                          'run_attempt': '1'},
               'vars': M.SNAPSHOT['variables'], 'inputs': payload.get('inputs') or {}, 'needs': {}}
        if event_name == 'merge_group':
            ctx['github']['ref'] = f'refs/heads/gh-readonly-queue/main/pr-1-{payload["merge_group"]["head_sha"][:7]}'
            ctx['github']['ref_name'] = ctx['github']['ref'][len('refs/heads/'):]
        elif event_name in ('pull_request', 'pull_request_target'):
            ctx['github']['ref'] = 'refs/pull/1/merge'
            ctx['github']['ref_name'] = '1/merge'
        return ctx

    def run_workflow(self, file, event_name, payload, cause_event, rerun_of=None):
        wf = self.tree.model['workflows'][file]
        ctx = self.context(file, event_name, payload)
        sha = {'pull_request': self.head, 'merge_group': payload.get('merge_group', {}).get('head_sha')}.get(
            event_name, 'main')
        run = {'id': len(self.runs) + 1, 'workflow': file, 'event': event_name, 'payload': payload, 'sha': sha,
               'jobs': {}, 'cause': cause_event['id'], 'rerun_of': rerun_of, 'status': 'queued', 'ctx': ctx,
               'rows': {}, 'state': {}, 'created_at': self.now,
               'attempt': self.runs[rerun_of - 1].get('attempt', 1) + 1 if rerun_of else 1}
        self.runs.append(run)
        for job_id, job in wf['jobs'].items():
            if not job['needs']:
                self.queue_row(run, job_id)
        group = self.group_of(wf.get('concurrency'), ctx)
        if group:
            self.post(self.now + ADMIT, 'admit', cause_event['id'], tie=self.tie(run['id']), run=run['id'],
                      job=None, group=group[0], cancel=group[1])
        else:
            self.start_run(run)
        return run

    def triggered(self, event):
        out = super().triggered(event)
        if event['kind'] == 'workflow_run':
            for _, _, payload in out:
                payload['workflow_run']['id'] = event.get('run_id')
        return out

    def tie(self, run_id):
        return run_id if self.c.admission == 'created' else -run_id

    def group_of(self, spec, ctx):
        if not spec:
            return None
        if isinstance(spec, str):
            return M.render(spec, ctx), False
        return M.render(spec.get('group', ''), ctx), bool(spec.get('cancel-in-progress'))

    def queue_row(self, run, job_id):
        job = self.tree.model['workflows'][run['workflow']]['jobs'][job_id]
        row = {'id': next(self.check_ids), 'name': job['check'], 'file': run['workflow'], 'job': job_id,
               'sha': run['sha'], 'event': run['event'], 'status': 'queued', 'conclusion': None, 'run': run['id']}
        if run['sha']:
            self.rows.append(row)
        run['rows'][job_id] = row
        return row

    def start_run(self, run):
        if run['status'] == 'cancelled':
            return
        run['status'] = 'in_progress'
        for job_id, job in self.tree.model['workflows'][run['workflow']]['jobs'].items():
            if not job['needs']:
                self.job_ready(run, job_id)

    def job_ready(self, run, job_id):
        wf = self.tree.model['workflows'][run['workflow']]
        job = wf['jobs'][job_id]
        ctx = run['ctx']
        results = run['jobs']
        ctx['needs'] = {n: {'result': results[n]['result'], 'outputs': results[n]['outputs']} for n in job['needs']}
        row = run['rows'].get(job_id) or self.queue_row(run, job_id)
        try:
            go = M.condition(job['if'], ctx, [results[n]['result'] for n in job['needs']])
        except ValueError as error:
            self.note(None, f'{run["workflow"]} {job_id}: could not evaluate `if:` ({error}); treated as true')
            go = True
        if not go:
            self.finish_job(run, job_id, 'skipped', {})
            return
        group = self.group_of(job.get('concurrency'), ctx)
        if group:  # G2: only a job that will run joins its group
            self.post(self.now + ADMIT, 'admit', None, tie=self.tie(run['id']), run=run['id'], job=job_id,
                      group=group[0], cancel=group[1])
        else:
            self.begin_job(run, job_id)

    def raw_job(self, file, job_id):
        cache = self.tree.__dict__.setdefault('_raw_jobs', {})
        if file not in cache:
            cache[file] = self.tree.raw(file).get('jobs', {}) or {}
        return cache[file].get(job_id) or {}

    def is_mac(self, file, job_id):
        runs_on = str(self.raw_job(file, job_id).get('runs-on', ''))
        return 'xcode' in runs_on or 'macos' in runs_on

    def timeout(self, file, job_id):
        return float(self.raw_job(file, job_id).get('timeout-minutes', 360))

    def outcome_for(self, file, job_id):
        key = (file, job_id)
        n = self.attempts.get(key, 0)
        self.attempts[key] = n + 1
        plan = self.c.jobs.get(key) or (self.c.mac if self.is_mac(file, job_id) else ())
        outcome = plan[n] if n < len(plan) else (plan[-1] if plan and plan[-1] in ('never',) else 'pass')
        if self.c.outage and key in EXTERNAL_DOWNLOADS and self.c.outage[0] <= self.now < self.c.outage[1]:
            outcome = 'fail'
        return outcome

    def begin_job(self, run, job_id):
        if run['status'] == 'cancelled':
            return
        file = run['workflow']
        row = run['rows'][job_id]
        row['status'] = 'in_progress'
        run['state'][job_id] = 'running'
        mac = self.is_mac(file, job_id)
        if mac:
            self.mac_jobs += 1
        base = DURATIONS.get((file, job_id), DEFAULT_MAC if mac else DEFAULT_LINUX)
        outcome = self.outcome_for(file, job_id)
        if outcome == 'never':
            self.note(None, f'{file} {job_id}: no runner picks it up')
            return
        minutes = {'hang': self.timeout(file, job_id), 'cancel': base / 2, 'slow': base + SLOW_EXTRA}.get(outcome, base)
        if outcome != 'pass':
            self.note(None, f'{file} {job_id} ({run["event"]}): black box says {outcome}, ends in {minutes:g}m')
        self.post(self.now + minutes, 'job_end', None, run=run['id'], job=job_id, outcome=outcome)

    def job_end(self, event):
        run = self.runs[event['run'] - 1]
        job_id = event['job']
        if run['status'] == 'cancelled' or run['state'].get(job_id) != 'running':
            return
        file = run['workflow']
        wf = self.tree.model['workflows'][file]
        job = wf['jobs'][job_id]
        outcome = event['outcome']
        if outcome in ('hang', 'cancel'):  # G5
            self.finish_job(run, job_id, 'cancelled', {})
            return
        if outcome == 'fail':
            self.finish_job(run, job_id, 'failure', {})
            return
        result, outputs = 'success', {}
        behaviour = self.behaviours.get((file, job_id))
        if behaviour:
            result, outputs = behaviour(self, run, job, run['ctx'], self.events[run['cause']])
        if self.defects & M.DEFECT_CATCHERS.get((file, job_id), set()):
            result = 'failure'
        self.finish_job(run, job_id, result, outputs)

    def finish_job(self, run, job_id, result, outputs):
        row = run['rows'].get(job_id)
        if row and outputs.get('check') == 'pending':  # the job succeeded and left its check run in progress (#4986)
            row['status'], row['conclusion'] = 'in_progress', None
        elif row:
            row['status'], row['conclusion'] = 'completed', result
        run['jobs'][job_id] = {'result': result, 'outputs': outputs}
        run['state'][job_id] = 'done'
        self.free(('job', run['id'], job_id))
        wf = self.tree.model['workflows'][run['workflow']]
        for other, job in wf['jobs'].items():
            if other not in run['state'] and job['needs'] and all(n in run['jobs'] for n in job['needs']):
                run['state'][other] = 'ready'
                self.job_ready(run, other)
        if all(j in run['jobs'] for j in wf['jobs']):
            self.finish_run(run)

    def finish_run(self, run, cancelled=False):
        if run['status'] in ('completed', 'cancelled'):
            return
        ran = [r['result'] for r in run['jobs'].values() if r['result'] != 'skipped']
        conclusion = 'cancelled' if cancelled else (
            'skipped' if not ran else 'failure' if 'failure' in ran else 'cancelled' if 'cancelled' in ran
            else 'success')
        run['status'] = 'cancelled' if cancelled else 'completed'
        run['conclusion'] = conclusion
        self.free(('run', run['id'], None))
        file = run['workflow']
        wf = self.tree.model['workflows'][file]
        if conclusion not in ('skipped',) or file in {k[0] for k in self.behaviours}:
            self.note(self.events.get(run['cause']), f'{file} ({run["event"]}) {conclusion}: ' + ', '.join(
                f'{j}={r["result"]}' for j, r in run['jobs'].items()))
        self.post(self.now, 'workflow_run', run['cause'], name=wf['name'], conclusion=conclusion,
                  run_event=run['event'], token='github', run_id=run['id'])
        if file == 'hosted-app-macos.yml' and run['event'] == 'push' and conclusion == 'failure':
            self.main_broken_by = self.main_broken_by or {'detected_by': file, 'at': self.now}
        if file == 'main-t3.yml' and conclusion == 'failure' and self.merged_at is not None:
            self.main_broken_by = self.main_broken_by or {'detected_by': file, 'at': self.now}

    def cancel_run(self, run, why):
        if run['status'] in ('completed', 'cancelled'):
            return
        self.note(None, f'{run["workflow"]} ({run["event"]}) run {run["id"]} cancelled: {why}')
        wf = self.tree.model['workflows'][run['workflow']]
        for job_id in wf['jobs']:
            if job_id in run['jobs']:
                continue
            row = run['rows'].get(job_id)
            if row:
                row['status'], row['conclusion'] = 'completed', 'cancelled'
            run['jobs'][job_id] = {'result': 'cancelled', 'outputs': {}}
            run['state'][job_id] = 'done'
            self.free(('job', run['id'], job_id))
        self.finish_run(run, cancelled=True)

    def cancel_job(self, run, job_id, why):
        if run['state'].get(job_id) == 'done':
            return
        self.note(None, f'{run["workflow"]} {job_id} (run {run["id"]}) cancelled: {why}')
        self.finish_job(run, job_id, 'cancelled', {})

    # concurrency groups (G1)
    def unit_cancel(self, unit, why):
        kind, run_id, job_id = unit
        run = self.runs[run_id - 1]
        if kind == 'run':
            self.cancel_run(run, why)
        else:
            self.cancel_job(run, job_id, why)

    def unit_start(self, unit):
        kind, run_id, job_id = unit
        run = self.runs[run_id - 1]
        if kind == 'run':
            self.start_run(run)
        else:
            self.begin_job(run, job_id)

    def admit(self, event):
        unit = ('job' if event['job'] else 'run', event['run'], event['job'])
        run = self.runs[event['run'] - 1]
        if run['status'] == 'cancelled':
            return
        group = event['group']
        running, pending = self.group_running.get(group), self.group_pending.get(group)
        if pending:
            self.group_pending.pop(group)
            self.unit_cancel(pending, f'replaced in group {group} by run {event["run"]}')
        if running and event['cancel']:
            self.group_running.pop(group, None)
            self.unit_cancel(running, f'cancel-in-progress in group {group} (run {event["run"]})')
            running = None
        if running:
            self.group_pending[group] = unit
            return
        self.group_running[group] = unit
        self.unit_start(unit)

    def free(self, unit):
        for group, held in list(self.group_running.items()):
            if held == unit:
                del self.group_running[group]
                nxt = self.group_pending.pop(group, None)
                if nxt:
                    self.group_running[group] = nxt
                    self.unit_start(nxt)
        for group, held in list(self.group_pending.items()):
            if held == unit:
                del self.group_pending[group]

    # the VPS dispatch backstop, with the tree's own decision code
    def backstop_tick(self, event):
        path = self.tree.root / 'ops/dispatch-backstop/sm_dispatch_backstop.py'
        if not path.is_file():
            return
        backstop = self.tree.module('backstop', 'ops/dispatch-backstop/sm_dispatch_backstop.py')
        minute = self.now

        def stamp(at):
            whole = int(at)
            return f'2026-11-20T{10 + whole // 60 % 14:02d}:{whole % 60:02d}:00Z' if at < 14 * 60 else \
                f'2026-11-21T{(10 + whole // 60) % 24:02d}:{whole % 60:02d}:00Z'

        def fake_get(method, path, token, body=None):
            workflow = path.split('/workflows/')[1].split('/')[0]
            if method == 'POST':
                self.post(self.now, 'workflow_dispatch', event['id'], workflow=workflow, inputs={}, token='user')
                return None
            runs = [r for r in reversed(self.runs) if r['workflow'] == workflow]
            done = ('completed', 'cancelled')
            return {'workflow_runs': [{'created_at': stamp(r.get('created_at', 0)), 'event': r['event'],
                                       'status': 'completed' if r.get('status') in done else 'in_progress',
                                       'conclusion': r.get('conclusion') if r.get('status') in done else None}
                                      for r in runs[:30]]}
        import datetime as dt
        now = dt.datetime.strptime(stamp(minute), '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
        out = io.StringIO()
        if 'backstop' in self.c.token_403:
            self.note(event, 'backstop: every dispatch refused, HTTP 403')
            return
        backstop.tick('token', now, out=out, get=fake_get)
        fired = [line for line in out.getvalue().splitlines() if 'dispatched' in line]
        if fired:
            self.note(event, 'backstop: ' + ' | '.join(fired))

    def step(self, event):
        self.now = event['at']
        kind = event['kind']
        if kind == 'admit':
            self.admit(event)
        elif kind == 'job_end':
            self.job_end(event)
        elif kind == 'backstop':
            self.backstop_tick(event)
        elif kind == 'action' and event['action'][0] == 'unlabel':
            self.change_label(self.now, event['action'][1], False, event['action'][2], event['id'])
            return
        else:
            super().step(event)
            return
        if self.in_queue:
            self.group_verdict(event)
        self.github_tick(event)


class FakeRerunGitHub:
    """rerun_cancelled_check.GitHub against the timed world."""

    def __init__(self, world, cause):
        self.w, self.cause = world, cause

    def get(self, path):
        w = self.w
        if path.startswith('actions/runs/'):
            r = w.runs[int(path.split('/')[2]) - 1]
            return {'id': r['id'], 'name': w.tree.model['workflows'][r['workflow']]['name'], 'event': r['event'],
                    'conclusion': r.get('conclusion'), 'run_attempt': r.get('attempt', 1), 'head_sha': r['sha'],
                    'pull_requests': [{'number': 1}] if r['event'] == 'pull_request' else []}
        if path.startswith('pulls/'):
            return {'number': 1, 'state': 'open' if w.merged_at is None else 'closed', 'draft': False,
                    'head': {'sha': w.head}, 'labels': [{'name': n} for n in sorted(w.labels)]}
        if path.startswith('commits/'):
            sha = path.split('/')[1]
            return {'check_runs': [{'id': row['id'], 'name': row['name'], 'conclusion': row['conclusion'],
                                    'details_url': f'https://github.com/{M.REPO}/actions/runs/{row["run"]}/job/1'}
                                   for row in w.rows if row['sha'] == sha]}
        raise KeyError(path)

    def rerun(self, run_id):
        self.w.post(self.w.now, 'rerun', self.cause['id'], run=run_id, token='github_token')


def b_rerun_cancelled(world, run, job, ctx, cause):
    """rerun-cancelled.yml: the tree's scripts/rerun_cancelled_check.py against the timed world."""
    if not (world.tree.root / 'scripts/rerun_cancelled_check.py').is_file():
        return 'success', {}
    module = world.tree.module('rerun_cancelled_check', 'scripts/rerun_cancelled_check.py')
    out = io.StringIO()
    module.main(['--repo', M.REPO, '--run-id', str(ctx['github']['event']['workflow_run']['id'])],
                github=FakeRerunGitHub(world, cause), out=out)
    world.note(cause, 'rerun-cancelled: ' + out.getvalue().strip())
    return 'success', {}


def simulate(case: Case, tree) -> dict:
    world = TimedWorld(copy.deepcopy(case), tree)
    with contextlib.redirect_stdout(io.StringIO()):
        result = world.simulate()
    result['log'] = [f'{e["at"]:g}m {e["text"]}' for e in world.log]
    result['mac_jobs'] = world.mac_jobs
    result['red_on_head'] = world.red_on_head()
    result['comments'] = [c['body'] for c in world.comments]
    return result


# --- the combinations ------------------------------------------------------------------------------------------------

KINDS = {
    'docs': ['docs/contributing/example.md'],
    'lane-script': ['scripts/lane_dedupe.py'],
    'sessionkit': ['Packages/SessionKit/Sources/SessionKit/Example.swift'],
    'app-audio': ['App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackExample.swift'],
    'web': ['Web/src/example.ts'],
    'workflow': ['.github/workflows/example.yml'],
}
ARMINGS = {
    'person': dict(steps=[(1, 'label', 'automerge', 'user')]),
    'at-open': dict(steps=[(0, 'label', 'automerge', 'user')]),
    'token': dict(steps=[(1, 'label', 'automerge', 'github_token')]),
    # A re-arm after a failed group: `needs-fix` comes off and `automerge` goes on in the same second (#4929).
    'rearm-burst': dict(labels={'needs-fix'}, steps=[(1, 'unlabel', 'needs-fix', 'user'),
                                                     (1, 'label', 'automerge', 'user')]),
    # An agent arms, notices something, takes it off and arms again within the minute.
    'flip': dict(steps=[(1, 'label', 'automerge', 'user'), (1, 'unlabel', 'automerge', 'user'),
                        (1, 'label', 'automerge', 'user')]),
}
FAULTS = {
    'none': dict(),
    'mac-fail-once': dict(mac=('fail', 'pass'), transient=True),
    'mac-hang-once': dict(mac=('hang', 'pass'), transient=True),
    'mac-cancel-once': dict(mac=('cancel', 'pass'), transient=True),
    'mac-slow-once': dict(mac=('slow', 'pass'), transient=True),
    'mac-fail-always': dict(mac=('fail',) * 20, expect='told'),
    'mac-no-runner': dict(mac=('never',), expect='told'),
    'outage-90m': dict(outage=(0, 90), transient=True),
    'bridge-token-403': dict(token_403=frozenset({'MERGE_QUEUE_TOKEN'}), expect='told'),
    # #4942's audit: an expired token is refused on reads too, not only on `gh pr merge` and the comment.
    'bridge-token-expired': dict(token_401=frozenset({'MERGE_QUEUE_TOKEN'}), expect='told'),
    'portable-timeout-once': dict(jobs={('hosted-portable.yml', 'portable'): ('hang', 'pass')}, transient=True),
    'schedules-dropped': dict(schedule_mode='dropped', backstop=False),
    'backstop-off': dict(backstop=False),
    'schedules-dropped-backstop': dict(schedule_mode='dropped', backstop=True),
    'schedules-dropped-backstop-403': dict(schedule_mode='dropped', backstop=True,
                                           token_403=frozenset({'backstop'})),
}
MAC_KINDS = {'sessionkit', 'app-audio', 'web'}
BURSTS = {'rearm-burst', 'flip'}


def case(kind: str, arming: str, fault: str, admission: str = 'created') -> Case:
    spec = {**ARMINGS[arming], **FAULTS[fault]}
    labels = set(spec.pop('labels', set()))
    steps = list(spec.pop('steps'))
    owner_tap_at = 120 if kind == 'workflow' else None
    return Case(name=f'{kind}/{arming}/{fault}/{admission}', description='', paths=list(KINDS[kind]), steps=steps,
                labels=labels, admission=admission, owner_tap_at=owner_tap_at, horizon=HORIZON, **spec)


def combinations():
    """Every case worth running: Mac faults only where a Mac job runs, both orders only for same-instant bursts."""
    for kind in KINDS:
        for arming in ARMINGS:
            for fault in FAULTS:
                if fault.startswith('mac-') and kind not in MAC_KINDS:
                    continue
                if fault.startswith(('outage', 'portable')) and kind == 'docs':
                    continue
                if fault.startswith('schedules') and arming != 'token' and kind not in ('lane-script', 'app-audio'):
                    continue
                for admission in (('created', 'reversed') if arming in BURSTS else ('created',)):
                    yield case(kind, arming, fault, admission)


def told(result) -> bool:
    """Someone can see why the PR is not merging: the dequeue notifier's or the bridge's comment, `needs-fix`, or a
    red required check on the PR head."""
    words = ('Left the merge queue', 'Not queued', 'could not queue', 'could not be queued', 'still set to merge',
             'not queued')
    return 'needs-fix' in result['labels'] or bool(result.get('red_on_head')) or \
        any(w in c for c in result['comments'] for w in words)


def violations(c: Case, result: dict, tree) -> list[str]:
    out = []
    caught = set()
    for (file, job_id), defects in M.DEFECT_CATCHERS.items():
        check = tree.model['workflows'].get(file, {}).get('jobs', {}).get(job_id, {}).get('check')
        if check in M.SNAPSHOT['ruleset']['required_checks']:
            caught |= defects
    if result['merged'] and c.defects & caught:
        out.append('merged-broken')
    if result['merge_groups'] >= M.MAX_GROUPS:
        out.append('loop')
    if result['merged']:
        if c.expect == 'merge' and result['merged_at_minute'] > SLOW_MINUTES + (c.owner_tap_at or 0):
            out.append('slow')
        return out
    if c.expect == 'told' or (c.defects & caught):
        if not told(result):
            out.append('silent-stuck')
        return out
    out.append('needs-person' if told(result) else 'silent-stuck')
    return out


# Violations the current tree has, each with its issue. `--check` fails on one not listed here, and on a listed one
# that no longer happens. Keys are fnmatch patterns over '<kind>/<arming>/<fault>/<admission>: <violation>'.
KNOWN = {
    # A merge group that fails for a reason outside the PR (a Mac job that fails once, a download host down for an
    # hour) is held as the PR's failure: `needs-fix`, `automerge` off, and a person re-arms each PR. Telling a flake
    # from a real failure needs the failing step; until then caches remove the outages (EXTERNAL_DOWNLOADS lists the
    # jobs still exposed).
    '*/outage-90m/*: needs-person': '#4940',
    '*/mac-fail-once/*: needs-person': '#4940',
    # A hosted Mac job that never gets a runner leaves its check queued; GitHub cancels it after 24 hours and the
    # merge-stall watch (not modelled) opens its issue after an hour. The pool is GitHub's.
    'web/*/mac-no-runner/*: silent-stuck': 'GitHub-hosted runner pool; merge-stall watch',
    # A PR armed by a token-made label is queued only by the bridge's sweep, which only the VPS backstop starts in
    # time. With the backstop down or every token it has refused, the PR waits for GitHub's daily tick. Nothing on the
    # PR says so; the coordinator's wake sweep (scripts/sm_sweep.py rule 15) reports the missing bridge runs instead.
    '*/token/schedules-dropped/*: silent-stuck': '#4866',
    '*/token/schedules-dropped-backstop-403/*: silent-stuck': '#4866',
    '*/token/backstop-off/*: slow': '#4866',
    # A Mac job that waits more than two hours for a runner on a PR merges late; capacity, not orchestration.
    'web/*/mac-slow-once/*: slow': 'GitHub-hosted runner pool',
}


# --- static rules: classes of fault that need no simulation --------------------------------------------------------

EVENT_VARYING = ('github.event.label', 'github.event.action', 'labels.*', 'github.event.changes')


def static_findings(tree) -> list[str]:
    """Faults of a kind already seen live, read straight from the workflow files.

    S1 (#4734's audit, lane-conflicts.yml and owner-tap-alert.yml on 2026-11-22): a workflow-level concurrency group
       on a workflow whose every first job can be skipped by a condition on the event's label or action. Every run
       the trigger starts joins the group, so a run that will skip everything replaces the pending run that does the
       work (G1, G2). Put the group on the job.
    S2 (hosted-web.yml on 2026-11-22): a job reporting a required check that is skipped when a job it needs did not
       succeed, where that job's own check is not required. A skipped job reports success, so a fault in the
       unrequired job lets the change merge untested.
    S3 (scripts/required_checks.py on 2026-11-22): a required check in the snapshot that no job reports, so every
       PR would wait for it until the queue's timeout.
    """
    out = []
    required = set(M.SNAPSHOT['ruleset']['required_checks'])
    reported = set()
    for file, wf in sorted(tree.model['workflows'].items()):
        jobs = wf['jobs']
        roots = [j for j in jobs.values() if not j['needs']]
        if wf.get('concurrency') and roots and all(j['if'] and any(k in j['if'] for k in EVENT_VARYING)
                                                    for j in roots):
            out.append(f'S1 {file}: workflow-level concurrency, but every first job skips on the event\'s label or '
                       f'action; a skipped run can replace a pending one. Move the group onto the job.')
        for job in jobs.values():
            reported.add(job['check'])
            if job['check'] not in required or not job['if']:
                continue
            for need in job['needs']:
                if f'needs.{need}.result == \'success\'' in job['if'] and jobs[need]['check'] not in required:
                    out.append(f'S2 {file} {job["id"]}: "{job["check"]}" is required but is skipped (= passes) when '
                               f'`{need}` fails, and "{jobs[need]["check"]}" is not required.')
    for name in sorted(required - reported):
        out.append(f'S3 required check "{name}" is reported by no job in .github/workflows')
    return out


def sweep(tree, only=None) -> dict[str, list[str]]:
    found = {}
    for c in combinations():
        if only and not all(part in c.name.split('/') for part in only):
            continue
        result = simulate(c, tree)
        v = violations(c, result, tree)
        if v:
            found[c.name] = v
    return found


def known_match(name, violation):
    import fnmatch
    return next((pattern for pattern in KNOWN if fnmatch.fnmatch(f'{name}: {violation}', pattern)), None)


def check(tree, out=sys.stdout) -> int:
    static = static_findings(tree)
    for line in static:
        print(f'  STATIC {line}', file=out)
    found = sweep(tree)
    total = sum(1 for _ in combinations())
    new, used = [], set()
    for name, vs in found.items():
        for v in vs:
            pattern = known_match(name, v)
            if pattern:
                used.add(pattern)
            else:
                new.append(f'{name}: {v}')
    stale = [p for p in KNOWN if p not in used]
    print(f'CI harness: {total} combinations, {sum(len(v) for v in found.values())} violations, '
          f'{len(new)} not in KNOWN, {len(stale)} KNOWN entries no longer seen', file=out)
    for line in new:
        print(f'  NEW {line}', file=out)
    for pattern in stale:
        print(f'  GONE {pattern}  ({KNOWN[pattern]}): remove it from KNOWN', file=out)
    return 1 if new or stale or static else 0


def grouped(found) -> dict[str, list[str]]:
    by = {}
    for name, vs in found.items():
        for v in vs:
            by.setdefault(v, []).append(name)
    return by


# --- diff and snapshot -----------------------------------------------------------------------------------------------

def diff(base: str, head: str | None, out=sys.stdout) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        old_tree = M.Tree(M.unpack(base, Path(tmp) / 'base'))
        new_tree = M.Tree(M.unpack(head, Path(tmp) / 'head') if head else ROOT)
        old, new = sweep(old_tree), sweep(new_tree)
    def flat(found):
        return {f'{n}: {v}' for n, vs in found.items() for v in vs}
    gone, added = sorted(flat(old) - flat(new)), sorted(flat(new) - flat(old))
    print(f'CI harness diff: {base} -> {head or "working tree"}: {len(added)} new violations, {len(gone)} fixed',
          file=out)
    for line in added:
        print(f'  + {line}', file=out)
    for line in gone:
        print(f'  - {line}', file=out)
    return 0


def check_snapshot(out=sys.stdout) -> int:
    """Compare ci_model.SNAPSHOT's ruleset with the live one (public repo: no token needed)."""
    ruleset = M.SNAPSHOT['ruleset']
    url = f'https://api.github.com/repos/{M.REPO}/rulesets/{ruleset["id"]}'
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'ci-harness'}), timeout=30) as r:
        live = json.loads(r.read())
    problems = []
    for rule in live.get('rules', []):
        if rule['type'] == 'required_status_checks':
            names = sorted(c['context'] for c in rule['parameters']['required_status_checks'])
            if names != sorted(ruleset['required_checks']):
                problems.append(f'required checks: snapshot {sorted(ruleset["required_checks"])}, live {names}')
        if rule['type'] == 'merge_queue':
            for key, value in ruleset['merge_queue'].items():
                if rule['parameters'].get(key) != value:
                    problems.append(f'merge queue {key}: snapshot {value}, live {rule["parameters"].get(key)}')
    for line in problems:
        print(f'SNAPSHOT drift: {line}', file=out)
    if not problems:
        print('SNAPSHOT ruleset matches the live ruleset', file=out)
    return 1 if problems else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--check', action='store_true', help='every combination; exit 1 on a violation not in KNOWN')
    parser.add_argument('--list', action='store_true', help='every violation, grouped by class')
    parser.add_argument('--one', nargs=4, metavar=('KIND', 'ARMING', 'FAULT', 'ADMISSION'))
    parser.add_argument('--only', nargs='+', help='with --list: only combinations naming all of these parts')
    parser.add_argument('--diff', nargs='+', metavar='REF')
    parser.add_argument('--check-snapshot', action='store_true')
    args = parser.parse_args(argv)
    if args.check_snapshot:
        return check_snapshot()
    if args.diff:
        return diff(args.diff[0], args.diff[1] if len(args.diff) > 1 else None)
    tree = M.Tree(ROOT)
    if args.one:
        c = case(*args.one)
        result = simulate(c, tree)
        print(f'{c.name}: {M.summary(result)}; mac jobs {result["mac_jobs"]}')
        print(f'violations: {violations(c, result, tree) or "none"}')
        for line in result['log']:
            print(f'  {line}')
        return 0
    if args.list:
        for v, names in sorted(grouped(sweep(tree, args.only)).items()):
            print(f'{v}: {len(names)}')
            for name in names:
                print(f'  {name}')
        return 0
    return check(tree)


if __name__ == '__main__':
    sys.exit(main())
