"""Workflow files as the parsed YAML GitHub reads, for tests that guard what a workflow does (#3704, the #1903 class).

A test that greps a workflow's text passes when the guard is turned into a comment, so these helpers answer from the
parsed file: a job's `if` as a value, its effective permissions, every place a secret is named. Parsing is PyYAML, or
Ruby when PyYAML is missing, as test_workflow_files.parse does.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_workflow_files import ROOT, parse  # noqa: E402


def load(name: str) -> dict:
    """.github/workflows/<name> as parsed YAML. A comment never reaches the result."""
    return parse(ROOT / '.github' / 'workflows' / name)


def effective_permissions(workflow: dict, job: str) -> dict:
    """What the job's token can do: its own `permissions` block when it has one (it replaces the workflow's, it does
    not add to it), else the workflow's."""
    own = workflow['jobs'][job].get('permissions')
    return dict(own if own is not None else workflow.get('permissions') or {})


def checkout_steps(workflow: dict) -> list[tuple[str, dict]]:
    """(job, `with` block) of every actions/checkout step."""
    return [(job, step.get('with') or {}) for job, body in workflow['jobs'].items() for step in body.get('steps', [])
            if str(step.get('uses', '')).startswith('actions/checkout@')]


def mentions_of(node, word: str, where: str = '') -> list[str]:
    """The path (job, step name, key) of every string value in a parsed workflow that names `word` as a context,
    `secrets.X`, `secrets['X']` or `toJSON(secrets)` alike. A key with no such value, and a comment, are not listed."""
    found = []
    pattern = re.compile(r'\b' + re.escape(word) + r'\b')
    if isinstance(node, dict):
        label = node.get('name') or node.get('id') or ''
        for key, value in node.items():
            found += mentions_of(value, word, f'{where}/{label}.{key}' if label and key in ('env', 'with', 'run', 'if')
                                 else f'{where}/{key}')
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found += mentions_of(value, word, f'{where}[{index}]')
    elif isinstance(node, str) and pattern.search(node):
        found.append(where)
    return found


def evaluate_condition(expression, **context) -> bool:
    """Run a job's `if:` for the contexts given, as GitHub would, for the small expressions this repo writes:
    `a.b != 'x' || c == 'y'` with dotted names, strings, == != && || ! and parentheses. `context` maps each dotted name
    with its dots as underscores, `github_event_name='push'`. A bare YAML `true` (the guard replaced) is True."""
    if isinstance(expression, bool):
        return expression
    text = str(expression).strip()
    if text.startswith('${{') and text.endswith('}}'):
        text = text[3:-2].strip()
    names = {}

    def name(match):
        key = match.group(0).replace('.', '_')
        names[key] = context[key]  # a name the test did not supply is a KeyError: the expression grew
        return key
    code = re.sub(r"'[^']*'", lambda m: repr(m.group(0)[1:-1]), text)
    code = re.sub(r'(?<![\w\'"])[A-Za-z_]\w*(?:\.\w+)+(?![\w\'"])', name, code)
    code = code.replace('||', ' or ').replace('&&', ' and ')
    code = re.sub(r'!(?!=)', ' not ', code)
    if re.search(r'[^\w\s\'"=!()]', code.replace(' or ', '').replace(' and ', '')):
        raise AssertionError(f'a condition this helper does not evaluate: {text!r}')
    return bool(eval(code, {'__builtins__': {}}, names))  # noqa: S307 - names and quoted strings only
