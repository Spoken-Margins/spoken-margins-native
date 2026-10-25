"""hosted-integration.yml must not let a branch's proof run feed desks or repeat steps (#2590).

Reads the workflow as text: the portable runner has no PyYAML."""
import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / '.github' / 'workflows' / 'hosted-integration.yml'


def steps():
    """Each step of the job as its block of lines, split at the `      - ` list markers."""
    blocks, current = [], None
    for line in WORKFLOW.read_text().splitlines():
        if re.match(r'      - ', line):
            current = [line]
            blocks.append(current)
        elif current is not None and (line.startswith('        ') or not line.strip()):
            current.append(line)
        elif not line.startswith('#'):
            current = None
    return ['\n'.join(b) for b in blocks]


class HostedIntegrationWorkflowTests(unittest.TestCase):
    def test_only_the_trunk_uploads_the_simulator_app_desks_take(self):
        step = next(s for s in steps() if 'name: Keep the simulator app for desks' in s)
        self.assertRegex(step, r"if: always\(\) && github\.ref_name == \(vars\.SM_TRUNK \|\| 'main'\)")

    def test_no_step_name_repeats(self):
        names = re.findall(r'^      - name: (.+)$', WORKFLOW.read_text(), re.M)
        self.assertGreater(len(names), 5)
        self.assertEqual(len(names), len(set(names)), names)


if __name__ == '__main__':
    unittest.main()
