#!/usr/bin/env python3
"""Check index.toml against the molds it is generated from.

Usage: check-index.py
  Run from the repository root directory.

Checks:
  - every toolchain has a status and a license
  - every mold is in the index once, and every toolchain has one mold
  - an active toolchain has an ingot for every environment it supports,
    and so has a disabled toolchain unless it has no ingots at all

An environment is "<platform>-<arch>". A toolchain supports the
environments in source.platforms.supported. Without that list, a fetch
toolchain supports the environments of its source.binaries and a build
toolchain supports every Tier 1 environment. Only Tier 1 environments
are cast, so a build toolchain, or a fetch binary with remove_needed,
outside Tier 1 has no ingot.

Exit codes:
  0 = The index matches the molds
  1 = The index breaks at least one check; each problem is printed
"""

import sys
import tomllib
from pathlib import Path

STATUSES = {"active", "deprecated", "disabled"}


def environment(entry):
    return f"{entry['platform']}-{entry['arch']}"


def load_molds(errors):
    molds = {}
    for path in sorted(Path("molds").rglob("mold.toml")):
        try:
            with path.open("rb") as f:
                mold = tomllib.load(f)
            key = (mold["metadata"]["family"], mold["metadata"]["version"])
        except (tomllib.TOMLDecodeError, KeyError) as e:
            errors.append(f"{path}: cannot be read: {e}")
            continue
        if key in molds:
            errors.append(f"{path}: is a second mold for {' '.join(key)}")
            continue
        molds[key] = mold
    return molds


def supported_environments(mold, tier1):
    source = mold["source"]
    declared = set(source.get("platforms", {}).get("supported", []))
    if source["type"] == "fetch":
        binaries = source.get("binaries", [])
        uncast = {
            environment(b) for b in binaries if b.get("remove_needed")
        } - tier1
        return (declared or {environment(b) for b in binaries}) - uncast
    return (declared or tier1) & tier1


def check_toolchain(name, toolchain, mold, tier1, errors):
    status = toolchain.get("status")
    if status not in STATUSES:
        errors.append(f"{name}: status is {status!r}")
    if not toolchain.get("license"):
        errors.append(f"{name}: has no license")
    if mold is None:
        errors.append(f"{name}: has no mold")
        return

    ingots = {environment(i) for i in toolchain.get("ingots", [])}
    if status == "active" or (status == "disabled" and ingots):
        for missing in sorted(supported_environments(mold, tier1) - ingots):
            errors.append(f"{name}: has no ingot for {missing}")


def main():
    errors = []
    with open("index.toml", "rb") as f:
        index = tomllib.load(f)
    with open("platforms.toml", "rb") as f:
        tier1 = {environment(p) for p in tomllib.load(f)["platforms"]["tier1"]}
    molds = load_molds(errors)

    listed = set()
    for toolchain in index.get("toolchains", []):
        key = (toolchain.get("family"), toolchain.get("version"))
        name = " ".join(map(str, key))
        if key in listed:
            errors.append(f"{name}: is listed more than once")
        listed.add(key)
        check_toolchain(name, toolchain, molds.get(key), tier1, errors)
    for family, version in sorted(molds.keys() - listed):
        errors.append(f"{family} {version}: has a mold but is not in the index")

    for error in errors:
        print(f"::error::{error}")
    print(f"{len(listed)} toolchains, {len(molds)} molds, {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
