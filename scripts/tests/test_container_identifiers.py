"""scripts/container_identifiers.py: a bare container's identifier hides its children's (#2898).

The table below is the scanner's neighbouring cases: each says whether the identifier is a row. A case that starts
failing means the heuristic moved and the script's docstring needs to follow. The last class runs the scan over the
app against the baseline, which is the guard itself.
"""
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import container_identifiers as ci  # noqa: E402


def rows(source):
    return ci.scan_source('App/X/Sources/X.swift', source)


def ids(source):
    return [row['identifier'] for row in rows(source)]


class WhatIsABareContainerIdentifier(unittest.TestCase):
    def test_the_playback_header_as_it_was_at_a633458_is_a_row(self):
        # #2262 put the Library chevron in the header; the container's identifier replaced its neighbours' (#2894).
        source = '''
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showLibrary() } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Library")
                Button { showItem() } label: { Text(title) }
                    .accessibilityIdentifier("playback.itemTitle.button")
            }
        }
        .accessibilityIdentifier("playback.title")
        '''
        found = rows(source)
        self.assertEqual([(r['container'], r['identifier'], r['hidden']) for r in found],
                         [('VStack', 'playback.title', 1)])

    def test_every_container_kind_is_a_row(self):
        for kind in ('VStack', 'HStack', 'ZStack', 'Group', 'ViewThatFits', 'LazyVStack', 'LazyHStack'):
            with self.subTest(kind):
                self.assertEqual(ids(f'{kind} {{ Text("a") }}\n.accessibilityIdentifier("x")'), ['x'])

    def test_arguments_and_modifiers_between_the_container_and_the_identifier_still_count(self):
        source = 'HStack(spacing: 4, content: { }) { Text("a") }\n.padding(8)\n.background { Color.red }\n.accessibilityIdentifier("x")'
        self.assertEqual(ids(source), ['x'])

    def test_a_section_with_a_header_closure_is_a_row(self):
        source = 'Section { Text("a") } header: { Text("h") }\n.accessibilityIdentifier("opml.failures")'
        self.assertEqual(ids(source), ['opml.failures'])

    def test_an_interpolated_identifier_is_a_row(self):
        self.assertEqual(ids('VStack { Text("a") }\n.accessibilityIdentifier("row.\\(row.id)")'), ['row.\\(row.id)'])

    def test_the_hidden_count_is_the_children_with_their_own_identifier(self):
        source = '''VStack {
            Button("a") { }.accessibilityIdentifier("a")
            HStack { Button("b") { }.accessibilityIdentifier("b") }
        }
        .accessibilityIdentifier("x")'''
        self.assertEqual(rows(source)[0]['hidden'], 2)

    def test_an_element_modifier_before_or_after_makes_it_safe(self):
        for chain in ('.accessibilityElement(children: .contain)\n.accessibilityIdentifier("x")',
                      '.accessibilityIdentifier("x")\n.accessibilityElement(children: .contain)',
                      '.accessibilityIdentifier("x")\n.padding(4)\n.accessibilityElement(children: .combine)',
                      '.accessibilityElement(children: .ignore).padding(4).accessibilityIdentifier("x")'):
            with self.subTest(chain):
                self.assertEqual(ids(f'VStack {{ Text("a") }}\n{chain}'), [])

    def test_a_view_that_is_itself_an_element_is_not_a_row(self):
        for view in ('Text("a")', 'Button("a") { }', 'ScrollView { Text("a") }', 'List { Text("a") }',
                     'Image(systemName: "x")', 'Menu("m") { }', 'Toggle("t", isOn: $on)'):
            with self.subTest(view):
                self.assertEqual(ids(f'{view}\n.accessibilityIdentifier("x")'), [])

    def test_a_container_inside_a_button_label_is_not_the_buttons_row(self):
        source = 'Button { } label: { VStack { Text("a") } }\n.accessibilityIdentifier("x")'
        self.assertEqual(ids(source), [])

    def test_braces_comments_and_strings_do_not_confuse_the_walk(self):
        source = '''VStack {
            Text("}) { not code")  // a stray } and ( here
            /* HStack { */
        }
        .accessibilityIdentifier("x")'''
        self.assertEqual(ids(source), ['x'])

    def test_a_commented_out_identifier_is_ignored(self):
        self.assertEqual(ids('VStack { }\n// .accessibilityIdentifier("x")'), [])

    def test_an_identifier_built_by_a_helper_is_not_seen(self):
        # The known blind spot: nothing here knows `id(...)` returns a string.
        self.assertEqual(ids('VStack { }\n.accessibilityIdentifier(ids.header)'), [])


class TheGuard(unittest.TestCase):
    def test_a_new_bare_container_identifier_fails(self):
        found = ci.problems(rows('VStack { Text("a") }\n.accessibilityIdentifier("brand.new")'), {})
        self.assertEqual(len(found), 1)
        self.assertIn('brand.new', found[0])
        self.assertIn('accessibilityElement', found[0])

    def test_a_known_row_passes_until_it_hides_more(self):
        baseline = {'App/X/Sources/X.swift::x': {'hidden': 0}}
        self.assertEqual(ci.problems(rows('VStack { Text("a") }\n.accessibilityIdentifier("x")'), baseline), [])
        grown = rows('VStack { Button("a") { }.accessibilityIdentifier("child") }\n.accessibilityIdentifier("x")')
        self.assertEqual(len(ci.problems(grown, baseline)), 1)

    def test_the_app_has_no_bare_container_identifier_outside_the_baseline(self):
        found = ci.problems(ci.scan_tree(), ci.load_baseline())
        self.assertEqual(found, [], '\n'.join(found))

    def test_every_baseline_row_says_why(self):
        for entry in ci.load_baseline().values():
            self.assertTrue(entry['why'].strip(), entry['key'])


if __name__ == '__main__':
    unittest.main()
