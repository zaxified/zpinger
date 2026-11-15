# How it works

## Problems first

The page's default order, the most urgent on top:

1. DOWN (not acknowledged);
2. LOSS: the last cycle lost some probes;
3. a problem in the last hour: 1 % packet loss on average, or a median
   jitter of 10 ms, or more (one lost probe in an hour is not a problem,
   nor are a few jitter spikes);
4. such a problem in the last 24 hours;
5. ACK: an acknowledged outage, known and so below the unknown ones;
6. the rest, then NEW (not probed yet), then PAUSED.

Within a tier, more packet loss and then more jitter go first, the last hour
before the last 24 hours. The first three tiers are the `nok` pill; tiers
4 and 6 (the rest that has been probed) are `ok`.

## Live trace

"Trace route" in a target's detail shows the path to it as mtr does: every
second one ICMP probe goes to each hop (TTL 1, 2, …, up to the destination,
or 30 hops while it has not answered), 10 ms apart, and each hop keeps its
loss and its last, average, best and worst round-trip time and jitter, plus
the last minute as a sparkline. Loss at one hop that the hops after it do
not show is that router limiting its ICMP answers, not loss on the path:
the page shows it grey, with the path's own loss in its tooltip, and keeps
red for loss that carries on to the end.

All traces of one address family run together, as members of one zig-libs
`traceroute.MtrSet` on one socket. Where their paths cross the same routers
(your gateway, your ISP), each such hop gets one probe a second, not one per
trace, and every trace shows that answer (a dotted hop number). Routers
limit their ICMP answers per source, often to about one a second, so
without this every extra trace would make the shared hops look lossier. A
hop is shared only once both traces have seen the same router there a few
times in a row (or one of them nothing at all, with agreeing routers after
it), and each trace probes its whole path itself every 30 seconds, so a
path that changes stops sharing. It runs on the same unprivileged ping socket as the probing (zig-libs
`traceroute`, which reads the routers' answers from the socket's error
queue), so it needs no capability either. Hops are named by reverse DNS
(PTR, through the system resolver, one lookup at a time beside the trace so
a slow resolver never delays a round); a PTR answer that is not a host name
(letters, digits, `-`, `_`, `.`) counts as no name, and `--trace-names off`
shows only the addresses.

A trace measures and changes nothing, so a read-only demo offers it too. It
does show every visitor the path out of your server: your gateway and your
provider's routers, with their names. If that path is nobody's business,
`--trace-max 0` turns traces off. The server bounds traces, not the page:

- **one trace per host**, shared by every viewer of every target with that
  host: more viewers never send more probes, they read the same numbers;
- at most `--trace-max` at once (default 4, `0` turns traces off), and at
  most 10 new ones a minute, 4 of them from one viewer;
- **at most 2 per viewer.** A viewer is a client address, an IPv6 one by
  its /64 (what one subscriber gets). Behind a reverse proxy every request
  comes from loopback, so for a loopback peer the viewer is the last
  `X-Forwarded-For` entry, the one the proxy added (`--trust-proxy off`
  ignores it); a peer that is not on loopback cannot have the header
  believed;
- a trace stops when no viewer polled it for `--trace-idle` (10 minutes on
  a writable instance, your own, so a trace survives switching away; 60 s on
  a read-only one, which is public), and after `--trace-age` in any case
  (1 hour, read-only 10 minutes). Stop (or closing the row) ends only that
  viewer's watching; the trace goes on while someone else watches it.

The page polls an open trace every second and not at all in a hidden tab.
Copy puts the whole table on the clipboard as text (like `mtr --report`); a
click on an address copies just that address. While you select text in the
table it stops refreshing, so a selection is not lost.

## How a cycle works

Every cycle (aligned to the wall clock) takes a copy of the active targets,
resolves names, and pings all of them in **one** `Pinger` round in `.count`
mode, spread over the whole cycle: 5 echo requests per target, a fifth of the
probing window apart (11.6 s at one minute), the first at a random point of
the first fifth, and at least 20 ms between any two packets. The probes of all targets
therefore lie scattered over the minute in no fixed order: the network never
sees a burst, and a short outage anywhere in the minute shows, not only one
during the first seconds. The window ends 2 s before the next cycle: the last
probe goes out by then, and its 1 s timeout leaves a second of room. A target
added, moved or resumed during a cycle joins the next one, so its first
result takes up to two cycles. Every answer and timeout goes to
the live view (`/api/live`) as it comes; at the end the results are recorded
under a lock: probes sent, replies, the median round-trip time and the jitter
(the mean difference between consecutive replies' round-trip times, so
between probes a fifth of the cycle apart). The web UI never waits for a
cycle.

History is a ring of 1440 slots per target, indexed by cycle number, so a gap
(daemon stopped, target paused) needs no bookkeeping: a slot whose timestamp is
not the expected one is shown as "no data".

## Limits

Not there yet; know them before you expose it:

- **No authentication.** Without `--read-only`, anyone who reaches the port can
  change the targets. The default address is loopback; the public instance runs
  read-only.
