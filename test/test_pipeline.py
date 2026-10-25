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

    def test_invalid_allow_regex_preserves_findings(self):
        config = self.work / 'config.toml'
        config.write_text('[allow]\nnetcap = ["["]\n')
        report = self.audit('netcap\t0.1.0\t0.2.0\n', RSA_CONFIG=config.as_posix())
        self.assertEqual(report['overall_tier'], 'critical')
        self.assertFalse(report['complete'])
        self.assertEqual(report['recommendation'], 'review')

    def test_invalid_review_regex_preserves_findings(self):
        reviews = self.work / 'reviews.toml'
        reviews.write_text('[[review]]\ncrate = "netcap"\nversion = "0.2.0"\naccept = ["["]\n')
        report = self.audit('netcap\t0.1.0\t0.2.0\n', REVIEWS=reviews.as_posix())
        self.assertEqual(report['overall_tier'], 'critical')
        self.assertFalse(report['complete'])

    def test_invalid_toml_cannot_create_a_signoff(self):
        reviews = self.work / 'reviews.toml'
        reviews.write_text('[[review]]\ncrate = "netcap"\nversion = "0.2.0"\naccept = [\n')
        report = self.audit('netcap\t0.1.0\t0.2.0\n', REVIEWS=reviews.as_posix())
        self.assertEqual(report['overall_tier'], 'critical')
        self.assertFalse(report['complete'])
        self.assertFalse(report['crates'][0]['reviewed'])

    def test_invalid_toml_config_does_not_ignore_crates(self):
        config = self.work / 'config.toml'
        config.write_text('ignore_crates = ["netcap"]\nbroken = [\n')
        report = self.audit('netcap\t0.1.0\t0.2.0\n', RSA_CONFIG=config.as_posix())
        self.assertEqual(report['overall_tier'], 'critical')
        self.assertFalse(report['complete'])

    def test_invalid_vet_file_does_not_import_partial_signoffs(self):
        audits = self.work / 'audits.toml'
        audits.write_text('[[audits.netcap]]\nversion = "0.2.0"\ncriteria = "safe-to-deploy"\n'
                          '[[audits.netcap]]\nversion = "0.2.0"\ncriteria = [\n')
        report = self.audit('netcap\t0.1.0\t0.2.0\n', VET_AUDITS=audits.as_posix())
        self.assertEqual(report['overall_tier'], 'critical')
        self.assertFalse(report['complete'])
        self.assertFalse(report['crates'][0]['reviewed'])

    def test_bad_rules_require_review_even_without_risky_changes(self):
        config = self.work / 'config.toml'
        config.write_text('[allow]\nnetcap = ["["]\n')
        report = self.audit('netcap\t0.1.0\t0.1.0\n', RSA_CONFIG=config.as_posix())
        self.assertEqual(report['overall_tier'], 'none')
        self.assertFalse(report['complete'])
        self.assertEqual(report['recommendation'], 'review')
        self.assertTrue(any('invalid regex' in r for r in report['incomplete_reasons']))

    def test_invalid_allow_cannot_bypass_fail_on(self):
        config = self.work / 'config.toml'
        config.write_text('[allow]\nnetcap = ["["]\n')
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.audit('netcap\t0.1.0\t0.2.0\n', RSA_CONFIG=config.as_posix(), FAIL_ON='critical')
        self.assertEqual(caught.exception.returncode, 1)
        report = json.loads((self.work / 'run/audit-report.json').read_text(encoding='utf-8'))
        self.assertEqual(report['overall_tier'], 'critical')
        self.assertEqual(report['recommendation'], 'review')

    def test_valid_regex_can_suppress_all_matches_without_error(self):
        config = self.work / 'config.toml'
        config.write_text('[allow]\nnetcap = [".*"]\n')
        report = self.audit('netcap\t0.1.0\t0.2.0\n', RSA_CONFIG=config.as_posix())
        self.assertEqual(report['overall_tier'], 'none')
        self.assertTrue(report['complete'])
        self.assertEqual(report['recommendation'], 'auto-merge')

    def test_rerun_does_not_reuse_disabled_lane_evidence(self):
        self.audit('netcap\t0.1.0\t0.1.0\n')
        cdir = self.work / 'run/crates/netcap'
        (cdir / 'advisory.filtered').write_text('critical\tadvisory\tstale advisory\n')
        (cdir / 'provenance.filtered').write_text('high\tpublisher-change\tstale publisher\n')
        (cdir / 'publish_age.txt').write_text('4 minutes ago')
        report = self.audit('netcap\t0.1.0\t0.1.0\n')
        self.assertEqual(report['crates'][0]['advisories'], [])
        self.assertEqual(report['crates'][0]['provenance'], [])
        body = (self.work / 'run/comment_body.md').read_text(encoding='utf-8')
        self.assertNotIn('4 minutes ago', body)

    def test_malformed_advisory_response_requires_review(self):
        fixture = self.work / 'osv'
        fixture.mkdir()
        (fixture / 'netcap-0.1.0.json').write_text('{broken')
        report = self.audit('netcap\t0.1.0\t0.1.0\n', RSA_CHECK_ADVISORIES='1',
                            RSA_ADVISORY_FIXTURE=fixture.as_posix())
        self.assertEqual(report['recommendation'], 'review')
        self.assertFalse(report['complete'])

    def test_registry_error_response_is_not_a_missing_version(self):
        fixture = self.work / 'registry'
        fixture.mkdir()
        (fixture / 'netcap.json').write_text('{"errors":[{"detail":"server error"}]}')
        report = self.audit('netcap\t0.1.0\t0.1.0\n', RSA_CHECK_PROVENANCE='1',
                            RSA_CRATESIO_FIXTURE=fixture.as_posix())
        self.assertEqual(report['overall_tier'], 'none')
        self.assertFalse(report['complete'])

    def test_withdrawn_advisories_are_not_findings(self):
        fixture = self.work / 'osv'
        fixture.mkdir()
        (fixture / 'netcap-0.1.0.json').write_text(json.dumps({'vulns': [
            {'id': 'RUSTSEC-2099-0001', 'withdrawn': '2025-01-01T00:00:00Z'}]}))
        report = self.audit('netcap\t0.1.0\t0.1.0\n', RSA_CHECK_ADVISORIES='1',
                            RSA_ADVISORY_FIXTURE=fixture.as_posix())
        self.assertEqual(report['overall_tier'], 'none')
        self.assertEqual(report['crates'][0]['advisories'], [])

    def test_review_cli_escapes_user_text(self):
        import tomllib
        ledger = self.work / 'reviews.toml'
        who = 'Alice "Reviewer"'
        notes = 'Windows path C:\\tools\nSecond line with "quotes"'
        self.bash(ROOT / 'scripts/review.sh', 'netcap', '0.2.0', who, notes,
                  env={'REVIEWS': ledger.as_posix()})
        review = tomllib.loads(ledger.read_text(encoding='utf-8'))['review'][0]
        self.assertEqual(review['reviewed_by'], who)
        self.assertEqual(review['notes'], notes)

    def test_review_cli_upgrades_partial_signoff(self):
        import tomllib
        ledger = self.work / 'reviews.toml'
        ledger.write_text('[[review]]\ncrate = "netcap"\nversion = "0.2.0"\naccept = ["TcpStream"]\n')
        self.bash(ROOT / 'scripts/review.sh', 'netcap', '0.2.0',
                  env={'REVIEWS': ledger.as_posix()})
        reviews = tomllib.loads(ledger.read_text(encoding='utf-8'))['review']
        self.assertEqual(len(reviews), 2)
        self.assertNotIn('accept', reviews[-1])

    def test_review_cli_refuses_to_append_to_malformed_ledger(self):
        ledger = self.work / 'reviews.toml'
        text = '[[review]]\ncrate = "netcap"\nversion = "0.2.0"\naccept = [\n'
        ledger.write_text(text)
        result = self.bash(ROOT / 'scripts/review.sh', 'netcap', '0.2.0',
                           env={'REVIEWS': ledger.as_posix()}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(ledger.read_text(), text)

    def test_sticky_post_uses_paginated_owned_comment_with_mock_gh(self):
        shim = self.work / 'gh'
        shim.write_text('''#!/usr/bin/env bash
if [ "$1 $2" = "api user" ]; then echo 'github-actions[bot]'; exit 0; fi
if [ "$2" = "repos/example/test/issues/7/comments" ]; then
  [ "$3 $4" = "--paginate --slurp" ] || exit 9
  printf '%s\\n' '[[{"id":10,"body":"<!-- rust-symbol-audit -->","user":{"login":"github-actions[bot]"}}],[{"id":30,"body":"<!-- rust-symbol-audit -->","user":{"login":"github-actions[bot]"}},{"id":40,"body":"<!-- rust-symbol-audit -->","user":{"login":"someone-else"}}]]'
  exit 0
fi
if [ "$2 $3" = "--method PATCH" ]; then printf '%s' "$4" > "$WORK/patched.txt"; exit 0; fi
exit 9
''', encoding='utf-8', newline='\n')
        shim.chmod(0o755)
        self.bash('-c', 'dir="$1"; command -v cygpath >/dev/null && dir="$(cygpath -u "$dir")"; export PATH="$dir:$PATH"; test "$(command -v gh)" = "$dir/gh" || exit 5; bash "$2"',
                  'test', self.work.as_posix(), (ROOT / 'scripts/post_comment.sh').as_posix(),
                  env={'WORK': self.work.as_posix(), 'GITHUB_REPOSITORY': 'example/test',
                       'PR_NUMBER': '7', 'RSA_DRY_RUN': '0', 'RSA_COMMENT': 'true'})
        self.assertEqual((self.work / 'patched.txt').read_text(), 'repos/example/test/issues/comments/30')

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
