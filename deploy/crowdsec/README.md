# CrowdSec for zpinger

zpinger writes its security events to the journal (README "Security log").
These files let CrowdSec read them and ban what they show:

| File | Goes to |
|---|---|
| `acquis.d/zpinger.yaml` | `/etc/crowdsec/acquis.d/` — read `zpinger.service`'s journal |
| `parsers/s01-parse/zpinger-logs.yaml` | `/etc/crowdsec/parsers/s01-parse/` |
| `scenarios/*.yaml` | `/etc/crowdsec/scenarios/` |

The package installs them under `/usr/share/zpinger/crowdsec/`; copy them,
then `systemctl reload crowdsec`. Bans are applied by a bouncer (the
nftables firewall bouncer bans an address before it reaches zpinger or a
proxy).

| Scenario | Bans a client that | Bucket |
|---|---|---|
| `zpinger/trace-abuse` | keeps asking for live traces past the limits (429, 503) | 10, one leaks every 30 s |
| `zpinger/api-probing` | sends changes zpinger refuses (read-only, not JSON, invalid, wrong method) | 5, 1 min |
| `zpinger/host-mismatch` | asks a writable instance for a host name it does not serve (421: DNS rebinding, host scans) | 10, 10 min |
| `zpinger/bad-requests` | sends malformed or oversized requests (400, 413, 414, 431) | 5, 1 min |
| `zpinger/slowloris` | holds connections until the read timeout without a request | 30, 20 s (browsers leave a few preconnects unused) |
| `zpinger/conn-flood` | keeps opening connections past the 16 per client | 20, 10 s |

A request that came straight from the client (no `peer=` in its line:
nothing in front of zpinger) is also handed to CrowdSec's generic HTTP
scenarios as an access-log line (`crowdsecurity/base-http-scenarios`:
path scans, sensitive files, bad user agents, ...). Behind a proxy they
read the proxy's log instead; zpinger's lines still add the scenarios above,
with the real client address (`--trust-proxy`).

Addresses on loopback and in private ranges are never banned
(`crowdsecurity/whitelists`): behind a proxy the connection events name the
proxy, and those cannot be told apart per client. Put your own networks on
CrowdSec's allowlist too: a firewall bouncer's ban closes every port, SSH
included, and opening a writable instance under a name it does not serve
fills `host-mismatch` within a minute.

## Checking it on a host

```
cscli explain --file /usr/share/zpinger/crowdsec/sample.log --type syslog
cscli metrics show acquisition parsers   # zpinger.service lines read and parsed
cscli decisions list                     # who is banned, by which scenario
```

`sample.log` holds one line of each kind, as journalctl shows them.
