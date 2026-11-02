#!/usr/bin/env bash
# smoke-test-libcxx.sh — Run a libc++ program in containers without libatomic
#
# Usage: smoke-test-libcxx.sh <ingot-root> <build-image> <run-image>...
#
# Builds a test program against the ingot's libc++ in <build-image>, with
# the packages the fetch flow installs for the mold's own test, so that
# the compiler and linker can run. Then runs it in each <run-image> as it
# is, with every symbol bound at load time. This catches an LLVM ingot
# whose libc++ still needs libatomic, which the mold's own test does not
# load because clang++ links libstdc++ by default.
#
# Exit codes:
#   0 = Test passed
#   1 = Test failed (build error, execution failure, output mismatch)
#   2 = Internal error (missing tools, libatomic present in a run image)

set -euo pipefail

USAGE="Usage: smoke-test-libcxx.sh <ingot-root> <build-image> <run-image>..."
INGOT_ROOT="${1:?$USAGE}"
BUILD_IMAGE="${2:?$USAGE}"
shift 2
[[ $# -gt 0 ]] || { echo "$USAGE"; exit 2; }

command -v docker > /dev/null || { echo "Error: docker is required"; exit 2; }

INGOT_ROOT=$(cd "$INGOT_ROOT" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Writes hello and libdir (the directory of libc++.so.1) into WORK_DIR.
echo "Build image: ${BUILD_IMAGE}"
if ! docker run --rm -i \
    -v "${INGOT_ROOT}:/ingot:ro" \
    -v "${WORK_DIR}:/work" \
    "$BUILD_IMAGE" \
    bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
apt-get install -y -qq --no-install-recommends libc6-dev libxml2 > /dev/null
cd "$(mktemp -d)"
cat > hello.cpp <<'CPP'
#include <iostream>
int main() {
    std::cout << "Hello, libc++!" << std::endl;
    return 0;
}
CPP
/ingot/bin/clang++ -stdlib=libc++ -rtlib=compiler-rt -unwindlib=libunwind -fuse-ld=lld \
    -o /work/hello hello.cpp
dirname "$(/ingot/bin/clang++ -stdlib=libc++ -print-file-name=libc++.so.1)" > /work/libdir
EOF
then
    echo "FAIL: building the libc++ program failed"
    exit 1
fi

for image in "$@"; do
    echo "Run image: ${image}"
    set +e
    docker run --rm -i \
        -v "${INGOT_ROOT}:/ingot:ro" \
        -v "${WORK_DIR}:/work:ro" \
        "$image" \
        bash -s <<'EOF'
set -euo pipefail
if ldconfig -p | grep -qF 'libatomic.so.1 '; then
    echo "Error: libatomic.so.1 is installed in the image"
    exit 2
fi
output=$(LD_BIND_NOW=1 LD_LIBRARY_PATH="$(cat /work/libdir)" timeout 30 /work/hello) || exit 1
[[ "$output" == "Hello, libc++!" ]] || { echo "Output: ${output}"; exit 1; }
EOF
    RUN_EXIT=$?
    set -e
    case "$RUN_EXIT" in
        0) echo "PASS: ran a libc++ program in ${image} without libatomic" ;;
        2) exit 2 ;;
        *) echo "FAIL: running the libc++ program in ${image} failed (exit code: ${RUN_EXIT})"; exit 1 ;;
    esac
done
