import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = str(Path(os.environ.get('ProgramFiles', '')) / 'Git/bin/bash.exe') if os.name == 'nt' else shutil.which('bash')


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def bash(self, script, *args, env=None, cwd=ROOT, check=True):
        clean = {k: v for k, v in os.environ.items()
                 if not k.startswith(('RSA_', 'GITHUB_', 'INPUT_'))}
        clean.update(PYTHONUTF8='1')
        clean.update(env or {})
        return subprocess.run([BASH, str(script), *map(str, args)], cwd=cwd, env=clean,
                              capture_output=True, text=True, encoding='utf-8', check=check, timeout=90)

    def git(self, *args):
        return subprocess.run(['git', '-c', 'commit.gpgsign=false', *args], cwd=self.work,
                              check=True, capture_output=True, text=True).stdout.strip()

    def lockdiff(self, old, new):
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        (self.work / 'base').touch()
        if old is not None:
            (self.work / 'Cargo.lock').write_text(old, encoding='utf-8')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        base = self.git('rev-parse', 'HEAD')
        (self.work / 'Cargo.lock').write_text(new, encoding='utf-8')
        self.git('add', '.')
        self.git('commit', '-qm', 'head')
        out = self.work / 'diff.tsv'
        self.bash(ROOT / 'scripts/parse_lockdiff.sh', base, 'HEAD', out.as_posix(), cwd=self.work)
        return out.read_text(encoding='utf-8')

    @staticmethod
    def packages(*versions):
        return 'version = 3\n' + ''.join(
            f'\n[[package]]\nname = "demo"\nversion = "{v}"\n' for v in versions)

    def test_adding_first_lockfile(self):
        self.assertEqual(self.lockdiff(None, self.packages('1.0.0')), 'demo\t\t1.0.0\n')

    def test_existing_parallel_versions_are_not_bumps(self):
        self.assertEqual(self.lockdiff(self.packages('1.0.0', '2.0.0'),
                                      self.packages('1.0.0', '2.0.0') + '\n# metadata\n'), '')

    def test_only_new_parallel_version_is_audited(self):
        self.assertEqual(self.lockdiff(self.packages('1.0.0', '2.0.0'),
                                      self.packages('1.0.0', '2.1.0')), 'demo\t2.0.0\t2.1.0\n')

    def test_build_script_manifest_rules(self):
        for declaration, expected in [('build = "custom.rs"', 'custom.rs'),
                                      ('build = false', None),
                                      ("build = 'custom.rs'", 'custom.rs'),
                                      ('', 'build.rs')]:
            with self.subTest(declaration=declaration):
                (self.work / 'Cargo.toml').write_text(f'[package]\nname = "demo"\nversion = "1.0.0"\n{declaration}\n')
                (self.work / 'build.rs').write_text('fn main() {}')
                (self.work / 'custom.rs').write_text('fn main() { reqwest::get(url); Command::new("sh"); }')
                result = self.bash('-c', '. scripts/lib.sh; inspect_crate_dir "$1"', 'test', self.work.as_posix())
                facts = dict(line.split('\t', 1) for line in result.stdout.splitlines())
                if expected is None:
                    self.assertNotIn('build_script', facts)
                else:
                    self.assertEqual(Path(facts['build_script']).name, expected)
                    self.assertEqual(facts['fetch_exec'], '1' if expected == 'custom.rs' else '0')

    def audit(self, rows, **extra):
        lockdiff = self.work / 'lockdiff.tsv'
        lockdiff.write_text(rows, newline='\n')
        env = dict(LOCKDIFF_TSV=lockdiff.as_posix(), WORK=(self.work / 'run').as_posix(),
                   RSA_FIXTURES=(ROOT / 'test/fixtures').as_posix(), RSA_CHECK_PROVENANCE='0',
                   RSA_CHECK_ADVISORIES='0', RSA_DRY_RUN='1', RSA_CONFIG='/nonexistent',
                   REVIEWS='/nonexistent', VET_AUDITS='/nonexistent')
        if not shutil.which('nm'):
            sysroot = subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip()
            tools = list(Path(sysroot).glob('lib/rustlib/*/bin/llvm-nm*'))
            if tools:
                env['NM'] = tools[0].as_posix()
        env.update(extra)
        self.bash(ROOT / 'scripts/run_audit.sh', env=env)
        return json.loads((self.work / 'run/audit-report.json').read_text(encoding='utf-8'))

    def test_capped_audit_never_recommends_auto_merge(self):
        report = self.audit('netcap\t0.1.0\t0.2.0\n', MAX_CRATES='0')
        self.assertEqual(report['recommendation'], 'review')
        self.assertFalse(report['complete'])
        self.assertTrue(report['incomplete_reasons'])
        body = (self.work / 'run/comment_body.md').read_text(encoding='utf-8')
        self.assertIn('INCOMPLETE', body)

    def test_failed_symbol_tool_never_recommends_auto_merge(self):
        report = self.audit('netcap\t0.1.0\t0.1.0\n', NM='false')
        self.assertEqual(report['recommendation'], 'review')
        self.assertFalse(report['complete'])

    def test_failed_build_never_recommends_auto_merge(self):
        report = self.audit('netcap\t0.1.0\t0.1.0\n', RUSTC='false')
        self.assertEqual(report['recommendation'], 'review')
        self.assertFalse(report['complete'])

    def test_dependency_cap_requires_review(self):
        report = self.audit('carrier\t0.1.0\t0.3.0\n', MAX_NEW_DEPS='0')
        self.assertEqual(report['recommendation'], 'review')
        self.assertFalse(report['complete'])

    def test_clean_audit_is_complete_and_rerun_excludes_stale_crates(self):
        report = self.audit('netcap\t0.1.0\t0.1.0\n')
        self.assertEqual(report['recommendation'], 'auto-merge')
        self.assertTrue(report['complete'])
        self.assertEqual(len(report['crates']), 1)
        report = self.audit('netcap\t0.1.0\t0.1.0\n', MAX_CRATES='0')
        self.assertEqual(report['crates'], [])

    def test_parallel_crate_versions_keep_separate_evidence(self):
        report = self.audit('netcap\t0.1.0\t0.1.0\nnetcap\t0.1.0\t0.2.0\n')
        self.assertEqual({c['new'] for c in report['crates']}, {'0.1.0', '0.2.0'})
        self.assertEqual(report['audited'], 2)

    def test_artifact_picker_rejects_wrong_packages_and_versions(self):
        log = self.work / 'build.json'
        for package in ['registry+https://example.test#other@1.0.0',
                        'registry+https://example.test#demo@2.0.0']:
            with self.subTest(package=package):
                log.write_text(json.dumps(dict(reason='compiler-artifact', package_id=package,
                                               target={'name': 'demo'}, filenames=['wrong.rlib'])) + '\n')
                result = subprocess.run([sys.executable,
                                         str(ROOT / 'scripts/pick_rlib.py'), str(log), 'demo', '1.0.0'],
                                        capture_output=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b'')

    def test_artifact_identity_does_not_depend_on_library_name(self):
        log = self.work / 'build.json'
        log.write_text(json.dumps(dict(reason='compiler-artifact',
                                       package_id='registry+https://example.test#demo@1.0.0',
                                       target={'name': 'renamed_lib'}, filenames=['correct.rlib'])) + '\n')
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/pick_rlib.py'),
                                 str(log), 'demo', '1.0.0'], capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), b'correct.rlib')

    def test_manifest_metadata_does_not_declare_compile_time_capabilities(self):
        (self.work / 'Cargo.toml').write_text(
            '[package]\nname = "demo"\nversion = "1.0.0"\n'
            '[package.metadata.example]\nproc-macro = true\nlinks = "not-a-library"\n')
        result = self.bash('-c', '. scripts/lib.sh; inspect_crate_dir "$1"', 'test', self.work.as_posix())
        facts = dict(line.split('\t', 1) for line in result.stdout.splitlines())
        self.assertEqual(facts['proc_macro'], '0')
        self.assertNotIn('links', facts)


if __name__ == '__main__':
    unittest.main()
