# Configuration

## The package's settings

The service reads `/etc/zpinger/env` (the package creates it, every line
commented out); after a change, `systemctl restart zpinger`.

| Variable | Default | |
|---|---|---|
| `ZPINGER_LISTEN` | `127.0.0.1:8080` | the web server address |
| `ZPINGER_TARGETS` | `/var/lib/zpinger/targets.json` | the target list; the page saves its changes there. A read-only instance points it at a file you manage, such as `/etc/zpinger/targets.json` |
| `ZPINGER_OPTS` | (none) | further [options](#options), such as `--read-only` or `--allow-host NAME` |

The history is kept in `/var/lib/zpinger/history.json`.

## Options

| Option | Default | |
|---|---|---|
| `--listen ADDR:PORT` | `127.0.0.1:8080` | web server address |
| `--targets FILE` | `targets.json` | target list; rewritten on every change; a writable instance without it starts empty |
| `--history FILE` | (memory only) | the 24-hour history, saved after every cycle; a corrupt one is moved to `FILE.bad`, one the service cannot read stops it from starting, one from another `--cycle` is ignored and overwritten |
| `--read-only` | off | refuse every change |
| `--demo` | off | `--read-only`, and history older than the last hour is sample data ([deploying.md](deploying.md#sample-data-for-a-demo)) |
| `--allow-host NAME` | | a writable instance also answers to this host name (repeatable; [below](#a-writable-instance-and-host-names)) |
| `--cycle SECONDS` | `60` | seconds between cycles |
| `--trace-max N` | `4` | live traces running at once, `0` turns them off |
| `--trace-names on\|off` | `on` | reverse-DNS names of the trace hops |
| `--trace-idle SECONDS` | `600`, read-only `60` | stop a live trace nobody watched this long (a background tab does not poll) |
| `--trace-age SECONDS` | `3600`, read-only `600` | stop every live trace this long after it started |
| `--trust-proxy on\|off` | `on` | for a request from a loopback peer (your reverse proxy), the client is the address its `X-Forwarded-For` names, or without that header its `X-Real-IP`; every local user counts as that proxy, so on a host shared with people you do not trust put the port out of their reach |
| `--dns-stale SECONDS` | `86400` | keep probing a name's last address this long while DNS does not answer; `0` = never |
| `--access-log refused\|all\|off` | `refused` | which requests become log lines: refused ones (status 400 and up), all, or none ([security-log.md](security-log.md)) |
| `--log-level err\|warn\|info\|debug` | `info` | `warn` keeps the refusals and drops starts, audits and traces |
| `--version` | | print the version and exit |

## The target list

`targets.json` needs only names and hosts; `tags` are optional, and ids,
`paused` and `acked` are added when zpinger saves it:

```json
{ "targets": [
  { "name": "Cloudflare DNS", "host": "1.1.1.1", "tags": ["dns", "ipv4"] },
  { "name": "Wikipedia", "host": "wikipedia.org" }
] }
```

At most 64 targets. The package carries a sample list of public resolvers
and sites, IPv4 and IPv6: `/usr/share/zpinger/targets.json`. Files are
written through a temporary file synced to disk before it replaces the old
one, so a crash or power loss never leaves a truncated list or history.

## A writable instance and host names

A writable instance has no login: anyone who reaches it can change what it
pings, including addresses on your internal network, and see which ones
answer. Keep it on loopback (the default) and reach it through a tunnel,
`ssh -L 8080:127.0.0.1:8080 server`, or behind a proxy that authenticates.

Loopback alone does not keep web pages out: a page on another site can point
its own host name at 127.0.0.1 (DNS rebinding) and then talk to zpinger as
its own origin. So a writable instance answers only when the `Host` header
is an IP address, `localhost`, or a name given with `--allow-host` (the
name of your authenticating proxy, say); anything else gets `421`. A
read-only instance answers to any name: it changes nothing and shows only
what it publishes.

## ICMP

zpinger pings through unprivileged ping sockets, so it needs no root and no
capability, but `net.ipv4.ping_group_range` must cover its group. systemd's
own defaults (`/usr/lib/sysctl.d/50-default.conf`, on Debian and Ubuntu)
allow every group; `sysctl net.ipv4.ping_group_range` shows what a host
has. Where they do not, the package says so when it is installed,
`/healthz` reports `"probing_ok":false` and the journal `probing failed:
PermissionDenied`. Either allow ping sockets in `/etc/sysctl.d/`:

```
net.ipv4.ping_group_range = 0 2147483647
```

or give the service raw sockets instead (`systemctl edit zpinger`):

```ini
[Service]
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
# A capability inside a private user namespace does not reach the host's network.
PrivateUsers=no
```

Run by hand, outside the package, the same holds for your own group.
