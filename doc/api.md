# HTTP API

The page uses this API and nothing else; scripts can too. `ID` is a target's
`id` from `/api/state`.

| Method | Path | |
|---|---|---|
| `GET` | `/api/state` | everything the page shows ([below](#get-apistate)) |
| `GET` | `/api/live` | the cycle being probed, probe by probe ([below](#get-apilive)) |
| `POST` | `/api/targets` | add a target |
| `PATCH` | `/api/targets/ID` | rename, move to another host, retag |
| `DELETE` | `/api/targets/ID` | remove |
| `POST` | `/api/targets/ID/tags` | replace the tags |
| `POST` | `/api/targets/ID/pause` | stop probing |
| `POST` | `/api/targets/ID/resume` | probe again |
| `POST` | `/api/targets/ID/ack` | acknowledge a DOWN target |
| `POST` | `/api/targets/ID/unack` | withdraw the acknowledgement |
| `POST` | `/api/targets/ID/trace` | start a live trace, or join the running one |
| `GET` | `/api/targets/ID/trace` | read the live trace |
| `DELETE` | `/api/targets/ID/trace` | stop watching it |
| `GET` | `/healthz` | health, for monitoring and deploy checks |

An error is a 4xx or 5xx status with `{"error": "..."}`; the security log
names its reason ([security-log.md](security-log.md)).

## `GET /api/state`

Per target its status, flags, tags and the 24-hour series, one entry per
cycle, oldest first, `null` = no data:

- `rtt`: the median round-trip time, ms;
- `jitter`: ms, `null` with fewer than two replies;
- `loss`: %.

With `--demo`, a target with sample data has `"sample": true` and its own
`demo_from`: the cycles before it are sample data. It is the state's
`demo_from` (the start of the real data), or later for a target added to
the list after that.

The answer carries an ETag: with `If-None-Match` it is `304` until the state
changes. A client that accepts gzip gets it compressed (`"…-gzip"` ETag).

`?since=END`, with the `end` of a state the client has, asks for a delta: the
same answer, but the series hold only the cycles from `END` on (`END`
included: it may have been recorded since), and `since` says so. Put them
after your own series without its newest entry, shifted by `(end - END) /
cycle_s`. A `since` that is not a cycle start within the last 60 cycles (an
hour at the default cycle) gets the whole state (no `since` in the answer):
the whole state is built once and shared by every viewer, a delta only by
the viewers asking from the same cycle. The page asks for a delta every
time the live view says the state changed: a few hundred bytes per target
rather than the whole day (3.5 MB, 650 KB compressed, at 200 targets).
Fetch the whole state again when `demo_from` or `demo_fills` changed (a demo
renews its sample data every hour, and after each of its first 10 cycles) or a
target is new.

The answer also has `version` (it changes with every recorded cycle and
every change of the targets) and `end`, the start (unix s) of the newest
cycle in the series.

## `GET /api/live`

The cycle being probed: `now` (the server's clock, unix ms), `cycle` (its
start, unix s), `cycle_s`, `version` (the state's), `targets` (the ids it
probes; one added during the cycle joins the next) and `probes`, every probe
answered or given up on so far, in that order, as `[id, ms, rtt]`: the target,
when the answer came or the probe timed out (ms after the cycle start) and the
round-trip time in ms, `null` = lost. A cycle's 5 probes per target are spread
over the whole cycle ([how-it-works.md](how-it-works.md#how-a-cycle-works)).
When `version` differs from the state's, or `cycle` is newer than its `end`,
the state has something new. `count` is the number of probes so far. With
`?cycle=C&from=N` (C the cycle the caller has, N the probes it has of it) the
answer lists only the probes after the first N, and `from` says where they
start; for another cycle, or an N past `count`, it lists them all (`from` is
0). The page polls it every 2 s that way, so a poll carries only the probes
of the last 2 s, however many targets there are. It has no ETag (`now`
changes anyway).

## Changes

Every change must be sent as `application/json` (else `415`): a cross-site
HTML form cannot do that without a CORS preflight, which the server never
approves, so a page on another site cannot change the targets behind your
back. A read-only instance answers `403` to all of them.

- `POST /api/targets`: `{"name": "...", "host": "...", "tags": ["..."]}`,
  `tags` optional; `201 {"id": N}`.
- `PATCH /api/targets/ID`: `{"name": "...", "host": "...", "tags": [...]}`,
  any of them may be left out, all or nothing. A new host keeps the
  history; the status starts over as PENDING and an acknowledgement is
  dropped.
- `POST /api/targets/ID/tags`: `{"tags": ["dns", "ipv6"]}`. At most 8 tags,
  each 1-32 characters without spaces or commas, stored lowercase without
  duplicates.
- `ack` takes only a DOWN target (`409` otherwise). An acknowledged target
  shows ACK until 5 cycles in a row are not DOWN.

## Live trace

`POST /api/targets/ID/trace` starts a trace of the target's host, or joins
the running one: `202`. Refusals: `429` when this viewer watches 2 traces
already or 10 traces started in the last minute, `503` when `--trace-max`
traces run, `403` when traces are off. Polling is watching: each `GET` keeps
the trace running and counts against the viewer's 2. `DELETE` stops
watching; the trace stops when its last viewer has. `404` when none runs.
The limits: [how-it-works.md](how-it-works.md#live-trace).

`GET` answers:

- `state`, `reason` (why it stopped), `rounds`, `reached`, `max_age` and
  `idle` (the limits, seconds);
- `hops`, each with:
  - `ttl`;
  - `hosts`, the latest responder first, and `names`, the reverse-DNS name of
    `hosts[i]` (`null` = none, or not yet);
  - `sent`, `recv`, `loss` (‰);
  - `last`, `avg`, `best`, `worst`, `jitter`: µs, `null` = none;
  - `code`: an ICMP Destination Unreachable code, or `null`;
  - `shared`: the last answer came from a probe shared with other traces;
  - `spark`: the last 60 rounds, µs, `null` = lost.

## `GET /healthz`

`200 {"ok": true, "probing_ok": true, "last_cycle": ..., "read_only": ...,
"demo": ..., "version": "..."}` while cycles keep finishing (at most 3
cycles apart) and the ICMP socket opens; `503` otherwise. Unreachable
targets do not count: they are what is being monitored.
