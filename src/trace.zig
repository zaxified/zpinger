//! Live per-hop traces for the target detail, mtr style: every round sends
//! one probe to each hop of the path and keeps running statistics per hop
//! (loss, last/average/best/worst round-trip time, jitter) plus the last
//! `spark_len` rounds for a sparkline.
//!
//! A trace is a measurement, not a change, so a read-only instance offers it
//! too; what bounds it is the server, not the page:
//! - one session per host, shared by every viewer of every target with
//!   that host: more viewers never mean more probes;
//! - at most `max_sessions` sessions at once (`--trace-max`, 0 disables),
//!   `max_starts_per_min` new ones a minute, `max_per_viewer` per viewer
//!   (a client address, see `Viewer`);
//! - a session stops when no viewer polled it for `Tracer.idle_s` (or the
//!   last one left), and `Tracer.max_age_s` after it started, whatever the
//!   page does (both shorter on a read-only instance, see `Limits`);
//! - every trace of one address family is a member of one zig-libs
//!   `traceroute.MtrSet` (`Engine`): one socket, rounds at most once a
//!   second, probes paced `gap_ms` apart, and a hop shared by several
//!   traces probed once a round.
//! Without CAP_NET_RAW it runs on an unprivileged ping socket, like the
//! probing cycle.
//!
//! Hop names come from reverse DNS (PTR) on a second task per session, one
//! lookup at a time, so a slow resolver never holds up a round
//! (`Tracer.names = false`, `--trace-names off`, turns it off). Every
//! session shares one cache of them (`NameCache`), kept like a target's
//! address: an answer for its TTL, a failure for a backoff growing to an
//! hour, freed once expired.
//!
//! A trace goes to the address the probing cycle uses for its host, and
//! follows it: when the cycle moves the name to the other family (the host
//! lost its IPv6 route, or got it back), the trace starts over there.
//!
//! Locking: `Tracer.mutex` guards the session table; each `Session.mutex`
//! guards that session's snapshot, which the engine of its family fills.

const std = @import("std");
const Io = std.Io;
const traceroute = @import("traceroute");
const netaddr = @import("netaddr");
const dns = @import("dns");
const ratelimit = @import("ratelimit");
const monitor = @import("monitor.zig");
const resolve = monitor.resolve;
const Monitor = monitor.Monitor;
const events = @import("events.zig");

const log = std.log.scoped(.trace);

/// Hops shown and probed while the destination has not answered.
pub const max_hops = 30;
/// Rounds kept per hop for the sparkline.
pub const spark_len = 60;
/// How long a trace runs: it stops `idle_s` after its last poll (a page
/// in a background tab does not poll), and `max_age_s` after it started in
/// any case; the page can start a new one. A writable instance is the
/// owner's own, so its traces wait for a viewer who switched away; a
/// read-only one is public, so a forgotten tab frees its trace soon.
pub const Limits = struct {
    idle_s: i64,
    max_age_s: i64,

    pub const writable: Limits = .{ .idle_s = 10 * 60, .max_age_s = 60 * 60 };
    pub const read_only: Limits = .{ .idle_s = 60, .max_age_s = 10 * 60 };
};
/// Upper bound of `--trace-max`.
pub const max_slots = 16;
/// Hop addresses a session looks up a name for: every responder of every hop.
const max_names = max_hops * traceroute.max_mtr_addresses;
/// A PTR lookup gets one try of this long per server: a name is a nicety,
/// and the next address waits behind it.
const name_timeout_ms = 1000;
/// How often the lookup task checks for new addresses.
const name_poll_ms = 250;

/// All traces of one address family run as members of one `MtrSet`: a hop
/// their paths share (the home gateway, the ISP's routers) gets one probe a
/// round, however many traces cross it, so a router limiting its ICMP
/// answers per source does not show false loss when several traces run.
const set_options: traceroute.MtrSetOptions = .{
    .mtr = .{
        .max_hops = max_hops,
        .interval_ms = 1000,
        .timeout_ms = 1000,
        // Paces the whole round, every member's probes together.
        .gap_ms = 10,
    },
};

pub const Error = error{ TraceDisabled, TooManyTraces, ViewerLimit, RateLimited };

/// Live traces one viewer may watch at once.
pub const max_per_viewer = 2;
/// New sessions per minute, all viewers together.
pub const max_starts_per_min = 10;
/// New sessions per minute for one viewer: starting and stopping in a loop
/// must not use up everybody's `max_starts_per_min`.
pub const max_viewer_starts_per_min = 4;
const starts_config: ratelimit.TokenBucket.Config = .{ .rate_per_s = @as(f64, max_starts_per_min) / 60, .burst = max_starts_per_min };
const viewer_starts_options: ratelimit.Options = .{ .rate_per_s = @as(f64, max_viewer_starts_per_min) / 60, .burst = max_viewer_starts_per_min, .max_keys = max_watches, .key = .forwarded_ip };
/// Viewer-to-session watches kept at once (a full table refuses new viewers).
const max_watches = 256;

/// Who watches a trace: the client address, IPv4 as IPv4-mapped, IPv6 cut
/// to its /64, the prefix one subscriber gets, so one subscriber cannot
/// pose as many viewers.
pub const Viewer = [16]u8;

pub fn viewerOf(ip: netaddr.Ip) Viewer {
    return events.keyOf(ip);
}

const Watch = struct { viewer: Viewer, session: *Session, last_poll: i64 };

