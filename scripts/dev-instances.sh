#!/bin/sh
# Local test instances for trying zpinger in a browser:
#   rw  writable, 127.0.0.1:18080, 10 s cycle, its own target list
#   ro  read-only demo, 0.0.0.0:18090 (reachable from a phone on the LAN)
#
#   scripts/dev-instances.sh start   [rw|ro]   start (builds only if there is no binary yet)
#   scripts/dev-instances.sh stop    [rw|ro]
#   scripts/dev-instances.sh restart [rw|ro]   build, then stop + start
#   scripts/dev-instances.sh status
#   scripts/dev-instances.sh log     rw|ro     follow its log
#
# State (targets, history, logs, pid files, the running binary) lives in
# .dev/ in the repo, so it survives reboots and rebuilds. The instances run
# a copy of zig-out/bin/zpinger: a build never swaps the binary under them.
# Addresses: ZPINGER_RW_LISTEN, ZPINGER_RO_LISTEN.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV=$ROOT/.dev
RW_LISTEN=${ZPINGER_RW_LISTEN:-127.0.0.1:18080}
RO_LISTEN=${ZPINGER_RO_LISTEN:-0.0.0.0:18090}

die() { echo "dev-instances: $*" >&2; exit 1; }

listen_of() { if [ "$1" = rw ]; then echo "$RW_LISTEN"; else echo "$RO_LISTEN"; fi; }
port_of() { listen_of "$1" | sed 's/.*://'; }
# A URL to reach it at from this machine (0.0.0.0 and :: are not addresses).
url_of() {
    case $(listen_of "$1") in
        0.0.0.0:* | \[::\]:*) echo "http://127.0.0.1:$(port_of "$1")" ;;
        *) echo "http://$(listen_of "$1")" ;;
    esac
}

args_of() {
    if [ "$1" = rw ]; then
        echo "--targets $DEV/rw-targets.json --history $DEV/rw-history.json --listen $RW_LISTEN --cycle 10"
    else
        echo "--demo --targets $ROOT/deploy/demo-targets.json --history $DEV/ro-history.json --listen $RO_LISTEN"
    fi
}

build() {
    echo "==> zig build"
    cmd="cd '$ROOT' && sh -c '. \"\$0\" && zig build' scripts/zig-env.sh"
    if command -v hw >/dev/null 2>&1; then
        hw run --name zpinger-dev-build --timeout 900 -- sh -c "$cmd"
    else
        sh -c "$cmd"
    fi
}

# The zpinger process listening on the instance's port, if any. Whatever
# zpinger holds that port is this instance's, also one started by hand.
port_pid() {
    ss -ltnpH "sport = :$(port_of "$1")" 2>/dev/null |
        sed -n 's/.*users:(("zpinger",pid=\([0-9]*\),.*/\1/p' | head -n 1
}

pid_of() {
    if [ -f "$DEV/$1.pid" ]; then
        pid=$(cat "$DEV/$1.pid")
        if [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = zpinger ]; then
            echo "$pid"
            return
        fi
    fi
    port_pid "$1"
}

stop_one() {
    pid=$(pid_of "$1")
    rm -f "$DEV/$1.pid"
    if [ -z "$pid" ]; then
        echo "$1: not running"
        return
    fi
    kill "$pid" 2>/dev/null || true
    i=0
    while [ -d "/proc/$pid" ]; do
        i=$((i + 1))
        if [ $i -ge 50 ]; then
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        sleep 0.1
    done
    echo "$1: stopped (pid $pid)"
}

start_one() {
    pid=$(pid_of "$1")
    [ -z "$pid" ] || die "$1 already runs (pid $pid); use restart"
    [ -x "$DEV/zpinger" ] || die "no binary in $DEV"
    # shellcheck disable=SC2046 # the arguments are split on purpose
    setsid "$DEV/zpinger" $(args_of "$1") >>"$DEV/$1.log" 2>&1 </dev/null &
    echo $! >"$DEV/$1.pid"
    url=$(url_of "$1")
    i=0
    until curl -sf -o /dev/null "$url/healthz"; do
        i=$((i + 1))
        if [ $i -ge 50 ] || ! [ -d "/proc/$(cat "$DEV/$1.pid")" ]; then
            echo "$1: did not come up; last lines of $DEV/$1.log:" >&2
            tail -n 5 "$DEV/$1.log" >&2
            exit 1
        fi
        sleep 0.1
    done
    echo "$1: running (pid $(cat "$DEV/$1.pid")) $url"
}

# Copy the fresh build in by rename: a running binary cannot be written.
install_binary() {
    [ -x "$ROOT/zig-out/bin/zpinger" ] || build
    cp "$ROOT/zig-out/bin/zpinger" "$DEV/zpinger.new"
    mv "$DEV/zpinger.new" "$DEV/zpinger"
}

status_one() {
    pid=$(pid_of "$1")
    if [ -z "$pid" ]; then
        echo "$1: not running ($(listen_of "$1"))"
        return
    fi
    health=$(curl -s --max-time 2 "$(url_of "$1")/healthz" || echo "no answer")
    echo "$1: pid $pid $(url_of "$1") $health"
}

action=${1:-status}
which=${2:-}
case $which in
    rw | ro) set -- "$which" ;;
    "") set -- rw ro ;;
    *) die "instance is rw or ro" ;;
esac
mkdir -p "$DEV"

case $action in
    start)
        [ -x "$DEV/zpinger" ] || install_binary
        for i in "$@"; do start_one "$i"; done
        ;;
    stop)
        for i in "$@"; do stop_one "$i"; done
        ;;
    restart)
        build
        for i in "$@"; do stop_one "$i"; done
        install_binary
        for i in "$@"; do start_one "$i"; done
        ;;
    status)
        for i in "$@"; do status_one "$i"; done
        ;;
    log)
        [ -n "$which" ] || die "log rw or log ro"
        exec tail -n 50 -f "$DEV/$which.log"
        ;;
    *) die "start, stop, restart, status or log" ;;
esac
