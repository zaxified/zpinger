# zpinger

Web monitor of ping targets: per-target loss, jitter and round-trip history
(24 h), tags, problem tiers, and a live mtr-style trace in the target detail.
One static binary (Zig 0.17, std + zig-libs), the web UI embedded. Shipped
as a .deb (amd64, arm64) with a systemd unit; runs without root or
CAP_NET_RAW (unprivileged ICMP "ping" sockets).

User documentation: `README.md` is only the front door (intro, screenshot, a
five-line install, a feature list, links) — a new user reads that far and no
further, so keep it short and put everything else in `doc/`:
`configuration.md` (settings, every option, ICMP), `deploying.md` (package,
public demo, CrowdSec, sample data, about page), `how-it-works.md`, `api.md`,
`security-log.md` (a contract for log parsers), `development.md`. Keep them in
step with every behaviour change; `doc/*.md` ships in the .deb.

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
- **Before a release: `sh scripts/release-check.sh`** (fuzz, scale, load, ui against
  `tools/check/budgets.json`; doc/development.md), then `--update-baseline` with the tag.
- Release: tag `vX.Y.Z` equal to `build.zig.zon`'s `.version` → `release.yml` runs the gate
  and publishes the debs with SHA256SUMS. Tag only after CI on the commit is green.

## zig-libs

zpinger depends on [zig-libs](https://github.com/zaxified/zig-libs) by URL + hash in
`build.zig.zon`. Its needs are met **in zig-libs**, not worked around here: a missing
capability becomes a zig-libs change (or a request in its module's SPEC backlog), then a
repin. For local work against a zig-libs checkout: `zig build --fork=<path-to-zig-libs>`;
a commit that needs an unpushed zig-libs change must not be pushed before that change and
the repin. Build options are set in `build.zig` (`-Ddns-doh=false`, `-Ddns-dot=false`: no
DoH or DoT, which would pull in the TLS stack). After a repin, compare `size` of the binary
with the previous pin: a new default-on feature in a module arrives silently.

## UI decisions (keep unless the owner changes them)

- Tags: at most 8, lowercase, no spaces or commas; tag chips filter with AND; the search
  matches every word against name, host and tags. View state lives in the URL fragment
  (`#open=&tags=&q=&sort=&rev=&st=`).
- A problem is **mean loss ≥ 1 % or mean jitter ≥ 10 ms** over the window (since 2026-11-14
  jitter compares probes a fifth of the cycle apart, ~11.6 s; threshold kept, owner OK). "Problems first"
  tiers: DOWN → LOSS now → problem 1 h → problem 24 h → ACK → rest → PENDING → PAUSED.
- Status pills (`ok · nok | up · down · loss · ack · pending · paused`) are always rendered
  (0 faint), OR among themselves, AND with tags and search; counts are facets.
- The top bar floats (sticky) and is folded by default (owner, 2026-11-14): its one line
  holds the logo (its ring counts down to the next cycle, grey when the server does not
  answer), the `ok · nok` pills, "N of M shown" while filtered, and ☰; unfolded it
  adds every pill, search, tags, the add form and last, on a line of their own, the order
  and the CompactMode and Events switches (owner 2026-11-14; the browser remembers it unfolded).
  The read-only mode tag says just `demo`. A 3 px line
  along its bottom is the cycle's probing window, coloured probe by probe until full; no
  text in it (owner: text there is distracting).
- Live (owner, 2026-11-14): the probes are spread over the cycle; a row's newest beat is
  built from its probes so far, the latency figure follows each probe, a new cycle slides
  the strip, a recorded beat "arrives", a status change flashes the row; the tab title
  counts nok targets and the favicon takes the worst colour.
- Events (global under the bar, per target in the detail) are hidden by default; newest
  (latest start) on top. Opened by the Events switch / the row's Events action, closed by a
  highlighted "Hide events" in the feed's head, like Stop in a trace's head (owner 2026-11-14:
  Stop and Hide events stand out; Pause has amber text, Acknowledge grey-green).
- The add form lives in the unfolded bar (☰; no `+` shortcut, owner 2026-11-14); the 3 px line sits
  inside the bar, which closes below it (owner: the line over the list was distracting).
- Look (owner 2026-11-14): corners `--r-card` 6 px / `--r-ctl` / `--r-chip` 5 px, frosted bar
  (82 % card colour + blur), CompactMode switch (one line per target, no tags, localStorage).
  Name/address column: `fitWhoColumn` sizes it to the longest name/host of all targets (capped,
  and to a share of the row), `fitWhoText` sets a row's name/host smaller (≥ 78 %) rather than
  cut it (owner: IPv6 addresses whole). Rows cached
  and updated in place (`rowSig` decides a rebuild), drawn 20 at a time (`PAGE`).
- Target limit: 200 by default (tested and tuned); `ZPINGER_MAX_TARGETS` raises it for testing only.
- Scale (measured 2026-11-14, netns sim up to 1000 targets with a cap-raised test build): the
  server holds 1000 (adaptive packet gap); the page needs the state delta (`?since=`) and
  `/api/live?cycle=&from=` to stay light; a full redraw is ~90 ms at 64, ~300 ms at 200.
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