pub const Tracer = struct {
    gpa: std.mem.Allocator,
    io: Io,
    max_sessions: u8 = 4,
    /// Where a trace takes its target's address: the one the cycle probes.
    /// Null (tests), or a host no target has an address for: a lookup.
    addresses: ?*Monitor = null,
    limits: Limits = .writable,
    /// Look up hop names (reverse DNS).
    names: bool = true,
    /// Hop names every session shares.
    name_cache: NameCache = .{},
    mutex: Io.Mutex = .init,
    /// One session per host: every viewer of that host, through any target,
    /// reads the same measurement.
    slots: [max_slots]?*Session = @splat(null),
    /// Sessions told to stop whose thread has not ended yet (it may sit in
    /// a DNS lookup for seconds); freed by `reap` once it has. Waiting for
    /// such a thread under `mutex` would hold up every trace request.
    dying: [max_slots]?*Session = @splat(null),
    watches: [max_watches]?Watch = @splat(null),
    /// The probing engines, IPv4 and IPv6.
    engines: [2]Engine = .{ .{ .family = .v4 }, .{ .family = .v6 } },
    /// Gives every session an identity the engines can check (a freed
    /// session's address may come back for the next one).
    serial: u64 = 0,
    /// New sessions, all viewers together and per viewer (`allowStart`);
    /// set up by the first start.
    starts: ?ratelimit.TokenBucket = null,
    viewer_starts: ?ratelimit.Limiter = null,

    /// Stops every session and waits for their threads, then for the
    /// engines (each stops after its round once no session is left).
    pub fn deinit(t: *Tracer) void {
        for (&t.slots) |*slot| if (slot.*) |s| {
            s.stop.store(true, .monotonic);
            t.release(s);
            slot.* = null;
        };
        for (&t.dying) |*d| if (d.*) |s| {
            t.release(s);
            d.* = null;
        };
        for (&t.engines) |*e| e.wait(t.io);
        t.name_cache.deinit(t.gpa);
        if (t.viewer_starts) |*l| l.deinit();
    }

    /// Frees the hop names whose time ran out (`main` calls it once a
    /// minute, whether a trace runs or not).
    pub fn pruneNames(t: *Tracer) void {
        t.name_cache.prune(t.io, t.gpa, t.clock());
    }

    /// `viewer` watches the trace of `host`: joins the running session, or
    /// starts one. A finished session (idle, too old, failed) is replaced.
    pub fn start(t: *Tracer, host: []const u8, viewer: Viewer) (Error || error{OutOfMemory} || Io.ConcurrentError)!void {
        if (t.max_sessions == 0) return error.TraceDisabled;
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const now = t.clock();
        t.reap();
        t.expireWatches(now);
        if (t.running(host)) |s| return t.watch(viewer, s, now);

        if (t.watchCount(viewer) >= max_per_viewer) return error.ViewerLimit;
        if (t.freeWatch() == null) return error.TooManyTraces;
        var free: ?usize = null;
        var running_n: usize = 0;
        for (&t.slots, 0..) |*slot, i| {
            const s = slot.* orelse {
                if (free == null) free = i;
                continue;
            };
            if (s.finished.load(.acquire)) {
                t.drop(s);
                slot.* = null;
                if (free == null) free = i;
                continue;
            }
            running_n += 1;
        }
        if (running_n >= t.max_sessions) return error.TooManyTraces;
        const slot = free orelse return error.TooManyTraces;
        if (!t.allowStart(viewer, t.clockNs())) return error.RateLimited;

        const s = try t.gpa.create(Session);
        errdefer t.gpa.destroy(s);
        t.serial += 1;
        s.* = .{ .tracer = t, .serial = t.serial, .host = try t.gpa.dupe(u8, host), .started = now, .last_poll = .init(now) };
        errdefer t.gpa.free(s.host);
        s.future = try t.io.concurrent(Session.run, .{s});
        t.slots[slot] = s;
        t.watch(viewer, s, now) catch unreachable; // count and room checked above
    }

    /// `viewer` stops watching the trace of `host`; the session stops when
    /// nobody watches it any more.
    pub fn stop(t: *Tracer, host: []const u8, viewer: Viewer) void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        t.reap();
        t.expireWatches(t.clock());
        const s = t.running(host) orelse return;
        var others = false;
        for (&t.watches) |*w| if (w.*) |x| if (x.session == s) {
            if (std.mem.eql(u8, &x.viewer, &viewer)) w.* = null else others = true;
        };
        if (others) return;
        for (&t.slots) |*slot| if (slot.* == s) {
            t.retire(s);
            slot.* = null;
        };
    }

    /// The trace of `host` as JSON (see `Session.writeJson`); null when there
    /// is none. Reading a running trace is watching it: it keeps the session
    /// alive and counts against `viewer`'s limit.
    pub fn json(t: *Tracer, host: []const u8, viewer: Viewer, arena: std.mem.Allocator) (error{ OutOfMemory, ViewerLimit, TooManyTraces })!?[]u8 {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const now = t.clock();
        t.reap();
        t.expireWatches(now);
        const s = t.running(host) orelse t.session(host) orelse return null;
        if (!s.finished.load(.acquire)) try t.watch(viewer, s, now);
        var out: Io.Writer.Allocating = .init(arena);
        s.writeJson(&out.writer, now) catch return error.OutOfMemory;
        return out.written();
    }

    /// Whether a new session may start now: at most `max_starts_per_min`
    /// a minute in total and `max_viewer_starts_per_min` per viewer (token
    /// buckets: the whole count at once, then refilled evenly over the
    /// minute). The viewer's limit is asked first, so a viewer held back
    /// takes nothing from everybody else. Under `mutex`.
    fn allowStart(t: *Tracer, viewer: Viewer, now_ns: u64) bool {
        if (t.viewer_starts == null) t.viewer_starts = .init(t.gpa, viewer_starts_options);
        if (t.starts == null) t.starts = .full(starts_config, now_ns);
        if (!t.viewer_starts.?.allowAt(&viewer, now_ns).allowed) return false;
        return t.starts.?.allowAt(starts_config, now_ns).allowed;
    }

    /// The running session of `host`. Under `mutex`.
    fn running(t: *Tracer, host: []const u8) ?*Session {
        for (t.slots) |slot| if (slot) |s| if (std.mem.eql(u8, s.host, host) and !s.finished.load(.acquire)) return s;
        return null;
    }

    /// Any session of `host`, finished ones too. Under `mutex`.
    fn session(t: *Tracer, host: []const u8) ?*Session {
        for (t.slots) |slot| if (slot) |s| if (std.mem.eql(u8, s.host, host)) return s;
        return null;
    }

    /// Records (or refreshes) that `viewer` watches `s`. Under `mutex`.
    /// Only an accepted watch keeps the session alive.
    fn watch(t: *Tracer, viewer: Viewer, s: *Session, now: i64) error{ ViewerLimit, TooManyTraces }!void {
        for (&t.watches) |*w| if (w.*) |*x| if (x.session == s and std.mem.eql(u8, &x.viewer, &viewer)) {
            x.last_poll = now;
            s.last_poll.store(now, .monotonic);
            return;
        };
        if (t.watchCount(viewer) >= max_per_viewer) return error.ViewerLimit;
        const i = t.freeWatch() orelse return error.TooManyTraces;
        t.watches[i] = .{ .viewer = viewer, .session = s, .last_poll = now };
        s.last_poll.store(now, .monotonic);
    }

    fn watchCount(t: *const Tracer, viewer: Viewer) usize {
        var n: usize = 0;
        for (t.watches) |w| if (w) |x| if (std.mem.eql(u8, &x.viewer, &viewer)) {
            n += 1;
        };
        return n;
    }

    fn freeWatch(t: *const Tracer) ?usize {
        for (t.watches, 0..) |w, i| if (w == null) return i;
        return null;
    }

    /// Forgets watches not polled for `limits.idle_s`, and those of finished sessions.
    fn expireWatches(t: *Tracer, now: i64) void {
        for (&t.watches) |*w| if (w.*) |x| if (now - x.last_poll > t.limits.idle_s or x.session.finished.load(.acquire)) {
            w.* = null;
        };
    }

    /// Tells a running `s` to stop and forgets its watches; it is freed
    /// by `reap` once its thread has ended, never waited for here. A full
    /// `dying` list (16 sessions stuck at once) falls back to waiting.
    /// Under `mutex`.
    fn retire(t: *Tracer, s: *Session) void {
        for (&t.watches) |*w| if (w.*) |x| if (x.session == s) {
            w.* = null;
        };
        s.stop.store(true, .monotonic);
        for (&t.dying) |*d| if (d.* == null) {
            d.* = s;
            return;
        };
        t.release(s);
    }

    /// Frees the stopped sessions whose thread has ended. Under `mutex`.
    fn reap(t: *Tracer) void {
        for (&t.dying) |*d| if (d.*) |s| if (s.finished.load(.acquire)) {
            t.release(s);
            d.* = null;
        };
    }

    /// Stops `s`, forgets its watches and frees it: only for a finished
    /// session, whose thread has (all but) ended. Under `mutex`.
    fn drop(t: *Tracer, s: *Session) void {
        for (&t.watches) |*w| if (w.*) |x| if (x.session == s) {
            w.* = null;
        };
        s.stop.store(true, .monotonic);
        t.release(s);
    }

    /// Waits for the session's thread (it stops within a round) and frees
    /// it. Called with `mutex` held: the thread never takes it.
    fn release(t: *Tracer, s: *Session) void {
        if (s.future) |*f| f.await(t.io);
        t.gpa.free(s.host);
        t.gpa.destroy(s);
    }

    fn clock(t: *const Tracer) i64 {
        return Io.Clock.awake.now(t.io).toSeconds();
    }

    fn clockNs(t: *const Tracer) u64 {
        return @intCast(@max(Io.Clock.awake.now(t.io).toNanoseconds(), 0));
    }
};