- **Names resolve 16 at a time**, each lookup bounded (2 s per attempt, 2
  attempts, A and AAAA), and an address is kept for its DNS TTL (1 minute
  to 1 hour); numeric addresses never wait. When DNS does not answer, the
  last address is probed for up to `--dns-stale` (24 hours) and the page
  says so; a name that no longer exists shows its target DOWN.
- **A name follows the host's network.** zpinger listens to the kernel's
  address and route notifications (what `ip monitor` reads, no privilege
  needed). When a global address or a default route comes or goes (a Wi-Fi
  switch, IPv6 lost or back, a VPN), the next cycle checks, without DNS,
  which names' addresses have no route any more and looks those up at once
  (a lookup puts addresses the host has no route to last, so the name moves
  to the family that has one). The other names are looked up again at a
  random point of the next 10 minutes, to move back to the preferred family
  (IPv6) once it returns. Without the notifications (a sandbox that refuses
  netlink), a probe that cannot be sent for lack of a route ("no route to
  host" on the page) makes its name look again within a minute.
- **DNS is asked sparingly.** At most `--dns-rate` names a second (20,
  1200 a minute) are looked up, names without a route first; the others
  keep their address until the next cycle, so a big list or a flapping link
  never sends the local resolver a burst. A lookup that keeps failing (no
  answer, no such name, no route to what it found) waits longer each time:
  1, 2, 4 … 60 minutes, back to normal after an answer that works or a
  change of the network. A target that is merely down (no replies) asks
  DNS only when its answer's TTL runs out, never per probe or per cycle.
- **No TLS.** HTTP/1.1 with keep-alive, each connection on its own thread. A
  reverse proxy in front provides TLS, and the host's protection (CrowdSec,
  fail2ban) per-client request limits.
- **At most 200 targets**, one address per name (the preferred one, in
  getaddrinfo's RFC 6724 order). 200 is what the defaults are measured and
  tuned for: 1000 probes a minute (about 17 packets a second, at least 20 ms
  apart), a state delta of about 3 KB a cycle to each open page, a full
  page redraw in a fraction of a second. `ZPINGER_MAX_TARGETS` raises the
  limit, up to 10 000, for testing: probing was measured to hold 1000
  targets (the gap between packets shrinks below 20 ms above about 580),
  the page was not tuned for more than 200.
- History is saved as JSON after every cycle (about 400 KB for 10 targets),
  or every few cycles when it is bigger: about a megabyte a minute at most
  (8.6 MB every 9 cycles at 200 targets). A crash or restart loses the
  cycles since the last write.

## Many viewers, and the open internet

Viewers only read: probing runs on its own schedule, however many people
have the page open. The one exception is a live trace, which a viewer
starts, but only to a listed target and within the server's bounds
([Live trace](#live-trace)).

- **One serialization per change.** The state JSON is built once per cycle
  (or target change) and served to every viewer from a cache. The page polls
  only the small live view (`/api/live`, the running cycle's probes) every
  2 s, and fetches the state when that says it changed: after the first
  load only a delta, the cycles since its own (`?since=`, shared by the
  viewers asking from the same cycle; [api.md](api.md#get-apistate)); a
  background tab does not poll at all. Measured with 64 targets (a 1.1 MB
  state): 200 concurrent clients fetching it for 10 s, 10 660 full
  responses, 99 threads, 34 MB RSS; idle 11 MB.
- **Bounded connections.** At most 256 at once and 16 from one client
  address (an IPv6 /64); more are closed unanswered. A reverse proxy on
  loopback carries every client on one address, so only the 256 apply to it;
  a proxy on another address (a container bridge, another host) counts as
  one client, and its X-Forwarded-For is not trusted either.
  A request must arrive whole within 10 s of its first byte, a connection
  that sends nothing (or nothing more) is closed after 10 s, and a response
  must be read within 30 s, so a client that never finishes cannot hold a
  thread for longer (250 such connections: 84 MB, all closed on time). A
  flood of them still fills the slots while it lasts; the proxy, which waits
  for a complete request before it connects here, and per-client limits in
  front of it are the answer to that.
- **Nothing to change, nothing to read.** `--read-only` refuses every write
  in the server, not just in the page; the routes are a fixed list (no file
  serving, no path handling); every string reaches the page through
  `textContent`, under a CSP without inline script.

Without `--read-only`, anyone who reaches the server can make it ping
addresses of their choice, including ones on your internal network, and read
which ones answer. Never expose a writable instance.

Loopback alone does not keep web pages out: a page on another site can point
its own host name at 127.0.0.1 (DNS rebinding) and then talk to the server
as its own origin, past the JSON content type check. So a writable instance
answers only when the `Host` header is an IP address, `localhost`, or a
name given with `--allow-host` (behind your own authenticating proxy, say);
anything else gets `421`. A read-only instance answers to any name: it
changes nothing and shows only what it publishes.

Everything in `targets.json` (names *and* host addresses) is public on a
read-only instance; list only targets you are happy to show.

The state is about 15 KB per target, a long run of small numbers that
compresses well: the server sends it gzip-compressed (about a fifth of the
size) to every client that accepts gzip, compressed once per change, not per
request. Enable compression in the proxy (`encode` in the
[Caddy site](deploying.md#a-public-read-only-demo)) for the page itself.
