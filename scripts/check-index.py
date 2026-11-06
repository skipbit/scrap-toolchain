#!/usr/bin/env python3
"""Check index.toml against the molds it is generated from.

Usage: check-index.py
  Run from the repository root directory.

Checks:
  - every toolchain has a status and a license
  - every mold is in the index, and every toolchain has a mold
  - an active or disabled toolchain has an ingot for every environment
    it supports

An environment is "<platform>-<arch>". A toolchain supports the
environments in source.platforms.supported. Without that list, a fetch
toolchain supports the environments of its source.binaries and a build
toolchain supports every Tier 1 environment. A build toolchain is cast
only for Tier 1 environments.

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
    for path in sorted(Path("molds").glob("*/*/mold.toml")):
        try:
            with path.open("rb") as f:
                mold = tomllib.load(f)
            key = (mold["metadata"]["family"], mold["metadata"]["version"])
        except (tomllib.TOMLDecodeError, KeyError) as e:
            errors.append(f"{path}: cannot be read: {e}")
            continue
        molds[key] = mold
    return molds


def supported_environments(mold, tier1):
    source = mold["source"]
    declared = set(source.get("platforms", {}).get("supported", []))
    if source["type"] == "fetch":
        return declared or {environment(b) for b in source.get("binaries", [])}
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

    if status in ("active", "disabled"):
        ingots = {environment(i) for i in toolchain.get("ingots", [])}
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
        listed.add(key)
        check_toolchain(" ".join(map(str, key)), toolchain, molds.get(key), tier1, errors)
    for family, version in sorted(molds.keys() - listed):
        errors.append(f"{family} {version}: has a mold but is not in the index")

    for error in errors:
        print(f"::error::{error}")
    print(f"{len(listed)} toolchains, {len(molds)} molds, {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
