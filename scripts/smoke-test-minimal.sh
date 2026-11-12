#!/usr/bin/env bash
# smoke-test-minimal.sh — Run the smoke test in a container without build tools
#
# Usage: smoke-test-minimal.sh <ingot-root> <mold-directory> <image>
#
# Compiles and runs the mold's test program, and a C program built with
# the C compiler of the mold, with the ingot in a fresh container of
# <image> that has only the C library headers (libc6-dev) installed.
# This catches an ingot that works only because the build container
# provides libraries or tools it does not ship.
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
# compiler as /ingot/bin/<compiler>) into WORK_DIR, and c_command for
# the C program as smoke-test.sh builds it.
python3 - "${MOLD_DIR}/mold.toml" "$WORK_DIR" <<'EOF' || exit 2
import os, re, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
mold, work = sys.argv[1:]
with open(mold, 'rb') as f:
    data = tomllib.load(f)
components = data['metadata']['components']
for key in ('compiler', 'c_compiler'):
    if not components.get(key):
        sys.exit(f'metadata.components.{key} not found')
    if not re.fullmatch(r'[A-Za-z0-9._+-]+', components[key]):
        sys.exit(f'invalid compiler name: {components[key]}')
compiler, c_compiler = components['compiler'], components['c_compiler']
test = data['test']
c_flags = ' -fuse-ld=lld' if '-fuse-ld=lld' in test['compile_command'].split() else ''
files = {
    'hello.cpp': test['hello_world_source'],
    'expected': test['expected_output'],
    'command': test['compile_command'].replace('{compiler}', f'/ingot/bin/{compiler}') + '\n',
    'c_command': f'/ingot/bin/{c_compiler}{c_flags} -o hello-c hello.c\n',
}
for name, text in files.items():
    with open(os.path.join(work, name), 'w') as f:
        f.write(text)
EOF

# The C program of smoke-test.sh, which stops at #error when the
# compiler takes it for C++.
cat > "${WORK_DIR}/hello.c" <<'C_SOURCE'
#ifdef __cplusplus
#error compiled as C++
#endif
#include <stdio.h>
int main(void) {
    printf("Hello, scrap!\n");
    return 0;
}
C_SOURCE
printf 'Hello, scrap!\n' > "${WORK_DIR}/c_expected"

echo "Image: ${IMAGE}"
echo "Command: $(cat "${WORK_DIR}/command")"
echo "C command: $(cat "${WORK_DIR}/c_command")"

# The C program runs first and without the ingot's libraries, and the
# test program with them, as smoke-test.sh runs them.
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
        step() {
            local name="$1" rc=0
            shift
            "$@" || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                echo "FAIL: ${name} (exit code: ${rc})" >&2
                exit 1
            fi
        }
        read -ra c_cmd < c_command
        read -ra cmd < command
        step "compiling the C program" "${c_cmd[@]}"
        step "running the C program" timeout 30 ./hello-c > c_actual
        step "compiling the test program" "${cmd[@]}"
        step "running the test program" \
            env LD_LIBRARY_PATH=/ingot/lib:/ingot/lib64 timeout 30 ./hello > actual
    '
RUN_EXIT=$?
set -e

if [[ "$RUN_EXIT" -ne 0 ]]; then
    echo "FAIL: the run in ${IMAGE} failed (exit code: ${RUN_EXIT})"
    exit 1
fi

check_output() {
    local name="$1" expected="${WORK_DIR}/$2" actual="${WORK_DIR}/$3"
    if ! cmp -s "$expected" "$actual"; then
        echo "FAIL: output mismatch (${name})"
        diff "$expected" "$actual" || true
        exit 1
    fi
}
check_output "C program" c_expected c_actual
check_output "test program" expected actual
echo "PASS: compiled and ran in ${IMAGE} with libc6-dev only"
