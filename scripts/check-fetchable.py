#!/usr/bin/env python3
"""Check that every ingot in index.toml can still be fetched.

Usage: check-fetchable.py
  Run from the repository root directory.

An upstream ingot passes when its URL answers a HEAD request with 200,
following redirects. A registry ingot passes when the registry answers
a HEAD request for the manifest of its digest with 200, using an
anonymous pull token. Nothing is downloaded, so the content is not
compared with the recorded sha256.

Exit codes:
  0 = Every ingot can be fetched
  1 = At least one ingot cannot be fetched; each one is printed
"""

import http.client
import json
import os
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

ATTEMPTS = 3
MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
])


def request(url, method="GET", headers=None):
    req = urllib.request.Request(url, method=method, headers=headers or {})
    for attempt in range(1, ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as e:
            if (e.code < 500 and e.code != 429) or attempt == ATTEMPTS:
                return e.code, b""
        except (OSError, http.client.HTTPException) as e:
            if attempt == ATTEMPTS:
                return str(getattr(e, "reason", e)), b""
        time.sleep(5 * attempt)


def registry_reference(ingot):
    host, _, namespace = ingot["registry"].partition("/")
    name = ingot["tag"].partition(":")[0]
    return host, f"{namespace}/{name}"


def pull_token(host, repository, tokens):
    if (host, repository) not in tokens:
        scope = urllib.parse.quote(f"repository:{repository}:pull")
        status, body = request(f"https://{host}/token?scope={scope}")
        tokens[(host, repository)] = (
            json.loads(body)["token"] if status == 200 else None
        )
    return tokens[(host, repository)]


def check_ingot(ingot, tokens):
    """Returns the place that was asked and its answer."""
    if "url" in ingot:
        status, _ = request(ingot["url"], method="HEAD")
        return ingot["url"], status
    host, repository = registry_reference(ingot)
    place = f"{host}/{repository}@{ingot['digest']}"
    token = pull_token(host, repository, tokens)
    if token is None:
        return place, "no pull token"
    status, _ = request(
        f"https://{host}/v2/{repository}/manifests/{ingot['digest']}",
        method="HEAD",
        headers={"Authorization": f"Bearer {token}", "Accept": MANIFEST_TYPES},
    )
    return place, status


def main():
    with open("index.toml", "rb") as f:
        index = tomllib.load(f)

    tokens = {}
    checked = 0
    failures = []
    for toolchain in index.get("toolchains", []):
        for ingot in toolchain.get("ingots", []):
            checked += 1
            place, status = check_ingot(ingot, tokens)
            if status != 200:
                failure = (
                    f"{toolchain['family']} {toolchain['version']} "
                    f"{ingot['platform']}-{ingot['arch']}: "
                    f"{place} answered {status}"
                )
                failures.append(failure)
                # Flushed so that a run stopped by its time limit keeps it.
                print(f"::error::{failure}", flush=True)

    print(f"{checked} ingots, {len(failures)} cannot be fetched")

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and failures:
        with open(summary, "a") as f:
            f.write("## Ingots that cannot be fetched\n\n")
            f.writelines(f"- {failure}\n" for failure in failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