const Reason = enum(u8) { running, idle, max_age, stopped, unresolved, no_socket, failed };

/// How often a session checks whether it should stop.
const session_poll_ms = 250;

/// The probes of every trace of one address family: one `LiveMtrSet` on its
/// own task, which runs while a session is registered. A session registers
/// once it has resolved its host; between rounds the engine adds and removes
/// set members to match, and after each round copies every member's
/// statistics into its session.
///
/// Locking: `mutex` guards `regs`, `running` and `future`; the engine holds
/// it while it copies into sessions (taking each `Session.mutex` inside it),
/// never during a round. Only a session's own thread calls `register` and
/// `unregister`, holding no other lock, so the order is always `mutex`, then
/// a `Session.mutex`. A session unregisters before its thread ends, and
/// `Tracer.release` frees it only after that: the engine never copies into
/// a freed session.
const Engine = struct {
    family: enum { v4, v6 },
    tracer: *Tracer = undefined,
    mutex: Io.Mutex = .init,
    regs: [max_slots]?Reg = @splat(null),
    running: bool = false,
    future: ?Io.Future(void) = null,

    const Reg = struct { session: *Session, serial: u64, member: ?u8 = null };

    fn register(e: *Engine, s: *Session) (error{TooManyTraces} || Io.ConcurrentError)!void {
        const io = s.tracer.io;
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        const slot = for (&e.regs) |*r| {
            if (r.* == null) break r;
        } else return error.TooManyTraces;
        slot.* = .{ .session = s, .serial = s.serial };
        if (e.running) return;
        e.tracer = s.tracer;
        // The last engine task finished (it cleared `running` as its last
        // step under `mutex`): reap it before starting the next.
        if (e.future) |*f| f.await(io);
        e.future = io.concurrent(run, .{e}) catch |err| {
            e.future = null;
            slot.* = null;
            return err;
        };
        e.running = true;
    }

    fn unregister(e: *Engine, s: *Session) void {
        const io = s.tracer.io;
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        for (&e.regs) |*r| if (r.*) |x| if (x.session == s and x.serial == s.serial) {
            r.* = null;
        };
    }

    /// Waits for the engine task, which stops once no session is
    /// registered (`Tracer.deinit`, after every session was released).
    fn wait(e: *Engine, io: Io) void {
        e.mutex.lockUncancelable(io);
        const f = e.future;
        e.future = null;
        e.mutex.unlock(io);
        if (f) |fut| {
            var x = fut;
            x.await(io);
        }
    }

    fn run(e: *Engine) void {
        const io = e.tracer.io;
        const live = e.tracer.gpa.create(traceroute.LiveMtrSet) catch return e.fail(.failed);
        defer e.tracer.gpa.destroy(live);
        live.* = traceroute.LiveMtrSet.open(e.tracer.gpa, switch (e.family) {
            .v4 => .v4,
            .v6 => .v6,
        }, set_options) catch |err| {
            log.info("cannot open the trace socket: {t}", .{err});
            return e.fail(if (err == error.PermissionDenied) .no_socket else .failed);
        };
        defer live.close();
        const unprivileged = live.lt.sock.kind == .dgram;
        while (true) {
            if (!e.sync(&live.set)) return;
            live.round() catch |err| {
                // An aborted round counts for nobody; the next one retries.
                log.info("trace round failed: {t}", .{err});
                io.sleep(.fromSeconds(1), .awake) catch return;
                continue;
            };
            e.mutex.lockUncancelable(io);
            defer e.mutex.unlock(io);
            for (e.regs) |r| if (r) |x| if (x.member) |id| if (live.set.member(id)) |mb|
                x.session.record(&mb.mtr, mb.sharedLastRound(), unprivileged);
        }
    }

    /// Matches the set's members to the registered sessions. False when
    /// none is left: the task then ends (`running` cleared under `mutex`).
    fn sync(e: *Engine, set: *traceroute.MtrSet) bool {
        const io = e.tracer.io;
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        var used: [traceroute.max_set_members]bool = @splat(false);
        var any = false;
        for (&e.regs) |*r| if (r.*) |*x| {
            any = true;
            if (x.member == null) x.member = set.add(x.session.address.?) catch |err| {
                log.info("trace of {s}: {t}", .{ x.session.host, err });
                x.session.failure.store(.failed, .release);
                r.* = null;
                continue;
            };
            used[x.member.?] = true;
        };
        for (used, 0..) |u, id| if (!u) set.remove(@intCast(id));
        if (!any) e.running = false;
        return any;
    }

    /// The socket cannot be opened: every registered session stops with
    /// `reason`, and the task ends.
    fn fail(e: *Engine, reason: Reason) void {
        const io = e.tracer.io;
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        for (&e.regs) |*r| if (r.*) |x| {
            x.session.failure.store(reason, .release);
            r.* = null;
        };
        e.running = false;
    }
};

