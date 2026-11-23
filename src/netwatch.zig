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

/// Errors after which the loop gives up for good, in a row (each costs a
/// second): a peer flooding the socket or a kernel sending what does not parse.
const max_failures = 10;

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
    // Subscribed first, then the dump: nothing falls between the two (an
    // event for what the dump already holds changes nothing).
    var view: View = .{};
    view.sync(m.gpa);
    var failures: u32 = 0;
    var quiet: u32 = 0;
    while (true) {
        try m.io.checkCancel();
        var events = sock.recvEvents() catch |err| switch (err) {
            // The timeout: nothing happened. A view that could not be kept
            // (a failed dump, more addresses or routes than it holds) is
            // tried again once a minute.
            error.WouldBlock => {
                quiet += 1;
                if (view.blind and quiet * recv_timeout_ms >= 60_000) {
                    quiet = 0;
                    view.sync(m.gpa);
                }
                continue;
            },
            // Notifications were dropped: something changed, but what is
            // not known. Looking up again is always safe.
            error.Overrun => {
                m.noteNetworkChange();
                view.sync(m.gpa);
                continue;
            },
            else => {
                failures += 1;
                if (failures >= max_failures) {
                    log.warn("network notifications failed, no longer followed: {t}", .{err});
                    return;
                }
                log.warn("network notifications failed: {t}", .{err});
                m.noteNetworkChange();
                try m.io.sleep(.fromSeconds(1), .awake);
                view.sync(m.gpa);
                continue;
            },
        };
        failures = 0;
        var changed = false;
        while (true) {
            const ev = events.next() catch {
                // The rest of the datagram is lost: assume the worst.
                changed = true;
                view.sync(m.gpa);
                break;
            } orelse break;
            if (view.apply(ev)) changed = true;
        }
        if (changed) m.noteNetworkChange();
    }
}

/// Whether `ev` is about what decides which addresses the host reaches: a
/// global address (a link-local one reaches no target), or a default route
/// of any table (a VPN's own table too). A link going down takes its routes
/// with it, and those are reported.
pub fn matters(ev: netlink.Event) bool {
    return switch (ev) {
        .addr_new, .addr_del => |a| a.scope == netlink.RT_SCOPE.UNIVERSE,
        .route_new, .route_del => |r| r.dst_len == 0,
        else => false,
    };
}

