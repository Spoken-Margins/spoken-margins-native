"""The `if:` conditions in .github/workflows/lane.yml, evaluated instead of grepped (#1903).

test_lane_dedupe, test_lane_sender and test_lane_runner assertIn the text of a condition. Flipping the
lane job's `&&` to `||` keeps every one of them green while the Mac job runs for a stranger's PR. Here the
`if:` of the `lane` and `automerge` jobs, and the route job's `skip_*` outputs, are parsed and evaluated over
a table of cases, and each `&&` is flipped in turn to show that some row notices.

The evaluator covers only what lane.yml uses: `!`, `==`, `!=`, `&&`, `||` (which, as in Actions, return an
operand rather than a boolean), parentheses, string/number/bool/null literals, `ctx.a.b` lookups, the
`labels.*.name` filter, and the functions contains, fromJSON, cancelled and always. Anything else raises, so
a new construct in lane.yml fails loudly here instead of being skipped.
"""
import json
import re
import unittest
from pathlib import Path

WORKFLOW = (Path(__file__).resolve().parents[2] / '.github/workflows/lane.yml').read_text()

TOKEN = re.compile(r"\s*(?:(\|\||&&|==|!=)|([!().,])|('(?:[^']|'')*')|(-?\d+(?:\.\d+)?)|([A-Za-z_][\w-]*|\*))")


def tokenize(text):
    tokens, pos = [], 0
    while pos < len(text):
        if not text[pos:].strip():
            break
        match = TOKEN.match(text, pos)
        if not match:
            raise ValueError(f'unsupported expression text at {text[pos:pos + 20]!r}')
        op, punct, string, number, word = match.groups()
        if op or punct:
            tokens.append(('op', op or punct))
        elif string is not None:
            tokens.append(('lit', string[1:-1].replace("''", "'")))
        elif number is not None:
            tokens.append(('lit', float(number)))
        else:
            tokens.append(('word', word))
        pos = match.end()
    return tokens


def truthy(value):
    return value not in (False, None, '', 0, 0.0)


def loosely_equal(left, right):
    if left is None:
        left = ''
    if right is None:
        right = ''
    if isinstance(left, str) and isinstance(right, str):
        return left.lower() == right.lower()
    if isinstance(left, (list, dict)) or isinstance(right, (list, dict)):
        return left is right
    return number(left) == number(right)


def number(value):
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if value == '':
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError):
        return float('nan')


class Evaluator:
    """Recursive descent over the token list, evaluating as it parses (no short-circuit needed: lookups are pure)."""

    def __init__(self, text, context, functions):
        self.tokens, self.at = tokenize(text), 0
        self.context, self.functions = context, functions

    def peek(self):
        return self.tokens[self.at] if self.at < len(self.tokens) else (None, None)

    def take(self, kind=None, value=None):
        token = self.peek()
        if token[0] is None or (kind and token[0] != kind) or (value and token[1] != value):
            raise ValueError(f'expected {value or kind}, found {token}')
        self.at += 1
        return token

    def run(self):
        result = self.disjunction()
        if self.at != len(self.tokens):
            raise ValueError(f'trailing tokens {self.tokens[self.at:]}')
        return result

    def disjunction(self):
        value = self.conjunction()
        while self.peek() == ('op', '||'):
            self.take()
            right = self.conjunction()
            value = value if truthy(value) else right
        return value

    def conjunction(self):
        value = self.equality()
        while self.peek() == ('op', '&&'):
            self.take()
            right = self.equality()
            value = right if truthy(value) else value
        return value

    def equality(self):
        value = self.unary()
        while self.peek() in (('op', '=='), ('op', '!=')):
            op = self.take()[1]
            same = loosely_equal(value, self.unary())
            value = same if op == '==' else not same
        return value

    def unary(self):
        if self.peek() == ('op', '!'):
            self.take()
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, value = self.peek()
        if (kind, value) == ('op', '('):
            self.take()
            inner = self.disjunction()
            self.take('op', ')')
            return inner
        if kind == 'lit':
            self.take()
            return value
        if kind != 'word':
            raise ValueError(f'unexpected {value!r}')
        self.take()
        if value in ('true', 'false', 'null'):
            return {'true': True, 'false': False, 'null': None}[value]
        if self.peek() == ('op', '('):
            self.take()
            args = []
            while self.peek() != ('op', ')'):
                args.append(self.disjunction())
                if self.peek() == ('op', ','):
                    self.take()
            self.take('op', ')')
            if value.lower() not in self.functions:
                raise ValueError(f'unsupported function {value}')
            return self.functions[value.lower()](*args)
        return self.lookup(value)

    def lookup(self, first):
        path = [first]
        while self.peek() == ('op', '.'):
            self.take()
            path.append(self.take('word')[1])
        return resolve(self.context, path)