const Hop = struct {
    stats: traceroute.MtrHop,
    /// The last round's answer came from a probe another trace sent.
    shared: bool = false,
    /// Round-trip times of the last rounds in µs, oldest first; null = lost.
    spark: [spark_len]?u32 = @splat(null),
    spark_n: u8 = 0,

    fn push(h: *Hop, rtt_ns: ?u64) void {
        const v: ?u32 = if (rtt_ns) |ns| @intCast(@min(ns / std.time.ns_per_us, std.math.maxInt(u32))) else null;
        if (h.spark_n == spark_len) {
            std.mem.copyForwards(?u32, h.spark[0 .. spark_len - 1], h.spark[1..]);
            h.spark[spark_len - 1] = v;
        } else {
            h.spark[h.spark_n] = v;
            h.spark_n += 1;
        }
    }
};

/// A PTR target as a name to show, or null when it is not a host name. DNS
/// labels are raw bytes and whoever runs a router's reverse zone chooses them:
/// a line break or an escape sequence must not reach a viewer's "Copy" and,
/// from there, a terminal.
fn hopName(ptr: []const u8) ?[]const u8 {
    // PTR targets come back with or without the root dot.
    const name = std.mem.trimEnd(u8, ptr, ".");
    if (name.len == 0) return null;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return null,
    };
    return name;
}

test "hop name cache: TTL, backoff for failures, freed when expired, bounded" {
    const gpa = testing.allocator;
    const io = testing.io;
    var c: NameCache = .{};
    defer c.deinit(gpa);
    const a = netaddr.parseIp("192.0.2.1").?;
    const b = netaddr.parseIp("2001:db8::1").?;
    const n = netaddr.parseIp("192.0.2.2").?;
    var buf: [64]u8 = undefined;

    try testing.expect(c.get(io, a, 100, &buf) == null); // nothing yet: look it up
    c.put(io, gpa, a, 100, .{ .answer = .{ .name = "gw.example", .ttl_s = 30 } });
    c.put(io, gpa, n, 100, .{ .answer = .{ .name = null, .ttl_s = 7200 } }); // no name: kept too
    try testing.expectEqualStrings("gw.example", c.get(io, a, 159, &buf).?.name.?);
    try testing.expect(c.get(io, a, 160, &buf) == null); // TTL 30 held at the 60 s floor
    try testing.expect(c.get(io, n, 100 + 3599, &buf).?.name == null);
    try testing.expect(c.get(io, n, 100 + 3600, &buf) == null); // at most an hour

    // The same family rules for v6; failures back off 1, 2, 4 ... minutes.
    c.put(io, gpa, b, 100, .failed);
    try testing.expect(c.get(io, b, 159, &buf) != null);
    try testing.expect(c.get(io, b, 160, &buf) == null);
    c.put(io, gpa, b, 160, .failed);
    try testing.expect(c.get(io, b, 279, &buf) != null);
    try testing.expect(c.get(io, b, 280, &buf) == null);
    c.put(io, gpa, b, 280, .{ .answer = .{ .name = "v6.example", .ttl_s = 600 } });
    try testing.expectEqual(0, c.map.get(NameCache.key(b)).?.fails);

    // Expired entries are freed (the allocator would report a leak otherwise).
    c.prune(io, gpa, 800);
    try testing.expectEqual(2, c.map.count()); // a (till 160) freed; b till 880, n till 3700
    c.prune(io, gpa, 100 + 3600);
    try testing.expectEqual(0, c.map.count());

    // Full: a new address is not kept, an expired one makes room.
    for (0..max_cached_names) |i| {
        const ip: netaddr.Ip = .{ .v6 = std.mem.toBytes(std.mem.nativeToBig(u128, i + 1)) };
        c.put(io, gpa, ip, 1000, .{ .answer = .{ .name = "x", .ttl_s = 60 } });
    }
    c.put(io, gpa, a, 1000, .{ .answer = .{ .name = "gw.example", .ttl_s = 60 } });
    try testing.expect(c.get(io, a, 1000, &buf) == null);
    c.put(io, gpa, a, 1060, .{ .answer = .{ .name = "gw.example", .ttl_s = 60 } });
    try testing.expect(c.get(io, a, 1060, &buf) != null);
}

test "hop names: host names only" {
    try testing.expectEqualStrings("gw-1.example_net.org", hopName("gw-1.example_net.org.").?);
    for ([_][]const u8{ "", ".", "a\nb.example", "\x1b[2Jx.example", "\xff\xfe.example", "a b.example", "a\"b.example" }) |bad|
        try testing.expectEqual(@as(?[]const u8, null), hopName(bad));
}

