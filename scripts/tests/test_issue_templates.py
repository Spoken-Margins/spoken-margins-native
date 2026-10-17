"""The issue templates a stranger sees must ask for what a person gives, and no template may label itself `ready` (#1848).

A `ready` issue is a task a thread follows, so a template that adds it (or `priority` or `automerge`) would let whoever
opens an issue put text in front of an agent. Outsider templates carry only `needs-triage-review`; the internal
template carries no label, and a collaborator adds `ready` by hand. Parsed by hand (flat `key: value` lines) so the
test needs no YAML package.
"""
import re
import unittest
from pathlib import Path

TEMPLATES = Path(__file__).resolve().parents[2] / '.github' / 'ISSUE_TEMPLATE'
FORBIDDEN_LABELS = {'ready', 'priority', 'automerge'}
OUTSIDER = {'bug.md', 'idea.md'}


def front_matter(path):
    text = path.read_text()
    match = re.match(r'---\n(.*?)\n---\n', text, re.DOTALL)
    assert match, f'{path.name} has no front matter'
    fields = {}
    for line in match.group(1).splitlines():
        key, sep, value = line.partition(':')
        assert sep and re.fullmatch(r'[a-z_]+', key), f'{path.name}: not a "key: value" line: {line!r}'
        fields[key] = value.strip().strip('"\'')
    return fields


def labels(fields):
    return {label.strip() for label in fields.get('labels', '').split(',') if label.strip()}


class IssueTemplateTests(unittest.TestCase):
    def test_every_markdown_template_has_valid_front_matter(self):
        paths = sorted(TEMPLATES.glob('*.md'))
        self.assertTrue(OUTSIDER <= {p.name for p in paths}, 'bug.md and idea.md must exist')
        self.assertIn('internal-task.md', {p.name for p in paths})
        for path in paths:
            with self.subTest(path.name):
                fields = front_matter(path)
                self.assertTrue(fields.get('name'), 'name')
                self.assertTrue(fields.get('about'), 'about')

    def test_no_template_adds_ready_priority_or_automerge(self):
        for path in sorted(TEMPLATES.glob('*.md')):
            with self.subTest(path.name):
                self.assertEqual(labels(front_matter(path)) & FORBIDDEN_LABELS, set())

    def test_outsider_templates_set_only_needs_triage_review(self):
        for name in sorted(OUTSIDER):
            with self.subTest(name):
                self.assertEqual(labels(front_matter(TEMPLATES / name)), {'needs-triage-review'})

    def test_the_internal_template_says_who_it_is_for_and_the_old_name_is_gone(self):
        self.assertFalse((TEMPLATES / 'agent-task.md').exists())
        body = (TEMPLATES / 'internal-task.md').read_text()
        self.assertIn('owner and collaborators', body.split('---', 2)[2][:400])
        for heading in ('**Outcome.**', '**Evidence.**', '**Done when**', '**Must not break:**'):
            self.assertIn(heading, body)

    def test_outsider_templates_ask_what_a_person_gives_and_nothing_agent_shaped(self):
        for name in sorted(OUTSIDER):
            with self.subTest(name):
                body = (TEMPLATES / name).read_text()
                self.assertNotRegex(body, r'\*\*(Done when|Must not break|Tier|Likely files|Taken by)')
        bug = (TEMPLATES / 'bug.md').read_text()
        for heading in ('**What happened.**', '**What you expected.**', '**Steps.**', '**Which build.**'):
            self.assertIn(heading, bug)

    def test_config_allows_blank_issues_and_links_security_and_contributing(self):
        config = (TEMPLATES / 'config.yml').read_text()
        self.assertRegex(config, r'(?m)^blank_issues_enabled: true$')
        urls = re.findall(r'(?m)^\s+url: (\S+)$', config)
        self.assertTrue(any(url.endswith('/security/policy') for url in urls), urls)
        self.assertTrue(any('CONTRIBUTING.md' in url for url in urls), urls)
        self.assertEqual(len(re.findall(r'(?m)^  - name: ', config)), len(urls))
        self.assertEqual(len(re.findall(r'(?m)^    about: ', config)), len(urls))


if __name__ == '__main__':
    unittest.main()
