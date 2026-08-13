#!/usr/bin/env python3
"""Pick the .rlib cargo just built for one crate, out of its JSON build log.

Every probe shares one target dir, so `lib<crate>-<hash>.rlib` no longer names a
version: both sides of a bump end up in the same `deps/`, and a cache hit leaves
the wanted one with an old mtime. Neither a glob nor "newest wins" can tell them
apart. Cargo names the package behind every artifact it emits, and one probe's
graph holds exactly one version of the crate, so ask cargo instead of guessing.

Usage: pick_rlib.py <build.json> <crate> [version]
  Prints the .rlib path (forward slashes). Exit 1 if there is nothing to pick.
"""

from __future__ import annotations

import json
import sys

PROBE = "probe_lib"


def package_of(package_id: str) -> tuple[str, str]:
    """Name and version out of a package id, in either cargo spelling.

    Modern cargo emits ``registry+https://...#once_cell@1.20.2`` (and drops the
    name when it already ends the path, as in ``path+file:///p/netcap-0.2.0#0.2.0``);
    cargo before 1.77 emitted ``once_cell 1.20.2 (registry+https://...)``.
    """
    if "#" in package_id:
        head, _, fragment = package_id.rpartition("#")
        if "@" in fragment:
            name, _, version = fragment.partition("@")
            return name, version
        return head.rstrip("/").rpartition("/")[2], fragment
    parts = package_id.split(" ")
    return parts[0], parts[1] if len(parts) > 1 else ""


def rlib_of(artifact: dict) -> str:
    for filename in artifact.get("filenames") or []:
        if filename.endswith(".rlib"):
            return filename.replace("\\", "/")
    return ""


def pick(artifacts: list[dict], crate: str, version: str) -> str:
    wanted = crate.replace("-", "_")
    named = []
    for artifact in artifacts:
        name, built_version = package_of(artifact.get("package_id", ""))
        if name.replace("-", "_") != wanted:
            continue
        # An unparseable id still identifies the crate; only reject a version we
        # actually read and that disagrees.
        if version and built_version and built_version != version:
            continue
        named.append(artifact)
    for artifact in named:
        if rlib_of(artifact):
            return rlib_of(artifact)

    # The package name and the [lib] name can differ, so fall back to the target
    # name, then to the last rlib that is not the probe: cargo finishes the
    # direct dependency after everything it pulls in.
    for artifact in reversed(artifacts):
        target = artifact.get("target") or {}
        if target.get("name", "").replace("-", "_") == wanted and rlib_of(artifact):
            return rlib_of(artifact)
    for artifact in reversed(artifacts):
        if package_of(artifact.get("package_id", ""))[0] == PROBE:
            continue
        if rlib_of(artifact):
            return rlib_of(artifact)
    return ""


def main(argv: list[str]) -> int:
    log, crate = argv[1], argv[2]
    version = argv[3] if len(argv) > 3 else ""

    artifacts = []
    with open(log, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("reason") == "compiler-artifact":
                artifacts.append(message)

    rlib = pick(artifacts, crate, version)
    if not rlib:
        return 1
    print(rlib)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
