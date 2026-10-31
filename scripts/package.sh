#!/bin/sh
# Build the Debian packages: zpinger_<version>_{amd64,arm64}.deb. The
# binary is static (no libc), so the package needs only what every systemd
# host has (init-system-helpers, for the maintainer scripts) and installs on
# any Debian or Ubuntu: `apt install ./zpinger_<version>_amd64.deb`.
#
#   scripts/package.sh [--skip-tests] [OUTDIR]     (default OUTDIR: zig-out/deb)
#
# Before packing, the native package's own (stripped) binary runs the smoke
# test. Needs dpkg-deb. Also ships the about page for a demo hub
# (zig build about) in /usr/share/zpinger/about/.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# zig-env.sh finds the repository from its own path ($0).
ZIG=$(sh -c '. "$0" && printf %s "$ZIG"' "$HERE/scripts/zig-env.sh")

TESTS=1
[ "${1:-}" = --skip-tests ] && { TESTS=; shift; }
OUT=${1:-$HERE/zig-out/deb}
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)

VERSION=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$HERE/build.zig.zon")
[ -n "$VERSION" ] || { echo "package.sh: cannot read the version from build.zig.zon" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "package.sh: needs dpkg-deb" >&2; exit 1; }

umask 022 # the stage dirs become the package's system dirs
cd "$HERE"
for pair in x86_64-linux:amd64 aarch64-linux:arm64; do
    target=${pair%:*}
    arch=${pair#*:}
    stage=$HERE/zig-out/deb-stage/$arch
    deb=$OUT/zpinger_${VERSION}_$arch.deb
    echo "==> $deb"
    rm -rf "$stage"
    "$ZIG" build -Dtarget="$target" -Dstrip=true --prefix "$stage/usr"
    if [ -n "$TESTS" ] && [ "$target" = "$(uname -m)-linux" ]; then
        sh scripts/smoke.sh "$stage/usr/bin/zpinger"
    fi

    install -D -m 0644 deploy/zpinger.service "$stage/usr/lib/systemd/system/zpinger.service"
    install -D -m 0644 deploy/targets.json "$stage/usr/share/zpinger/targets.json"
    install -D -m 0644 deploy/demo-targets.json "$stage/usr/share/zpinger/demo-targets.json"
    install -D -m 0644 deploy/Caddyfile "$stage/usr/share/zpinger/Caddyfile"
    # CrowdSec acquisition, parser and scenarios for the security log.
    (cd deploy && find crowdsec -type f) | while read -r f; do
        install -D -m 0644 "deploy/$f" "$stage/usr/share/zpinger/$f"
    done
    # The about page for a demo hub: /usr/share/zpinger/about/.
    "$ZIG" build about --prefix "$stage/usr/share/zpinger"
    install -D -m 0644 README.md "$stage/usr/share/doc/zpinger/README.md"
    # The binary links zig-libs in (MIT, whose notice travels with copies):
    # the pinned package's LICENSE, from the hash in build.zig.zon.
    libs_license=$HERE/zig-pkg/$(sed -n 's/^ *\.hash = "\(zig_libs-.*\)",$/\1/p' build.zig.zon)/LICENSE
    [ -f "$libs_license" ] || { echo "package.sh: no $libs_license" >&2; exit 1; }
    { cat "$HERE/LICENSE"; printf '\n%s\n\n' '---------------------------------------------------------------------- zig-libs (linked in):'; cat "$libs_license"; } \
        > "$stage/copyright"
    install -D -m 0644 "$stage/copyright" "$stage/usr/share/doc/zpinger/copyright"
    rm "$stage/copyright"
    install -d "$stage/DEBIAN"
    for script in postinst prerm postrm; do
        install -m 0755 "deploy/debian/$script" "$stage/DEBIAN/$script"
    done
    cat > "$stage/DEBIAN/control" <<EOF
Package: zpinger
Version: $VERSION
Architecture: $arch
Maintainer: zaxified <zaxified@users.noreply.github.com>
Installed-Size: $(du -sk "$stage/usr" | cut -f1)
Depends: init-system-helpers
Conflicts: fping-watch
Section: net
Priority: optional
Homepage: https://github.com/zaxified/zpinger
Description: ping monitor with a web page
 Pings a list of targets once a minute and serves a web page with the last
 24 hours of status, latency and packet loss, on 127.0.0.1:8080. Targets are
 added, paused and acknowledged in the page; ZPINGER_OPTS=--read-only in
 /etc/zpinger/env turns it into a public demo for a reverse proxy.
 Built on zig-libs; one static binary.
EOF
    dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb" >/dev/null
done
ls -l "$OUT"/zpinger_"$VERSION"_*.deb