/// The reverse-DNS name of one hop address.
const Name = struct {
    ip: netaddr.Ip,
    state: enum { pending, done } = .pending,
    len: u8 = 0,
    buf: [dns.message.max_name_text_len]u8 = undefined,

    /// The name, or null while pending or when the address has none.
    fn get(n: *const Name) ?[]const u8 {
        return if (n.len == 0) null else n.buf[0..n.len];
    }
};

/// Hop names kept between lookups and shared by every session, keyed by
/// address; the same rules as a target's address (`monitor.zig`): a name
/// is kept for its answer's TTL (within 1 minute and 1 hour), a failed
/// lookup is retried after `monitor.backoffS` of the failures in a row,
/// and an entry past its time is freed by `prune`. Bounded: with
/// `max_cached_names` entries, a new one is not kept.
// zig-libs request: dns — no caching resolver; see monitor.zig resolveAll.
const NameCache = struct {
    mutex: Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,

    const Key = [17]u8; // family, then the address as 16 bytes
    const Entry = struct {
        /// Awake-clock seconds until which this entry stands.
        expires: i64,
        /// Failed lookups in a row (no answer); 0 after an answer.
        fails: u8 = 0,
        /// The name; null when the address has none or the lookup failed.
        name: ?[]u8 = null,
    };
    pub const Hit = struct { name: ?[]const u8 };

    fn key(ip: netaddr.Ip) Key {
        var k: Key = undefined;
        k[0] = if (ip == .v4) 4 else 6;
        k[1..].* = ip.as16();
        return k;
    }

    /// The cached outcome for `ip`, copied into `buf`; null when there is
    /// none or it expired (a lookup is due).
    fn get(c: *NameCache, io: Io, ip: netaddr.Ip, now: i64, buf: []u8) ?Hit {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const e = c.map.get(key(ip)) orelse return null;
        if (now >= e.expires) return null;
        const name = e.name orelse return .{ .name = null };
        const len = @min(name.len, buf.len);
        @memcpy(buf[0..len], name[0..len]);
        return .{ .name = buf[0..len] };
    }

    /// Keeps a lookup's outcome: `name` (null: none) for `ttl_s`, or a
    /// failure (`failed`) for the backoff of the failures so far.
    fn put(c: *NameCache, io: Io, gpa: std.mem.Allocator, ip: netaddr.Ip, now: i64, outcome: union(enum) { answer: struct { name: ?[]const u8, ttl_s: ?i64 }, failed }) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const k = key(ip);
        const prev_fails: u8 = if (c.map.get(k)) |e| e.fails else 0;
        var entry: Entry = switch (outcome) {
            .answer => |a| .{ .expires = now + std.math.clamp(a.ttl_s orelse monitor.default_ttl_s, monitor.min_ttl_s, monitor.max_ttl_s) },
            .failed => .{ .expires = now + monitor.backoffS(prev_fails), .fails = prev_fails +| 1 },
        };
        if (outcome == .answer) if (outcome.answer.name) |n| {
            entry.name = gpa.dupe(u8, n) catch return;
        };
        if (!c.map.contains(k) and c.map.count() >= max_cached_names) {
            c.pruneLocked(gpa, now);
            if (c.map.count() >= max_cached_names) {
                if (entry.name) |n| gpa.free(n);
                return;
            }
        }
        const gop = c.map.getOrPut(gpa, k) catch {
            if (entry.name) |n| gpa.free(n);
            return;
        };
        if (gop.found_existing) if (gop.value_ptr.name) |old| gpa.free(old);
        gop.value_ptr.* = entry;
    }

    fn prune(c: *NameCache, io: Io, gpa: std.mem.Allocator, now: i64) void {
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.pruneLocked(gpa, now);
    }

    fn pruneLocked(c: *NameCache, gpa: std.mem.Allocator, now: i64) void {
        var it = c.map.iterator();
        var gone: [64]Key = undefined;
        while (true) {
            var n: usize = 0;
            it = c.map.iterator();
            while (it.next()) |e| if (now >= e.value_ptr.expires) {
                gone[n] = e.key_ptr.*;
                n += 1;
                if (n == gone.len) break;
            };
            for (gone[0..n]) |k| if (c.map.fetchRemove(k)) |kv| if (kv.value.name) |name| gpa.free(name);
            if (n < gone.len) break;
        }
        // Give the memory back once the cache is empty.
        if (c.map.count() == 0) c.map.clearAndFree(gpa);
    }

    fn deinit(c: *NameCache, gpa: std.mem.Allocator) void {
        var it = c.map.valueIterator();
        while (it.next()) |e| if (e.name) |n| gpa.free(n);
        c.map.deinit(gpa);
    }
};

/// Hop names kept at once: 16 traces of 30 hops with 4 responders each is
/// 1920; more are not cached (looked up again by the next trace).
const max_cached_names = 4096;

