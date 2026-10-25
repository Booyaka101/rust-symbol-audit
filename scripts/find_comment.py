#!/usr/bin/env python3
"""Select the newest marker comment from the authenticated author, across pages."""
import json
import sys


def find_comment(pages, author, marker):
    ids = [comment['id'] for page in pages for comment in page
           if (comment.get('user') or {}).get('login') == author
           and (comment.get('body') or '').startswith(marker)
           and isinstance(comment.get('id'), int)]
    return str(max(ids)) if ids else ''


if __name__ == '__main__':
    print(find_comment(json.load(sys.stdin), sys.argv[1], sys.argv[2]))
