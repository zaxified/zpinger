#!/bin/sh
# The whole gate, the same locally and in CI: fmt, unit tests (in a private
# network namespace, scripts/netns-run), then package.sh, which builds both
# .deb packages and smoke-tests the native packaged binary.
#
#   scripts/test.sh            (the packages land in zig-out/deb/)
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# zig-env.sh finds the repository from its own path ($0).
ZIG=$(sh -c '. "$0" && printf %s "$ZIG"' "$REPO/scripts/zig-env.sh")
cd "$REPO"

echo "==> fmt"
"$ZIG" fmt --check build.zig build.zig.zon src tools

# The namespace below has no network: fetch the dependencies out here.
echo "==> fetch"
"$ZIG" build --fetch=all

echo "==> unit tests"
scripts/netns-run "$ZIG" build test --summary all

echo "==> packages + smoke"
./package.sh