const Session = struct {
    tracer: *Tracer,
    serial: u64,
    host: []u8,
    started: i64,
    last_poll: std.atomic.Value(i64),
    stop: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,
    /// Set by the engine when it cannot probe for this session.
    failure: std.atomic.Value(Reason) = .init(.running),

    /// The snapshot the page reads, under `mutex`.
    mutex: Io.Mutex = .init,
    reason: Reason = .running,
    address: ?netaddr.Ip = null,
    unprivileged: bool = false,
    rounds: u64 = 0,
    reached: bool = false,
    hops: [max_hops]Hop = undefined,
    hop_n: usize = 0,
    /// Hop addresses seen so far and their names; entries are only appended.
    names: [max_names]Name = undefined,
    name_n: usize = 0,

    fn run(s: *Session) void {
        const io = s.tracer.io;
        // The names task lives as long as the trace: started here, canceled
        // below, so `Tracer.release` only ever waits for this thread.
        var names: ?Io.Future(void) = if (s.tracer.names) io.concurrent(lookupNames, .{s}) catch null else null;
        defer if (names) |*f| f.cancel(io);
        const reason = s.trace() catch |err| blk: {
            log.info("trace of {s} failed: {t}", .{ s.host, err });
            break :blk Reason.failed;
        };
        s.mutex.lockUncancelable(io);
        s.reason = reason;
        s.mutex.unlock(io);
        s.finished.store(true, .release);
        _ = events.emit(.info, .trace, .system, null, "action=end host={f} reason={t}", .{ events.quote(s.host), reason });
    }

    /// Resolves the host, then watches the engine of its family probe it
    /// until the session ends (the engine fills the snapshot).
    fn trace(s: *Session) !Reason {
        const io = s.tracer.io;
        const cached = if (s.tracer.addresses) |m| m.addressOf(s.host) else null;
        // No address or no answer from DNS: either way, nothing to trace.
        const addr = cached orelse resolve(io, s.tracer.gpa, s.host) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |e| return e,
            else => return .unresolved,
        };
        var dest = addr.toIp();
        s.mutex.lockUncancelable(io);
        s.address = dest;
        s.mutex.unlock(io);
        var engine = &s.tracer.engines[if (dest == .v4) 0 else 1];
        try engine.register(s);
        defer engine.unregister(s); // the engine of the last address
        while (true) {
            if (s.stop.load(.monotonic)) return .stopped;
            // The cycle moved the host to another address (another family
            // after a network change): the trace starts over there.
            if (s.tracer.addresses) |m| if (m.addressOf(s.host)) |a| if (!a.toIp().eql(dest)) {
                engine.unregister(s); // no record from it after this
                dest = a.toIp();
                s.restartAt(dest);
                engine = &s.tracer.engines[if (dest == .v4) 0 else 1];
                try engine.register(s);
                log.info("trace of {s} moved to {f}", .{ s.host, dest });
            };
            const failure = s.failure.load(.acquire);
            if (failure != .running) return failure;
            const now = s.tracer.clock();
            const limits = s.tracer.limits;
            if (now - s.last_poll.load(.monotonic) > limits.idle_s) return .idle;
            if (now - s.started > limits.max_age_s) return .max_age;
            io.sleep(.fromMilliseconds(session_poll_ms), .awake) catch return .stopped;
        }
    }

    /// A new destination: the path and its statistics start over.
    fn restartAt(s: *Session, dest: netaddr.Ip) void {
        const io = s.tracer.io;
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.address = dest;
        s.hop_n = 0;
        s.rounds = 0;
        s.reached = false;
    }

    /// The engine's copy of this session's member after a round.
    fn record(s: *Session, m: *const traceroute.Mtr, shared: []const bool, unprivileged: bool) void {
        const io = s.tracer.io;
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.unprivileged = unprivileged;
        const hops = m.hops();
        const last = m.lastRound();
        const n = @min(hops.len, max_hops);
        for (0..n) |i| {
            // A hop the engine reset (the path changed) starts its line over.
            if (i >= s.hop_n or hops[i].sent < s.hops[i].stats.sent) s.hops[i] = .{ .stats = hops[i] };
            s.hops[i].stats = hops[i];
            s.hops[i].shared = i < shared.len and shared[i];
            s.hops[i].push(last[i].rtt_ns);
            if (hops[i].address) |a| s.noteAddress(a);
            for (hops[i].addressList()) |a| s.noteAddress(a);
        }
        s.hop_n = n;
        s.rounds = m.rounds;
        s.reached = m.reached();
    }

    /// Queues `a` for a name lookup unless it is known. Under `mutex`.
    fn noteAddress(s: *Session, a: netaddr.Ip) void {
        for (s.names[0..s.name_n]) |*n| if (n.ip.eql(a)) return;
        if (s.name_n == max_names) return;
        s.names[s.name_n] = .{ .ip = a };
        s.name_n += 1;
    }

    /// The name of `a`, if looked up and found. Under `mutex`.
    fn nameOf(s: *const Session, a: netaddr.Ip) ?[]const u8 {
        for (s.names[0..s.name_n]) |*n| if (n.ip.eql(a)) return n.get();
        return null;
    }

    /// Records the name (null: none) of queued address `i`.
    fn setName(s: *Session, i: usize, name: ?[]const u8) void {
        const io = s.tracer.io;
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const n = &s.names[i];
        n.state = .done;
        const v = name orelse return;
        const len = @min(v.len, n.buf.len);
        @memcpy(n.buf[0..len], v[0..len]);
        n.len = @intCast(len);
    }

    /// The names task: looks up queued addresses one at a time until the
    /// trace cancels it.
    fn lookupNames(s: *Session) void {
        const io = s.tracer.io;
        var resolver = dns.Resolver.init(io, s.tracer.gpa, .{ .timeout_ms = name_timeout_ms, .attempts = 1 });
        defer resolver.deinit();
        while (true) {
            const next: ?struct { usize, netaddr.Ip } = blk: {
                s.mutex.lockUncancelable(io);
                defer s.mutex.unlock(io);
                for (s.names[0..s.name_n], 0..) |*n, i| if (n.state == .pending) break :blk .{ i, n.ip };
                break :blk null;
            };
            const i, const ip = next orelse {
                io.sleep(.fromMilliseconds(name_poll_ms), .awake) catch return;
                continue;
            };
            const cache = &s.tracer.name_cache;
            var buf: [dns.message.max_name_text_len]u8 = undefined;
            if (cache.get(io, ip, s.tracer.clock(), &buf)) |hit| {
                s.setName(i, hit.name);
                continue;
            }
            // A failure (timeout, no server) leaves the address nameless,
            // the plain address is what mtr shows too; the cache tries it
            // again after a backoff.
            const found: ?[]const []const u8 = resolver.reverse(ip) catch |err| switch (err) {
                error.Canceled => return,
                else => null,
            };
            defer if (found) |f| resolver.freeNames(f);
            const name: ?[]const u8 = if (found) |f| (if (f.len > 0) hopName(f[0]) else null) else null;
            // zig-libs request: dns — `reverse` returns no TTL, so a PTR
            // answer is kept `monitor.default_ttl_s` (as an answer without
            // a TTL is) until a TTL-carrying reverse lookup exists.
            cache.put(io, s.tracer.gpa, ip, s.tracer.clock(), if (found == null) .failed else .{ .answer = .{ .name = name, .ttl_s = null } });
            s.setName(i, name);
        }
    }

    fn writeJson(s: *Session, w: *Io.Writer, now: i64) Io.Writer.Error!void {
        s.mutex.lockUncancelable(s.tracer.io);
        defer s.mutex.unlock(s.tracer.io);
        var j: std.json.Stringify = .{ .writer = w };
        try j.beginObject();
        try j.objectField("state");
        try j.write(if (s.reason == .running) "running" else "stopped");
        try j.objectField("reason");
        try j.write(@tagName(s.reason));
        try j.objectField("address");
        if (s.address) |a| try writeIp(&j, a) else try j.write(null);
        try j.objectField("unprivileged");
        try j.write(s.unprivileged);
        try j.objectField("rounds");
        try j.write(s.rounds);
        try j.objectField("reached");
        try j.write(s.reached);
        try j.objectField("age");
        try j.write(now - s.started);
        try j.objectField("max_age");
        try j.write(s.tracer.limits.max_age_s);
        try j.objectField("idle");
        try j.write(s.tracer.limits.idle_s);
        try j.objectField("hops");
        try j.beginArray();
        for (s.hops[0..s.hop_n]) |*h| {
            const st = &h.stats;
            try j.beginObject();
            try j.objectField("ttl");
            try j.write(st.ttl);
            try j.objectField("hosts");
            try j.beginArray();
            // The most recent responder first.
            if (st.address) |a| try writeIp(&j, a);
            for (st.addressList()) |a| if (st.address == null or !a.eql(st.address.?)) try writeIp(&j, a);
            try j.endArray();
            // names[k] is the reverse-DNS name of hosts[k], null if none (yet).
            try j.objectField("names");
            try j.beginArray();
            if (st.address) |a| try j.write(s.nameOf(a));
            for (st.addressList()) |a| if (st.address == null or !a.eql(st.address.?)) try j.write(s.nameOf(a));
            try j.endArray();
            try j.objectField("sent");
            try j.write(st.sent);
            try j.objectField("recv");
            try j.write(st.received);
            try j.objectField("loss");
            try j.write(st.lossPermille());
            try j.objectField("last");
            try writeUs(&j, st.last_ns);
            try j.objectField("avg");
            try writeUs(&j, st.avgNs());
            try j.objectField("best");
            try writeUs(&j, st.best_ns);
            try j.objectField("worst");
            try writeUs(&j, st.worst_ns);
            try j.objectField("jitter");
            try writeUs(&j, st.jitterNs());
            try j.objectField("code");
            try j.write(st.unreachable_code);
            try j.objectField("shared");
            try j.write(h.shared);
            try j.objectField("spark");
            try j.write(h.spark[0..h.spark_n]);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
};

fn writeIp(j: *std.json.Stringify, a: netaddr.Ip) Io.Writer.Error!void {
    var buf: [netaddr.max_ip_text_len]u8 = undefined;
    try j.write(netaddr.formatIp(a, &buf));
}

/// Nanoseconds as whole microseconds; null stays null.
fn writeUs(j: *std.json.Stringify, ns: ?u64) Io.Writer.Error!void {
    if (ns) |v| try j.write(v / std.time.ns_per_us) else try j.write(null);
}

// ----- tests ----------------------------------------------------------------------

const testing = std.testing;

test "sparkline keeps the last spark_len rounds, oldest first" {
    var h: Hop = .{ .stats = .{ .ttl = 1 } };
    for (0..spark_len + 5) |i| h.push(if (i % 7 == 0) null else @as(u64, i) * std.time.ns_per_us);
    try testing.expectEqual(@as(u8, spark_len), h.spark_n);
    try testing.expectEqual(@as(?u32, 5), h.spark[0]);
    try testing.expectEqual(@as(?u32, spark_len + 4), h.spark[spark_len - 1]);
    try testing.expectEqual(@as(?u32, null), h.spark[2]); // round 7 (i % 7 == 0): lost
}

const viewer_a = viewerOf(.{ .v4 = .{ 192, 0, 2, 1 } });
const viewer_b = viewerOf(.{ .v4 = .{ 192, 0, 2, 2 } });

test "a disabled tracer starts nothing" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io, .max_sessions = 0 };
    defer t.deinit();
    try testing.expectError(error.TraceDisabled, t.start("127.0.0.1", viewer_a));
    try testing.expectEqual(@as(?[]u8, null), try t.json("127.0.0.1", viewer_a, testing.allocator));
}

