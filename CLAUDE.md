# zpinger

Web monitor of ping targets: per-target loss, jitter and round-trip history
(24 h), tags, problem tiers, and a live mtr-style trace in the target detail.
One static binary (Zig 0.17, std + zig-libs), the web UI embedded. Shipped
as a .deb (amd64, arm64) with a systemd unit; runs without root or
CAP_NET_RAW (unprivileged ICMP "ping" sockets).

The README is the user documentation (options, API, how a cycle works); keep
it in step with every behaviour change.

## Layout

- `src/main.zig` — CLI, HTTP server, routing, the API.
- `src/monitor.zig` — probing cycle (zig-libs `icmp`), history ring, problem tiers.
- `src/trace.zig` — live traces: sessions, limits, reverse-DNS hop names (zig-libs `traceroute`, `dns`).
- `src/demo.zig` — `--demo` sample data.
- `src/web/` — `index.html`, `app.js`, `style.css`, `favicon.svg`; `@embedFile`d, so
  rebuild before looking at a UI change in a browser.
- `tools/about.zig` — `zig build about`: the demo hub's about page from `deploy/about.json`.
- `deploy/` — systemd unit, Debian packaging files, sample and demo targets, Caddyfile, CrowdSec.
- `scripts/package.sh` — both .deb packages + `scripts/smoke.sh` on the native one.
- `scripts/dev-instances.sh` — local test instances (RW 127.0.0.1:18080, RO demo 0.0.0.0:18090), state in `.dev/`.

## Building and the gate

- Zig version is pinned in `.zigversion`; `scripts/zig-env.sh` finds or downloads it.
  It locates the repository from `$0`, so source it as
  `sh -c '. "$0" && zig build' scripts/zig-env.sh`, not `. scripts/zig-env.sh` from another shell.
- Default build is ReleaseSafe with LLVM; `-Dselfhosted` is for the edit loop only.
- **The gate is `sh scripts/test.sh`** — fmt, unit tests, both packages, smoke test.
  CI (`.github/workflows/ci.yml`) runs exactly that. A change is done when it passes.
- Unit tests and `scripts/smoke.sh` send real ICMP. `scripts/netns-run` runs them in a private
  network namespace (loopback only) with `ping_group_range` opened; it needs unprivileged
  user namespaces (Ubuntu: `kernel.apparmor_restrict_unprivileged_userns=0`). Dependencies
  are fetched before entering it — the namespace has no network.
- Release: tag `vX.Y.Z` equal to `build.zig.zon`'s `.version` → `release.yml` runs the gate
  and publishes the debs with SHA256SUMS. Tag only after CI on the commit is green.

## zig-libs

zpinger depends on [zig-libs](https://github.com/zaxified/zig-libs) by URL + hash in
`build.zig.zon`. Its needs are met **in zig-libs**, not worked around here: a missing
capability becomes a zig-libs change (or a request in its module's SPEC backlog), then a
repin. For local work against a zig-libs checkout: `zig build --fork=<path-to-zig-libs>`;
a commit that needs an unpushed zig-libs change must not be pushed before that change and
the repin. Build options are set in `build.zig` (`-Ddns-doh=false`: no DoH, which would
pull in the http/TLS stack).

## UI decisions (keep unless the owner changes them)

- Tags: at most 8, lowercase, no spaces or commas; tag chips filter with AND; the search
  matches every word against name, host and tags. View state lives in the URL fragment
  (`#open=&tags=&q=&sort=&rev=&st=`).
- A problem is **mean loss ≥ 1 % or mean jitter ≥ 10 ms** over the window. "Problems first"
  tiers: DOWN → LOSS now → problem 1 h → problem 24 h → ACK → rest → PENDING → PAUSED.
- Status pills (`ok · nok | up · down · loss · ack · pending · paused`) are always shown,
  OR among themselves, AND with tags and search; counts are facets.
- Editing happens in the row head (✎): name/host editor (`PATCH`, all or nothing) and a
  tag picker under its tags. Enter or click-outside saves only if changed, Esc cancels.
  No bottom sheet on phones (rejected).
- Untrusted text (target names, PTR names) is inserted with `textContent`, never as HTML.

## Conventions

- Code, comments, commits and docs in English. MIT licence (`LICENSE`).
- Every user-visible change gets a `CHANGELOG.md` entry.
- `README.md`'s `doc/screenshot.png` (also the about page's) shows the read-only demo in the
  dark theme at 1200 px; regenerate it when the UI changes visibly, with private network
  hops replaced by documentation addresses.
