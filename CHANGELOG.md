# Changelog

Until 1.0.0 this application lived in the zig-fping repository as
`example-apps/fping-watch`; its history was carried over (`git filter-repo`),
and these entries come from zig-fping's CHANGELOG.md.

## Unreleased

- **Own repository.** zig-fping is now a package dependency pinned to the
  `v0.2.1` tag (by URL and hash) instead of the parent checkout;
  `scripts/netns-run` and `scripts/zig-env.sh` are copied from zig-fping.

- **Jitter** per cycle (mean step between consecutive replies' round-trip
  times): a `jitter` series in `/api/state`, a ± jitter band in the chart,
  24 h jitter and 95th percentile in the stats. History files from 1.0.0
  still load.
- **Read-only shows every control**; using one explains that it is a demo
  (the server still answers 403). Every button explains itself on hover.
- **`--demo`** (read-only too): after the first cycle and at every full
  hour, history older than the last hour of real probing is replaced with
  sample data, one scenario per target (`"demo"` in the target list:
  `steady`, `evening_congestion`, `route_change`, `flapping`, `outage`,
  `down`, `bufferbloat`, `long_haul`), scaled to the target's real latency.
  The chart shades it as "sample data"; it is never written to the history
  file. The package ships `/usr/share/fping-watch/demo-targets.json`:
  public IPv4 and IPv6 targets, the DOWN one in 203.0.113.0/24 (RFC 5737).
  `/healthz` reports `demo`.
- **Status pills filter the list**: `ok` and `nok` (DOWN, LOSS now, or a
  problem in the last hour, unacknowledged: the first tiers of problems
  first), then `up`, `down`, `loss`, `ack`, `pending` and `paused`, every
  one shown even at 0. A click shows only that group, several pills show any
  of them (and the tags and search still apply); the counts follow the tags
  and the search, like a shop's search facets. Kept in the fragment
  (`#st=nok,down`).
- **Tags** per target (at most 8; lowercase, no spaces or commas), set when
  adding a target or later, with a picker like GitHub's label picker (in
  the add form, and next to the tags in the row): every tag in use with a
  tick, a filter that also creates a new tag. An IP address ticks `ipv4` or
  `ipv6` for a new target (untick it to keep it off); saved in `targets.json`
  (`"tags": [...]`, optional, files from 1.0.0 load unchanged), served in
  `/api/state`, changed with `POST /api/targets/ID/tags`. The demo targets
  carry tags.
- **Filter, find and order** above the list: tag chips (a target must have
  every selected tag), a search over name, host and tags (every word must
  match), and an order: name, the packet loss, jitter, average or worst
  latency of the last hour or the last 24 hours, or problems first (default:
  DOWN, LOSS now, a problem in the last hour, one in the last 24 hours, ACK,
  the rest; a problem is 1 % packet loss or 10 ms of jitter on average, or
  more; within a tier more loss, then more jitter), with a button to reverse
  it; targets without data stay last. The view is kept in the URL fragment
  (`#open=3&tags=dns,ipv6&q=google&sort=loss1h&rev=1`, the old `#3,5` still
  works) and follows a changed fragment without a reload. A filtered list
  says "N of M shown".
- **Rename a target or move it to another host** in place: the ✎ next to
  its name (shown on hover where there is a mouse, always on touch screens)
  opens a name and host editor; `PATCH /api/targets/ID` (name, host and/or
  tags, all or nothing). A new host keeps the history; the status starts
  over as PENDING and an acknowledgement is dropped, a cycle that probed the
  old host is not recorded for the new one, and moving between an IPv4 and
  an IPv6 address swaps the `ipv4`/`ipv6` tag. Both editors work alike:
  Enter or a click outside saves what changed (nothing changed: it just
  closes), Esc drops the changes; a name or host the server refuses keeps
  the editor open with the reason. The row head is no longer one button (it holds the edit buttons now):
  a click anywhere still expands it, and a full-size button underneath
  serves the keyboard.
- The tag picker draws above an open detail (its chart showed through), and
  on a narrow screen moves left just enough to stay on it, still hanging
  under the tags it edits.