test "viewer: IPv6 by /64, IPv4 by address" {
    const a = netaddr.parseIp("2001:db8:1:2::1").?;
    const b = netaddr.parseIp("2001:db8:1:2:ffff::9").?;
    const c = netaddr.parseIp("2001:db8:1:3::1").?;
    try testing.expectEqual(viewerOf(a), viewerOf(b));
    try testing.expect(!std.mem.eql(u8, &viewerOf(a), &viewerOf(c)));
    try testing.expect(!std.mem.eql(u8, &viewer_a, &viewer_b));
    // IPv4-mapped is the same viewer as plain IPv4, not cut to a /64.
    try testing.expectEqual(viewer_a, viewerOf(netaddr.parseIp("::ffff:192.0.2.1").?));
}

/// A session in the table that runs no thread (tests of the bookkeeping).
fn idleSession(t: *Tracer, host: []const u8, now: i64) !*Session {
    const s = try t.gpa.create(Session);
    s.* = .{ .tracer = t, .serial = 0, .host = try t.gpa.dupe(u8, host), .started = now, .last_poll = .init(now) };
    for (&t.slots) |*slot| if (slot.* == null) {
        slot.* = s;
        return s;
    };
    unreachable;
}

test "a viewer watches at most max_per_viewer traces; watches expire" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    defer t.deinit();
    const s1 = try idleSession(&t, "h1", 0);
    const s2 = try idleSession(&t, "h2", 0);
    const s3 = try idleSession(&t, "h3", 0);
    try t.watch(viewer_a, s1, 0);
    try t.watch(viewer_a, s2, 0);
    try t.watch(viewer_a, s1, 5); // a refresh, not a third watch
    try testing.expectError(error.ViewerLimit, t.watch(viewer_a, s3, 5));
    try t.watch(viewer_b, s3, 5); // another viewer is not limited by a's
    try testing.expectEqual(@as(i64, 5), s1.last_poll.load(.monotonic));
    t.expireWatches(5 + t.limits.idle_s + 1);
    try testing.expectEqual(@as(usize, 0), t.watchCount(viewer_a));
    try t.watch(viewer_a, s3, 40);
}

