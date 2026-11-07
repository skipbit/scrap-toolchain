#!/usr/bin/env python3
"""Print the hash of the parts of a mold that its ingots are built from.

Usage: mold-hash.py <mold directory>

The hash covers the source, test and patches tables of mold.toml and
the files under patches/: the parts whose change makes Ingot Cast build
the mold again; detect-build-targets in ingot-cast.yml compares the same
parts. Ingot Cast records the hash with the ingots, and
generate-index.sh compares it with the mold on main, so that the index
does not pair the values of a mold with ingots built from another
version of it. The metadata table is left out, because a change to it
alone is not built.

Prints "sha256:<hex>".
"""

import hashlib
import json
import sys
import tomllib
from pathlib import Path


def mold_hash(mold_dir):
    with (mold_dir / "mold.toml").open("rb") as f:
        mold = tomllib.load(f)
    patches_dir = mold_dir / "patches"
    patch_files = sorted(p for p in patches_dir.rglob("*") if p.is_file())
    built_from = {
        "mold": {key: mold.get(key) for key in ("source", "test", "patches")},
        "patch_files": {
            p.relative_to(patches_dir).as_posix():
                hashlib.sha256(p.read_bytes()).hexdigest()
            for p in patch_files
        },
    }
    # default=str covers TOML dates and times, which JSON has no type for.
    canonical = json.dumps(built_from, sort_keys=True, default=str)
    return "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print(mold_hash(Path(sys.argv[1])))
