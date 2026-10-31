# Contributing to zpinger

Contributions are welcome, including fully agentic / AI-assisted pull
requests. Small, focused changes are the easiest to review: if a PR
touches more than one area, consider splitting it.

## Ground rules

- **Linux only, one static binary.** No libc, no C dependencies; the only
  dependency is [zig-libs](https://github.com/zaxified/zig-libs). A
  capability that belongs in a library goes to zig-libs (or a request in
  its issues), not into a copy here.
- **Unprivileged.** zpinger runs as a throwaway user with no capabilities
  (ICMP through ping sockets); a change must not need root or
  `CAP_NET_RAW`.
- **Bounded.** Everything a client can trigger (connections, live traces,
  log lines) has a limit; a new feature reachable from the web needs one
  too, and a line in the README if it is a new option.
- **The security log is a contract.** The README section "Security log"
  lists every event and key; parsers (CrowdSec in `deploy/crowdsec/`)
  match on it. Keep the field order; add new keys at the end of a line.
- **English** for code comments, commit messages and documentation.
- No personal information (names, e-mails, `/home/<user>` paths) in
  committed files.

## Checks before submitting

```sh
sh scripts/test.sh   # fmt check, unit tests, both .deb packages, smoke test
```

This is the same entry point CI uses. It downloads the pinned Zig
(`.zigversion`) when none is installed and needs no sudo, but it needs
unprivileged user namespaces (`unshare -Urn`): the unit tests and
`scripts/smoke.sh` send real ICMP inside a private network namespace
(`scripts/netns-run`) and touch no real network. `dpkg-deb` builds the
packages.

New behaviour needs a test: pure logic gets a unit test next to the code;
anything on the wire gets a case in `scripts/smoke.sh`. For a UI change,
`scripts/dev-instances.sh restart` runs local instances to look at it.

## License

By contributing you agree that your contribution is licensed under the
project's MIT license (see LICENSE).
