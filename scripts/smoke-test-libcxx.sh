#!/usr/bin/env bash
# smoke-test-libcxx.sh — Run a libc++ program in a container without libatomic
#
# Usage: smoke-test-libcxx.sh <ingot-root> <image>
#
# Compiles a test program against the ingot's libc++ in a fresh container
# of <image> that has only the C library headers (libc6-dev) installed,
# and runs it with every symbol bound at load time. This catches an LLVM
# ingot whose libc++ still needs libatomic, which the mold's own test
# does not load because clang++ links libstdc++ by default.
#
# Exit codes:
#   0 = Test passed
#   1 = Test failed (compilation error, execution failure, output mismatch)
#   2 = Internal error (missing tools, libatomic present in the image)

set -euo pipefail

INGOT_ROOT="${1:?Usage: smoke-test-libcxx.sh <ingot-root> <image>}"
IMAGE="${2:?Usage: smoke-test-libcxx.sh <ingot-root> <image>}"

command -v docker > /dev/null || { echo "Error: docker is required"; exit 2; }

INGOT_ROOT=$(cd "$INGOT_ROOT" && pwd)

echo "Image: ${IMAGE}"

set +e
docker run --rm -i \
    -v "${INGOT_ROOT}:/ingot:ro" \
    "$IMAGE" \
    bash -s <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
apt-get install -y -qq --no-install-recommends libc6-dev > /dev/null
if ldconfig -p | grep -qF 'libatomic.so.1 '; then
    echo "Error: libatomic.so.1 is installed in the image"
    exit 2
fi
cd "$(mktemp -d)"
cat > hello.cpp <<'CPP'
#include <iostream>
int main() {
    std::cout << "Hello, libc++!" << std::endl;
    return 0;
}
CPP
/ingot/bin/clang++ -stdlib=libc++ -rtlib=compiler-rt -unwindlib=libunwind -fuse-ld=lld \
    -o hello hello.cpp || exit 1
LIBCXX_DIR=$(dirname "$(/ingot/bin/clang++ -stdlib=libc++ -print-file-name=libc++.so.1)")
LD_BIND_NOW=1 LD_LIBRARY_PATH="$LIBCXX_DIR" timeout 30 ./hello > actual || exit 1
[[ "$(cat actual)" == "Hello, libc++!" ]] || { echo "Output: $(cat actual)"; exit 1; }
EOF
RUN_EXIT=$?
set -e

case "$RUN_EXIT" in
    0) echo "PASS: ran a libc++ program in ${IMAGE} without libatomic" ;;
    2) exit 2 ;;
    *) echo "FAIL: compiling or running the libc++ program failed (exit code: ${RUN_EXIT})"; exit 1 ;;
esac
