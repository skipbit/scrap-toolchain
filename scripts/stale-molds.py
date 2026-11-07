#!/usr/bin/env python3
"""List the molds whose ingots in the registry are not built from them.

Usage: stale-molds.py
  Run from the repository root directory.

Environment variables:
  GITHUB_REPOSITORY - owner/repo
  GITHUB_TOKEN      - token that can read the packages of the repository.
                      Without it, a family not cast yet cannot be told
                      apart from a registry that refuses the read.

For each mold under molds/, the hash from scripts/mold-hash.py is
compared with org.skipbit.scrap.mold_hash on its OCI Index. A mold is
listed when the hashes differ or the version has no OCI Index, so a
mold left behind by a cancelled or failed cast is built by the next one.

Exit codes:
  0 = Every OCI Index was read
  1 = At least one OCI Index cannot be read; each one is printed to
      stderr, and nothing should be built from this list
"""

import base64
import importlib.util
import json
import os
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ANNOTATION = "org.skipbit.scrap.mold_hash"
INDEX_TYPE = "application/vnd.oci.image.index.v1+json"


def load_mold_hash():
    path = Path(__file__).with_name("mold-hash.py")
    spec = importlib.util.spec_from_file_location("mold_hash", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.mold_hash


def get_json(url, headers):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def recorded_hash(repository, family, version, auth):
    """The hash on the OCI Index, or None when the version has none."""
    name = f"{repository}/{family}"
    scope = urllib.parse.quote(f"repository:{name}:pull")
    token = get_json(f"https://ghcr.io/token?scope={scope}", auth)["token"]
    try:
        index = get_json(
            f"https://ghcr.io/v2/{name}/manifests/{version}",
            {"Authorization": f"Bearer {token}", "Accept": INDEX_TYPE},
        )
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    return index.get("annotations", {}).get(ANNOTATION)


def main():
    mold_hash = load_mold_hash()
    repository = os.environ["GITHUB_REPOSITORY"]
    auth = {}
    if os.environ.get("GITHUB_TOKEN"):
        basic = base64.b64encode(f"_:{os.environ['GITHUB_TOKEN']}".encode())
        auth = {"Authorization": f"Basic {basic.decode()}"}
    unreadable = 0
    for mold_toml in sorted(Path("molds").rglob("mold.toml")):
        mold_dir = mold_toml.parent
        with mold_toml.open("rb") as f:
            metadata = tomllib.load(f)["metadata"]
        try:
            recorded = recorded_hash(
                repository, metadata["family"], metadata["version"], auth)
        except (OSError, ValueError, KeyError) as e:
            unreadable += 1
            print(f"{mold_dir}: OCI Index cannot be read: {e}", file=sys.stderr)
            continue
        if recorded != mold_hash(mold_dir):
            print(mold_dir)
    return 1 if unreadable else 0


if __name__ == "__main__":
    sys.exit(main())
