#!/usr/bin/env python3
"""A local, offline model of how a PR moves from arming to merged, built from the real workflow files.

Three parts, one file:

1. `extract(root)`: a static model of .github/workflows. For each workflow: its triggers (events, types, branches,
   paths, crons, upstream workflows), concurrency groups, jobs with their `if:` conditions and the check names they
   report, the variables and secrets it reads, the token each job writes with, and what the scripts it runs do
   (labels, comments, dispatches, re-runs, queueing, pushes), each with file:line. It is regenerated from the YAML on
   every run, never kept by hand.
2. `simulate(scenario, root)`: a small discrete-event simulator over that model. GitHub's side (which events start
   which workflows, `if:` evaluation, the token rule, auto-merge, the merge queue) is modelled here; the repository's
   own decisions are not copied: the label bridge, the dequeue notifier, the merge-policy rules and the audit's
   eligibility are imported from the same tree and run against a fake GitHub. Where GitHub's behaviour is not
   documented, the model says so in ASSUMPTIONS, and a scenario can flip one to see what changes.
3. `--diff BASE [HEAD]`: run every scenario against two trees (git refs, or the working tree) and print the scenarios
   whose outcome changes. That is how a CI change is tested before it lands.

Repository state that is not in the files (the ruleset, variables, secret names, disabled workflows, and how often
GitHub actually ran the schedules) is the SNAPSHOT below, dated. `--live` re-reads the first four with `gh`.

Run:
  .venv/bin/python scripts/ci_model.py                 # every scenario against the working tree
  .venv/bin/python scripts/ci_model.py --extract       # the static model as JSON
  .venv/bin/python scripts/ci_model.py --diff origin/main          # main against the working tree
  .venv/bin/python scripts/ci_model.py --diff origin/main origin/some-branch
"""
from __future__ import annotations

import argparse
import ast
import contextlib
import copy
import dataclasses
import fnmatch
import heapq
import importlib.util
import io
import itertools
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
REPO = 'Spoken-Margins/spoken-margins-native'

# --- what the files don't say ---------------------------------------------------------------------------------------

SNAPSHOT = {
    'taken': '2026-11-20; ruleset re-read 2026-11-22',
    # gh api repos/Spoken-Margins/spoken-margins-native/rulesets/19241264 (readable without a token: the repo is public;
    # ci_harness.py --check-snapshot compares this with the live ruleset)
    'ruleset': {
        'id': 19241264,
        'required_checks': ['hosted fast: scope', 'hosted fast: portable', 'hosted fast: Mac rest',
                            'hosted web: build and Playwright', 'merge policy', 'hosted app: build (no tests)'],
        'merge_queue': {'grouping_strategy': 'HEADGREEN', 'max_entries_to_build': 3, 'max_entries_to_merge': 5,
                        'check_response_timeout_minutes': 120, 'merge_method': 'MERGE'},
        'bypass_actors': [],
    },
    # gh variable list
    'variables': {'LANE_HOSTED_APP': 'on', 'LANE_HOSTED_FAST': 'on', 'LANE_HOSTED_MAC_REST': 'on',
                  'MERGE_QUEUE': 'on', 'MERGE_QUEUE_MAC': 'queue-only', 'SM_TRUNK': 'main'},
    # gh secret list (names only)
    'secrets': ['MERGE_QUEUE_TOKEN', 'SM_LANE_OPEN_TOKEN', 'SM_LANE_OPEN_URL', 'SM_LANE_RUNNERS_TOKEN'],
    # gh workflow list --all: state disabled_manually
    'disabled_workflows': ['lane.yml'],
    # How often GitHub actually started the scheduled runs (gh run list --workflow X --event schedule).
    'schedule_observed': {
        'claude-audit.yml': {'gap_minutes': 480, 'evidence': '16 schedule runs 2026-11-16..20, gaps of 4 to 9 hours, '
                                                             'against a 15-minute cron'},
        'merge-queue-label-bridge.yml': {'gap_minutes': 720, 'evidence': 'one schedule run (12:45Z) between the '
                                                                         'switch-over at 04:02Z and 17:58Z on '
                                                                         '2026-11-20, against a 15-minute cron'},
    },
}

# Every rule the model takes on trust. `basis`: documented (with source), observed (with evidence), or inferred.
ASSUMPTIONS = {
    'A1-token-rule': {
        'basis': 'documented',
        'text': 'An event caused by GITHUB_TOKEN starts no workflow run, except workflow_dispatch and '
                'repository_dispatch.',
        'source': 'docs.github.com "Triggering a workflow from a workflow"; quoted in merge-queue-label-bridge.yml:15'},
    'A2-skipped-is-success': {
        'basis': 'documented',
        'text': 'A job skipped by its `if:` reports its check as skipped, which satisfies a required check.',
        'source': 'GitHub docs on required checks; relied on in hosted-portable.yml:64 and hosted-web.yml:36'},
    'A3-missing-check-waits': {
        'basis': 'documented',
        'text': 'A required check that never reports leaves the PR (or merge group) pending; in the queue the group '
                'fails after check_response_timeout_minutes.',
        'source': 'ruleset merge_queue.check_response_timeout_minutes; hosted-portable.yml:64'},
    'A4-dispatch-check-not-required': {
        'basis': 'inferred',
        'text': 'A check from a workflow_dispatch run (on main) does not satisfy a PR\'s required check; only '
                'pull_request runs on the PR head do.',
        'source': 'stated in merge-policy.yml:15-17 and sm_codex_audit.py rerun_merge_policy; not re-verified here'},
    'A5-rerun-keeps-event': {
        'basis': 'documented',
        'text': 'Re-running a workflow run replays its original event and SHA, reading current state (comments, '
                'labels) when its steps run.',
        'source': 'GitHub docs "Re-running workflows and jobs"'},
    'A6-rerun-by-token-allowed': {
        'basis': 'inferred',
        'text': 'A re-run requested with GITHUB_TOKEN (actions: write) runs; the token rule covers new events, and a '
                're-run is not one.',
        'source': 'not documented either way; sm_codex_audit.py:1188 depends on it'},
    'A7-auto-merge-enqueues': {
        'basis': 'documented',
        'text': 'With a required merge queue, `gh pr merge N` (no method) turns auto-merge on, and GitHub adds the PR '
                'to the queue once its required checks pass; a failing required check leaves it waiting, not '
                'cancelled.',
        'source': 'GitHub docs "Managing a merge queue"; merge_queue_label_bridge.py:9-10'},
    'A8-queue-events-fire': {
        'basis': 'inferred',
        'text': 'merge_group checks_requested and pull_request_target dequeued are GitHub\'s own events and start '
                'runs whoever queued the PR. Flip `gh_token_enqueue_starts_groups` to model the opposite for a PR '
                'queued with GITHUB_TOKEN.',
        'source': 'undocumented; merge-queue-label-bridge.yml:17-20 calls it out'},
    'A9-dequeue-disables-auto-merge': {
        'basis': 'inferred',
        'text': 'When a merge group fails, GitHub removes the PR from the queue and turns its auto-merge off, so it '
                'does not re-enter by itself. Flip `dequeue_keeps_auto_merge` to see the loop if it does not.',
        'source': 'not verified; merge_queue_dequeued.py relies on labels only and does not call --disable-auto'},
    'A10-dequeue-reason': {
        'basis': 'inferred',
        'text': 'A failed group sends `dequeued` with a reason other than MERGE/MANUAL (the model uses '
                'FAILED_CHECKS), which merge_queue_dequeued.py treats as a failure.',
        'source': 'GitHub does not list the reason strings; merge_queue_dequeued.py NO_LABEL_REASONS'},
    'A11-merge-push-fires': {
        'basis': 'inferred',
        'text': 'The merge queue\'s merge into main is a push event that starts `push` workflows.',
        'source': 'observed in practice for hosted-app-macos.yml runs after queue merges; not re-checked here'},
    'A12-generic-job-passes': {
        'basis': 'inferred',
        'text': 'A job the model has no behaviour for succeeds and has no outputs or effects.',
        'source': 'model simplification; BEHAVIOURS lists the jobs that are modelled'},
    'A13-runs-are-instant': {
        'basis': 'inferred',
        'text': 'Workflow runs take no simulated time, so races between runs (a re-run asked for while a run is still '
                'going) appear only when a scenario sets them up.',
        'source': 'model simplification'},
    'A14-observed-schedules': {
        'basis': 'observed',
        'text': 'In "observed" schedule mode a scheduled workflow first fires half its observed gap after the start, '
                'then once per gap; in "nominal" mode it fires on its cron.',
        'source': 'SNAPSHOT schedule_observed'},
    'A16-dispatch-disabled-fails': {
        'basis': 'observed',
        'text': 'Dispatching a disabled workflow fails, so a job that does it ends red.',
        'source': 'PR #4754 head, hosted-portable run 44771542367 job `rearm`: "could not start its merge run" '
                  'from POST .../workflows/lane.yml/dispatches, 2026-11-20'},
    'A15-defect-catchers': {
        'basis': 'inferred',
        'text': 'Which job fails for which defect (DEFECT_CATCHERS): app Swift compiles only in hosted-app-macos.yml '
                'and main-t3.yml; Mac rest builds SessionKit (verify-tests.py fast-mac-rest) but not the app '
                '(PLANS["app"] is a separate plan, verify-tests.py:40-41).',
        'source': 'read from the workflows and verify-tests.py, not run'},
}