- **Fix: the page no longer jumps to the top while scrolling on a phone.**
  A mobile browser resizes the viewport height whenever its toolbar slides
  in or out; every resize re-rendered the list, which collapsed the page for
  a moment and reset the scroll position. Now only a width change
  re-renders, and a re-render (also the one after each cycle) keeps the
  scroll position, with expanded details filled in before the next paint.

## 1.0.0 — a finished application, shipped as a Debian package (2026-10-28, in zig-fping v0.2.1)

The example application is no longer a proof of concept: it is finished for
its purpose (the library's example, a ping monitor to run for yourself, and
a public read-only demo) and stays deliberately small. Authentication, more
targets and a real time-series store are out of its scope.

- **Debian packages**: releases now carry `fping-watch_<version>_amd64.deb` and
  `_arm64.deb`, built by `example-apps/fping-watch/package.sh` (called by
  `scripts/release.sh`, which smoke-tests the packaged binary). They install a
  sandboxed systemd service on `127.0.0.1:8080`, **writable by default**: the
  target list lives in the state directory
  (`/var/lib/fping-watch/targets.json`) and starts empty. A public demo
  sets `FPING_WATCH_OPTS=--read-only` and `FPING_WATCH_TARGETS` in
  `/etc/fping-watch/env`; `/healthz` reports `read_only`, so a deployment can
  check it. The service has no capabilities at all (ping sockets only; a
  drop-in for `CAP_NET_RAW` is documented), runs as a `DynamicUser` in a
  private user namespace with seccomp `@system-service` and IP sockets only
  (`systemd-analyze security` 1.3). The maintainer scripts are what
  `dh_installsystemd` generates: a failed start does not fail the
  installation, an admin's `disable` survives upgrades, `policy-rc.d` is
  honoured. Tested in a Debian 13 container under systemd: install, add a
  target and ping it, switch to read-only, corrupt history, upgrade, disable,
  remove, reinstall, purge.
- **DNS rebinding guard**: a writable instance answers only when `Host` is an
  IP address, `localhost` or a `--allow-host` name (`421` otherwise). Being on
  loopback did not keep web pages out: a page could point its own name at
  127.0.0.1 and add targets as its own origin, past the JSON content type
  check, then read which internal addresses answer.
- **Robust files**: the target list and the history are written through a
  temporary file synced to disk before the rename. An unreadable history is
  moved to `history.json.bad` with a warning instead of keeping the daemon
  from starting (under systemd: a restart every 5 s, forever). History
  samples with more replies than probes are skipped instead of making every
  `/api/state` panic.
- **About page for a demo hub**: `zig build about` (a host tool,
  `tools/about.zig`) turns `deploy/about.json` into `about-card.html` (an
  unstyled `<article>` fragment with stable class names and schema.org
  microdata), a standalone `about.html` and `about.json`; the package ships
  them with the screenshot in `/usr/share/fping-watch/about/`.
- `GET /healthz`: `503` when cycles stop finishing or the ICMP socket cannot
  be opened.
- `--version`; startup errors (no target list, unreadable history, port in
  use) are one line on stderr instead of an error trace; a favicon.

- Many viewers cost one serialization per change: `/api/state` is built once
  per state version (a recorded cycle, a target change, a new cycle start)
  and served from a cache, with an ETag; a poll that finds nothing new is
  answered `304 Not Modified` without a body. The page revalidates instead
  of refetching, skips redrawing on an unchanged ETag and stops polling in a
  background tab. Viewers never trigger probing (that was already so).
- Bounded connections: at most 256 at once (more are closed unanswered), and
  each is shut down 10 s after it was accepted. Before, a client that never
  finished its request held a thread forever, the thread count was
  unbounded, and when no thread could be started the accept loop served the
  connection itself, so one idle client stopped the server.

## Proof of concept (2026-10-18, in zig-fping v0.2.0)

`example-apps/fping-watch` (proof of concept): a ping monitor daemon on top
of the library. It probes a JSON list of targets once a minute in one paced
`Pinger` round and serves a web page (std `http.Server`, embedded HTML/JS,
no dependencies) with 24 hours of status, latency and loss per target. Targets
can be added, removed and paused; a DOWN target can be acknowledged, Nagios
style, until 5 cycles in a row are not DOWN. `--read-only` refuses every
change for a public demo. A separate package depending on this checkout by
path; `scripts/test.sh` runs its unit tests and an end-to-end smoke test in a
network namespace.
