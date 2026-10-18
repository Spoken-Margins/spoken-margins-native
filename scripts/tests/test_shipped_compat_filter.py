"""The shipped-build-compat path filter names every file that defines a stored type (#1900).

.github/workflows/shipped-build-compat.yml runs only on PRs that touch one of its `paths`, and the list of
SessionKit files in it is kept by hand. `Item.linkedEpisode` held a Codable `LinkedEpisode` for builds while its
file was missing from the list, so a change to it never ran the Build 29 database check. This test finds the
Codable types a stored model reaches and fails when the file defining one is outside the filter.

Reach: start at every type declared in a `*Models*.swift` file of SessionKit; follow stored-property type
annotations and enum case payloads to other SessionKit types. A reached type that is Codable is stored or sent in
a packet. Types reached only from logic (an engine, a composer, a journal) are not followed: add their file to the
filter by hand when they gain a stored shape.
"""
import fnmatch
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'Packages' / 'SessionKit' / 'Sources' / 'SessionKit'
WORKFLOW = ROOT / '.github' / 'workflows' / 'shipped-build-compat.yml'

DECLARATION = re.compile(
    r'^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|fileprivate|private|final|indirect|open)\s+)*'
    r'(?:struct|class|enum|actor)\s+(\w+)([^{]*)\{', re.M)
TYPE_NAME = re.compile(r'\b[A-Z]\w+\b')
STORED_PROPERTY = re.compile(r'\b(?:let|var)\s+\w+\s*:\s*([^=\n{]+)')
CASE_PAYLOAD = re.compile(r'\bcase\s+\w+\(([^)]*)\)')
CODABLE = re.compile(r'\b(?:Codable|Encodable|Decodable)\b')


def without_comments_and_strings(text):
    text = re.sub(r'//[^\n]*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)


def declared_types():
    """name -> (file name, declaration header, body) for every struct, class, enum and actor in SessionKit."""
    found = {}
    for path in sorted(SOURCES.glob('*.swift')):
        text = without_comments_and_strings(path.read_text())
        for match in DECLARATION.finditer(text):
            end, depth = match.end(), 1
            while depth and end < len(text):
                depth += (text[end] == '{') - (text[end] == '}')
                end += 1
            found[match.group(1)] = (path.name, match.group(2), text[match.end():end])
    return found


def stored_codable_types(types):
    """Codable type name -> the chain of types that reaches it from a *Models* file."""
    parent, todo = {}, [(name, None) for name, (file, _, _) in types.items() if 'Models' in file]
    while todo:
        name, came_from = todo.pop()
        if name in parent:
            continue
        parent[name] = came_from
        body = types[name][2]
        for annotation in [m.group(1) for m in STORED_PROPERTY.finditer(body)] + [m.group(1) for m in CASE_PAYLOAD.finditer(body)]:
            todo.extend((other, name) for other in TYPE_NAME.findall(annotation) if other in types and other not in parent)
    def chain(name):
        steps = []
        while name:
            steps.append(name)
            name = parent[name]
        return steps
    return {name: chain(name) for name in parent if CODABLE.search(types[name][1])}


def workflow_paths():
    text = WORKFLOW.read_text()
    block = text.split('    paths:\n', 1)[1].split('\npermissions:', 1)[0]
    return [m.group(1) for m in re.finditer(r"^\s*-\s*'([^']+)'", block, re.M)]


def matches(pattern, path):
    """GitHub's glob: `*` stays inside a folder, `**` crosses folders."""
    regex = re.escape(pattern).replace(r'\*\*', '\0').replace(r'\*', '[^/]*').replace('\0', '.*')
    return re.fullmatch(regex, path) is not None


class ShippedCompatFilterTests(unittest.TestCase):
    def test_the_scan_sees_the_models_and_the_chain_that_reaches_linked_episode(self):
        # Guards the scan itself: an empty or shallow scan would make the coverage test below pass for nothing.
        types = declared_types()
        self.assertGreater(len(types), 500)
        reached = stored_codable_types(types)
        self.assertIn('Item', reached)
        self.assertEqual(reached['LinkedEpisode'], ['LinkedEpisode', 'Item'])

    def test_every_file_that_defines_a_stored_type_is_in_the_filter(self):
        types, paths = declared_types(), workflow_paths()
        self.assertIn('Packages/SessionKit/Sources/SessionKitPersistence/**', paths)
        missing = {}
        for name, chain in stored_codable_types(types).items():
            relative = f'Packages/SessionKit/Sources/SessionKit/{types[name][0]}'
            if not any(matches(pattern, relative) for pattern in paths):
                missing.setdefault(relative, []).append(' <- '.join(chain))
        self.assertEqual(missing, {}, 'Add these files to the `paths` of shipped-build-compat.yml (a stored or '
                                      'packet type lives in each). Each value is the chain of types from a *Models* file to it.')

    def test_the_filter_matcher_follows_githubs_glob_rules(self):
        self.assertTrue(matches('Packages/SessionKit/Sources/SessionKit/*Models*.swift',
                                'Packages/SessionKit/Sources/SessionKit/SharingModels.swift'))
        self.assertFalse(matches('Packages/SessionKit/Sources/SessionKit/*Models*.swift',
                                 'Packages/SessionKit/Sources/SessionKit/Sub/SharingModels.swift'))
        self.assertTrue(matches('Packages/SessionKit/Sources/SessionKitSharing/**',
                                'Packages/SessionKit/Sources/SessionKitSharing/A/B.swift'))

    def test_a_filter_without_linked_episode_is_caught(self):
        types = declared_types()
        paths = [p for p in workflow_paths() if not p.endswith('/LinkedEpisode.swift')]
        relative = f'Packages/SessionKit/Sources/SessionKit/{types["LinkedEpisode"][0]}'
        self.assertIn('LinkedEpisode', stored_codable_types(types))
        self.assertFalse(any(matches(pattern, relative) for pattern in paths))


if __name__ == '__main__':
    unittest.main()
