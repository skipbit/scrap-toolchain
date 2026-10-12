#!/usr/bin/env bash
# smoke-test-minimal.sh — Run the smoke test in a container without build tools
#
# Usage: smoke-test-minimal.sh <ingot-root> <mold-directory> <image>
#
# Compiles and runs the mold's test program with the ingot in a fresh
# container of <image> that has only the C library headers (libc6-dev)
# installed. This catches an ingot that works only because the build
# container provides libraries or tools it does not ship.
#
# The mold is read on the host, so that no tool installed to read it
# brings a dependency into the container.
#
# Exit codes:
#   0 = Test passed
#   1 = Test failed (compilation error, execution failure, output mismatch)
#   2 = Internal error (missing tools, unexpected failures)

set -euo pipefail

INGOT_ROOT="${1:?Usage: smoke-test-minimal.sh <ingot-root> <mold-directory> <image>}"
MOLD_DIR="${2:?Usage: smoke-test-minimal.sh <ingot-root> <mold-directory> <image>}"
IMAGE="${3:?Usage: smoke-test-minimal.sh <ingot-root> <mold-directory> <image>}"

for cmd in docker python3; do
    command -v "$cmd" > /dev/null || { echo "Error: ${cmd} is required"; exit 2; }
done

INGOT_ROOT=$(cd "$INGOT_ROOT" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Writes hello.cpp, expected and command (the compile command with the
# compiler as /ingot/bin/<compiler>) into WORK_DIR.
python3 - "${MOLD_DIR}/mold.toml" "$WORK_DIR" <<'EOF' || exit 2
import os, re, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
mold, work = sys.argv[1:]
with open(mold, 'rb') as f:
    data = tomllib.load(f)
compiler = data['metadata']['components']['compiler']
if not re.fullmatch(r'[A-Za-z0-9._+-]+', compiler):
    sys.exit(f'invalid compiler name: {compiler}')
test = data['test']
files = {
    'hello.cpp': test['hello_world_source'],
    'expected': test['expected_output'],
    'command': test['compile_command'].replace('{compiler}', f'/ingot/bin/{compiler}') + '\n',
}
for name, text in files.items():
    with open(os.path.join(work, name), 'w') as f:
        f.write(text)
EOF

echo "Image: ${IMAGE}"
echo "Command: $(cat "${WORK_DIR}/command")"

# The program runs with the ingot's libraries first, as smoke-test.sh does.
set +e
docker run --rm \
    -v "${INGOT_ROOT}:/ingot:ro" \
    -v "${WORK_DIR}:/work" \
    -w /work \
    "$IMAGE" \
    bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq > /dev/null
        apt-get install -y -qq --no-install-recommends libc6-dev > /dev/null
        read -ra cmd < command
        "${cmd[@]}"
        LD_LIBRARY_PATH=/ingot/lib:/ingot/lib64 timeout 30 ./hello > actual
    '
RUN_EXIT=$?
set -e

if [[ "$RUN_EXIT" -ne 0 ]]; then
    echo "FAIL: compiling or running the test program failed (exit code: ${RUN_EXIT})"
    exit 1
fi
if ! cmp -s "${WORK_DIR}/expected" "${WORK_DIR}/actual"; then
    echo "FAIL: output mismatch"
    diff "${WORK_DIR}/expected" "${WORK_DIR}/actual" || true
    exit 1
fi
echo "PASS: compiled and ran in ${IMAGE} with libc6-dev only"
