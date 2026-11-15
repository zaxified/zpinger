// SPDX-License-Identifier: MIT
//! Follows the host's network: a change of its addresses or default routes
//! (a Wi-Fi switch, IPv6 coming or going, a VPN up or down) makes the next
//! cycle look every name up again, whatever its DNS TTL. A lookup orders the
//! addresses by what the host can reach now (RFC 6724 rule 1: an address
//! without a route goes last), so a name moves to the family with a route
//! within one cycle, without first failing a cycle on the old one -- and
//! moves back as soon as the preferred family returns, not after an hour.
//!
//! The notifications are rtnetlink's multicast groups, what `ip monitor`
//! reads; they need no privilege. Without them (a sandbox refusing
//! AF_NETLINK) a probe failing for lack of a route still triggers a lookup
//! within a minute (`monitor.zig`).

const std = @import("std");
const Io = std.Io;
const netlink = @import("netlink");
const Monitor = @import("monitor.zig").Monitor;

const log = std.log.scoped(.netwatch);

/// How long a receive waits before the loop checks for cancellation.
const recv_timeout_ms = 1000;

/// Watches until canceled; returns early (logged) when the kernel refuses
/// the subscription.
pub fn loop(m: *Monitor) Io.Cancelable!void {
    const mask = netlink.rtnlGroupMask(&.{
        netlink.RTNLGRP.IPV4_IFADDR, netlink.RTNLGRP.IPV6_IFADDR,
        netlink.RTNLGRP.IPV4_ROUTE,  netlink.RTNLGRP.IPV6_ROUTE,
    }) catch unreachable; // constant groups, all below 32
    var sock = netlink.Socket.openMonitor(m.gpa, mask) catch |err| {
        log.warn("not following network changes: {t}", .{err});
        return;
    };
    defer sock.close();
    sock.setRecvTimeout(recv_timeout_ms) catch |err| {
        log.warn("not following network changes: {t}", .{err});
        return;
    };
    while (true) {
        try m.io.checkCancel();
        var events = sock.recvEvents() catch |err| switch (err) {
            error.WouldBlock => continue, // the timeout: nothing happened
            // Notifications were dropped: something changed, but what is
            // not known. Looking up again is always safe.
            error.Overrun => {
                m.noteNetworkChange();
                continue;
            },
            else => {
                log.warn("network notifications failed, no longer followed: {t}", .{err});
                return;
            },
        };
        while (events.next() catch null) |ev| if (matters(ev)) {
            m.noteNetworkChange();
            break;
        };
    }
}

/// Whether `ev` can change which addresses the host reaches: a global
/// address coming or going (a link-local one reaches no target), or a
/// default route of any table (a VPN's own table too). A link going down
/// takes its routes with it, and those are reported.
pub fn matters(ev: netlink.Event) bool {
    return switch (ev) {
        .addr_new, .addr_del => |a| a.scope == netlink.RT_SCOPE.UNIVERSE,
        .route_new, .route_del => |r| r.dst_len == 0,
        else => false,
    };
}

// ----- tests ----------------------------------------------------------------------

const testing = std.testing;

test "which notifications make the names be looked up again" {
    var addr: netlink.Address = std.mem.zeroes(netlink.Address);
    addr.scope = netlink.RT_SCOPE.UNIVERSE;
    try testing.expect(matters(.{ .addr_new = addr }));
    try testing.expect(matters(.{ .addr_del = addr }));
    addr.scope = netlink.RT_SCOPE.LINK; // fe80::/10
    try testing.expect(!matters(.{ .addr_new = addr }));

    var route: netlink.Route = std.mem.zeroes(netlink.Route);
    try testing.expect(matters(.{ .route_new = route }));
    try testing.expect(matters(.{ .route_del = route }));
    route.dst_len = 24; // a LAN route
    try testing.expect(!matters(.{ .route_new = route }));
    try testing.expect(!matters(.{ .neigh_new = std.mem.zeroes(netlink.Neighbor) }));
}

test "the subscription needs no privilege, and a quiet network times out" {
    // scripts/netns-run runs the tests as an ordinary user: what the daemon
    // gets under systemd (no capabilities).
    const mask = try netlink.rtnlGroupMask(&.{ netlink.RTNLGRP.IPV4_ROUTE, netlink.RTNLGRP.IPV6_ROUTE });
    var watch = try netlink.Socket.openMonitor(testing.allocator, mask);
    defer watch.close();
    try watch.setRecvTimeout(50);
    try testing.expectError(error.WouldBlock, watch.recvEvents());
}
