# Deploying

## The package

Every release carries `zpinger_<version>_amd64.deb` and `_arm64.deb` with
their `SHA256SUMS` (installing: [README](../README.md#install)). The binary
is static; the package needs only `init-system-helpers`, which every Debian
or Ubuntu with systemd has. It installs, enables and starts
`zpinger.service` on `127.0.0.1:8080`, writable and with no targets yet.

| Path | |
|---|---|
| `/usr/bin/zpinger` | the binary |
| `/usr/lib/systemd/system/zpinger.service` | the service ([deploy/zpinger.service](../deploy/zpinger.service)) |
| `/etc/zpinger/env` | the settings ([configuration.md](configuration.md)); created on install when missing, never overwritten |
| `/var/lib/zpinger/targets.json` | the target list the page edits (systemd `StateDirectory`) |
| `/var/lib/zpinger/history.json` | the history |
| `/usr/share/zpinger/targets.json` | a sample list: public resolvers and sites, IPv4 and IPv6 |
| `/usr/share/zpinger/demo-targets.json` | the demo's list, with sample-data scenarios |
| `/usr/share/zpinger/Caddyfile` | a Caddy site to start from ([deploy/Caddyfile](../deploy/Caddyfile)) |
| `/usr/share/zpinger/crowdsec/` | CrowdSec acquisition, parser and scenarios ([below](#crowdsec)) |
| `/usr/share/zpinger/about/` | an about card for a page of demos ([below](#about-page)) |
| `/usr/share/doc/zpinger/` | this documentation |

Upgrades restart the service (and leave it alone if you disabled it).
`apt remove` keeps the settings, the list and the history; `apt purge`
deletes them.

zpinger was called `fping-watch` while it lived in zig-fping. The package
conflicts with the old `fping-watch` package (same default port); its
`/etc/fping-watch/env` and `/var/lib/fping-watch/` are not carried over
(the variables are now `ZPINGER_*`).

The service runs as a throwaway user (`DynamicUser`) that can write only its
state directory, with no capabilities at all and under a strict sandbox:
seccomp `@system-service`, IPv4/IPv6 sockets only, a private user namespace,
no writable-executable memory, read-only system, `TasksMax` and `MemoryMax`
(`systemd-analyze security zpinger`: 1.3, "OK"). It pings through
unprivileged ping sockets ([configuration.md](configuration.md#icmp)).

## A public read-only demo

Two settings turn the package into a public demo: read-only, with sample
history ([below](#sample-data-for-a-demo)) for the shipped demo targets.

```sh
printf '%s\n' ZPINGER_TARGETS=/usr/share/zpinger/demo-targets.json \
    ZPINGER_OPTS=--demo | sudo tee /etc/zpinger/env
sudo systemctl restart zpinger
curl -s http://127.0.0.1:8080/healthz   # "read_only":true
```

For your own list, point `ZPINGER_TARGETS` at a file you manage, such as
`/etc/zpinger/targets.json`. Everything in it (names *and* host addresses)
is public on a read-only instance: list only targets you are happy to show.

### With Ansible

The settings first, then the package, so the service never
runs writable; the health check then insists on read-only.

```yaml
- name: zpinger settings directory
  ansible.builtin.file: { path: /etc/zpinger, state: directory, mode: "0755" }
- name: zpinger settings
  ansible.builtin.copy:
    dest: /etc/zpinger/env
    mode: "0644"
    content: |
      ZPINGER_LISTEN=127.0.0.1:8080
      ZPINGER_TARGETS=/etc/zpinger/targets.json
      ZPINGER_OPTS=--demo
  notify: restart zpinger
- name: zpinger targets
  ansible.builtin.copy: { src: targets.json, dest: /etc/zpinger/targets.json, mode: "0644" }
  notify: restart zpinger
- name: zpinger package
  ansible.builtin.get_url:
    url: https://github.com/zaxified/zpinger/releases/download/v0.2.0/zpinger_0.2.0_amd64.deb
    dest: /var/cache/zpinger_0.2.0_amd64.deb
    # Pinned from the release's SHA256SUMS: a checksum fetched along with
    # the package would prove nothing.
    checksum: "sha256:<the hash from SHA256SUMS>"
- name: zpinger installed
  ansible.builtin.apt: { deb: /var/cache/zpinger_0.2.0_amd64.deb }
- name: zpinger is healthy and read-only
  ansible.builtin.uri: { url: "http://127.0.0.1:8080/healthz" }
  register: health
  until: health.status == 200 and health.json.read_only
  retries: 10
  delay: 2
```

### Behind a reverse proxy

Publish it through a reverse proxy, which adds TLS, compressed
(`/usr/share/zpinger/Caddyfile`):

```caddyfile
ping.example.org {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}
```

Caddy has no per-client rate limits without a plugin; on the open internet
let the host's protection watch the logs ([CrowdSec](#crowdsec)). The
sample list pings IPv6 addresses too: on a host without IPv6 they stay DOWN,
so leave them out there.

## CrowdSec

zpinger logs every refusal, connection drop and change as one line in a
fixed shape ([security-log.md](security-log.md)). The package carries what
CrowdSec needs to read those lines and ban what they show, in
`/usr/share/zpinger/crowdsec/`; installing and checking it:
[deploy/crowdsec/README.md](../deploy/crowdsec/README.md).

## Sample data for a demo

A new demo has no history, and a healthy network has nothing to show. With
`--demo`, after the first cycle and then at every full hour, everything older
than the last full hour of real probing (or than the start of the daemon,
whichever is later) is replaced with sample data; the page shades it and
marks it "sample data", tooltips included. Only targets with a `"demo"`
scenario get it:

```json
{ "id": 1, "name": "Cloudflare DNS", "host": "1.1.1.1", "demo": "evening_congestion" }
```

| scenario | what it shows |
|---|---|
| `steady` | nothing: small noise, a rare spike |
| `evening_congestion` | a congested uplink 18-22 UTC: latency and jitter climb, a little loss |
| `route_change` | a latency plateau for three hours, 18 to 15 hours ago |
| `flapping` | bursts of partial loss all day, an 8-minute outage 6 hours ago |
| `outage` | 20 minutes of rising latency, jitter and loss, then 45 minutes DOWN, recovered 3 hours ago |
| `down` | the same warning signs, then DOWN from 25 minutes before the live hour: for a target that never answers |
| `bufferbloat` | a nightly backup 01:00-02:30 UTC: a sawtooth of queueing delay |
| `long_haul` | a distant host: more jitter, busier 10-14 UTC |

The sample data is scaled to the target's real median latency, so it joins
the live hour. Time-of-day scenarios stay where they are; the others are
placed relative to the live hour, so they never fall into it, and move on
with it every hour. The sample data is never written to the history file. Live probing stays real, so choose
targets that answer. The package ships a list of public IPv4 and IPv6
targets with one scenario each, `/usr/share/zpinger/demo-targets.json`
(`ZPINGER_TARGETS` can point at it directly); its DOWN target is in
203.0.113.0/24, a range reserved for documentation (RFC 5737) that never
answers.

## About page

For a page that lists several demos, the package carries a description of
this one in `/usr/share/zpinger/about/` (`zig build about` writes the same
into `zig-out/about/`), generated from [deploy/about.json](../deploy/about.json):

| file | |
|---|---|
| `about-card.html` | an HTML fragment to include: one `<article class="demo" id="demo-zpinger">`, no styles, no scripts; class names (`demo-title`, `demo-tagline`, `demo-screenshot`, `demo-summary`, `demo-features`, `demo-facts`, `demo-source`) for the hub to style, schema.org `SoftwareApplication` microdata, `data-version` |
| `about.html` | the same card as a standalone page (light and dark) |
| `about.json` | the same data plus `version`, for templating |
| `screenshot.png` | referenced by both pages relatively, keep it next to them |

None of them links to the demo itself: only the hub knows its URL. With
Ansible, after the package is installed on the same host:

```yaml
- name: zpinger about card
  ansible.builtin.copy:
    src: /usr/share/zpinger/about/
    dest: "{{ demo_hub_root }}/zpinger/"
    remote_src: true
```
