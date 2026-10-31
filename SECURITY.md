# Security policy

## Supported versions

zpinger is pre-1.0 and ships from a single release line. Only the **latest
release** (see the [releases page](https://github.com/zaxified/zpinger/releases))
gets security fixes; there are no backports to earlier `v0.x` versions.

## Reporting a vulnerability

Please **do not open a public issue** for a suspected security problem.
Use GitHub's private vulnerability reporting:

1. Go to <https://github.com/zaxified/zpinger/security/advisories/new>.
2. Describe the issue with a reproduction (the requests sent, or a target
   list and history file) and the affected version (`zpinger --version`).

A reply usually comes within 7 days. This is a small project, so there is
no guaranteed response time; a confirmed issue is typically fixed within
days to a couple of weeks, depending on severity. Once a fix is released,
the GitHub Security Advisory is published with credit, unless you prefer
to stay anonymous.

## In scope

zpinger is meant to face the internet (a read-only demo) or a LAN (a
writable instance), so the realistic attack surfaces are:

- **The HTTP server and API**: a request that crashes or hangs the daemon,
  exhausts its memory, threads or connections past the documented limits,
  or changes the target list on a read-only instance.
- **The writable instance's guards**: getting around the Host header guard
  (DNS rebinding) or the JSON content type check (cross-site requests).
- **Live traces**: making zpinger send more probes than its limits allow
  (a trace used as a traffic amplifier), or traces to hosts that are not
  on the target list.
- **The security log**: a request that forges a log line, or one that gets
  around the rate limits and floods the journal.
- **Files it reads**: a crafted target list or history file that crashes
  the daemon instead of being refused (`.bad`).
- **The Debian package**: the systemd unit's sandbox, the maintainer
  scripts.

## Out of scope

- Anything that needs write access to zpinger's state directory or
  configuration, or root on the host.
- Denial of service by sheer volume that the documented limits already
  bound (put a reverse proxy or CrowdSec in front for rates).
- What a read-only instance publishes by design: target names and
  addresses are public there (doc/how-it-works.md, "Many viewers, and the open internet").
- Issues in upstream dependencies (Zig's standard library, zig-libs):
  report them there, unless zpinger's use turns a harmless bug into a
  security issue.
- Findings from automated scanners without a working reproduction.
