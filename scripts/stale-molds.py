#!/usr/bin/env python3
"""List the molds whose ingots in the registry are not built from them.

Usage: stale-molds.py
  Run from the repository root directory.

Environment variables:
  GITHUB_REPOSITORY - owner/repo
  GITHUB_TOKEN      - token that can read the packages of the repository.
                      Without it, a family not cast yet cannot be told
                      apart from a registry that refuses the read.

For each mold at molds/<family>/<version>, the hash from
scripts/mold-hash.py is compared with org.skipbit.scrap.mold_hash on its
OCI Index. A mold is listed when the hashes differ or the version has no
OCI Index, so a mold left behind by a cancelled or failed cast is built
by the next one. The registry is read with the helpers of
scripts/check-fetchable.py, which retry on 5xx and 429.

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
from pathlib import Path

HOST = "ghcr.io"
ANNOTATION = "org.skipbit.scrap.mold_hash"
INDEX_TYPE = "application/vnd.oci.image.index.v1+json"


def load_script(name):
    path = Path(__file__).with_name(name)
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mold_hash = load_script("mold-hash.py").mold_hash
registry = load_script("check-fetchable.py")


def recorded_hash(repository, version, tokens, auth):
    """The hash on the OCI Index; None when the version has none."""
    token = registry.pull_token(HOST, repository, tokens, auth)
    if token is None:
        raise RuntimeError("no pull token")
    status, body = registry.request(
        f"https://{HOST}/v2/{repository}/manifests/{version}",
        headers={"Authorization": f"Bearer {token}", "Accept": INDEX_TYPE},
    )
    if status == 404:
        return None
    if status != 200:
        raise RuntimeError(f"answered {status}")
    return json.loads(body).get("annotations", {}).get(ANNOTATION)


def main():
    owner_repo = os.environ["GITHUB_REPOSITORY"]
    auth = {}
    if os.environ.get("GITHUB_TOKEN"):
        basic = base64.b64encode(f"_:{os.environ['GITHUB_TOKEN']}".encode())
        auth = {"Authorization": f"Basic {basic.decode()}"}

    tokens = {}
    compared = 0
    stale = 0
    unreadable = 0
    for mold_toml in sorted(Path("molds").glob("*/*/mold.toml")):
        mold_dir = mold_toml.parent
        with mold_toml.open("rb") as f:
            metadata = tomllib.load(f)["metadata"]
        repository = f"{owner_repo}/{metadata['family']}"
        compared += 1
        try:
            recorded = recorded_hash(
                repository, metadata["version"], tokens, auth)
        except (RuntimeError, ValueError, KeyError) as e:
            unreadable += 1
            print(f"{mold_dir}: OCI Index cannot be read: {e}", file=sys.stderr)
            continue
        if recorded != mold_hash(mold_dir):
            stale += 1
            print(mold_dir)
    print(f"{compared} molds compared, {stale} not matching the registry, "
          f"{unreadable} unreadable", file=sys.stderr)
    return 1 if unreadable else 0


if __name__ == "__main__":
    sys.exit(main())
