#!/usr/bin/env python3
"""Print the environments Ingot Cast builds ingots of for a mold.

Usage: mold-environments.py [--all] <mold directory>

An environment is "<platform>-<arch>". Only Tier 1 environments in
platforms.toml are cast. A fetch mold casts the environments of its
binaries that remove DT_NEEDED entries or rebuild libraries; the others
are used as published upstream. A build mold casts the environments in
source.platforms.supported, or every Tier 1 environment without that list.

A mold supports the environments in source.platforms.supported. Without
that list, a fetch mold supports the environments of its binaries and a
build mold every Tier 1 environment. A binary that would be cast outside
Tier 1 is not supported, since it has no ingot.

Prints one environment per line, in the order of platforms.toml. With
--all, prints the environments the mold asks to cast, Tier 1 or not.
"""

import sys
import tomllib
from pathlib import Path

PLATFORMS = Path(__file__).resolve().parent.parent / "platforms.toml"


def environment(entry):
    return f"{entry['platform']}-{entry['arch']}"


def tier1_environments():
    with PLATFORMS.open("rb") as f:
        return [environment(p) for p in tomllib.load(f)["platforms"]["tier1"]]


def is_cast(binary):
    return bool(binary.get("remove_needed") or binary.get("rebuild"))


def wanted_environments(mold, tier1):
    source = mold["source"]
    if source["type"] == "fetch":
        return [environment(b) for b in source.get("binaries", []) if is_cast(b)]
    return source.get("platforms", {}).get("supported", []) or list(tier1)


def cast_environments(mold, tier1):
    wanted = set(wanted_environments(mold, tier1))
    return [e for e in tier1 if e in wanted]


def supported_environments(mold, tier1):
    source = mold["source"]
    declared = set(source.get("platforms", {}).get("supported", []))
    if source["type"] == "fetch":
        binaries = source.get("binaries", [])
        uncast = {environment(b) for b in binaries if is_cast(b)} - set(tier1)
        return (declared or {environment(b) for b in binaries}) - uncast
    return (declared or set(tier1)) & set(tier1)


if __name__ == "__main__":
    args = sys.argv[1:]
    show_all = args[:1] == ["--all"]
    if show_all:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    with (Path(args[0]) / "mold.toml").open("rb") as f:
        mold = tomllib.load(f)
    pick = wanted_environments if show_all else cast_environments
    for env in pick(mold, tier1_environments()):
        print(env)
