import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location('find_comment', Path(__file__).resolve().parents[1] / 'scripts/find_comment.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
MARKER = '<!-- rust-symbol-audit -->'


class StickyCommentTests(unittest.TestCase):
    def comment(self, ident, author='github-actions[bot]', body=MARKER):
        return dict(id=ident, user={'login': author}, body=body)

    def test_selects_one_newest_owned_comment_across_pages(self):
        pages = [[self.comment(10)], [self.comment(30), self.comment(20)]]
        self.assertEqual(module.find_comment(pages, 'github-actions[bot]', MARKER), '30')

    def test_ignores_copied_markers_and_quoted_reports(self):
        pages = [[self.comment(10), self.comment(20, author='someone-else'),
                  self.comment(30, body='Quoted report: ' + MARKER)]]
        self.assertEqual(module.find_comment(pages, 'github-actions[bot]', MARKER), '10')

    def test_empty_pages_and_null_bodies(self):
        self.assertEqual(module.find_comment([[], [self.comment(10, body=None)]], 'github-actions[bot]', MARKER), '')

    def test_custom_token_author(self):
        self.assertEqual(module.find_comment([[self.comment(10, author='owner')]], 'owner', MARKER), '10')


if __name__ == '__main__':
    unittest.main()
