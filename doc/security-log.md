# Security log

Everything goes to stderr, under systemd into the journal with its priority
(`journalctl -u zpinger -p warning` shows the refusals). Besides the plain
messages (start-up errors, a failed write), anything worth knowing about
who did what is an **event**: one line in a fixed shape, for people and for
log parsers such as CrowdSec ([deploy/crowdsec/](../deploy/crowdsec/README.md)).

```
event=http client=198.51.100.7 peer=127.0.0.1 status=429 reason=trace_rate method="POST" path="/api/targets/3/trace" ms=0 bytes=86 ua="Mozilla/5.0 ..."
```

- `client` is who the line is about: the socket peer, or behind a reverse
  proxy on loopback (`--trust-proxy`) the address it forwarded, in which case
  `peer=` follows with the proxy's. A line without `peer` came straight from
  the client.
- Text a client chose (`method`, `path`, `ua`, `host`, a name) is quoted,
  `"` and `\` are escaped with a backslash, every byte outside printable
  ASCII is written `\xNN`, and a value over 200 bytes is cut and ends in
  `...`. A request cannot forge a line or write bytes a parser chokes on.
- What a client can trigger is rate-limited per client (an IPv6 /64: a
  burst of 20, then 2 lines a second) and in total, in classes with budgets
  of their own (refusals and traces 500 then 50 a second, connection events
  the same, answered requests 1000 then 100, changes on a writable instance
  200 then 10): a flood neither fills the journal, nor buries other
  clients' lines, nor one kind of line another. A line is cut at 4 KiB,
  marked ` ...`; `status` and `reason` come first, so no request can push
  them out. No thread waits for the journal: lines go through a 64 KiB
  queue, and when the journal falls that far behind, lines are dropped
  (the server keeps accepting). What was dropped is reported
  every 10 s as `event=log action=dropped class=... count=N`.

| Event | When | Keys |
|---|---|---|
| `start` | the daemon starts | `version listen targets mode trust_proxy allow_host trace_max access_log dns_stale` |
| `conn action=refused` | a connection closed at accept, unanswered | `reason`: `total_cap` (256 open), `per_ip_cap` (16 from one client), `store_full` (too many clients tracked at once) |
| `conn action=closed` | a timeout cut a connection off, or it ended without a single request | `reason`: `timeout` (a slowloris or a slow reader held it to a 10 s deadline), `no_request` (closed by the client: a port scan, TLS on the plain-HTTP port), `idle` (a kept-alive connection no next request came on: browsers do that; `debug` level); `requests ms`, with a timeout `phase` (`no_request head body write response`) |
| `http` | a request, with `--access-log refused` (the default) only those answered 400 or above, with `all` every one | `status reason method path ms bytes ua` (in this order), `host` (with `host_not_allowed`), `xff_ignored` (an X-Forwarded-For from a peer that is not a trusted proxy) |
| `http reason=bad_request_head` | refused before it was read whole: a malformed head (400), too large (431, 414), a body over 4 KiB (413; a chunked one once its reading crosses the cap) | `status`; only the peer is known |
| `audit` | a change on a writable instance | `action` (`add edit remove tags pause resume ack unack`), `target`, `name`, `host`, `host_was`, `tags` (a count) |
| `trace` | a live trace asked for, left, or ended | `action`: `start` (or join), `stop`, `end` (no client, `reason`: `idle max_age stopped unresolved no_socket failed`); `target host` |
| `dns` | a target's name stops resolving or resolves again | `action`: `stale` (no answer from DNS, the last address is probed), `failed` (no address), `recovered`, `moved` (`from addr`); `target host error` |
| `log action=dropped` | the rate limits or a full queue dropped lines | `class count` |

`reason` on `http` lines says why a request was refused:

| `reason` | Status | Meaning |
|---|---|---|
| `host_not_allowed` | 421 | a writable instance asked for under a name it does not answer to: DNS rebinding, or a scanner |
| `read_only` | 403 | a change sent to a read-only instance |
| `not_json` | 415 | a change without the JSON content type (what a cross-site form sends) |
| `bad_json`, `invalid_name`, `invalid_host`, `invalid_tags` | 400 | a change that does not parse or validate |
| `not_found`, `no_such_target`, `no_trace` | 404 | an unknown path (a scanner's signature), target or trace |
| `bad_method` | 405 | a method the route does not take |
| `too_many_targets`, `not_down` | 409 | the target list is full; an acknowledgement of a target that is not DOWN |
| `trace_viewer_limit`, `trace_rate` | 429 | the client watches 2 traces already; it started 4, or everybody 10, in the last minute |
| `trace_cap`, `trace_disabled` | 503, 403 | `--trace-max` traces running; traces are off |
| `body_aborted` | 500 | the client hung up inside its request body (nobody reads this status) |
| `handler_failed`, `server_failed` | 500, 503 | a fault on the server's side (logged as errors) |

`--log-level warn` keeps the refusals and drops the rest (starts, audits,
traces); `--access-log off` drops the `http` lines too.