def resolve(node, path):
    if not path:
        return node
    head, rest = path[0], path[1:]
    if head == '*':
        return [resolve(item, rest) for item in node]
    if isinstance(node, list):
        raise ValueError(f'cannot index a list with {head!r}; use .*.')
    if not isinstance(node, dict) or head not in node:
        return None  # an unset context value reads as null, as in Actions
    return resolve(node[head], rest)


def contains(haystack, needle):
    if isinstance(haystack, list):
        return any(loosely_equal(item, needle) for item in haystack)
    return str(needle).lower() in str(haystack or '').lower()


def evaluate(expression, context, cancelled=False):
    functions = {
        'contains': contains,
        'startswith': lambda text, prefix: str(text or '').lower().startswith(str(prefix or '').lower()),
        'fromjson': lambda text: json.loads(text),
        'cancelled': lambda: cancelled,
        'always': lambda: True,
    }
    return Evaluator(expression, context, functions).run()


# ---- Reading lane.yml -------------------------------------------------------------------------------------

def job_text(job):
    parts = re.split(r'\n  (?=[A-Za-z][\w-]*:\n)', '\n' + WORKFLOW.split('\njobs:\n', 1)[1])[1:]
    for part in parts:
        if part.startswith(f'{job}:\n'):
            return part
    raise AssertionError(f'lane.yml has no job {job!r}')


def job_condition(job):
    """The job's own `if:` (four spaces in), with a folded `>-` block joined by single spaces."""
    lines = job_text(job).splitlines()
    for number_, line in enumerate(lines):
        match = re.fullmatch(r'    if: (.*)', line)
        if not match:
            continue
        if match[1].strip() not in ('>-', '>'):
            return match[1].strip()
        body = []
        for follower in lines[number_ + 1:]:
            if follower.strip() and not follower.startswith(' ' * 6):
                break
            body.append(follower.strip())
        return ' '.join(part for part in body if part)
    raise AssertionError(f'job {job!r} has no if:')


def job_output(job, name):
    for line in job_text(job).splitlines():
        match = re.fullmatch(rf'      {name}: \$\{{\{{ (.*) \}}\}}', line)
        if match:
            return match[1]
    raise AssertionError(f'job {job!r} has no output {name!r}')


# ---- The cases --------------------------------------------------------------------------------------------

REPO = 'owner/repo'


def pull_request_context(labels, action='synchronize', label='', head_repo=REPO, route=None, base='main',
                         trunk=None):
    """<trunk> is the SM_TRUNK repository variable (#1492): None while it is unset, so the trunk is main."""
    return {
        'vars': {} if trunk is None else {'SM_TRUNK': trunk},
        'github': {
            'repository': REPO,
            'event': {
                'action': action,
                'label': {'name': label},
                'pull_request': {
                    'head': {'repo': {'full_name': head_repo}},
                    'base': {'ref': base},
                    'labels': [{'name': name} for name in labels],
                },
            },
        },
        'needs': {'route': {'outputs': route or {}}},
    }


def skip_rows(label_name, skip_output):
    """(case, context, cancelled, should the Mac job run) for the lane or automerge job."""
    other_skip = 'skip_automerge' if skip_output == 'skip_lane' else 'skip_lane'

    def row(name, run, labels=None, cancelled=False, **kwargs):
        route = kwargs.pop('route', {})
        labels = [label_name] if labels is None else labels
        return name, pull_request_context(labels, route=route, **kwargs), cancelled, run

    return [
        row('same-repo push with the label', True),
        row('the label was just added', True, action='labeled', label=label_name),
        row('skip output explicitly false', True, route={skip_output: 'false'}),
        row('skip output unset', True, route={skip_output: ''}),
        row('the other queue is skipped, this one is not', True, route={other_skip: 'true'}),
        row('route says skip this queue', False, route={skip_output: 'true'}),
        row('route says skip this queue, label just added', False, action='labeled', label=label_name,
            route={skip_output: 'true'}),
        row('route says skip both queues', False, route={'skip_lane': 'true', 'skip_automerge': 'true'}),
        row('head is a fork', False, head_repo='stranger/repo'),
        row('head is a fork whose route output is unset', False, head_repo='stranger/repo', route={skip_output: ''}),
        row('the label is missing', False, labels=['bug']),
        row('no labels at all', False, labels=[]),
        row('another label was just added', False, labels=[label_name, 'bug'], action='labeled', label='bug'),
        row('the run was cancelled', False, cancelled=True),
        # #1492: only PRs into the trunk (SM_TRUNK, main while unset) or a lane-check base start a Mac job.
        row('a PR into the retired next', False, base='next'),
        row('a PR into main with SM_TRUNK set', True, base='main', trunk='main'),
        row('a PR into next with SM_TRUNK=main', False, base='next', trunk='main'),
        row('SM_TRUNK set to next', True, base='next', trunk='next'),
        row('a PR into main with SM_TRUNK=next', False, base='main', trunk='next'),
        row('a lane-check base', True, base='lane-check/try-it'),
        row('a lane-check base with SM_TRUNK set', True, base='lane-check/try-it', trunk='main'),
        row('a lane-check lookalike', False, base='main-lane-check/x'),
        row('cancelled and the route skips', False, cancelled=True, route={skip_output: 'true'}),
    ]


