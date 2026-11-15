# Changelog

This application started in the zig-fping repository as
`example-apps/fping-watch`; its history was carried over (`git filter-repo`),
and these entries come from zig-fping's CHANGELOG.md.

## Unreleased

- **A name follows a network change.** A target given by name kept its
  address as long as DNS still listed it, so after a switch to a network
  without IPv6 its AAAA address stayed DOWN for good although the name had
  a reachable A address. The kept address now stays only within the family
  the answer prefers (RFC 6724 puts one without a route last), and a probe
  that cannot be sent for lack of a route ("no route to host" on the page)
  makes the name look again within a minute instead of at its TTL.
- **The ipv4/ipv6 tag of a name follows its address.** The family filter
  went by the tags in the configuration, which a name could not have right:
  it moves between the families with the network. A target given by name now
  shows (dashed) and filters by the family of the address it resolves to
  now; an ipv4/ipv6 tag stored on it is ignored and its tag editor does not
  offer them. A literal address keeps its own tags, as before.

- **zpinger follows the host's network changes.** It listens to the
  kernel's address and route notifications (rtnetlink, no privilege): a
  global address or a default route coming or going makes the next cycle
  look every name up again, so a name moves to the family the host can reach
  within one cycle, and back to IPv6 as soon as it returns instead of after
  its TTL. The systemd unit allows `AF_NETLINK` for it (exposure still 1.3).

- **DNS is asked sparingly.** At most `--dns-rate` names a second (default
  20) are looked up, names whose address lost its route first; after a
  network change only those are looked up at once, the others at random
  within 10 minutes, so 10 000 names or a flapping IPv6 link do not burst
  the local resolver. A lookup that keeps failing backs off exponentially
  (1 to 60 minutes) instead of repeating every minute.

- **A trace shares hop names and follows its target's address.** Reverse-DNS
  names are cached for every trace (5 minutes, failures backing off 1 to 60
  minutes, freed once expired, at most 4096), instead of each trace asking
  again. A trace goes where the probing goes: after a move to the other
  family it starts over at the new address.

## 0.3.0 (2026-11-14)

- **A problem is judged by the median jitter**, not the mean: 1 % packet
  loss on average or a median jitter of 10 ms, over the hour or the day. A
  few spikes (a busy probing host, one bad minute) no longer make every
  target "nok"; a jittery link still does. The figures still show the mean.