GITHUB_GENERATED = {'merge_group', 'schedule', 'workflow_run', 'push_by_queue', 'dequeued'}
DISPATCH_EVENTS = {'workflow_dispatch', 'repository_dispatch'}
DEFAULT_TYPES = {'pull_request': ['opened', 'synchronize', 'reopened'],
                 'pull_request_target': ['opened', 'synchronize', 'reopened'],
                 'merge_group': ['checks_requested'], 'workflow_run': ['completed', 'requested']}

# --- static extraction ----------------------------------------------------------------------------------------------

EFFECT_PATTERNS = [
    ('label-add', re.compile(r"issues/\{?[\w.\[\]'\"]*\}?/labels['\"]?,\s*\{|--add-label|add_label\(|"
                             r"'-X', 'POST'.*labels")),
    ('label-remove', re.compile(r"labels/\{[^}]*\}['\"]?\]?\)|--remove-label|remove_label\(|DELETE.*labels/")),
    ('comment', re.compile(r"'pr', 'comment'|\"pr\", \"comment\"|issues/\{[^}]*\}/comments['\"],\s*\{|gh pr comment")),
    ('dispatch', re.compile(r"dispatch_workflow\(\s*[\"'][\w.-]+|gh workflow run|'workflow', 'run'")),
    ('rerun', re.compile(r"\"run\", \"rerun\"|'run', 'rerun'|gh run rerun")),
    ('queue', re.compile(r"['\"]pr['\"],\s*['\"]merge['\"]|gh pr merge|dequeuePullRequest")),
    ('push', re.compile(r"\['push'|'push', '--|git push")),
    ('cancel-run', re.compile(r"actions/runs/\{[^}]*\}/cancel")),
]
SCRIPT_CALL = re.compile(r'(?:python3?|\.venv/bin/python|bash)\s+(?:"?\$RUNNER_TEMP/)?((?:scripts|ops)/[\w./-]+)')
EXPR = re.compile(r'\$\{\{(.*?)\}\}', re.S)
VAR_REF = re.compile(r'\bvars\.([A-Z0-9_]+)')
SECRET_REF = re.compile(r'\bsecrets\.([A-Z0-9_]+)')


def _on(doc: dict) -> dict:
    on = doc.get('on', doc.get(True))  # YAML 1.1 reads a bare `on` key as True
    if isinstance(on, str):
        return {on: {}}
    if isinstance(on, list):
        return {e: {} for e in on}
    return {k: (v or {}) for k, v in (on or {}).items()}


def _line_of(text: str, needle: str) -> int:
    index = text.find(needle)
    return text.count('\n', 0, index) + 1 if index >= 0 else 0


def _job_token(job: dict) -> str:
    """Who a job's `gh` calls act as: the secret named in GH_TOKEN when the repository has it, else GITHUB_TOKEN."""
    exprs = []
    for scope in [job.get('env') or {}] + [s.get('env') or {} for s in job.get('steps') or []]:
        if 'GH_TOKEN' in scope:
            exprs.append(str(scope['GH_TOKEN']))
    for expr in exprs:
        for name in SECRET_REF.findall(expr):
            if name in SNAPSHOT['secrets']:
                return f'secret:{name}'
    return 'github_token' if exprs else 'none'


def _effect(kind: str, rel: str, number: int, text: str) -> dict:
    target = re.search(r"dispatch_workflow\(\s*[\"']([\w.-]+)", text)
    return {'kind': kind, 'at': f'{rel}:{number}', **({'workflow': target.group(1)} if target else {})}


