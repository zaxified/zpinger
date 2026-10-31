# Development

## Building

Zig 0.17.0 (`.zigversion`); `scripts/zig-env.sh` finds it, or downloads
the official build into `.zig-toolchain/` (checked against a pinned
SHA256, no sudo). The only dependency is
[zig-libs](https://github.com/zaxified/zig-libs), pinned to a commit in
`build.zig.zon`; `zig build --fork=../zig-libs` builds against a local
checkout.

```sh
zig build                     # ReleaseSafe by default
./zig-out/bin/zpinger --targets targets.json --history history.json
# open http://127.0.0.1:8080
```

Options: [configuration.md](configuration.md#options). Running it needs
ping sockets for your group ([configuration.md](configuration.md#icmp)).

The code: `src/monitor.zig` (targets, probing, history, persistence),
`src/main.zig` (HTTP server and API), `src/trace.zig` (live traces),
`src/events.zig` (the security log), `src/web/` (the page; no framework and
no build step, embedded into the binary, so rebuild before looking at a
change in a browser).

## Tests

```sh
sh scripts/test.sh    # everything CI runs: fmt, unit tests, both .deb packages, smoke test
zig build test        # unit tests alone
sh scripts/smoke.sh   # end to end against a running binary: API, ETag, health, Host guard, deadlines, read-only, demo
sh scripts/package.sh # the .deb packages; smoke-tests the packaged binary first
```

The unit tests and `scripts/smoke.sh` send real ICMP; `scripts/netns-run`
runs them in a private network namespace (unprivileged user namespaces
needed), so they touch no real network. A `v*` tag runs `scripts/test.sh`
too and publishes the packages as a GitHub release; the tag must match the
version in `build.zig.zon`.

## Trying a change in a browser

`scripts/dev-instances.sh restart` builds and (re)starts a writable
instance on `127.0.0.1:18080` and the read-only demo on `0.0.0.0:18090`,
keeping their state in `.dev/`; `status`, `stop` and `log rw|ro` do what
they say.