- **A stop writes the history.** SIGTERM (`systemctl stop`, a package
  upgrade's restart) and SIGINT write the history before the process exits
  (status 0); a big history is written only every few cycles, so a restart
  lost up to 15 of them. A `stop` event in the security log says so.
- **A page reloads the whole state after a server restart.** The state has
  `started` (when the server started); a page that sees it change stops
  merging deltas onto a history the server may no longer have.

- **The probes are spread over the whole cycle.** Each target's 5 probes go
  out a fifth of the probing window apart (11.6 s at one minute), starting at a
  random point, so the probes of all targets are scattered over the minute
  instead of a burst in its first seconds: a short outage anywhere in the
  minute shows, and the network never sees a burst. The jitter figure is
  now the round-trip change between probes 11.6 s apart, not 1 s; the
  problem threshold (10 ms) stays. A target added during a cycle joins the
  next one: its first result takes up to two cycles.
- **The page is live.** New `GET /api/live` lists the probes of the cycle
  being probed as they come; the page polls it every 2 s and loads the
  state only when a cycle was recorded or something changed (it polled the
  whole state every 15 s). A row's newest beat is built from its probes so
  far and its latency follows each probe; a new cycle slides the strip and
  the recorded beat arrives; a target changing status flashes its row. The
  tab's title counts the targets that need attention, and the icon takes
  the colour of the worst status.
- **A floating, folded top bar.** One line: the logo, whose ring counts down
  to the next cycle (grey while the server does not answer), the `ok` and
  `nok` pills, how many targets a filter leaves, and ☰ for every pill, the
  search, the tags, the add form and, on a line of their own at the end,
  the order and the CompactMode and Events switches. A read-only demo is marked
  `demo`. A thin line along its bottom
  fills with the cycle's probes, green answered, red lost.
- **Events.** The outages and losses of the last 24 hours, read from the
  history: under the bar for all targets shown, or in a target's detail for
  that one, the newest on top; both hidden until asked for (the Events
  switch in ☰, a target's Events action) and closed by a highlighted
  **Hide events** button in their head, as a trace's Stop is. A run of lossy
  cycles is one event (up to 5 clean cycles inside it do not end it), a DOWN
  one when some of its cycles lost every probe; a single cycle that lost one
  probe is left out.
- **The demo list has 30 targets** (was 8), grouped by region (`europe`,
  `americas`, `asia`, `oceania`, `africa`): Wikimedia's data centres, public
  DNS and NTP servers and university mirrors from 11 ms to 300 ms away, plus
  a second DOWN target that is acknowledged (`"acked": true`). A demo
  target added to an existing demo gets sample data up to its own first
  cycle (it had an empty stretch back to when the other targets' real data
  began); the state gives each demo target its own `demo_from`.
- **A target not probed yet is NEW** (badge and pill; was PENDING, which
  did not fit the badge). The API status stays `pending`, and so does the
  fragment's `st=pending`.
- **Up to 200 targets** (was 64), the number zpinger is now measured and
  tuned for; `ZPINGER_MAX_TARGETS` raises it for testing (a warning at
  start). A big history is written every few cycles instead of every one:
  about a megabyte a minute at most (8.6 MB at 200 targets every 9 cycles,
  not every minute).
- **Rows are updated in place, and drawn 20 at a time.** A new cycle
  changes a row's beats, figures and open detail without building the list
  again; only a row whose name, host, tags or status changed is rebuilt.
  Only the first 20 rows matching the filter are drawn, 20 more as the
  reader scrolls near the end (a link that opens a row further down,
  `#open=ID`, draws it), and each target's figures are computed once
  per state, in one pass: at 200 targets a keystroke in the search takes
  6 ms, a new cycle 22 ms (measured in headless Chrome).
- **Fixed: a target's tags leaked when memory ran out while copying them**
  (`dupeTags` freed the filled part of its list, not the list), found by the
  new allocation-failure sweep.
- **A release check** (`scripts/release-check.sh`, for maintainers): the
  history file, the targets file and the whole API fuzzed with zig-libs
  testkit's driver, the limits at 200 targets, a load test, the page in
  headless Chrome, all against stated limits (`tools/check/budgets.json`).
- **A client that stops reading the answer is no longer logged as a server
  error.** It was `handler_failed error=WriteFailed` at level err (found by
  a load test with slow readers); now `reason=write_aborted` at warn, like
  `body_aborted`, next to the `conn ... reason=timeout phase=write` line.
- **New look:** less rounded corners, tighter spacing, a frosted bar (the
  list scrolling under it shows through, blurred), and a **CompactMode**
  switch in the bar: one line per target in one panel, remembered by the
  browser; a compact row leaves out the tags. The name/address column is
  as wide as the longest name or address (within bounds, the same in every
  row), and one that still does not fit is set smaller rather than cut, so
  IPv6 addresses show whole. The figures in a target's detail are denser.
  A trace's Stop and a feed's Hide events stand out; Pause is amber,
  Acknowledge grey-green.
- **Light on the wire and in the browser, for large lists.** The page asks
  for the state only as a delta after the first load (`/api/state?since=`:
  the cycles since its own, 1.1 KB instead of 208 KB compressed per cycle at
  64 targets; a delta reaches back at most 60 cycles, an older `since` gets
  the whole, shared state), and for only the probes it has not seen
  (`/api/live?cycle=&from=`). Times are formatted with one shared formatter and the beats'
  tooltips written on hover: a redraw at 64 targets takes 91 ms (was 468).
  The gap between two packets shrinks below 20 ms when a minute would not
  hold every probe otherwise (above about 580 targets). Measured up to 1000
  targets.
- **The add form moved into the bar** (☰); the
  footer links to zpinger. The beat strips are fitted to their real width
  (a strip drawn before its row was in the page had about ten beats more).
- **`--demo` keeps 12 hours of real data** (was 1 hour; half the history, so
  12 hours at the default `--cycle 60`); only the older half is sample data.
  The real data includes what the history file kept from before a restart.
  For the first 10 cycles the sample data is scaled again after every
  cycle: it is scaled to the real median, and one slow first cycle (155 ms
  for a 12 ms target, seen after a restart) made the whole sample half ten
  times too slow until the next full hour.
  The route change scenario moved to 10 to 7 hours before the real data, to
  stay in the sample half.
- **Built with Zig 0.17.1** (was 0.17.0) and zig-libs tag `2026-11-13`. The
  0.17.1 compiler fixes a miscompile of signed-to-narrower-unsigned casts in
  optimized builds. `--listen` now also accepts an IPv6 literal with an IPv4
  tail such as `64:ff9b::192.0.2.1`; 0.17.0's parser accepted only the
  `::ffff:` form. Addresses on the page and in logs print as before (zig-libs
  `netaddr`, not std's formatter).

## 0.2.0 (2026-11-02)

- **Audit before the first public deployment.** One viewer can start at most
  4 live traces a minute, so starting and stopping in a loop no longer uses
  up everybody's 10. A reverse-DNS answer that is not a host name is shown as
  no name: control bytes from a router's reverse zone never reach the page or
  the Copy button. A link with `#sort=constructor` no longer breaks the page.
  A client hanging up inside its request body logs `reason=body_aborted` as a
  warning instead of a server error. The binary no longer carries a TLS stack
  it never uses (zig-libs' new DNS over TLS, `-Ddns-dot=false`).
- **Shorter README, documentation in `doc/`.** The README is an
  introduction, the screenshot and a five-line install (download, checksum,
  `apt install`); settings, every option, deploying, how it works, the API
  and the security log each have a page in `doc/`, shipped in the package
  under `/usr/share/doc/zpinger/doc/`. The API table lists method, path and
  a short description; the details follow it.
- **The package sets itself up:** it creates `/etc/zpinger/env` with every
  setting commented out when there is none (settings written before the
  install are kept, and no dpkg prompt appears), warns at install time when
  `net.ipv4.ping_group_range` would refuse the service's ping sockets, and
  says where it listens after a first install.
- **The first release as zpinger**, formerly fping-watch in zig-fping. The
  package is a new one (`zpinger`, conflicting with `fping-watch`).
- **Every deadline is reported:** a connection a timeout cut off is
  `event=conn action=closed reason=timeout` with `requests`, `ms` and the
  `phase` it stalled in (`no_request`, `head`, `body`, `write`,
  `response`): a request body or a response read a byte at a time now
  shows too, not only a connection that never sent a request. A
  kept-alive connection no next request came on is `reason=idle`, at debug
  level. The CrowdSec slowloris scenario counts every `timeout`.
- A second instance on the same port fails to start (zig-libs
  `http.Server` binds with SO_REUSEADDR alone); the Host guard, the client
  address behind a proxy and the atomic saves are zig-libs' now
  (`http.HostGuard`, `ratelimit.clientIp`, `filestore.writeFileAtomic`).
- `smoke.sh` and `package.sh` moved to `scripts/`, the sample target list
  to `deploy/targets.json`. `scripts/dev-instances.sh` starts, restarts and
  stops two local instances (writable and read-only demo) for trying a
  change in a browser.

- **Security log.** Every refusal, connection drop, change and live trace is
  an event: one line in a fixed shape (`event=http client=... status=429
  reason=trace_rate ...`) with the client's address (the forwarded one
  behind a loopback proxy, `peer=` then names the proxy), client-chosen text
  quoted and escaped, rate-limited per client and in total. Under systemd
  each line carries its syslog priority; elsewhere a UTC timestamp. New
  `--access-log refused|all|off` (default `refused`: status 400 and up) and
  `--log-level`. Keys and reason codes: README, "Security log". Lines go
  through a queue written by a task of its own, so a journal that falls
  behind never stalls the accept loop (a full queue drops and counts); a
  chunked body cut off at the cap is logged once, as the 413 it got.
- **Saves are durable across a power loss:** the directory is synced after
  the rename that replaces the targets or the history file.
- **CrowdSec** acquisition, parser and six scenarios (live-trace abuse, API
  probing, Host mismatch / DNS rebinding, malformed requests, slowloris,
  connection floods) in `deploy/crowdsec/`, installed to
  `/usr/share/zpinger/crowdsec/`. Without a proxy in front, zpinger's
  request lines also feed CrowdSec's generic HTTP scenarios.
- **Addresses are kept between cycles** for their DNS TTL (60 s to 1 h;
  zig-libs `dns.lookupIpTtl`), and an address stays while DNS still returns
  it, so a name with several addresses is no longer probed at a different
  one every cycle. When DNS does not answer, the last address is probed for
  up to `--dns-stale` (default 24 h, RFC 8767) and the page says so; that
  includes a resolver answering SERVFAIL (zig-libs `dns` now reports it as
  a failure, not an empty answer), and an answer missing the kept
  address's family because that family's query failed. A name that no
  longer exists is DOWN at once and looked up again after its negative TTL
  (at least a minute). A live trace follows the address
  the cycle probes. The state JSON has `address` and `dns` per target.
- **HTTP on zig-libs `http.Server`** instead of std's: keep-alive (a page
  polling a live trace every second reuses its connection), server
  timeouts per request (10 s to send it, 10 s of silence, 30 s to read the
  answer) in place of one fixed 10 s per connection, request bodies capped
  at 4 KiB before the handler runs (`413`), and at most 16 connections per
  client address (zig-libs `abuseguard`; a proxy on loopback is exempt) next
  to the 256 overall. `/api/state` goes out gzip-compressed (a fifth of the
  size) to clients that accept it, compressed once per state, with its own
  ETag (`"…-gzip"`) and `Vary: Accept-Encoding`.
- **Names resolve 16 at a time** (zig-libs `dns.Resolver`, 2 s per attempt):
  with a dead DNS server a cycle no longer takes minutes. The address used is
  the preferred one in RFC 6724 order, for the cycle and the live trace alike.
- **Saving no longer holds up the page:** the target list and the history
  are serialized under the monitor's lock but written (and synced to disk)
  after it is released, one file at a time, newest wins. A history entry
  from the future (a clock that was ahead) is dropped on load.
- `ZFPING_NETNS` is now `ZPINGER_NETNS` (scripts/netns-run, smoke.sh).
- **Robustness (independent review):** stopping a trace no longer waits,
  under the tracer's lock, for a session stuck in a slow DNS lookup (every
  trace request used to stall for the resolver timeout); a viewer refused
  for its limit no longer keeps a trace alive; the state is one shared,
  reference-counted snapshot instead of a copy per request; history values
  are range-checked (an RTT over 60 s or a corrupt count is dropped, never
  wrapped, never a crash in `--demo`), the file is limited to 8 MiB; a
  target id of 4294967295 no longer crashes the start; `accept` errors back
  off 100 ms instead of spinning; a wall clock stepped back no longer puts
  probing to sleep. A thin rule separates the live trace from the
  statistics above it.
- **Trace: copy, limits, width.** A Copy button puts the trace table on the
  clipboard as text (`mtr --report` style); a click on a hop's address
  copies the address alone; a text selection in the table pauses its
  refresh. A trace idles out after 10 minutes without a viewer on a
  writable instance, 60 s on a read-only one (`--trace-idle`), and stops
  after 1 hour / 10 minutes in any case (`--trace-age`); JSON `idle`. On a
  wide screen an address is never cut (an IPv6 one fits whole), only a long
  name. The trace buttons get the accent border on hover like the others.
- **Live traces share their common hops** (zig-libs `traceroute.MtrSet`, one
  socket per address family): a router several traces cross gets one probe a
  second, not one per trace, so its per-source ICMP limit no longer shows as
  loss when more traces run; the hop number is dotted, JSON `shared`. Each
  trace re-probes its whole path every 30 s.
- **Loss a router's answer limit causes is grey:** loss at a hop that the
  hops after it do not show is shown grey, with the path's own loss in the
  tooltip; red stays for loss that carries on.
- **Live traces bounded per viewer:** one trace per host (not per target),
  shared by every viewer; at most 2 per viewer (a client address, IPv6 by
  /64; behind a proxy on loopback the last `X-Forwarded-For` entry,
  `--trust-proxy on|off`) and 10 new ones a minute (`429`). `DELETE` ends
  only the caller's watching; the trace stops when nobody watches it.
- **A second instance can no longer share the port.** std's `reuse_address`
  also set SO_REUSEPORT, so a second zpinger bound the same port and the
  kernel split the requests between the two; now it fails with
  `AddressInUse`.
- **Trace table on narrow screens:** the table keeps its horizontal scroll
  position across the per-second refresh (it jumped back to the left edge);
  a hop shows "address name", the name cut with an ellipsis (whole in the
  tooltip), on a phone under the address; the 60 s sparkline comes right
  after the host, narrower on a phone, so loss fits without scrolling.
- **Trace hops named by reverse DNS** (PTR through the system resolver,
  one lookup at a time beside the trace, never delaying a round); the page
  shows "name (address)", the trace JSON gains `names`. `--trace-names off`
  shows addresses only. zig-libs `dns`, built without DoH.
- **Live trace** in the target detail, mtr style: one probe to every hop each
  second, per hop loss, last/average/best/worst latency, jitter and a
  sparkline of the last 60 rounds. Unprivileged (a ping socket), offered
  read-only too; bounded by the server: one trace per target, at most
  `--trace-max` (default 4, 0 = off), stopped 30 s after the last poll and
  after 10 minutes. API: `POST|GET|DELETE /api/targets/ID/trace`. Built on
  zig-libs `traceroute.LiveMtr`.
- **Pings through zig-libs** (`icmp.Pinger`, the same fping-style paced
  engine) instead of zig-fping; the package's `copyright` carries the
  zig-libs MIT notice. A raw-socket fallback draws a random ICMP ident.
- **Renamed to zpinger**, licensed MIT. Binary, package, service,
  `/etc/zpinger/env`, `/var/lib/zpinger/` and the `ZPINGER_*` variables
  replace their `fping-watch` names; the package conflicts with
  `fping-watch` and carries nothing over from it.
- **Own repository**, split out of zig-fping with its history;
  `scripts/netns-run` and `scripts/zig-env.sh` are copied from zig-fping.

- **Jitter** per cycle (mean step between consecutive replies' round-trip
  times): a `jitter` series in `/api/state`, a ± jitter band in the chart,
  24 h jitter and 95th percentile in the stats. History files from fping-watch
  still load.
- **Read-only shows every control**; using one explains that it is a demo
  (the server still answers 403). Every button explains itself on hover.
- **`--demo`** (read-only too): after the first cycle and at every full
  hour, history older than the last hour of real probing is replaced with
  sample data, one scenario per target (`"demo"` in the target list:
  `steady`, `evening_congestion`, `route_change`, `flapping`, `outage`,
  `down`, `bufferbloat`, `long_haul`), scaled to the target's real latency.
  The chart shades it as "sample data"; it is never written to the history
  file. The package ships `/usr/share/zpinger/demo-targets.json`:
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
  (`"tags": [...]`, optional, files from fping-watch load unchanged), served in
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

## fping-watch — a finished application, shipped as a Debian package (2026-10-28)

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

## fping-watch — proof of concept (2026-10-18)

`example-apps/fping-watch` (proof of concept): a ping monitor daemon on top
of the library. It probes a JSON list of targets once a minute in one paced
`Pinger` round and serves a web page (std `http.Server`, embedded HTML/JS,
no dependencies) with 24 hours of status, latency and loss per target. Targets
can be added, removed and paused; a DOWN target can be acknowledged, Nagios
style, until 5 cycles in a row are not DOWN. `--read-only` refuses every
change for a public demo. A separate package depending on this checkout by
path; `scripts/test.sh` runs its unit tests and an end-to-end smoke test in a
network namespace.
