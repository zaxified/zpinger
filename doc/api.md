# HTTP API

The page uses this API and nothing else; scripts can too. `ID` is a target's
`id` from `/api/state`.

| Method | Path | |
|---|---|---|
| `GET` | `/api/state` | everything the page shows ([below](#get-apistate)) |
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

The answer carries an ETag: with `If-None-Match` it is `304` until the state
changes. A client that accepts gzip gets it compressed (`"…-gzip"` ETag).

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
