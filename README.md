# zpinger

[![CI](https://github.com/zaxified/zpinger/actions/workflows/ci.yml/badge.svg)](https://github.com/zaxified/zpinger/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/zaxified/zpinger?include_prereleases&sort=semver)](https://github.com/zaxified/zpinger/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig 0.17](https://img.shields.io/badge/Zig-0.17-f7a41d.svg)](https://ziglang.org)

A small ping monitor: a daemon that pings your hosts once a minute and serves
a web page with their status, latency and packet loss over the last 24
hours, plus a live trace of the route to any of them. One static binary,
shipped as a Debian package; no root needed.

![zpinger: eight hosts with status, tags, recent cycles and uptime; one row expanded to its 24-hour latency chart and a live trace of the route, hop by hop](doc/screenshot.png)

<sub>The read-only demo (`--demo`, sample data): one target down, one row expanded with a live trace. The route is made up from documentation addresses.</sub>

## Install

On Debian or Ubuntu (amd64 or arm64), the latest release:

```sh
v=0.2.0 arch=$(dpkg --print-architecture)
url=https://github.com/zaxified/zpinger/releases/download/v$v
curl -fL -O "$url/zpinger_${v}_$arch.deb" -O "$url/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
sudo apt install "./zpinger_${v}_$arch.deb"
```

It starts right away on `http://127.0.0.1:8080`: open it and add the hosts
to watch. On a server, reach it through a tunnel:
`ssh -L 8080:127.0.0.1:8080 server`. Until you change that it is writable
without a login, for anything that reaches the port: on a host you share,
write `/etc/zpinger/env` before you install. Never put a writable instance
on the internet.

Everything else is optional: settings in `/etc/zpinger/env`
([configuration](doc/configuration.md)), a public read-only demo behind a
reverse proxy, CrowdSec ([deploying](doc/deploying.md)).

## What it shows

- one row per host: its status, a strip of recent cycles (green: all
  replies, orange: some lost, red: all lost), 24-hour uptime and latency;
- a click opens the 24-hour latency chart with packet loss underneath, and
  the averages, 95th percentile, jitter, loss and uptime;
- **live trace** (like mtr): the route hop by hop, loss and latency per hop,
  updated every second;
- problems first: DOWN, then losing probes now, then a problem in the last
  hour or day ([how it works](doc/how-it-works.md));
- tags, search, sorting and status filters, kept in the URL so a view can be
  bookmarked; names and tags edited in place;
- pause a host, or **acknowledge** an outage until it is over;
- `--read-only` for a public demo, `--demo` with sample history that shows
  what problems look like.

## Documentation

| | |
|---|---|
| [Configuration](doc/configuration.md) | settings, every option, the target list, ping permissions, a writable instance's safety |
| [Deploying](doc/deploying.md) | what the package installs, a public read-only demo (by hand, Ansible, Caddy), CrowdSec, sample data |
| [How it works](doc/how-it-works.md) | problem tiers, live traces and their limits, the probing cycle, many viewers, the open internet |
| [HTTP API](doc/api.md) | the endpoints the page uses |
| [Security log](doc/security-log.md) | the events zpinger logs, for people and for log parsers |
| [Development](doc/development.md) | building from source, tests, trying a change |
| [CHANGELOG](CHANGELOG.md) | what changed in each release |

## Contributing and security

Pull requests are welcome: [CONTRIBUTING.md](CONTRIBUTING.md). Report a
security problem privately, as [SECURITY.md](SECURITY.md) describes.

## License

MIT ([LICENSE](LICENSE)). It started as `fping-watch`, zig-fping's example
application, and is built on [zig-libs](https://github.com/zaxified/zig-libs),
MIT too; the package's `copyright` file carries both notices.