def failing_rows(expression, rows):
    failures = []
    for name, context, cancelled, expected in rows:
        got = truthy(evaluate(expression, context, cancelled=cancelled))
        if got != expected:
            failures.append(f'{name}: expected {"run" if expected else "skip"}, got {"run" if got else "skip"}')
    return failures


def and_positions(expression):
    return [match.start() for match in re.finditer(r'&&', expression)]


class MacJobConditions(unittest.TestCase):
    JOBS = (('lane', 'lane:queued', 'skip_lane'), ('automerge', 'automerge', 'skip_automerge'))

    def test_each_mac_job_runs_only_for_its_label_a_same_repo_head_and_no_skip(self):
        for job, label, skip in self.JOBS:
            with self.subTest(job=job):
                self.assertEqual(failing_rows(job_condition(job), skip_rows(label, skip)), [])

    def test_flipping_any_and_in_a_condition_makes_some_case_fail(self):
        # The #1903 audit's mutation: `skip_lane != 'true' &&` became `||`, every old test still passed.
        for job, label, skip in self.JOBS:
            expression = job_condition(job)
            rows = skip_rows(label, skip)
            positions = and_positions(expression)
            self.assertGreaterEqual(len(positions), 4, f'{job} condition changed shape: {expression}')
            for at in positions:
                with self.subTest(job=job, flipped=expression[max(0, at - 40):at + 12]):
                    mutant = expression[:at] + '||' + expression[at + 2:]
                    self.assertNotEqual(failing_rows(mutant, rows), [], 'no case notices this flip')

    def test_dropping_or_inverting_the_skip_clause_is_noticed(self):
        for job, label, skip in self.JOBS:
            expression = job_condition(job)
            clause = f"needs.route.outputs.{skip} != 'true'"
            self.assertIn(clause, expression)
            rows = skip_rows(label, skip)
            with self.subTest(job=job, mutation='dropped'):
                self.assertNotEqual(failing_rows(expression.replace(clause + ' &&', ''), rows), [])
            with self.subTest(job=job, mutation='inverted'):
                self.assertNotEqual(failing_rows(expression.replace(clause, clause.replace('!=', '==')), rows), [])


def route_outputs(sender_trusted, dedupe):
    """What the route job publishes, from its own output expressions, for given step outputs."""
    context = {'steps': {'sender': {'outputs': {} if sender_trusted is None else {'trusted': sender_trusted}},
                         'dedupe': {'outputs': dedupe}}}
    return {name: evaluate(job_output('route', name), context) for name in ('skip_lane', 'skip_automerge')}