/// The host's global addresses and default routes, as last reported. A
/// notification is a change only when it makes a prefix appear on or vanish
/// from an interface, or adds or removes a default route: the kernel repeats
/// RTM_NEWADDR for an address it already has whenever a router advertisement
/// refreshes its lifetimes (every few seconds to minutes on a SLAAC network),
/// and a new temporary address (RFC 8981) joins a prefix already there.
/// Fixed size; past it every relevant notification counts, as when the view
/// cannot be dumped.
pub const View = struct {
    const max_addrs = 64;
    const max_routes = 32;

    const Addr = struct { family: u8, ifindex: u32, prefixlen: u8, addr: [16]u8 };
    /// A route's identity (what `ip route replace` replaces in place: the
    /// kernel then sends RTM_NEWROUTE only, no RTM_DELROUTE for the old one)
    /// and where it leads.
    const Route = struct {
        family: u8,
        table: u32,
        priority: u32,
        rtype: u8,
        nhid: u32,
        oif: u32 = 0,
        gateway_len: u8 = 0,
        gateway: [16]u8 = @splat(0),

        fn sameIdentity(x: Route, y: Route) bool {
            return x.family == y.family and x.table == y.table and x.priority == y.priority and
                x.rtype == y.rtype and x.nhid == y.nhid;
        }
    };

    addrs: [max_addrs]Addr = undefined,
    addr_n: usize = 0,
    routes: [max_routes]Route = undefined,
    route_n: usize = 0,
    /// Not complete (a failed dump, a full table): every relevant
    /// notification is a change.
    blind: bool = false,

    /// Rebuild from a dump; blind when it fails.
    pub fn sync(v: *View, gpa: std.mem.Allocator) void {
        v.* = .{};
        var nl = netlink.Socket.open(gpa) catch return v.goBlind();
        defer nl.close();
        const addrs = nl.addresses(.{}) catch return v.goBlind();
        defer gpa.free(addrs);
        const routes = nl.routes(.{}) catch return v.goBlind();
        defer gpa.free(routes);
        for (addrs) |a| _ = v.apply(.{ .addr_new = a });
        for (routes) |r| _ = v.apply(.{ .route_new = r });
    }

    fn goBlind(v: *View) void {
        v.* = .{ .blind = true };
    }

    /// Records `ev`; whether it changed what the host can reach.
    pub fn apply(v: *View, ev: netlink.Event) bool {
        if (!matters(ev)) return false;
        if (v.blind) return true;
        return switch (ev) {
            .addr_new => |a| v.addrNew(a),
            .addr_del => |a| v.addrDel(a),
            .route_new => |r| v.routeNew(r),
            .route_del => |r| v.routeDel(r),
            else => false,
        };
    }

    fn addrKey(a: netlink.Address) Addr {
        var k: Addr = .{ .family = a.family, .ifindex = a.ifindex, .prefixlen = a.prefixlen, .addr = @splat(0) };
        @memcpy(k.addr[0..a.addr_len], a.bytes());
        return k;
    }

    fn samePrefix(x: Addr, y: Addr) bool {
        if (x.family != y.family or x.ifindex != y.ifindex or x.prefixlen != y.prefixlen) return false;
        const bits: usize = @min(x.prefixlen, 128);
        const whole = bits / 8;
        if (!std.mem.eql(u8, x.addr[0..whole], y.addr[0..whole])) return false;
        if (bits % 8 == 0) return true;
        const mask: u8 = @truncate(@as(u16, 0xff00) >> @intCast(bits % 8));
        return x.addr[whole] & mask == y.addr[whole] & mask;
    }

    fn prefixCount(v: *const View, k: Addr) usize {
        var n: usize = 0;
        for (v.addrs[0..v.addr_n]) |e| n += @intFromBool(samePrefix(e, k));
        return n;
    }

    fn findAddr(v: *const View, k: Addr) ?usize {
        for (v.addrs[0..v.addr_n], 0..) |e, i| if (std.meta.eql(e, k)) return i;
        return null;
    }

    fn addrNew(v: *View, a: netlink.Address) bool {
        const flags = if (a.flags32 != 0) a.flags32 else a.flags;
        // Still in duplicate address detection: not usable yet. The kernel
        // reports it again when it is.
        if (flags & netlink.IFA_F.TENTATIVE != 0) return false;
        const k = addrKey(a);
        if (v.findAddr(k) != null) return false; // a lifetime refresh
        if (v.addr_n == max_addrs) {
            v.goBlind();
            return true;
        }
        const was = v.prefixCount(k);
        v.addrs[v.addr_n] = k;
        v.addr_n += 1;
        return was == 0;
    }

    fn addrDel(v: *View, a: netlink.Address) bool {
        const k = addrKey(a);
        const i = v.findAddr(k) orelse return false;
        v.addrs[i] = v.addrs[v.addr_n - 1];
        v.addr_n -= 1;
        return v.prefixCount(k) == 0;
    }

    fn routeKey(r: netlink.Route) Route {
        var k: Route = .{ .family = r.family, .table = r.table, .priority = r.priority, .rtype = r.rtype, .nhid = r.nhid, .oif = r.oif, .gateway_len = r.gateway_len };
        @memcpy(k.gateway[0..r.gateway_len], r.gateway[0..r.gateway_len]);
        return k;
    }

    fn findRoute(v: *const View, k: Route) ?usize {
        for (v.routes[0..v.route_n], 0..) |e, i| if (e.sameIdentity(k)) return i;
        return null;
    }

    fn routeNew(v: *View, r: netlink.Route) bool {
        const k = routeKey(r);
        if (v.findRoute(k)) |i| {
            // The same route again (an RA's router lifetime) is no change;
            // a replace that leads elsewhere (multipath hops aside) is.
            if (std.meta.eql(v.routes[i], k)) return false;
            v.routes[i] = k;
            return true;
        }
        if (v.route_n == max_routes) {
            v.goBlind();
            return true;
        }
        v.routes[v.route_n] = k;
        v.route_n += 1;
        return true;
    }

    fn routeDel(v: *View, r: netlink.Route) bool {
        const i = v.findRoute(routeKey(r)) orelse return false;
        v.routes[i] = v.routes[v.route_n - 1];
        v.route_n -= 1;
        return true;
    }
};

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

