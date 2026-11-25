#!/usr/bin/env python3
"""Check index.toml against the molds it is generated from.

Usage: check-index.py
  Run from the repository root directory.

Checks:
  - every toolchain has a status, a license and a c_compiler
  - every mold is in the index once, and every toolchain has one mold
  - an active toolchain has an ingot for every environment it supports,
    and so has a disabled toolchain unless it has no ingots at all

The environments a toolchain supports are given by
scripts/mold-environments.py.

Exit codes:
  0 = The index matches the molds
  1 = The index breaks at least one check; each problem is printed
"""

import importlib.util
import sys
import tomllib
from pathlib import Path

STATUSES = {"active", "deprecated", "disabled"}


def load_script(name):
    path = Path(__file__).with_name(name)
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


environments = load_script("mold-environments.py")


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


def check_toolchain(name, toolchain, mold, tier1, errors):
    status = toolchain.get("status")
    if status not in STATUSES:
        errors.append(f"{name}: status is {status!r}")
    if not toolchain.get("license"):
        errors.append(f"{name}: has no license")
    if not toolchain.get("c_compiler"):
        errors.append(f"{name}: has no c_compiler")
    if mold is None:
        errors.append(f"{name}: has no mold")
        return

    ingots = {environments.environment(i) for i in toolchain.get("ingots", [])}
    if status == "active" or (status == "disabled" and ingots):
        for missing in sorted(environments.supported_environments(mold, tier1) - ingots):
            errors.append(f"{name}: has no ingot for {missing}")


def main():
    errors = []
    with open("index.toml", "rb") as f:
        index = tomllib.load(f)
    tier1 = environments.tier1_environments()
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
