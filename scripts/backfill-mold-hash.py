#!/usr/bin/env python3
"""Plan the mold hash annotation for OCI Indexes cast before it was recorded.

Usage: backfill-mold-hash.py <output directory>
  Run from the repository root directory, with the full git history.

Environment variables:
  GITHUB_TOKEN      - token that can read the Actions runs of the repository
  GITHUB_REPOSITORY - owner/repo

For each version whose OCI Index has no org.skipbit.scrap.mold_hash, the
Ingot Cast run that pushed its ingots is found from their creation time.
The hash is computed with scripts/mold-hash.py on the mold at the commit
of that run, which is what Ingot Cast would have recorded. The OCI Index
with the annotation added is written to
<output directory>/<family>/<version>.json. Nothing is pushed.

A version not cast yet is skipped. A version whose ingots cannot be
read, or do not come from the runs of one commit, is listed and left
out; the other versions are still planned.

Exit codes:
  0 = Every version without the annotation is planned
  1 = At least one version is left out; each one is printed
"""

import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

ANNOTATION = "org.skipbit.scrap.mold_hash"
INDEX_TYPE = "application/vnd.oci.image.index.v1+json"
MANIFEST_TYPE = "application/vnd.oci.image.manifest.v1+json"


def get_json(url, headers):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def time_of(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def cast_attempts(repository, token):
    """Every attempt of every Ingot Cast run: (start, end, commit, label)."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    }
    api = f"https://api.github.com/repos/{repository}/actions"
    attempts = []
    page = 1
    while True:
        runs = get_json(
            f"{api}/workflows/ingot-cast.yml/runs?per_page=100&page={page}",
            headers,
        )["workflow_runs"]
        if not runs:
            return attempts
        for run in runs:
            for n in range(1, run["run_attempt"] + 1):
                attempt = run if n == run["run_attempt"] else get_json(
                    f"{api}/runs/{run['id']}/attempts/{n}", headers)
                attempts.append((
                    time_of(attempt["run_started_at"]),
                    time_of(attempt["updated_at"]),
                    run["head_sha"],
                    f"run {run['id']} attempt {n}",
                ))
        page += 1


class Registry:
    def __init__(self, repository):
        self.repository = repository
        self.tokens = {}

    def manifest(self, family, reference, media_type):
        name = f"{self.repository}/{family}"
        if name not in self.tokens:
            scope = urllib.parse.quote(f"repository:{name}:pull")
            self.tokens[name] = get_json(
                f"https://ghcr.io/token?scope={scope}", {})["token"]
        return get_json(
            f"https://ghcr.io/v2/{name}/manifests/{reference}",
            {"Authorization": f"Bearer {self.tokens[name]}",
             "Accept": media_type},
        )


def casts_from_registry(mold):
    source = mold["source"]
    if source["type"] == "build":
        return True
    return any(b.get("remove_needed") for b in source.get("binaries", []))


def mold_hash_at(commit, mold_dir):
    """The hash of the mold at a commit, or None when it cannot be read."""
    archive = subprocess.run(
        ["git", "archive", commit, "--", str(mold_dir)],
        capture_output=True,
    )
    if archive.returncode != 0:
        return None
    with tempfile.TemporaryDirectory() as tree:
        with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
            tar.extractall(tree, filter="data")
        result = subprocess.run(
            [sys.executable, "scripts/mold-hash.py", str(Path(tree) / mold_dir)],
            capture_output=True, text=True,
        )
    return result.stdout.strip() if result.returncode == 0 else None


def plan(mold_dir, family, index, registry, attempts):
    """Returns the annotated OCI Index, or None and why it is left out."""
    commits = set()
    runs = set()
    for child in index["manifests"]:
        try:
            manifest = registry.manifest(family, child["digest"], MANIFEST_TYPE)
        except (OSError, ValueError) as e:
            return None, f"{child['digest']} cannot be read: {e}"
        created = manifest.get("annotations", {}) \
            .get("org.opencontainers.image.created")
        if created is None:
            return None, f"{child['digest']} has no creation time"
        matches = [a for a in attempts
                   if a[0] <= time_of(created) <= a[1]]
        # Attempts of one run share its commit, and so the hash.
        match_commits = {a[2] for a in matches}
        if len(match_commits) != 1:
            return None, (f"{child['digest']} created {created} matches "
                          f"runs of {len(match_commits)} commits")
        commits |= match_commits
        runs |= {a[3] for a in matches}
    if len(commits) != 1:
        return None, f"ingots come from {len(commits)} commits"
    commit, = commits

    mold_hash = mold_hash_at(commit, mold_dir)
    if mold_hash is None:
        return None, f"the mold cannot be read at {commit[:7]}"
    annotated = dict(index)
    annotated["annotations"] = {**index.get("annotations", {}), ANNOTATION: mold_hash}
    return annotated, f"{', '.join(sorted(runs))} at {commit[:7]}"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    repository = os.environ["GITHUB_REPOSITORY"]
    attempts = cast_attempts(repository, os.environ["GITHUB_TOKEN"])
    registry = Registry(repository)

    planned = 0
    left_out = 0
    for mold_toml in sorted(Path("molds").rglob("mold.toml")):
        mold_dir = mold_toml.parent
        with mold_toml.open("rb") as f:
            mold = tomllib.load(f)
        family = mold["metadata"]["family"]
        version = mold["metadata"]["version"]
        if not casts_from_registry(mold):
            continue
        try:
            index = registry.manifest(family, version, INDEX_TYPE)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                # Not cast yet. Ingot Cast records the hash when it is.
                continue
            index, how = None, f"OCI Index cannot be read: {e}"
        except (OSError, ValueError) as e:
            index, how = None, f"OCI Index cannot be read: {e}"
        if index is not None and ANNOTATION in index.get("annotations", {}):
            continue

        annotated = None
        if index is not None:
            annotated, how = plan(mold_dir, family, index, registry, attempts)
        if annotated is None:
            left_out += 1
            print(f"::error::{mold_dir}: left out: {how}")
            continue
        # The push step takes the tag from this path.
        target = out / family / f"{version}.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(annotated, indent=2) + "\n")
        planned += 1
        print(f"{mold_dir}: {annotated['annotations'][ANNOTATION]} from {how}")

    print(f"{planned} planned, {left_out} left out")
    return 1 if left_out else 0


if __name__ == "__main__":
    sys.exit(main())
