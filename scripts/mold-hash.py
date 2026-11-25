#!/usr/bin/env python3
"""Print the hash of the parts of a mold that its ingots are built from.

Usage: mold-hash.py <mold directory>

The hash covers the source, test and patches tables of mold.toml, the
files under patches/, and the files that decide how every ingot is
built (BUILD_FILES). Ingot Cast builds a mold again when its hash
changes, and records the hash with the ingots. A cast that is cancelled
or fails leaves the old hash in the registry, so the next cast builds
the mold again. generate-index.sh compares it with the mold on main, so
that the index does not pair the values of a mold with ingots built
from another version of it. The metadata table is left out, so a change
to it alone is not built.

Prints "sha256:<hex>".
"""

import hashlib
import json
import sys
import tomllib
from pathlib import Path

# cast-ingot.sh is the build, remove-needed.sh rewrites files of Linux
# fetch ingots, rebuild-libunwind.sh rebuilds libunwind of macOS fetch
# ingots, measure-glibc.sh gives the glibc version published with an
# ingot, and platforms.toml picks the container that sets the glibc
# baseline. The other scripts check or publish an ingot, and do not
# change what is built.
BUILD_FILES = (
    "platforms.toml",
    "scripts/cast-ingot.sh",
    "scripts/measure-glibc.sh",
    "scripts/remove-needed.sh",
    "scripts/rebuild-libunwind.sh",
)
REPO_ROOT = Path(__file__).resolve().parent.parent


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mold_hash(mold_dir):
    with (mold_dir / "mold.toml").open("rb") as f:
        mold = tomllib.load(f)
    patches_dir = mold_dir / "patches"
    patch_files = sorted(p for p in patches_dir.rglob("*") if p.is_file())
    built_from = {
        "mold": {key: mold.get(key) for key in ("source", "test", "patches")},
        "patch_files": {
            p.relative_to(patches_dir).as_posix(): file_hash(p)
            for p in patch_files
        },
        "build_files": {
            name: file_hash(REPO_ROOT / name) for name in BUILD_FILES
        },
    }
    # default=str covers TOML dates and times, which JSON has no type for.
    canonical = json.dumps(built_from, sort_keys=True, default=str)
    return "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print(mold_hash(Path(sys.argv[1])))
