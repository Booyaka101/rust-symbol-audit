import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCANNER = Path(__file__).resolve().parents[1] / "scripts" / "code_scan.py"
spec = importlib.util.spec_from_file_location("code_scan", SCANNER)
code_scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(code_scan)


class CommentScanTests(unittest.TestCase):
    def test_literal_comment_markers_do_not_hide_code(self):
        for start, end in [
            ('"/*"', '"*/"'),
            ('r#"/*"#', 'r#"*/"#'),
            ('br##"/*"##', 'br##"*/"##'),
            ('"//"', '"end"'),
            ('"escaped \\" /*"', '"*/"'),
        ]:
            with self.subTest(start=start):
                source = (
                    f'let marker = {start}; '
                    'reqwest::get(url); std::process::Command::new("sh"); '
                    f'let end = {end};'
                )
                self.assertEqual(code_scan.strip_comments(source), source)

    def test_nested_block_comments_are_fully_removed(self):
        source = '/* outer /* inner */ reqwest Command::new */ fn main() {}'
        self.assertEqual(code_scan.strip_comments(source).strip(), 'fn main() {}')

    def test_comments_after_colons_are_removed(self):
        self.assertNotIn('reqwest', code_scan.strip_comments('label: // reqwest\n'))

    def test_literals_and_lifetimes_are_preserved(self):
        source = '''fn f<'a>(s: &'a str) { let c = '"'; let q = '\\''; let url = "https://example.test"; }'''
        self.assertEqual(code_scan.strip_comments(source), source)

    def test_raw_string_quotes_do_not_end_literal_early(self):
        source = 'let x = r###"a " // /* b"###; Command::new("sh");'
        self.assertEqual(code_scan.strip_comments(source), source)

    def test_comments_separate_tokens(self):
        self.assertEqual(code_scan.strip_comments('req/* comment */west'), 'req west')

    def test_cli_reports_real_code_but_not_comments(self):
        env = dict(os.environ, SRC_ALARM='command::new', SRC_FETCH='reqwest', SRC_EXEC='command::new')
        for source, expected in [
            ('let x = "/*"; reqwest::get(url); Command::new("sh"); let y = "*/";', 'alarm\t1\nfetch_exec\t1\n'),
            ('/* outer /* inner */ reqwest Command::new */', 'alarm\t0\nfetch_exec\t0\n'),
        ]:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as tmp:
                script = Path(tmp) / 'build.rs'
                script.write_text(source, encoding='utf-8')
                result = subprocess.run([sys.executable, str(SCANNER), str(script)], env=env, capture_output=True, check=True)
                self.assertEqual(result.stdout, expected.encode())


if __name__ == '__main__':
    unittest.main()
