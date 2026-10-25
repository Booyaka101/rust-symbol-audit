import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('registry_data', Path(__file__).resolve().parents[1] / 'scripts/registry_data.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RegistryDataTests(unittest.TestCase):
    def validate(self, data, loader, *args):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'response.json'
            path.write_text(json.dumps(data), encoding='utf-8')
            return loader(path, *args)

    def test_error_objects_and_non_objects_are_not_clean_results(self):
        for data in ([], None, {'code': 500}, {'error': 'unavailable'}, {'errors': []}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.validate(data, module.osv)

    def test_empty_osv_response_is_a_successful_check(self):
        self.assertEqual(self.validate({}, module.osv), {})

    def test_invalid_vulnerability_shapes_are_rejected(self):
        for vulns in (None, {}, [None], [{'summary': 'no id'}]):
            with self.subTest(vulns=vulns), self.assertRaises(ValueError):
                self.validate({'vulns': vulns}, module.osv)

    def test_wrong_crate_is_not_used_as_provenance(self):
        with self.assertRaises(ValueError):
            self.validate({'crate': {'name': 'other'}, 'versions': []}, module.cratesio, 'demo')

    def test_valid_empty_versions_means_missing_version_not_bad_response(self):
        data = {'crate': {'name': 'demo'}, 'versions': []}
        self.assertEqual(self.validate(data, module.cratesio, 'demo'), data)

    def test_missing_versions_are_not_a_removed_version(self):
        with self.assertRaises(ValueError):
            self.validate({'crate': {'name': 'demo'}}, module.cratesio, 'demo')


if __name__ == '__main__':
    unittest.main()
