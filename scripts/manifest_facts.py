#!/usr/bin/env python3
"""Read Cargo's compile-time manifest settings without matching other tables."""
from pathlib import Path
import sys
import tomllib


def main():
    sys.stdout.reconfigure(newline="\n")
    root = Path(sys.argv[1])
    with (root / "Cargo.toml").open("rb") as fh:
        manifest = tomllib.load(fh)
    package = manifest.get("package", {})
    build = package.get("build", "build.rs")
    if build is not False:
        script = root / (build if isinstance(build, str) else "build.rs")
        if script.is_file():
            print("build_script\t%s" % script.as_posix())
    print("proc_macro\t%d" % (manifest.get("lib", {}).get("proc-macro") is True))
    links = package.get("links")
    if links:
        print("links\t%s" % links)


if __name__ == "__main__":
    main()
