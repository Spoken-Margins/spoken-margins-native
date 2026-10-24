"""hosted-integration.yml must not let a branch's proof run feed desks or repeat steps (#2590)."""
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[2] / '.github' / 'workflows' / 'hosted-integration.yml'


class HostedIntegrationWorkflowTests(unittest.TestCase):
    def steps(self):
        return yaml.safe_load(WORKFLOW.read_text())['jobs']['integration']['steps']

    def test_only_the_trunk_uploads_the_simulator_app_desks_take(self):
        step = next(s for s in self.steps() if s.get('name') == 'Keep the simulator app for desks')
        self.assertIn("github.ref_name == (vars.SM_TRUNK || 'main')", step['if'])

    def test_no_step_name_repeats(self):
        names = [s['name'] for s in self.steps() if 'name' in s]
        self.assertEqual(len(names), len(set(names)), names)


if __name__ == '__main__':
    unittest.main()