def _python_effects(rel: str, source: str) -> tuple[list[dict], dict[str, list[range]]]:
    """Effects of a Python script read from its syntax tree: each call is matched as ast.unparse renders it, on one
    line with normalised quotes, so a call split across lines or formatted differently is still found. Only the
    innermost matching call counts, so a wrapper around a matching call does not add a second effect."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return [], {}
    found, spans = [], {}
    calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
    rendered = {id(node): ast.unparse(node) for node in calls}
    for kind, pattern in EFFECT_PATTERNS:
        matching = [node for node in calls if pattern.search(rendered[id(node)])]
        inner = [node for node in matching
                 if not any(other is not node and pattern.search(rendered[id(other)])
                            for other in ast.walk(node) if isinstance(other, ast.Call))]
        for node in inner:
            found.append(_effect(kind, rel, node.lineno, rendered[id(node)]))
            spans.setdefault(kind, []).append(range(node.lineno, (node.end_lineno or node.lineno) + 1))
    return found, spans


def script_effects(root: Path, rel: str) -> list[dict]:
    """What a script does to GitHub. Python is read with `ast` (any formatting); every file is also scanned line by
    line for command text outside calls (shell scripts, argument lists built in a variable)."""
    path = root / rel
    if not path.is_file():
        return []
    source = path.read_text(encoding='utf-8', errors='replace')
    found, spans = _python_effects(rel, source) if rel.endswith('.py') else ([], {})
    for number, line in enumerate(source.splitlines(), 1):
        if line.strip().startswith('#'):
            continue
        for kind, pattern in EFFECT_PATTERNS:
            if pattern.search(line) and not any(number in span for span in spans.get(kind, [])):
                found.append(_effect(kind, rel, number, line))
    return sorted(found, key=lambda e: (int(e['at'].rsplit(':', 1)[1]), e['kind']))


def extract(root: Path = ROOT) -> dict:
    """The static model of every workflow under <root>/.github/workflows."""
    workflows = {}
    for path in sorted((root / '.github/workflows').glob('*.yml')):
        text = path.read_text(encoding='utf-8')
        doc = yaml.safe_load(text) or {}
        jobs = {}
        scripts_run = set()
        for job_id, job in (doc.get('jobs') or {}).items():
            job = job or {}
            runs = '\n'.join(str(s.get('run') or '') for s in job.get('steps') or [])
            called = sorted(set(SCRIPT_CALL.findall(runs)))
            scripts_run.update(called)
            needs = job.get('needs') or []
            jobs[job_id] = {
                'id': job_id,
                # A job that posts its own check run under another name says so in `SM_REPORTS_CHECK` (merge-policy.yml,
                # #4986): the job is named `merge policy run`, the check the ruleset requires is `merge policy`.
                'check': str((job.get('env') or {}).get('SM_REPORTS_CHECK') or job.get('name') or job_id),
                'if': None if job.get('if') is None else str(job['if']).strip(),
                'needs': [needs] if isinstance(needs, str) else list(needs),
                'concurrency': job.get('concurrency'),
                'outputs': sorted((job.get('outputs') or {}).keys()),
                'token': _job_token(job),
                'scripts': called,
                'line': _line_of(text, f'\n  {job_id}:'),
            }
        triggers = {}
        for event, spec in _on(doc).items():
            spec = spec if isinstance(spec, dict) else {}
            triggers[event] = {k: spec[k] for k in ('types', 'branches', 'paths', 'paths-ignore', 'workflows')
                               if k in spec}
            if event == 'schedule':
                triggers[event] = {'cron': [c.get('cron') for c in (_on(doc)['schedule'] or [])]}
            if 'inputs' in spec:
                triggers[event]['inputs'] = sorted(spec['inputs'] or {})
        effects = [e for rel in sorted(scripts_run) for e in script_effects(root, rel)]
        workflows[path.name] = {
            'name': doc.get('name') or path.name,
            'triggers': triggers,
            'concurrency': doc.get('concurrency'),
            'permissions': doc.get('permissions'),
            'jobs': jobs,
            'vars': sorted(set(VAR_REF.findall(text))),
            'secrets': sorted(set(SECRET_REF.findall(text))),
            'scripts': sorted(scripts_run),
            'effects': effects,
            'disabled': path.name in SNAPSHOT['disabled_workflows'],
        }
    producers = {}
    for file, wf in workflows.items():
        for job_id, job in wf['jobs'].items():
            producers.setdefault(job['check'], []).append(
                {'workflow': file, 'job': job_id, 'events': sorted(wf['triggers'])})
    required = {name: producers.get(name, []) for name in SNAPSHOT['ruleset']['required_checks']}
    return {'snapshot': SNAPSHOT, 'workflows': workflows, 'required_checks': required,
            'assumptions': ASSUMPTIONS}


# --- GitHub expressions ---------------------------------------------------------------------------------------------

TOKEN = re.compile(r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<num>\d+(?:\.\d+)?)|(?P<op>==|!=|<=|>=|&&|\|\||[!<>(),])|"
                   r"(?P<id>[A-Za-z_][\w-]*(?:\.(?:[\w-]+|\*))*))")


class Expr:
    """A small evaluator for the GitHub Actions expression syntax `if:` conditions use."""

    def __init__(self, text: str, ctx: dict, status: dict):
        text = text.strip()
        match = re.fullmatch(r'\$\{\{(.*)\}\}', text, re.S)
        self.text = match.group(1) if match else text
        self.tokens, pos = [], 0
        while pos < len(self.text):
            m = TOKEN.match(self.text, pos)
            if not m or m.end() == pos:
                if self.text[pos:].strip() == '':
                    break
                raise ValueError(f'cannot read expression at {self.text[pos:pos + 20]!r}')
            kind = m.lastgroup
            self.tokens.append((kind, m.group(kind)))
            pos = m.end()
        self.i, self.ctx, self.status = 0, ctx, status

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def take(self):
        tok = self.peek()
        self.i += 1
        return tok

    def evaluate(self):
        value = self.or_()
        if self.i != len(self.tokens):
            raise ValueError(f'trailing tokens in {self.text!r}')
        return value

    def or_(self):
        left = self.and_()
        while self.peek() == ('op', '||'):
            self.take()
            right = self.and_()
            left = left if truthy(left) else right
        return left

    def and_(self):
        left = self.cmp()
        while self.peek() == ('op', '&&'):
            self.take()
            right = self.cmp()
            left = right if truthy(left) else left
        return left

    def cmp(self):
        left = self.unary()
        while self.peek()[0] == 'op' and self.peek()[1] in ('==', '!=', '<', '>', '<=', '>='):
            op = self.take()[1]
            right = self.unary()
            if op in ('==', '!='):
                same = loose_equal(left, right)
                left = same if op == '==' else not same
            else:
                left = {'<': lambda a, b: a < b, '>': lambda a, b: a > b, '<=': lambda a, b: a <= b,
                        '>=': lambda a, b: a >= b}[op](left or 0, right or 0)
        return left

    def unary(self):
        if self.peek() == ('op', '!'):
            self.take()
            return not truthy(self.unary())
        return self.atom()

    def atom(self):
        kind, value = self.take()
        if kind == 'str':
            return value[1:-1].replace("''", "'")
        if kind == 'num':
            return float(value)
        if (kind, value) == ('op', '('):
            inner = self.or_()
            self.take()
            return inner
        if kind == 'id':
            if self.peek() == ('op', '('):
                self.take()
                args = []
                while self.peek() != ('op', ')'):
                    args.append(self.or_())
                    if self.peek() == ('op', ','):
                        self.take()
                self.take()
                return self.call(value, args)
            if value in ('true', 'false'):
                return value == 'true'
            if value == 'null':
                return None
            return lookup(self.ctx, value)
        raise ValueError(f'unexpected {value!r} in {self.text!r}')

    def call(self, name, args):
        name = name.lower()
        if name == 'contains':
            hay, needle = args
            if isinstance(hay, list):
                return any(loose_equal(h, needle) for h in hay)
            return str(needle or '').lower() in str(hay or '').lower()
        if name == 'startswith':
            return str(args[0] or '').lower().startswith(str(args[1] or '').lower())
        if name == 'endswith':
            return str(args[0] or '').lower().endswith(str(args[1] or '').lower())
        if name == 'always':
            return True
        if name == 'cancelled':
            return False
        if name == 'success':
            return self.status['success']
        if name == 'failure':
            return self.status['failure']
        if name == 'fromjson':
            try:
                return json.loads(args[0])
            except (TypeError, ValueError):
                return None
        if name == 'format':
            return re.sub(r'\{(\d+)\}', lambda m: str(args[int(m.group(1)) + 1]), str(args[0]))
        if name == 'hashfiles':
            return ''
        raise ValueError(f'unknown function {name}')


def truthy(value) -> bool:
    return value not in (None, False, 0, '', 0.0)


def loose_equal(a, b) -> bool:
    if a is None or b is None:
        return (a in (None, '') and b in (None, ''))
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if isinstance(a, bool) or isinstance(b, bool):
        return truthy(a) == truthy(b)
    return a == b


def lookup(ctx: dict, dotted: str):
    values = [ctx]
    for part in dotted.split('.'):
        out = []
        for value in values:
            if part == '*':
                out.extend(value if isinstance(value, list) else [])
            elif isinstance(value, dict):
                out.append(value.get(part))
            else:
                out.append(None)
        values = out
    return values if '*' in dotted else values[0]


def condition(text: str | None, ctx: dict, needs_results: list[str]) -> bool:
    status = {'success': all(r == 'success' for r in needs_results),
              'failure': any(r == 'failure' for r in needs_results)}
    if text is None:
        return status['success']
    if not re.search(r'\b(always|success|failure|cancelled)\(', text):
        return status['success'] and truthy(Expr(text, ctx, status).evaluate())
    return truthy(Expr(text, ctx, status).evaluate())


# --- trigger matching -----------------------------------------------------------------------------------------------

def glob_match(path: str, pattern: str) -> bool:
    regex = ''
    i = 0
    while i < len(pattern):
        if pattern.startswith('**', i):
            regex += '.*'
            i += 2
        elif pattern[i] == '*':
            regex += '[^/]*'
            i += 1
        else:
            regex += re.escape(pattern[i])
            i += 1
    return re.fullmatch(regex, path) is not None


def filter_match(items: list[str], patterns: list[str] | None, ignore: list[str] | None = None) -> bool:
    """GitHub's branches/paths filters: the last matching pattern wins, and `!` negates."""
    if patterns is None and ignore is None:
        return True
    if ignore is not None:
        return any(not any(glob_match(i, p) for p in ignore) for i in items)
    for item in items:
        keep = False
        for pattern in patterns:
            if pattern.startswith('!'):
                if glob_match(item, pattern[1:]):
                    keep = False
            elif glob_match(item, pattern):
                keep = True
        if keep:
            return True
    return False


