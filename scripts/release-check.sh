#!/bin/sh
# SPDX-License-Identifier: MIT
# The release check: before tagging, on a developer machine. Builds the
# release binary and the test binary, then in a private network namespace
# (loopback only): fuzzes what zpinger reads from outside (src/fuzz_test.zig),
# measures the limits and expected values of the server and the page at 200
# targets, load-tests the HTTP server, runs the whole page in Chrome; all
# against tools/check/budgets.json, where a breach fails. About 12 minutes.
#
#     sh scripts/release-check.sh [--only fuzz,scale,load,serve,ui] [--update-baseline]
#
# Needs google-chrome (or CHROME=path), curl, python3 with `websockets`, and
# unprivileged user namespaces (see scripts/netns-run). --update-baseline
# stores this run's numbers as the last release's (tools/check/baseline.json):
# do it when tagging, so the next check warns about what got twice as bad.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
python3 -c 'import websockets' 2>/dev/null || { echo "release-check: needs python3 websockets (apt install python3-websockets)" >&2; exit 2; }
sh -c '. "$0" && zig build && zig build test-bin' scripts/zig-env.sh
OUT="$ROOT/.zig-cache/release-check"
mkdir -p "$OUT"
# The stages that measure: in a private network namespace (loopback only;
# Chrome there needs --no-sandbox, which the scripts add: the page is our
# own, served from loopback). The page's behaviour: outside it, against the
# demo as visitors see it (its targets answer from the internet).
ONLY=fuzz,scale,load,serve,ui
REST=
while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY=$2; shift 2 ;;
        *) REST="$REST $1"; shift ;;
    esac
done
INNER=$(echo "$ONLY" | tr , '\n' | grep -v '^ui$' | paste -sd, -)
rc=0
if [ -n "$INNER" ]; then
    # shellcheck disable=SC2086
    scripts/netns-run sh -c 'ulimit -n 4096 2>/dev/null || true; exec python3 tools/check/check.py "$@"' check \
        "$ROOT/zig-out/bin/zpinger" "$OUT" --only "$INNER" $REST || rc=1
fi
case ",$ONLY," in
    *,ui,*)
        # shellcheck disable=SC2086
        env -u SSH_ASKPASS DBUS_SESSION_BUS_ADDRESS=disabled: \
            python3 tools/check/check.py "$ROOT/zig-out/bin/zpinger" "$OUT" --only ui $REST || rc=1 ;;
esac
[ $rc = 0 ] && echo "release check: all passed" || echo "release check: FAILED (see above)"
exit $rc