class RouteSkipOutputs(unittest.TestCase):
    def test_a_stranger_skips_both_queues_whatever_dedupe_says(self):
        for dedupe in ({}, {'skip_lane': 'false', 'skip_automerge': 'false'}, {'skip_lane': 'true'}):
            with self.subTest(dedupe=dedupe):
                self.assertEqual(route_outputs('false', dedupe), {'skip_lane': 'true', 'skip_automerge': 'true'})

    def test_a_trusted_sender_gets_dedupes_answer_and_a_missing_answer_means_run(self):
        self.assertEqual(route_outputs('true', {}), {'skip_lane': None, 'skip_automerge': None})
        self.assertEqual(route_outputs('true', {'skip_lane': 'true', 'skip_automerge': 'false'}),
                         {'skip_lane': 'true', 'skip_automerge': 'false'})
        self.assertEqual(route_outputs(None, {'skip_automerge': 'true'}),
                         {'skip_lane': None, 'skip_automerge': 'true'})  # sender step never ran: dedupe decides

    def test_neither_mac_job_starts_for_a_stranger_and_a_trusted_pr_still_does(self):
        for job, label, skip in MacJobConditions.JOBS:
            expression = job_condition(job)
            for trusted, expected in (('false', False), ('true', True)):
                route = {name: ('' if value is None else value)
                         for name, value in route_outputs(trusted, {}).items()}
                context = pull_request_context([label], route=route)
                with self.subTest(job=job, trusted=trusted):
                    self.assertEqual(truthy(evaluate(expression, context)), expected)

    @staticmethod
    def output_failures(expression, name):
        rows = [  # (sender step output, dedupe output, does the queue start)
            ('false', '', False), ('false', 'false', False), ('false', 'true', False),
            ('true', '', True), ('true', 'false', True), ('true', 'true', False),
            (None, '', True), (None, 'true', False),
        ]
        failures = []
        for trusted, dedupe, starts in rows:
            context = {'steps': {'sender': {'outputs': {} if trusted is None else {'trusted': trusted}},
                                 'dedupe': {'outputs': {name: dedupe}}}}
            if loosely_equal(evaluate(expression, context), 'true') == starts:
                failures.append((trusted, dedupe))
        return failures

    def test_flipping_the_stranger_clause_in_a_route_output_is_noticed(self):
        for name in ('skip_lane', 'skip_automerge'):
            expression = job_output('route', name)
            self.assertEqual(self.output_failures(expression, name), [])
            self.assertIn(" && 'true' || ", expression)
            mutants = [expression.replace(" && 'true' || ", " || 'true' && "),
                       expression.replace("== 'false'", "== 'true'"),
                       expression.replace("steps.sender.outputs.trusted == 'false' && 'true' || ", "")]
            for mutant in mutants:
                with self.subTest(output=name, mutant=mutant):
                    self.assertNotEqual(self.output_failures(mutant, name), [])


class EvaluatorBehavesLikeActions(unittest.TestCase):
    """The evaluator itself, so a wrong evaluator cannot make the table above agree with a wrong workflow."""

    def check(self, expression, expected, context=None):
        self.assertEqual(evaluate(expression, context or {}), expected, expression)

    def test_and_or_return_operands(self):
        self.check("'a' && 'b'", 'b')
        self.check("'' && 'b'", '')
        self.check("'' || 'b'", 'b')
        self.check("'a' || 'b'", 'a')
        self.check("false && 'x' || 'y'", 'y')

    def test_precedence(self):
        self.check('true || false && false', True)
        self.check('(true || false) && false', False)
        self.check('!false && false', False)
        self.check("'a' != 'b' && 'c' == 'C'", True)

    def test_unset_values_are_null_and_compare_equal_to_empty(self):
        self.check("x.y.z == ''", True)
        self.check("x.y.z != 'true'", True)
        self.check('!x', True)

    def test_label_filter_and_contains(self):
        context = {'labels': [{'name': 'Automerge'}, {'name': 'bug'}]}
        self.check("contains(labels.*.name, 'automerge')", True, context)
        self.check("contains(labels.*.name, 'lane:queued')", False, context)

    def test_unsupported_syntax_raises(self):
        with self.assertRaises(ValueError):
            evaluate('github.event.x < 3', {})
        with self.assertRaises(ValueError):
            evaluate("endsWith('a', 'a')", {})

    def test_startswith_ignores_case_and_reads_null_as_empty(self):
        self.check("startsWith('lane-check/x', 'lane-check/')", True)
        self.check("startsWith('Lane-Check/x', 'lane-check/')", True)
        self.check("startsWith('next', 'lane-check/')", False)
        self.check("startsWith(github.x, 'lane-check/')", False)
        self.check("vars.SM_TRUNK || 'main'", 'main')
        self.check("vars.SM_TRUNK || 'main'", 'next', {'vars': {'SM_TRUNK': 'next'}})


class WorkflowShape(unittest.TestCase):
    """What the evaluated contexts above assume lane.yml wires up: delete these and the table could pass a broken file."""

    def test_the_mac_jobs_wait_for_route_so_its_skip_outputs_exist(self):
        # Without `needs: route`, needs.route.outputs.skip_* reads as '' and `!= 'true'` is always true.
        for job, _, _ in MacJobConditions.JOBS:
            with self.subTest(job=job):
                self.assertRegex(job_text(job), r'\n    needs: route\n')

    def test_the_route_outputs_read_the_steps_that_set_them(self):
        route = job_text('route')
        for step in ('sender', 'dedupe'):
            with self.subTest(step=step):
                self.assertRegex(route, rf'\n        id: {step}\n')

    def test_conditions_are_read_whole(self):
        lane = job_condition('lane')
        self.assertTrue(lane.startswith('!cancelled() &&'), lane)
        self.assertNotIn('\n', lane)
        self.assertIn("needs.route.outputs.skip_lane != 'true'", lane)


if __name__ == '__main__':
    unittest.main()
