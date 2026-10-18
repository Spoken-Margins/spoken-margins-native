"""The public overview pages must match the repository (#1846).

Pages in docs/overview/ are written for readers outside the project. They go stale the usual way: a file moves and the
page still names it. This test checks that every relative link, every heading anchor and every path in a code span
points at something that exists, and that no page carries a home directory or the project's server hostname.

Two path shorthands are defined in offline-and-privacy.md and expanded here: `{app}` is the app's source folder and
`{kit}` is Packages/SessionKit/Sources. A code span with an ellipsis, a space, a leading slash or a URL is not a path.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGES = ROOT / 'docs' / 'overview'
SHORTHANDS = {
    '{app}': 'App/SpokenMarginsApp/Sources/SpokenMarginsApp',
    '{kit}': 'Packages/SessionKit/Sources',
}
EXPECTED = {'architecture.md', 'compatibility.md', 'offline-and-privacy.md'}
FORBIDDEN = ('/Users/', '/home/', 'proximitytoprogress', 'C:\\')


def slug(heading):
    text = re.sub(r'[`*_]', '', heading.strip().lower())
    return re.sub(r'\s', '-', re.sub(r'[^\w\s-]', '', text))


def anchors(path):
    return {slug(m.group(1)) for m in re.finditer(r'(?m)^#{1,6}\s+(.*)$', path.read_text())}


def prose(path):
    """The page without fenced code blocks (the diagram's labels are not paths)."""
    return re.sub(r'```.*?```', '', path.read_text(), flags=re.DOTALL)


def path_spans(text):
    for span in re.findall(r'`([^`\n]+)`', text):
        if '/' not in span or re.search(r'[\s…]|^/|://|^#', span):
            continue
        yield span


class OverviewDocsTests(unittest.TestCase):
    def test_the_three_pages_exist(self):
        self.assertEqual({p.name for p in PAGES.glob('*.md')}, EXPECTED)

    def test_every_relative_link_and_anchor_resolves(self):
        for page in sorted(PAGES.glob('*.md')):
            for target in re.findall(r'\]\(([^)\s]+)\)', prose(page)):
                if re.match(r'[a-z]+:', target):
                    continue
                with self.subTest(f'{page.name}: {target}'):
                    file_part, _, fragment = target.partition('#')
                    destination = page if not file_part else (page.parent / file_part).resolve()
                    self.assertTrue(destination.exists(), f'{target} does not exist')
                    if fragment and destination.suffix == '.md':
                        self.assertIn(fragment, anchors(destination), f'{target}: no such heading')

    def test_every_path_named_in_a_code_span_exists(self):
        for page in sorted(PAGES.glob('*.md')):
            for span in sorted(set(path_spans(prose(page)))):
                with self.subTest(f'{page.name}: {span}'):
                    candidate = span
                    for short, full in SHORTHANDS.items():
                        if span.startswith(short):
                            candidate = full + span[len(short):]
                    self.assertTrue((ROOT / candidate).exists(), f'{span} does not exist')

    def test_pages_carry_no_home_paths_or_server_hostname(self):
        for page in sorted(PAGES.glob('*.md')):
            text = page.read_text()
            for bad in FORBIDDEN:
                with self.subTest(f'{page.name}: {bad}'):
                    self.assertNotIn(bad, text)

    def test_readme_links_all_three_pages(self):
        readme = (ROOT / 'README.md').read_text()
        for name in sorted(EXPECTED):
            with self.subTest(name):
                self.assertIn(f'docs/overview/{name}', readme)


if __name__ == '__main__':
    unittest.main()