test "a repeated address or route is not a change, a prefix coming or going is" {
    var v: View = .{};
    var a: netlink.Address = std.mem.zeroes(netlink.Address);
    a.family = netlink.AF.INET6;
    a.scope = netlink.RT_SCOPE.UNIVERSE;
    a.ifindex = 2;
    a.prefixlen = 64;
    a.addr_len = 16;
    a.addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0x10 };
    try testing.expect(v.apply(.{ .addr_new = a })); // the prefix appears
    try testing.expect(!v.apply(.{ .addr_new = a })); // an RA refreshing its lifetimes
    var tmp = a; // a new temporary address in the same prefix
    tmp.addr[15] = 0x99;
    tmp.flags = @truncate(netlink.IFA_F.TEMPORARY);
    try testing.expect(!v.apply(.{ .addr_new = tmp }));
    try testing.expect(!v.apply(.{ .addr_del = a })); // the prefix stays (tmp)
    try testing.expect(v.apply(.{ .addr_del = tmp })); // the prefix is gone
    try testing.expect(!v.apply(.{ .addr_del = tmp })); // unknown: nothing to lose

    var tent = a; // in duplicate address detection: not yet usable
    tent.flags = @truncate(netlink.IFA_F.TENTATIVE);
    try testing.expect(!v.apply(.{ .addr_new = tent }));
    try testing.expect(v.apply(.{ .addr_new = a }));

    var other = a; // another /64 on the same link
    other.addr[7] = 2;
    try testing.expect(v.apply(.{ .addr_new = other }));

    var r: netlink.Route = std.mem.zeroes(netlink.Route);
    r.family = netlink.AF.INET6;
    r.table = 254;
    r.oif = 2;
    r.gateway_len = 16;
    r.gateway[0] = 0xfe;
    r.gateway[1] = 0x80;
    try testing.expect(v.apply(.{ .route_new = r }));
    try testing.expect(!v.apply(.{ .route_new = r }));
    var via = r; // `ip route replace`: the same route, another gateway, no delete
    via.gateway[15] = 2;
    try testing.expect(v.apply(.{ .route_new = via }));
    try testing.expect(v.apply(.{ .route_new = r })); // and back: a change again
    try testing.expectEqual(1, v.route_n);
    var metric = r; // a second default route, another metric
    metric.priority = 1024;
    try testing.expect(v.apply(.{ .route_new = metric }));
    try testing.expect(v.apply(.{ .route_del = r }));
    try testing.expect(!v.apply(.{ .route_del = r }));
    try testing.expect(v.apply(.{ .route_del = metric }));

    // More addresses than the view holds: blind, every notification counts.
    var full: View = .{};
    for (0..View.max_addrs + 1) |i| {
        var x = a;
        x.addr[6] = @intCast(i);
        try testing.expect(full.apply(.{ .addr_new = x }));
    }
    try testing.expect(full.blind);
    try testing.expect(full.apply(.{ .addr_new = a }));

    var lan = r; // not a default route: never a change
    lan.dst_len = 16;
    try testing.expect(!v.apply(.{ .route_new = lan }));

    var blind: View = .{ .blind = true };
    try testing.expect(blind.apply(.{ .addr_new = a }));
    try testing.expect(!blind.apply(.{ .route_new = lan }));
}

test "the dump fills the view" {
    // In scripts/netns-run: loopback only, so no global address and no
    // default route; the dump itself must work unprivileged.
    var v: View = .{};
    v.sync(testing.allocator);
    try testing.expect(!v.blind);
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
