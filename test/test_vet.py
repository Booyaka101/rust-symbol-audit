import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class VetImportTests(unittest.TestCase):
    def imported(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'audits.toml'
            path.write_text(text, encoding='utf-8')
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/read_vet.py'), str(path)],
                                    capture_output=True, text=True, check=True)
            return {line.split('\t')[2] for line in result.stdout.splitlines()}

    @staticmethod
    def entry(field, value, criteria='safe-to-run'):
        return f'[[audits.demo]]\n{field} = {json.dumps(value)}\ncriteria = {json.dumps(criteria)}\n'

    def test_unrooted_delta_is_not_a_full_audit(self):
        self.assertEqual(self.imported(self.entry('delta', '1.0.0 -> 1.0.1')), set())

    def test_custom_non_safety_criteria_is_not_approval(self):
        self.assertEqual(self.imported(self.entry('version', '1.0.0', 'license-checked')), set())

    def test_rooted_delta_chain_is_followed_independent_of_order(self):
        text = (self.entry('delta', '1.0.1 -> 1.0.2') + self.entry('delta', '1.0.0 -> 1.0.1')
                + self.entry('version', '1.0.0', 'safe-to-deploy'))
        self.assertEqual(self.imported(text), {'1.0.0', '1.0.1', '1.0.2'})

    def test_non_safety_delta_cannot_extend_a_safety_root(self):
        text = self.entry('version', '1.0.0') + self.entry('delta', '1.0.0 -> 1.0.1', 'license-checked')
        self.assertEqual(self.imported(text), {'1.0.0'})

    def test_violation_prevents_import_for_that_crate(self):
        text = self.entry('version', '1.0.0') + self.entry('violation', '>=1.0.0')
        self.assertEqual(self.imported(text), set())

    def test_custom_criteria_can_imply_safety(self):
        text = '[criteria.thorough]\nimplies = "safe-to-deploy"\n' + self.entry('version', '1.0.0', 'thorough')
        self.assertEqual(self.imported(text), {'1.0.0'})

    def test_unrooted_cycles_never_create_approval(self):
        text = self.entry('delta', '1.0.0 -> 1.0.1') + self.entry('delta', '1.0.1 -> 1.0.0')
        self.assertEqual(self.imported(text), set())

    def test_criteria_cycles_without_safety_never_create_approval(self):
        text = ('[criteria.one]\nimplies = "two"\n[criteria.two]\nimplies = "one"\n'
                + self.entry('version', '1.0.0', 'one'))
        self.assertEqual(self.imported(text), set())


if __name__ == '__main__':
    unittest.main()