test "stop: the session ends only when its last viewer leaves" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    defer t.deinit();
    const now = t.clock();
    const s = try idleSession(&t, "h", now);
    try t.watch(viewer_a, s, now);
    try t.watch(viewer_b, s, now);
    t.stop("h", viewer_a);
    try testing.expect(t.running("h") == s);
    try testing.expectEqual(@as(usize, 0), t.watchCount(viewer_a));
    t.stop("h", viewer_b);
    try testing.expect(t.session("h") == null);
}

test "stop never waits for a session stuck in its thread; reap frees it once it ended" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    defer t.deinit();
    const now = t.clock();
    // A session whose thread has not finished (as one blocked in DNS).
    const s = try idleSession(&t, "stuck", now);
    try t.watch(viewer_a, s, now);
    t.stop("stuck", viewer_a); // must return at once
    try testing.expect(t.session("stuck") == null);
    try testing.expect(s.stop.load(.monotonic));
    try testing.expectEqual(@as(?*Session, s), t.dying[0]);
    t.reap(); // still running: kept
    try testing.expectEqual(@as(?*Session, s), t.dying[0]);
    s.finished.store(true, .release);
    t.reap(); // ended: freed (the testing allocator would report it otherwise)
    try testing.expectEqual(@as(?*Session, null), t.dying[0]);
}

test "a refused viewer does not keep a session alive" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    defer t.deinit();
    const s1 = try idleSession(&t, "h1", 0);
    const s2 = try idleSession(&t, "h2", 0);
    const s3 = try idleSession(&t, "h3", 0);
    try t.watch(viewer_a, s1, 0);
    try t.watch(viewer_a, s2, 0);
    try testing.expectError(error.ViewerLimit, t.watch(viewer_a, s3, 50));
    try testing.expectEqual(@as(i64, 0), s3.last_poll.load(.monotonic));
}

test "at most max_starts_per_min new sessions a minute" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    defer t.deinit();
    const ns = std.time.ns_per_s;
    // Ten viewers start one each: the eleventh waits for the bucket to refill
    // (one start every 6 s).
    for (0..max_starts_per_min) |i| try testing.expect(t.allowStart(viewerOf(.{ .v4 = .{ 198, 51, 100, @intCast(i) } }), 1000 * ns));
    const late = viewerOf(.{ .v4 = .{ 198, 51, 100, 200 } });
    try testing.expect(!t.allowStart(late, 1000 * ns));
    try testing.expect(t.allowStart(late, 1006 * ns));
    // Through `start`, at the real clock.
    var u: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    defer u.deinit();
    for (0..max_starts_per_min) |i| _ = u.allowStart(viewerOf(.{ .v4 = .{ 198, 51, 100, @intCast(i) } }), u.clockNs());
    try testing.expectError(error.RateLimited, u.start("127.0.0.1", viewer_a));
    try testing.expectEqual(@as(usize, 0), u.watchCount(viewer_a));
}

test "one viewer cannot use up the starts of everybody else" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    defer t.deinit();
    const ns = std.time.ns_per_s;
    const other = viewerOf(.{ .v4 = .{ 192, 0, 2, 99 } });
    for (0..max_viewer_starts_per_min) |_| try testing.expect(t.allowStart(viewer_a, 5000 * ns));
    try testing.expect(!t.allowStart(viewer_a, 5000 * ns));
    // Its refusals took nothing from the others: 6 more fit in the total.
    try testing.expect(t.allowStart(other, 5000 * ns));
    for (1..max_starts_per_min - max_viewer_starts_per_min) |i| try testing.expect(t.allowStart(viewerOf(.{ .v4 = .{ 198, 51, 100, @intCast(i) } }), 5000 * ns));
    try testing.expect(!t.allowStart(viewerOf(.{ .v4 = .{ 192, 0, 2, 98 } }), 5000 * ns)); // the total is used up
    // A viewer's own start comes back after 15 s (4 a minute).
    try testing.expect(t.allowStart(viewer_a, 5015 * ns));
}

test "snapshot JSON: hops, responders first, microseconds" {
    var t: Tracer = .{ .gpa = testing.allocator, .io = testing.io };
    var s: Session = .{ .tracer = &t, .serial = 0, .host = @constCast("x"), .started = 100, .last_poll = .init(100) };
    s.address = .{ .v4 = .{ 192, 0, 2, 1 } };
    s.rounds = 2;
    var st: traceroute.MtrHop = .{ .ttl = 1, .sent = 2, .received = 1, .last_ns = 1_500_000, .best_ns = 1_500_000, .worst_ns = 1_500_000, .sum_ns = 1_500_000 };
    st.address = .{ .v4 = .{ 10, 0, 0, 2 } };
    st.addresses[0] = .{ .v4 = .{ 10, 0, 0, 1 } };
    st.addresses[1] = .{ .v4 = .{ 10, 0, 0, 2 } };
    st.address_count = 2;
    s.hops[0] = .{ .stats = st };
    s.hops[0].push(null);
    s.hops[0].push(1_500_000);
    s.hop_n = 1;
    s.noteAddress(.{ .v4 = .{ 10, 0, 0, 2 } });
    s.noteAddress(.{ .v4 = .{ 10, 0, 0, 1 } });
    s.noteAddress(.{ .v4 = .{ 10, 0, 0, 2 } }); // known: not queued twice
    try testing.expectEqual(@as(usize, 2), s.name_n);
    s.names[0].state = .done;
    @memcpy(s.names[0].buf[0..10], "gw.example");
    s.names[0].len = 10;
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try s.writeJson(&out.writer, 130);
    try testing.expectEqualStrings(
        \\{"state":"running","reason":"running","address":"192.0.2.1","unprivileged":false,"rounds":2,"reached":false,"age":30,"max_age":3600,"idle":600,"hops":[{"ttl":1,"hosts":["10.0.0.2","10.0.0.1"],"names":["gw.example",null],"sent":2,"recv":1,"loss":500,"last":1500,"avg":1500,"best":1500,"worst":1500,"jitter":null,"code":null,"shared":false,"spark":[null,1500]}]}
    , out.written());
}
