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
//! (`Tracer.names = false`, `--trace-names off`, turns it off).
//!
//! Locking: `Tracer.mutex` guards the session table; each `Session.mutex`
//! guards that session's snapshot, which the engine of its family fills.

const std = @import("std");
const Io = std.Io;
const traceroute = @import("traceroute");
const netaddr = @import("netaddr");
const dns = @import("dns");
const resolve = @import("monitor.zig").resolve;
const Monitor = @import("monitor.zig").Monitor;
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
/// Viewer-to-session watches kept at once (a full table refuses new viewers).
const max_watches = 256;

/// Who watches a trace: the client address, IPv4 as IPv4-mapped, IPv6 cut
/// to its /64, the prefix one subscriber gets, so one subscriber cannot
/// pose as many viewers.
pub const Viewer = [16]u8;

pub fn viewerOf(ip: netaddr.Ip) Viewer {
    var v = ip.as16();
    if (ip.unmap() == .v6) @memset(v[8..], 0);
    return v;
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
    /// Start times of the last `max_starts_per_min` sessions (a ring).
    starts: [max_starts_per_min]?i64 = @splat(null),
    start_i: usize = 0,

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
        if (t.rateLimited(now)) return error.RateLimited;

        const s = try t.gpa.create(Session);
        errdefer t.gpa.destroy(s);
        t.serial += 1;
        s.* = .{ .tracer = t, .serial = t.serial, .host = try t.gpa.dupe(u8, host), .started = now, .last_poll = .init(now) };
        errdefer t.gpa.free(s.host);
        s.future = try t.io.concurrent(Session.run, .{s});
        t.slots[slot] = s;
        t.noteStart(now);
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

    /// Whether `max_starts_per_min` sessions started in the last minute.
    fn rateLimited(t: *const Tracer, now: i64) bool {
        const oldest = t.starts[t.start_i] orelse return false;
        return now - oldest < 60;
    }

    fn noteStart(t: *Tracer, now: i64) void {
        t.starts[t.start_i] = now;
        t.start_i = (t.start_i + 1) % max_starts_per_min;
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
        const dest = addr.toIp();
        s.mutex.lockUncancelable(io);
        s.address = dest;
        s.mutex.unlock(io);
        const engine = &s.tracer.engines[if (dest == .v4) 0 else 1];
        try engine.register(s);
        defer engine.unregister(s);
        while (true) {
            if (s.stop.load(.monotonic)) return .stopped;
            const failure = s.failure.load(.acquire);
            if (failure != .running) return failure;
            const now = s.tracer.clock();
            const limits = s.tracer.limits;
            if (now - s.last_poll.load(.monotonic) > limits.idle_s) return .idle;
            if (now - s.started > limits.max_age_s) return .max_age;
            io.sleep(.fromMilliseconds(session_poll_ms), .awake) catch return .stopped;
        }
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
            // Any failure (timeout, no server) leaves the address nameless;
            // it is not retried, the plain address is what mtr shows too.
            const found: ?[]const []const u8 = resolver.reverse(ip) catch |err| switch (err) {
                error.Canceled => return,
                else => null,
            };
            defer if (found) |f| resolver.freeNames(f);
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            const n = &s.names[i];
            n.state = .done;
            if (found) |f| if (f.len > 0) {
                // PTR targets come back with or without the root dot.
                const name = std.mem.trimEnd(u8, f[0], ".");
                const len = @min(name.len, n.buf.len);
                @memcpy(n.buf[0..len], name[0..len]);
                n.len = @intCast(len);
            };
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
    // A fresh tracer, at any clock value (the awake clock may be small).
    for ([_]i64{ 0, 5, 1 << 40 }) |now| try testing.expect(!t.rateLimited(now));
    for (0..max_starts_per_min) |k| t.noteStart(1000 + @as(i64, @intCast(k)));
    try testing.expect(t.rateLimited(1059));
    try testing.expect(!t.rateLimited(1060)); // the oldest is a minute old
    t.noteStart(1060);
    try testing.expect(t.rateLimited(1060)); // the oldest is now 1001
    try testing.expect(!t.rateLimited(1061));
    const now = t.clock();
    t.starts = @splat(now - 59);
    try testing.expectError(error.RateLimited, t.start("127.0.0.1", viewer_a));
    try testing.expectEqual(@as(usize, 0), t.watchCount(viewer_a));
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
