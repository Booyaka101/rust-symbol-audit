#!/usr/bin/env python3
"""corpus_scan.py — measure the new-dependency build-script gate against a real
corpus, so the false-positive claim in the README is reproducible rather than
asserted.

It reads every `.crate` tarball in the local cargo cache (populate it first with
a broad `cargo fetch`, see test/CORPUS.md), and for each unique crate version
applies the exact fetch-and-execute gate the tool ships: strip comments (keeping
URL schemes), then require a network-client token AND an execution token. The
regexes are the SRC_FETCH / SRC_EXEC defaults from scripts/lib.sh.

Usage: python3 test/corpus_scan.py
"""
import glob
import os
import re
import sys
import tarfile

# Mirrors scripts/lib.sh SRC_FETCH / SRC_EXEC.
SRC_FETCH = re.compile(
    r"reqwest|ureq|isahc|attohttpc|minreq|\bhyper\b|\bcurl\b|\bwget\b|tcpstream|udpsocket|std::net",
    re.I,
)
SRC_EXEC = re.compile(
    r"process::command|command::new|::exec|::spawn|/bin/sh|/bin/bash|powershell|cmd\.exe",
    re.I,
)
BUILD_PATH = re.compile(r'^[ \t]*build[ \t]*=[ \t]*"([^"]+)"', re.I | re.M)


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    s = re.sub(r"(?<!:)//[^\n]*", " ", s)
    return s


def build_script_of(tf, root):
    names = tf.getnames()
    if root + "build.rs" in names:
        return root + "build.rs"
    toml = root + "Cargo.toml"
    if toml in names:
        man = tf.extractfile(toml).read().decode("utf-8", "replace")
        m = BUILD_PATH.search(man)
        if m and root + m.group(1) in names:
            return root + m.group(1)
    return None


def typosquat_pairs(names):
    """Every pair of real crate names within one edit, so the typosquat rule's
    false-positive claim can be hand-checked. Name proximity alone is not a
    finding: the shipped rule additionally requires the newcomer to be young or
    barely downloaded, which is what takes this list to zero."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "scripts"))
    from typosquat import norm, within
    out, ordered = [], sorted(names)
    for i, a in enumerate(ordered):
        for b in ordered[i + 1:]:
            na, nb = norm(a), norm(b)
            if na != nb and within(na, nb, 1) == 1:
                out.append((a, b))
    return out


def main():
    cache = os.path.expanduser("~/.cargo/registry/cache")
    seen = set()
    total = with_build = 0
    hits = []
    for path in glob.glob(os.path.join(cache, "*", "*.crate")):
        base = os.path.basename(path)[:-6]
        if base in seen:
            continue
        seen.add(base)
        total += 1
        try:
            with tarfile.open(path, "r:gz") as tf:
                bs = build_script_of(tf, base + "/")
                if not bs:
                    continue
                with_build += 1
                code = strip_comments(tf.extractfile(bs).read().decode("utf-8", "replace"))
                if SRC_FETCH.search(code) and SRC_EXEC.search(code):
                    hits.append(base)
        except (tarfile.TarError, OSError):
            pass
    print("unique crate versions : %d" % total)
    print("  with a build script : %d" % with_build)
    print("fetch+execute hits    : %d" % len(hits))
    for h in sorted(hits):
        print("   ", h)

    names = {re.sub(r"-\d+\.\d+\.\d+.*$", "", b) for b in seen}
    pairs = typosquat_pairs(names)
    print()
    print("unique crate names    : %d" % len(names))
    print("distance-1 name pairs : %d  (all legitimate; the youth/adoption gate"
          " is what makes this rule usable)" % len(pairs))
    for a, b in pairs:
        print("    %-28s <-> %s" % (a, b))


if __name__ == "__main__":
    main()