def cron_fires(cron: str, minute_of_day: int, weekday: int, day: int, month: int) -> bool:
    fields = cron.split()
    values = [minute_of_day % 60, minute_of_day // 60, day, month, weekday]
    for field, value in zip(fields, values):
        ok = False
        for part in field.split(','):
            step = 1
            if '/' in part:
                part, step = part.split('/')
                step = int(step)
            if part == '*':
                lo, hi = 0, 59
            elif '-' in part:
                lo, hi = map(int, part.split('-'))
            else:
                lo = hi = int(part)
            if lo <= value <= hi and (value - lo) % step == 0:
                ok = True
        if not ok:
            return False
    return True


# --- scenarios ------------------------------------------------------------------------------------------------------

HEAD = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
HEAD2 = 'b2c3d4e5f60718293a4b5c6d7e8f901234567890'
MAX_GROUPS = 10
DEFECT_CATCHERS = {  # (workflow, job) -> defects that make it fail (A15)
    ('hosted-portable.yml', 'portable'): {'portable_test_failure'},
    ('hosted-portable.yml', 'mac-rest'): {'sessionkit_compile_error', 'sessionkit_test_failure'},
    ('hosted-portable.yml', 'sessionkit'): {'sessionkit_compile_error', 'sessionkit_test_failure'},
    ('hosted-portable.yml', 'app-compile'): {'app_compile_error'},
    ('hosted-web.yml', 'web'): {'web_failure'},
    ('hosted-app-macos.yml', 'app'): {'app_compile_error', 'sessionkit_compile_error'},
    ('main-t3.yml', 't3'): {'app_compile_error', 'sessionkit_compile_error', 'app_test_failure'},
}


@dataclasses.dataclass
class Scenario:
    name: str
    description: str
    paths: list[str]
    steps: list[tuple] = dataclasses.field(default_factory=list)  # (minute, action, *args)
    labels: set[str] = dataclasses.field(default_factory=set)
    defects: set[str] = dataclasses.field(default_factory=set)
    audit_verdict: str = 'No blocking findings.'
    schedule_mode: str = 'observed'
    horizon: int = 24 * 60
    flags: dict = dataclasses.field(default_factory=dict)
    title: str = 'A change'
    pushes: list[tuple] = dataclasses.field(default_factory=list)  # (minute, new paths, new defects)


def scenarios() -> list[Scenario]:
    return [
        Scenario('a-docs-armed', 'A docs-only PR armed with automerge by a person merges.',
                 ['docs/contributing/example.md'], steps=[(1, 'label', 'automerge', 'user')]),
        Scenario('b-lane-no-audit', 'A lane-touching PR armed by a person, with no audit yet: merge policy holds it '
                 'until the Claude audit posts and re-runs the check.',
                 ['scripts/lane_dedupe.py'], steps=[(1, 'label', 'automerge', 'user')]),
        Scenario('b2-lane-audit-from-outside', 'As b, but the hosted audit is paused (no token, or the head failed '
                 'twice) and the clean audit is posted from outside a workflow run (the local launchd audit, or a '
                 'person): nothing re-runs merge policy.',
                 ['scripts/lane_dedupe.py'],
                 steps=[(1, 'label', 'automerge', 'user'), (30, 'audit', 'user')], flags={'audit_paused': True}),
        Scenario('b3-lane-audit-while-policy-runs', 'As b, but the PR\'s merge policy run is still going when the '
                 'audit posts (a label event just started it): the audit skips the re-run and nothing asks again.',
                 ['scripts/lane_dedupe.py'], steps=[(1, 'label', 'automerge', 'user')],
                 flags={'policy_run_in_progress': True}),
        Scenario('b4-lane-armed-before-checks', 'As b, but the PR is armed before its hosted checks finish (created '
                 'with the label, or a fix pushed after arming): the head\'s `rearm` job dispatches the disabled '
                 'lane.yml and fails, the audit reads that red check as "checks failed" and never audits, so merge '
                 'policy never turns green.',
                 ['scripts/lane_dedupe.py'], steps=[(0, 'label', 'automerge', 'user')]),
        Scenario('c-token-label', 'automerge added with GITHUB_TOKEN (by another workflow): the bridge does not start, '
                 'and only the 15-minute sweep queues it.',
                 ['docs/contributing/example.md'], steps=[(1, 'label', 'automerge', 'github_token')]),
        Scenario('c2-token-label-nominal', 'As c, with schedules on their cron rather than as observed.',
                 ['docs/contributing/example.md'], steps=[(1, 'label', 'automerge', 'github_token')],
                 schedule_mode='nominal'),
        Scenario('d-group-fails', 'A SessionKit test failure that only the queue-only Mac rest job sees: the merge '
                 'group fails, the PR is dequeued, gets needs-fix and loses automerge.',
                 ['Packages/SessionKit/Sources/SessionKit/Example.swift'],
                 steps=[(1, 'label', 'automerge', 'user')], defects={'sessionkit_test_failure'}),
        Scenario('d2-group-fails-auto-merge-kept', 'As d, if GitHub kept auto-merge on after a failed group (A9 '
                 'flipped).', ['Packages/SessionKit/Sources/SessionKit/Example.swift'],
                 steps=[(1, 'label', 'automerge', 'user')], defects={'sessionkit_test_failure'},
                 flags={'dequeue_keeps_auto_merge': True}, horizon=6 * 60),
        Scenario('e-app-swift-compile-error', 'An app Swift file that does not compile: `hosted app: build (no '
                 'tests)` is required (ruleset re-read 2026-11-22), so the merge group fails and the PR is held '
                 'with needs-fix instead of breaking main.',
                 ['App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExampleView.swift'],
                 steps=[(1, 'label', 'automerge', 'user')], defects={'app_compile_error'}),
        Scenario('f-rearm-by-token-after-fix', 'A dequeued PR (needs-fix) re-armed with GITHUB_TOKEN: the bridge does '
                 'not start, and the sweep skips needs-fix PRs, so it never re-queues.',
                 ['Packages/SessionKit/Sources/SessionKit/Example.swift'],
                 steps=[(1, 'label', 'automerge', 'user'), (180, 'label', 'automerge', 'github_token')],
                 defects={'sessionkit_test_failure'}, pushes=[(120, None, set())]),
        Scenario('g-owner-tap-workflow', 'A .github/ change armed by a person: held for the audit and the owner\'s '
                 '`owner-tap` label, which the owner adds after the audit.',
                 ['.github/workflows/example.yml'],
                 steps=[(1, 'label', 'automerge', 'user'), (600, 'label', 'owner-tap', 'user')]),
    ]


# --- the simulator --------------------------------------------------------------------------------------------------

class Tree:
    """The repository's own decision code, loaded from one tree (the working tree or an unpacked ref)."""

    def __init__(self, root: Path):
        self.root = root
        self._modules = {}
        self._scopes = {}
        self.model = extract(root)

    def module(self, name: str, rel: str):
        if name not in self._modules:
            for extra in (self.root / 'scripts', self.root / Path(rel).parent):
                if str(extra) not in sys.path:
                    sys.path.insert(0, str(extra))
            spec = importlib.util.spec_from_file_location(f'ci_model_{name}_{id(self)}', self.root / rel)
            module = importlib.util.module_from_spec(spec)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                spec.loader.exec_module(module)
            self._modules[name] = module
        return self._modules[name]

    def classify(self, paths: list[str]) -> dict:
        """test-scope.py's classify, once per set of paths (it reads every Swift source for an app path)."""
        key = tuple(sorted(paths))
        if key not in self._scopes:
            ts = self.module('test_scope', 'scripts/test-scope.py')
            self._scopes[key] = ts.classify(list(key), {}, root=self.root)
        return self._scopes[key]

    def raw(self, file: str) -> dict:
        """The workflow file as parsed YAML, for a step's env or run text."""
        return yaml.safe_load(self.yaml_text(file)) or {}

    def yaml_text(self, file: str) -> str:
        return (self.root / '.github/workflows' / file).read_text(encoding='utf-8')


class World:
    def __init__(self, scenario: Scenario, tree: Tree):
        self.s, self.tree = scenario, tree
        self.flags = {'gh_token_enqueue_starts_groups': True, 'dequeue_keeps_auto_merge': False, **scenario.flags}
        self.labels = set(scenario.labels)
        self.paths = list(scenario.paths)
        self.defects = set(scenario.defects)
        self.head = HEAD
        self.comments: list[dict] = []
        self.auto_merge = False
        self.enqueued_by = None
        self.in_queue = False
        self.merged_at = None
        self.main_broken_by = None
        # sha -> (check name, workflow) -> {name, conclusion, run, event}; two workflows may report the same name
        self.checks: dict[str, dict[tuple, dict]] = {}
        self.runs: list[dict] = []
        self.queue = []
        self.seq = itertools.count()
        self.log: list[dict] = []
        self.groups = 0
        self.group_sha = None
        self.now = 0
        self.events: dict[int, dict] = {}

    # events
    def post(self, at, kind, cause=None, **payload):
        event = {'id': next(self.seq), 'at': at, 'kind': kind, 'cause': cause, **payload}
        self.events[event['id']] = event
        heapq.heappush(self.queue, (at, event['id'], event))
        return event

    def note(self, event, text):
        self.log.append({'at': self.now, 'event': event['id'] if event else None, 'text': text})

    def chain(self, event_id) -> list[dict]:
        out = []
        while event_id is not None:
            event = self.events[event_id]
            out.append(event)
            event_id = event.get('cause')
        return list(reversed(out))

    def pr_event(self, action, label=None):
        return {'action': action, 'label': {'name': label} if label else None,
                'pull_request': {'number': 1, 'title': self.s.title, 'draft': False, 'merged': self.merged_at is not None,
                                 'head': {'sha': self.head, 'repo': {'full_name': REPO}},
                                 'base': {'ref': 'main', 'sha': 'base'},
                                 'labels': [{'name': n} for n in sorted(self.labels)]},
                'repository': {'full_name': REPO}}

    def run_status(self, run) -> str:
        """A run's status as the Actions API reports it. Runs take no time here, so every run is finished unless a
        scenario says the PR's merge policy run is still going (b3); ci_harness.TimedWorld reads the real status."""
        return 'in_progress' if self.flags.get('policy_run_in_progress') else 'completed'

    def bridge_github(self, job, cause):
        """The fake GitHub the label bridge runs against; ci_harness.TimedWorld swaps in one whose token can fail."""
        return FakeBridgeGitHub(self, job['token'], cause)

    def change_label(self, at, label, add, token, cause):
        before = label in self.labels
        (self.labels.add if add else self.labels.discard)(label)
        if before != add:
            self.post(at, 'pr', cause, action='labeled' if add else 'unlabeled', label=label, token=token)

    # schedules
    def seed_schedules(self):
        for file, wf in self.tree.model['workflows'].items():
            crons = (wf['triggers'].get('schedule') or {}).get('cron') or []
            if not crons or wf['disabled']:
                continue
            if file == 'claude-audit.yml' and self.flags.get('no_scheduled_audit'):
                continue
            observed = SNAPSHOT['schedule_observed'].get(file)
            if self.s.schedule_mode == 'observed' and observed:
                gap = observed['gap_minutes']
                times = range(gap // 2, self.s.horizon + 1, gap)
            else:
                start = 10 * 60  # the simulation starts at 10:00 UTC on a Friday, 2026-11-20
                times = [m for m in range(self.s.horizon + 1)
                         if any(cron_fires(c, (start + m) % 1440, (4 + (start + m) // 1440) % 7, 20, 11) for c in crons)]
            for at in times:
                self.post(at, 'schedule', None, workflow=file, token='github')

    # running workflows
    def triggered(self, event) -> list[tuple[str, str, dict]]:
        """(workflow file, event name, github.event payload) for every workflow this event starts."""
        kind, token = event['kind'], event.get('token')
        out = []
        for file, wf in self.tree.model['workflows'].items():
            if wf['disabled']:
                continue
            trig = wf['triggers']
            if kind == 'pr':
                if token == 'github_token':  # A1
                    continue
                for name in ('pull_request', 'pull_request_target'):
                    spec = trig.get(name)
                    if spec is None or event['action'] not in spec.get('types', DEFAULT_TYPES[name]):
                        continue
                    if not filter_match(['main'], spec.get('branches')):
                        continue
                    if name == 'pull_request' and not filter_match(self.paths, spec.get('paths'),
                                                                     spec.get('paths-ignore')):
                        continue
                    out.append((file, name, self.pr_event(event['action'], event.get('label'))))
            elif kind == 'dequeued' and 'pull_request_target' in trig:
                if 'dequeued' in trig['pull_request_target'].get('types', []):
                    payload = self.pr_event('dequeued')
                    payload['reason'] = event['reason']
                    out.append((file, 'pull_request_target', payload))
            elif kind == 'merge_group' and 'merge_group' in trig:
                out.append((file, 'merge_group', {'merge_group': {'head_sha': event['sha'], 'base_sha': 'base'}}))
            elif kind == 'push' and 'push' in trig:
                spec = trig['push']
                if filter_match(['main'], spec.get('branches')) and filter_match(self.paths, spec.get('paths'),
                                                                                  spec.get('paths-ignore')):
                    out.append((file, 'push', {}))
            elif kind == 'schedule' and event['workflow'] == file:
                out.append((file, 'schedule', {}))
            elif kind == 'workflow_dispatch' and event['workflow'] == file and 'workflow_dispatch' in trig:
                out.append((file, 'workflow_dispatch', {'inputs': event.get('inputs') or {}}))
            elif kind == 'workflow_run' and 'workflow_run' in trig:
                spec = trig['workflow_run']
                if event['name'] in (spec.get('workflows') or []) and 'completed' in spec.get('types', ['completed']):
                    out.append((file, 'workflow_run', {'workflow_run': {'conclusion': event['conclusion'],
                                                                         'event': event['run_event']}}))
        return out

    def run_workflow(self, file, event_name, payload, cause_event, rerun_of=None):
        wf = self.tree.model['workflows'][file]
        ctx = {'github': {'event_name': event_name, 'event': payload, 'repository': REPO,
                          'ref_name': 'main', 'ref': 'refs/heads/main', 'token': 'github_token'},
               'vars': SNAPSHOT['variables'], 'inputs': payload.get('inputs') or {}, 'needs': {}}
        if event_name == 'merge_group':
            ctx['github']['ref'] = 'refs/heads/gh-readonly-queue/main/pr-1-base'
            ctx['github']['ref_name'] = 'gh-readonly-queue/main/pr-1-base'
        sha = {'pull_request': self.head, 'merge_group': payload.get('merge_group', {}).get('head_sha')}.get(
            event_name, 'main')
        run = {'id': len(self.runs) + 1, 'workflow': file, 'event': event_name, 'payload': payload, 'sha': sha,
               'jobs': {}, 'cause': cause_event['id'], 'rerun_of': rerun_of}
        self.runs.append(run)
        pending = list(wf['jobs'])
        results = {}
        while pending:
            progressed = False
            for job_id in list(pending):
                job = wf['jobs'][job_id]
                if any(n not in results for n in job['needs']):
                    continue
                pending.remove(job_id)
                progressed = True
                ctx['needs'] = {n: {'result': results[n]['result'], 'outputs': results[n]['outputs']}
                                for n in job['needs']}
                try:
                    go = condition(job['if'], ctx, [results[n]['result'] for n in job['needs']])
                except ValueError as error:
                    self.note(cause_event, f'{file} {job_id}: could not evaluate `if:` ({error}); treated as true')
                    go = True
                if not go:
                    results[job_id] = {'result': 'skipped', 'outputs': {}}
                else:
                    behaviour = BEHAVIOURS.get((file, job_id))
                    result, outputs = ('success', {})
                    if behaviour:
                        result, outputs = behaviour(self, run, job, ctx, cause_event)
                    if self.defects & DEFECT_CATCHERS.get((file, job_id), set()):
                        result = 'failure'
                    results[job_id] = {'result': result, 'outputs': outputs}
                if sha:
                    held = results[job_id]['outputs'].get('check') == 'pending'
                    self.checks.setdefault(sha, {})[(job['check'], file)] = {
                        'name': job['check'], 'conclusion': 'pending' if held else results[job_id]['result'],
                        'run': run['id'], 'event': event_name}
            if not progressed:
                break
        run['jobs'] = results
        ran = [r['result'] for r in results.values() if r['result'] != 'skipped']
        conclusion = 'skipped' if not ran else ('failure' if 'failure' in ran else 'success')
        run['conclusion'] = conclusion
        if cause_event['kind'] != 'schedule' or any(k[0] == file for k in BEHAVIOURS) or conclusion == 'failure':
            self.note(cause_event, f'{file} ({event_name}): ' + ', '.join(
                f'{job_id}={r["result"]}' for job_id, r in results.items()))
        self.post(self.now, 'workflow_run', cause_event['id'], name=wf['name'], conclusion=conclusion,
                  run_event=event_name, token='github')
        if file == 'hosted-app-macos.yml' and event_name == 'push' and conclusion == 'failure':
            self.main_broken_by = self.main_broken_by or {'detected_by': file, 'at': self.now}
        if file == 'main-t3.yml' and conclusion == 'failure' and self.merged_at is not None:
            self.main_broken_by = self.main_broken_by or {'detected_by': file, 'at': self.now}
        return run

    # GitHub's merge machinery
    def required_state(self, sha) -> tuple[str, list[str]]:
        checks = self.checks.get(sha, {})
        missing, failed = [], []
        for name in SNAPSHOT['ruleset']['required_checks']:
            found = [c for c in checks.values() if c['name'] == name and c['event'] in ('pull_request', 'merge_group')]
            if not found:  # A3, A4
                missing.append(name)
            elif any(c['conclusion'] not in ('success', 'skipped', 'neutral', 'pending') for c in found):  # A2
                failed.append(name)
            elif any(c['conclusion'] == 'pending' for c in found):  # an in-progress check run is not yet a pass (#4986)
                missing.append(name)
        if failed:
            return 'failed', failed
        if missing:
            return 'missing', missing
        return 'ok', []

    def github_tick(self, cause):
        if self.merged_at is not None or self.in_queue or not self.auto_merge:
            return
        state, _ = self.required_state(self.head)
        if state != 'ok':
            return
        if self.groups >= MAX_GROUPS:
            if self.groups == MAX_GROUPS:
                self.note(cause, f'{MAX_GROUPS} merge groups for one PR: a re-queue loop; the model stops queueing')
                self.groups += 1
            return
        self.in_queue = True
        self.groups += 1
        self.group_sha = f'{self.groups:02d}' + HEAD2[2:]
        self.note(cause, f'GitHub queues the PR: merge group {self.group_sha[:7]} (A7)')
        if self.enqueued_by == 'github_token' and not self.flags['gh_token_enqueue_starts_groups']:
            self.note(cause, 'merge_group runs do not start for a GITHUB_TOKEN enqueue (A8 flipped)')
        else:
            self.post(self.now, 'merge_group', cause['id'], sha=self.group_sha, token='github')
        timeout = SNAPSHOT['ruleset']['merge_queue']['check_response_timeout_minutes']
        self.post(self.now + timeout, 'queue_timeout', cause['id'], sha=self.group_sha, token='github')

    def group_verdict(self, cause):
        if not self.in_queue or self.group_sha is None:
            return
        state, names = self.required_state(self.group_sha)
        if state == 'ok':
            self.in_queue = False
            self.merged_at = self.now
            self.note(cause, f'merge group {self.group_sha[:7]} green: merged into main')
            self.post(self.now, 'push', cause['id'], token='github')
        elif state == 'failed':
            self.dequeue(cause, 'FAILED_CHECKS', names)

    def dequeue(self, cause, reason, names):
        self.in_queue = False
        if not self.flags['dequeue_keeps_auto_merge']:
            self.auto_merge = False
        self.note(cause, f'merge group {self.group_sha[:7]} dequeued ({reason}: {", ".join(names)}) (A9, A10)')
        self.post(self.now, 'dequeued', cause['id'], reason=reason, token='github')

    def step(self, event):
        self.now = event['at']
        kind = event['kind']
        if kind == 'action':
            action = event['action']
            if action[0] == 'label':
                self.change_label(self.now, action[1], True, action[2], event['id'])
            elif action[0] == 'audit':
                self.comments.append(audit_comment(self.head, self.s.audit_verdict, action[1]))
                self.note(event, f'audit comment posted on {self.head[:7]} by {action[1]} (outside a workflow)')
            elif action[0] == 'push':
                if action[1] is not None:
                    self.paths = action[1]
                self.defects = set(action[2])
                self.head = HEAD2
                self.note(event, f'new head {self.head[:7]} pushed; defects now {sorted(self.defects) or "none"}')
                self.post(self.now, 'pr', event['id'], action='synchronize', label=None, token='user')
            return
        if kind == 'queue_timeout':
            if self.in_queue and self.group_sha == event['sha'] and self.required_state(event['sha'])[0] == 'missing':
                self.dequeue(event, 'CHECKS_TIMED_OUT', self.required_state(event['sha'])[1])
            return
        if kind == 'rerun':
            original = self.runs[event['run'] - 1]
            self.note(event, f're-run of {original["workflow"]} run {original["id"]} ({original["event"]})')
            self.run_workflow(original['workflow'], original['event'], original['payload'], event,
                              rerun_of=original['id'])
        else:
            for file, name, payload in self.triggered(event):
                self.run_workflow(file, name, payload, event)
        if kind == 'merge_group' or (self.in_queue and kind == 'workflow_run'):
            self.group_verdict(event)
        self.github_tick(event)

    def simulate(self) -> dict:
        self.seed_schedules()
        for minute, *action in self.s.steps:
            self.post(minute, 'action', None, action=tuple(action))
        for minute, paths, defects in self.s.pushes:
            self.post(minute, 'action', None, action=('push', paths, defects))
        self.post(0, 'pr', None, action='opened', label=None, token='user')
        while self.queue:
            at, _, event = heapq.heappop(self.queue)
            if at > self.s.horizon:
                break
            if self.merged_at is not None and event['kind'] == 'schedule' and event['workflow'] != 'main-t3.yml':
                continue
            self.step(event)
            if len(self.log) > 2000:
                break
        return self.outcome()

    def outcome(self) -> dict:
        merged = self.merged_at is not None
        state, names = self.required_state(self.head)
        out = {'scenario': self.s.name, 'merged': merged, 'merged_at_minute': self.merged_at,
               'merge_groups': self.groups, 'labels': sorted(self.labels), 'auto_merge': self.auto_merge,
               'main_broken': self.main_broken_by}
        if merged:
            merge_event = next(e for e in reversed(self.log) if 'merged into main' in e['text'])
            chain = self.chain(merge_event['event'])
            out['relied_on_schedule'] = sorted({e['workflow'] for e in chain if e['kind'] == 'schedule'})
            out['path'] = [describe(e) for e in chain]
            out['state'] = 'merged'
        else:
            policy = self.latest_policy_output()
            why = []
            if not self.auto_merge:
                why.append('auto-merge is off (nothing queued it)')
            if state != 'ok':
                why.append(f'required checks {state}: {", ".join(names)}')
            if policy:
                why.append(f'merge policy says: {policy}')
            out['state'] = 'stuck'
            out['why'] = why
        return out

    def latest_policy_output(self):
        for run in reversed(self.runs):
            if run['workflow'] == 'merge-policy.yml' and run['event'] == 'pull_request':
                return (run['jobs'].get('policy') or {}).get('outputs', {}).get('reasons')
        return None


def describe(event: dict) -> str:
    kind = event['kind']
    if kind == 'pr':
        return f'{event["at"]}m pull_request {event["action"]}' + (f' `{event["label"]}`' if event.get('label') else '') \
            + f' by {event["token"]}'
    if kind == 'action':
        return f'{event["at"]}m scenario: {" ".join(str(a) for a in event["action"][:3])}'
    if kind == 'schedule':
        return f'{event["at"]}m schedule {event["workflow"]}'
    if kind == 'workflow_dispatch':
        return f'{event["at"]}m dispatch {event["workflow"]}'
    if kind == 'workflow_run':
        return f'{event["at"]}m workflow_run {event["name"]} {event["conclusion"]}'
    if kind == 'rerun':
        return f'{event["at"]}m re-run of run {event["run"]}'
    return f'{event["at"]}m {kind}'


def audit_comment(head: str, verdict: str, who: str) -> dict:
    return {'body': f'**Claude audit on `{head[:7]}`**\n\n{verdict}\n', 'created_at': '2026-11-20T10:00:00Z',
            'user': {'login': 'github-actions[bot]' if who != 'user' else 'a-maintainer'},
            'author_association': 'NONE' if who != 'user' else 'OWNER'}


# --- behaviours: the jobs whose decisions matter, run with the tree's own code ---------------------------------------

def changed_paths(world, ctx):
    return world.paths  # a single-PR world: the merge group adds exactly the PR's paths


def b_scope(world, run, job, ctx, cause):
    ts = world.tree.module('test_scope', 'scripts/test-scope.py')
    mac, _ = ts.mac_checks_required(changed_paths(world, ctx))
    text = world.tree.yaml_text('hosted-portable.yml')
    match = re.search(r'docs = (\(.*?\))', text)
    docs = ast.literal_eval(match.group(1)) if match else ()
    paths = changed_paths(world, ctx)
    docs_only = bool(paths) and all(p.endswith('.md') or p.startswith(docs) for p in paths)
    return 'success', {'mac': 'true' if mac else 'false', 'docs_only': 'true' if docs_only else 'false'}


def b_web_changes(world, run, job, ctx, cause):
    text = world.tree.yaml_text('hosted-web.yml')
    match = re.search(r"grep -qE '([^']+)'", text)
    pattern = re.compile(match.group(1)) if match else re.compile('^Web/')
    return 'success', {'web': 'true' if any(pattern.search(p) for p in changed_paths(world, ctx)) else 'false'}


class FakePolicyGitHub:
    """merge_policy.GitHub against the simulated world: the PR's labels and its trusted comments."""

    def __init__(self, world):
        self.w, self.repo = world, REPO

    def pull(self, number):
        return {'labels': [{'name': n} for n in sorted(self.w.labels)], 'author_association': 'MEMBER',
                'user': {'login': 'a-maintainer'}, 'head': {'sha': self.w.head}}

    def comments(self, number):
        rules = self.w.tree.module('lane_merge_rules', 'scripts/lane_merge_rules.py')
        return [c for c in self.w.comments if rules.trusted_comment(c)]


def b_merge_policy(world, run, job, ctx, cause):
    """The tree's merge_policy.blockers(), with its git reads replaced by the world's paths (a member's PR, so the
    sign-off rule has nothing to check) and no inherited holds."""
    policy = world.tree.module('merge_policy', 'scripts/merge_policy.py')
    saved = policy.fetch_head, policy.changes, policy.unsigned_commits, policy.commit_messages
    policy.fetch_head = lambda *a, **k: None
    policy.changes = lambda *a, **k: (sorted(world.paths), {})
    policy.unsigned_commits = lambda *a, **k: []
    policy.commit_messages = lambda *a, **k: ''
    try:
        reasons = policy.blockers(FakePolicyGitHub(world), world.tree.root, 'main', 1, world.head,
                                  classify=lambda paths, diffs: world.tree.classify(paths), inherited=lambda c: [])
    finally:
        policy.fetch_head, policy.changes, policy.unsigned_commits, policy.commit_messages = saved
    if not hasattr(policy, 'verdict'):  # a tree from before #4986 (ci_harness.py --diff reads old trees): red for any hold
        return ('failure' if reasons else 'success'), {'reasons': '; '.join(reasons) or 'may merge'}
    state = policy.verdict([(1, world.head, reasons, False)], queue=ctx['github']['event_name'] == 'merge_group')
    # What the check run shows (#4986): a PR that is only waiting for an audit or the owner's tap leaves the `merge
    # policy` check in progress and the job succeeds, so no runner waits and nothing reads red.
    outputs = {'reasons': '; '.join(reasons) or 'may merge'}
    if state == 'waiting':
        outputs['check'] = 'pending'
    return ('failure' if state == 'failure' else 'success'), outputs


class FakeBridgeGitHub:
    """merge_queue_label_bridge.GitHub against the simulated world."""

    def __init__(self, world, token, cause):
        self.w, self.token, self.cause = world, token, cause

    def pull(self, number):
        w = self.w
        return {'id': 'PR_1', 'number': 1, 'isDraft': False, 'title': w.s.title, 'state': 'OPEN' if w.merged_at is None
                else 'MERGED', 'labels': {'nodes': [{'name': n} for n in sorted(w.labels)]},
                'autoMergeRequest': {'enabledAt': 'now'} if w.auto_merge else None,
                'mergeQueueEntry': {'id': 'MQE'} if w.in_queue else None}

    def open_pulls(self):
        return [self.pull(1)] if self.w.merged_at is None else []

    def comments(self, number):
        return '\n'.join(c['body'] for c in self.w.comments)

    def comment(self, number, body):
        self.w.comments.append({'body': body, 'user': {'login': 'github-actions[bot]'}, 'author_association': 'NONE'})

    def remove_label(self, number, name):
        self.w.change_label(self.w.now, name, False, self.token, self.cause['id'])

    def merge(self, number):
        self.w.auto_merge = True
        self.w.enqueued_by = self.token
        self.w.note(self.cause, f'bridge: auto-merge on (as {self.token})')
        return 0, ''

    def disable_auto(self, number):
        self.w.auto_merge = False
        return 0, ''

    def dequeue(self, node_id):
        self.w.in_queue = False


def b_bridge(world, run, job, ctx, cause):
    bridge = world.tree.module('bridge', 'scripts/merge_queue_label_bridge.py')
    event = ctx['github']['event']
    args = ['--repo', REPO]
    if ctx['github']['event_name'] == 'pull_request_target':
        args += ['--pr', '1', '--action', event['action'], '--label', (event.get('label') or {}).get('name') or '']
    elif (ctx.get('inputs') or {}).get('pr'):
        args += ['--pr', '1', '--action', 'edited']
    else:
        args += ['--sweep']
    out = io.StringIO()
    code = bridge.main(args, github=world.bridge_github(job, cause), out=out)
    world.note(cause, 'bridge: ' + ' | '.join(line for line in out.getvalue().splitlines() if line.strip()))
    return ('success' if code == 0 else 'failure'), {}


class FakeDequeueGitHub:
    def __init__(self, world, token, cause):
        self.w, self.token, self.cause = world, token, cause

    def get(self, path):
        w = self.w
        if path.startswith('actions/runs?event=merge_group'):
            return {'workflow_runs': [{'head_branch': 'gh-readonly-queue/main/pr-1-base', 'head_sha': r['sha'],
                                       'created_at': f'{r["id"]:06d}'} for r in w.runs if r['event'] == 'merge_group']}
        if path.startswith('commits/'):
            sha = path.split('/')[1]
            return {'check_runs': [{'name': c['name'], 'conclusion': None if c['conclusion'] == 'pending' else c['conclusion'],
                                    'status': 'in_progress' if c['conclusion'] == 'pending' else 'completed',
                                    'completed_at': 'x', 'html_url': ''} for c in w.checks.get(sha, {}).values()]}
        if path.startswith('issues/'):
            return list(w.comments)
        return {'workflow_runs': []}

    def queue_heads(self):
        return set()

    def post(self, path, body):
        if path.endswith('/comments'):
            self.w.comments.append({'body': body['body'], 'user': {'login': 'github-actions[bot]'},
                                    'author_association': 'NONE'})
        elif path.endswith('/labels'):
            for label in body['labels']:
                self.w.change_label(self.w.now, label, True, self.token, self.cause['id'])

    def delete(self, path):
        if '/labels/' in path:
            self.w.change_label(self.w.now, path.rsplit('/', 1)[1], False, self.token, self.cause['id'])

    def requeue(self, number):
        """`gh pr merge` with QUEUE_TOKEN (MERGE_QUEUE_TOKEN) when the workflow passes it."""
        token = 'secret:MERGE_QUEUE_TOKEN' if 'MERGE_QUEUE_TOKEN' in SNAPSHOT['secrets'] else self.token
        if token[len('secret:'):] in getattr(self.w.s, 'token_403', ()):
            self.w.note(self.cause, 'dequeued notifier: `gh pr merge` refused, HTTP 403')
            return False
        self.w.auto_merge = True
        self.w.enqueued_by = token
        self.w.note(self.cause, f'dequeued notifier: set to merge again (as {token})')
        return True


def b_dequeued(world, run, job, ctx, cause):
    module = world.tree.module('dequeued', 'scripts/merge_queue_dequeued.py')
    out = io.StringIO()
    did = module.notify(FakeDequeueGitHub(world, job['token'], cause), ctx['github']['event'], out=out)
    world.note(cause, f'dequeued notifier: {did}')
    return 'success', {}


def b_claude_audit(world, run, job, ctx, cause):
    """The audit's eligibility, from the tree's sm_codex_audit.py (the candidate loop around its line 866)."""
    if world.merged_at is not None:
        return 'success', {}
    if world.flags.get('audit_paused'):
        world.note(cause, 'claude-audit: paused (no Claude token, or the head failed twice); posts nothing')
        return 'success', {}
    audit = world.tree.module('audit', 'ops/codex/sm_codex_audit.py')
    rules = world.tree.module('lane_merge_rules', 'scripts/lane_merge_rules.py')
    pr = {'number': 1, 'headRefOid': world.head, 'isDraft': False, 'baseRefName': 'main', 'title': world.s.title,
          'body': ''}
    comments = [c for c in world.comments if rules.trusted_comment(c)]
    files = [{'filename': p} for p in world.paths]
    ok, why, _ = audit.evaluate(pr, comments, None)
    tap_checks_done = False
    if audit.lane_report_missing_for_head(why):
        if audit.touches_owner_tap(files) or audit.risky_areas(world.paths):
            runs = [{'name': c['name'], 'status': 'in_progress' if c['conclusion'] == 'pending' else 'completed',
                     'conclusion': None if c['conclusion'] == 'pending' else c['conclusion']}
                    for c in world.checks.get(world.head, {}).values()]
            state, _ = audit.owner_tap_alert.checks_state(runs, [])
            tap_checks_done = state == 'ok' and bool(runs)
            if not tap_checks_done:
                why = f'checks {state}'
    if why == 'need files' or tap_checks_done:
        ok, why, _ = audit.evaluate(pr, comments, files, tap_checks_done=tap_checks_done)
    if not ok:
        world.note(cause, f'claude-audit: not audited ({why})')
        return 'success', {}
    world.comments.append(audit_comment(world.head, world.s.audit_verdict, 'workflow'))
    world.note(cause, f'claude-audit: audited {world.head[:7]} ({why}), posted with GITHUB_TOKEN')
    if not hasattr(audit, 'rerun_merge_policy'):
        world.note(cause, 'claude-audit: this tree\'s audit has no merge policy re-run')
        return 'success', {}
    policy_runs = [r for r in world.runs if r['workflow'] == 'merge-policy.yml' and r['event'] == 'pull_request'
                   and r['sha'] == world.head]

    def fake_run(cmd, **kwargs):
        if cmd[:2] == ['gh', 'api']:
            body = {'workflow_runs': [{'id': r['id'], 'created_at': f'{r["id"]:06d}', 'status': world.run_status(r)}
                                      for r in policy_runs]}
            return subprocess.CompletedProcess(cmd, 0, json.dumps(body), '')
        if cmd[:3] == ['gh', 'run', 'rerun']:
            world.post(world.now, 'rerun', cause['id'], run=int(cmd[3]), token='github_token')  # A5, A6
            return subprocess.CompletedProcess(cmd, 0, '', '')
        return subprocess.CompletedProcess(cmd, 1, '', 'not modelled')

    # The tree's own rerun_merge_policy decides. The audit calls it only inside a workflow (in_a_workflow), after posting.
    saved, audit.run = audit.run, fake_run
    try:
        said = audit.rerun_merge_policy(world.head)
    finally:
        audit.run = saved
    world.note(cause, f'claude-audit: {said} (A6)')
    return 'success', {}


def b_main_t3_decide(world, run, job, ctx, cause):
    """main-t3's `decide`: run when main has moved since its last main-t3 (here: once after the PR merged)."""
    moved = world.merged_at is not None and not world.flags.get('_main_t3_done')
    if moved:
        world.flags['_main_t3_done'] = True
    return 'success', {'run': 'true' if moved else 'false'}


def render(template: str, ctx: dict) -> str:
    """A step's `${{ }}` template with each expression evaluated against <ctx>."""
    def value(match):
        result = Expr(match.group(1), ctx, {'success': True, 'failure': False}).evaluate()
        return '' if result is None else str(result)
    return EXPR.sub(value, str(template))


class FakeRearmApi:
    """lane_rearm.GitHubApi against the simulated world. A dispatch of a disabled workflow is refused (A16)."""

    def __init__(self, world, token, cause):
        self.w, self.token, self.cause, self.repo = world, token, cause, REPO

    def get(self, path):
        w = self.w
        workflow = re.match(r'actions/workflows/([\w.-]+\.yml)(/runs)?', path)
        if workflow and not workflow.group(2):
            return {'state': 'disabled_manually' if workflow.group(1) in SNAPSHOT['disabled_workflows'] else 'active'}
        if workflow:
            if 'status=' in path:  # runs take no time (A13), so none is still going
                return {'total_count': 0}
            sha = re.search(r'head_sha=(\w+)', path).group(1)
            return {'total_count': sum(1 for r in w.runs if r['workflow'] == workflow.group(1) and r['sha'] == sha
                                       and r['event'] == 'pull_request')}
        if '/pulls' in path:
            return [] if w.merged_at is not None else [
                {'number': 1, 'state': 'open', 'base': {'ref': 'main'},
                 'head': {'sha': w.head, 'repo': {'full_name': REPO}}, 'labels': [{'name': n} for n in sorted(w.labels)]}]
        raise KeyError(f'the model does not answer GET {path}')

    def dispatch_lane(self, ref, pr, head):
        if 'lane.yml' in SNAPSHOT['disabled_workflows']:
            raise subprocess.CalledProcessError(1, ['gh', 'api', '-X', 'POST', 'actions/workflows/lane.yml/dispatches'],
                                                stderr='HTTP 422: workflow is disabled')
        self.w.post(self.w.now, 'workflow_dispatch', self.cause['id'], workflow='lane.yml',
                    inputs={'pr': str(pr), 'head': head, 'auto': 'true'}, token=self.token)


def b_rearm(world, run, job, ctx, cause):
    """hosted-portable/hosted-web `rearm`: the tree's scripts/lane_rearm.py main(), with the step's own --results
    rendered from the workflow, against FakeRearmApi. A missing script is a green no-op, as the step's guard says."""
    if not (world.tree.root / 'scripts/lane_rearm.py').is_file():
        return 'success', {}
    steps = world.tree.raw(run['workflow'])['jobs'][job['id']].get('steps') or []
    step = next((s for s in steps if 'lane_rearm.py' in str(s.get('run') or '')), None)
    if step is None:
        return 'success', {}
    results = render((step.get('env') or {}).get('RESULTS', ''), ctx)
    module = world.tree.module('lane_rearm', 'scripts/lane_rearm.py')
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = module.main(['--repo', REPO, '--trunk', 'main', '--head', world.head, '--results', results],
                           api=FakeRearmApi(world, job['token'], cause), out=out)
    lines = [line for line in out.getvalue().splitlines() if line.strip()]
    world.note(cause, f'{run["workflow"]} rearm: ' + (' | '.join(lines) or 'nothing to do'))
    return ('success' if code == 0 else 'failure'), {}


BEHAVIOURS = {
    ('main-t3.yml', 'decide'): b_main_t3_decide,
    ('hosted-portable.yml', 'rearm'): b_rearm,
    ('hosted-web.yml', 'rearm'): b_rearm,
    ('hosted-portable.yml', 'scope'): b_scope,
    ('hosted-web.yml', 'changes'): b_web_changes,
    ('merge-policy.yml', 'policy'): b_merge_policy,
    ('merge-queue-label-bridge.yml', 'bridge'): b_bridge,
    ('merge-queue-dequeued.yml', 'dequeued'): b_dequeued,
    ('claude-audit.yml', 'audit'): b_claude_audit,
}


def simulate(scenario: Scenario, tree: Tree) -> dict:
    world = World(copy.deepcopy(scenario), tree)
    result = world.simulate()
    result['log'] = [f'{e["at"]}m {e["text"]}' for e in world.log]
    return result


def run_all(tree: Tree) -> dict[str, dict]:
    return {s.name: simulate(s, tree) for s in scenarios()}


# --- diff -----------------------------------------------------------------------------------------------------------

TREE_PATHS = ['.github', 'scripts', 'ops', 'project.yml', 'TestPlans']


def unpack(ref: str, into: Path) -> Path:
    """The files the model reads, as they are at <ref>."""
    present = [p for p in TREE_PATHS
               if subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', f'{ref}:{p}'],
                                 capture_output=True).returncode == 0]
    data = subprocess.run(['git', '-C', str(ROOT), 'archive', '--format=tar', ref, *present],
                          capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        tar.extractall(into, filter='data')
    return into


def summary(outcome: dict) -> str:
    if outcome['merged']:
        text = f'merged at {outcome["merged_at_minute"]}m'
        if outcome.get('relied_on_schedule'):
            text += f' (waited on schedule: {", ".join(outcome["relied_on_schedule"])})'
        if outcome['main_broken']:
            text += f'; main broken, first seen by {outcome["main_broken"]["detected_by"]}'
        return text
    loop = f'; {outcome["merge_groups"]} merge groups (re-queue loop)' if outcome['merge_groups'] >= MAX_GROUPS else ''
    return 'stuck: ' + '; '.join(outcome['why']) + loop + f'; labels: {", ".join(outcome["labels"]) or "none"}'


def static_diff(old: dict, new: dict) -> list[str]:
    lines = []
    for file in sorted(set(old['workflows']) | set(new['workflows'])):
        a, b = old['workflows'].get(file), new['workflows'].get(file)
        if a is None or b is None:
            lines.append(f'{file}: {"added" if a is None else "removed"}')
            continue
        if a['triggers'] != b['triggers']:
            lines.append(f'{file}: triggers changed')
        for job in sorted(set(a['jobs']) | set(b['jobs'])):
            ja, jb = a['jobs'].get(job), b['jobs'].get(job)
            if ja is None or jb is None:
                lines.append(f'{file} {job}: job {"added" if ja is None else "removed"}')
            else:
                for key in ('check', 'if', 'needs', 'token', 'scripts'):
                    if ja[key] != jb[key]:
                        lines.append(f'{file} {job}: {key} changed')
        if [e['kind'] for e in a['effects']] != [e['kind'] for e in b['effects']]:
            lines.append(f'{file}: effects of its scripts changed')
    return lines


def diff(base: str, head: str | None, out=sys.stdout) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        old_tree = Tree(unpack(base, Path(tmp) / 'base'))
        new_tree = Tree(unpack(head, Path(tmp) / 'head') if head else ROOT)
        old, new = run_all(old_tree), run_all(new_tree)
        changes = static_diff(old_tree.model, new_tree.model)
    print(f'CI model diff: {base} -> {head or "working tree"}', file=out)
    print(f'Static changes: {len(changes)}', file=out)
    for line in changes:
        print(f'  {line}', file=out)
    changed = [name for name in old if summary(old[name]) != summary(new[name])]
    print(f'Scenarios that change outcome: {len(changed)} of {len(old)}', file=out)
    for name in changed:
        print(f'  {name}\n    before: {summary(old[name])}\n    after:  {summary(new[name])}', file=out)
    return 0


# --- command line ---------------------------------------------------------------------------------------------------

def refresh_live():
    """Re-read the repository state that is not in the files (needs `gh` and network)."""
    def gh(*args):
        return json.loads(subprocess.run(['gh', *args], capture_output=True, text=True, check=True).stdout)
    rules = gh('api', f'repos/{REPO}/rulesets/{SNAPSHOT["ruleset"]["id"]}')['rules']
    for rule in rules:
        if rule['type'] == 'required_status_checks':
            SNAPSHOT['ruleset']['required_checks'] = [c['context'] for c in
                                                      rule['parameters']['required_status_checks']]
        if rule['type'] == 'merge_queue':
            SNAPSHOT['ruleset']['merge_queue'].update(rule['parameters'])
    SNAPSHOT['variables'] = {v['name']: v['value'] for v in gh('variable', 'list', '--json', 'name,value')}
    SNAPSHOT['secrets'] = [s['name'] for s in gh('secret', 'list', '--json', 'name')]
    SNAPSHOT['disabled_workflows'] = [Path(w['path']).name for w in gh('workflow', 'list', '--all', '--json',
                                                                       'path,state') if w['state'] != 'active']
    SNAPSHOT['taken'] = 'live'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--extract', action='store_true', help='print the static model as JSON')
    parser.add_argument('--diff', nargs='+', metavar='REF', help='BASE [HEAD]: scenarios that change outcome')
    parser.add_argument('--scenario', help='run one scenario and print its event log')
    parser.add_argument('--live', action='store_true', help='re-read ruleset, variables, secrets and workflow state')
    parser.add_argument('--json', action='store_true', help='print outcomes as JSON')
    args = parser.parse_args(argv)
    if args.live:
        refresh_live()
    if args.extract:
        json.dump(extract(ROOT), sys.stdout, indent=1, default=str)
        print()
        return 0
    if args.diff:
        return diff(args.diff[0], args.diff[1] if len(args.diff) > 1 else None)
    tree = Tree(ROOT)
    chosen = [s for s in scenarios() if not args.scenario or s.name == args.scenario]
    if not chosen:
        parser.error(f'no scenario {args.scenario}; have {", ".join(s.name for s in scenarios())}')
    results = {s.name: simulate(s, tree) for s in chosen}
    if args.json:
        json.dump(results, sys.stdout, indent=1, default=str)
        print()
        return 0
    for s in chosen:
        result = results[s.name]
        print(f'{s.name}: {summary(result)}')
        if args.scenario:
            print(f'  {s.description}')
            for line in result['log']:
                print(f'    {line}')
            for line in result.get('path', []):
                print(f'  path: {line}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
