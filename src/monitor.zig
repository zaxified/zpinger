//! The monitor: a list of targets, one probing cycle per minute, and the last
//! 24 hours of results per target.
//!
//! Every cycle sends a few echo requests to each active target through one
//! zig-libs `icmp.Pinger` (so global pacing and in-flight limits apply across all
//! targets) and stores one `Sample` per target: probes sent, replies received,
//! the median round-trip time and the jitter.
//!
//! Locking: `mutex` guards `targets` and everything inside them. Probing runs
//! without the lock, on a copy of the target list, so the web UI never waits
//! for a cycle to finish.

const std = @import("std");
const Io = std.Io;
const icmp = @import("icmp");
const dns = @import("dns");
const gzip = @import("http").gzip;
const netaddr = @import("netaddr");
const filestore = @import("filestore");
const events = @import("events.zig");
const demo = @import("demo.zig");

const log = std.log.scoped(.monitor);

/// Samples kept per target: 24 hours of one-minute cycles.
pub const history_len = 24 * 60;
/// Echo requests per target per cycle.
pub const probes_per_cycle = 5;
/// An acknowledgement clears itself after this many cycles in a row that
/// were not DOWN, so the next outage is reported again.
pub const ack_clear_after = 5;

/// One cycle of one target. `t == 0` marks an empty slot (paused, not yet
/// probed, or the daemon was not running).
pub const Sample = struct {
    /// Unix time (seconds) of the cycle start.
    t: i64 = 0,
    sent: u8 = 0,
    recv: u8 = 0,
    /// Median round-trip time of the replies, microseconds.
    rtt_us: u32 = 0,
    /// Mean difference between consecutive replies' round-trip times,
    /// microseconds; 0 with fewer than two replies.
    jitter_us: u32 = 0,
};

pub const Status = enum {
    /// No sample yet.
    pending,
    /// Every probe answered.
    up,
    /// Some probes lost.
    degraded,
    /// Every probe lost (or the name did not resolve).
    down,
    paused,
};

pub const Target = struct {
    id: u32,
    name: []u8,
    host: []u8,
    /// Lowercase, unique, at most `max_tags`; the page filters by them.
    tags: [][]u8 = &.{},
    paused: bool = false,
    acked: bool = false,
    /// Consecutive cycles that were not DOWN while acknowledged.
    ok_streak: u8 = 0,
    /// Why the last cycle could not probe (static string), if it could not.
    last_error: ?[]const u8 = null,
    /// The address probed for a host name, kept between cycles and looked
    /// up again when its DNS answer expires (see `resolveAll`).
    addr: ?icmp.Addr = null,
    /// When `addr` is due for a lookup (unix s); 0 = at the next cycle.
    addr_expires: i64 = 0,
    /// When DNS last gave `addr` (unix s).
    addr_confirmed: i64 = 0,
    /// The name's DNS state, for the page and the transition events.
    dns: DnsState = .ok,
    /// Why the last lookup failed while the old `addr` is still probed.
    dns_error: ?[]const u8 = null,
    /// Sample-data scenario for `Monitor.demo`.
    scenario: ?demo.Scenario = null,
    last: Sample = .{},
    /// Ring buffer indexed by cycle number, see `slot()`.
    history: [history_len]Sample = @splat(.{}),

    pub fn status(t: *const Target) Status {
        if (t.paused) return .paused;
        if (t.last.t == 0) return .pending;
        if (t.last.recv == 0) return .down;
        if (t.last.recv < t.last.sent) return .degraded;
        return .up;
    }
};

pub const DnsState = enum {
    ok,
    /// The lookup failed (no answer from DNS); the last address is probed.
    stale,
    /// No address: the name does not exist, or DNS failed with none kept.
    failed,
};

pub const Error = error{ InvalidName, InvalidHost, InvalidTags, InvalidScenario, TooManyTargets, UnknownTarget, NotDown };

/// Identifies one version of the web state; the HTTP layer turns it into
/// an ETag, so a viewer polling between cycles gets `304 Not Modified`.
pub const StateTag = struct {
    version: u64,
    /// Start (unix seconds) of the newest cycle in the series.
    end: i64,
};

/// Upper bound on targets: this is a small demo, not a monitoring system.
pub const max_targets = 64;
/// Tags per target, and bytes per tag.
pub const max_tags = 8;
pub const max_tag_len = 32;

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    targets: std.ArrayList(*Target) = .empty,
    next_id: u32 = 1,
    cycle_s: i64 = 60,
    /// How long the last address of a name is probed while DNS does not
    /// answer (RFC 8767 "serve stale"); 0 = never (`--dns-stale`).
    dns_stale_s: i64 = 24 * 3600,
    /// Target list (JSON). Rewritten on every change unless `read_only`.
    config_path: []const u8,
    /// History snapshot (JSON), rewritten after every cycle; null = keep
    /// history in memory only.
    history_path: ?[]const u8 = null,
    read_only: bool = false,
    /// Public demo: every full hour, history older than the last hour of
    /// real probing is replaced with sample data (see demo.zig).
    demo: bool = false,
    /// Start (unix s) of the real data; older samples are sample data. 0 until
    /// the first fill.
    demo_from: i64 = 0,
    /// The first cycle of this run, and the hour of the last fill.
    demo_since: i64 = 0,
    demo_hour: i64 = 0,
    /// Bumped on every change the web page would show; with the cycle start
    /// it identifies one `stateJson` result (see `StateTag`).
    version: u64 = 0,
    /// The last `state` result, shared by every viewer (holds one reference).
    snapshot: ?*Snapshot = null,
    /// Files serialized under `mutex` but not written yet: `flushSaves`
    /// writes them after `mutex` is released, so a slow disk (fsync) never
    /// holds up the page or the probing loop.
    pending_config: ?[]u8 = null,
    pending_history: ?[]u8 = null,
    /// Serializes `flushSaves`: files are written one at a time, each the
    /// newest serialization when its turn came, so an older one never lands
    /// over a newer one.
    save_mutex: Io.Mutex = .init,
    /// For `health()`, read without the lock: when `loop` started, when the
    /// last cycle finished (0: none yet), and whether its probing worked.
    started_at: std.atomic.Value(i64) = .init(0),
    cycle_done_at: std.atomic.Value(i64) = .init(0),
    probing_ok: std.atomic.Value(bool) = .init(true),

    pub fn deinit(m: *Monitor) void {
        for (m.targets.items) |t| m.freeTarget(t);
        m.targets.deinit(m.gpa);
        if (m.snapshot) |snap| snap.release();
        if (m.pending_config) |c| m.gpa.free(c);
        if (m.pending_history) |h| m.gpa.free(h);
    }

    fn freeTarget(m: *Monitor, t: *Target) void {
        m.gpa.free(t.name);
        m.gpa.free(t.host);
        freeTags(m.gpa, t.tags);
        m.gpa.destroy(t);
    }

    fn slot(m: *const Monitor, t: i64) usize {
        return @intCast(@mod(@divFloor(t, m.cycle_s), history_len));
    }

    /// A copy of target `id`'s host (into `buf`), or null if there is none.
    pub fn hostOf(m: *Monitor, id: u32, buf: []u8) ?[]const u8 {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const host = m.targets.items[m.find(id) orelse return null].host;
        if (host.len > buf.len) return null;
        @memcpy(buf[0..host.len], host);
        return buf[0..host.len];
    }

    /// The address the cycle probes for `host`, if a target has one: a live
    /// trace of the target then follows the same address.
    /// Not one older than the cycle would probe (a target paused for days
    /// keeps its last address): a lookup then.
    pub fn addressOf(m: *Monitor, host: []const u8) ?icmp.Addr {
        const now = Io.Clock.real.now(m.io).toSeconds();
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (m.targets.items) |t| if (std.mem.eql(u8, t.host, host)) if (t.addr) |a| {
            if (now < t.addr_expires or now - t.addr_confirmed <= m.dns_stale_s) return a;
        };
        return null;
    }

    fn find(m: *Monitor, id: u32) ?usize {
        for (m.targets.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    // ----- target management (caller holds no lock) -------------------------

    pub fn add(m: *Monitor, name: []const u8, host: []const u8, tags: []const []const u8) (Error || error{OutOfMemory})!u32 {
        try validateName(name);
        try validateHost(host);
        try validateTags(tags);
        defer m.flushSaves(); // after the unlock below
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const id = try m.addLocked(m.next_id, name, host, tags);
        m.version += 1;
        m.saveConfigLocked();
        return id;
    }

    /// `tags` must have passed `validateTags`.
    fn addLocked(m: *Monitor, id: u32, name: []const u8, host: []const u8, tags: []const []const u8) (Error || error{OutOfMemory})!u32 {
        if (m.targets.items.len >= max_targets) return error.TooManyTargets;
        const t = try m.gpa.create(Target);
        errdefer m.gpa.destroy(t);
        const name_copy = try m.gpa.dupe(u8, name);
        errdefer m.gpa.free(name_copy);
        const host_copy = try m.gpa.dupe(u8, host);
        errdefer m.gpa.free(host_copy);
        const tags_copy = try dupeTags(m.gpa, tags);
        errdefer freeTags(m.gpa, tags_copy);
        t.* = .{ .id = id, .name = name_copy, .host = host_copy, .tags = tags_copy };
        try m.targets.append(m.gpa, t);
        m.next_id = @max(m.next_id, id +| 1);
        return id;
    }

    pub fn remove(m: *Monitor, id: u32) Error!void {
        defer m.flushSaves(); // after the unlock below
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const i = m.find(id) orelse return error.UnknownTarget;
        m.freeTarget(m.targets.orderedRemove(i));
        m.version += 1;
        m.saveConfigLocked();
    }

    /// Replaces the target's tags.
    pub fn setTags(m: *Monitor, id: u32, tags: []const []const u8) (Error || error{OutOfMemory})!void {
        try validateTags(tags);
        const copy = try dupeTags(m.gpa, tags);
        defer m.flushSaves(); // after the unlock below
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const t = m.targets.items[
            m.find(id) orelse {
                freeTags(m.gpa, copy);
                return error.UnknownTarget;
            }
        ];
        freeTags(m.gpa, t.tags);
        t.tags = copy;
        m.version += 1;
        m.saveConfigLocked();
    }

    /// Renames the target, moves it to another host and/or replaces its tags
    /// (null: keep), all or nothing. A new host keeps the history but not the
    /// current status: the target is PENDING until the next cycle, and an
    /// acknowledgement is dropped (it was for the old host).
    pub fn edit(m: *Monitor, id: u32, name: ?[]const u8, host: ?[]const u8, tags: ?[]const []const u8) (Error || error{OutOfMemory})!void {
        if (name) |n| try validateName(n);
        if (host) |h| try validateHost(h);
        if (tags) |t| try validateTags(t);
        const tags_copy = if (tags) |t| try dupeTags(m.gpa, t) else null;
        errdefer if (tags_copy) |t| freeTags(m.gpa, t);
        const name_copy = if (name) |n| try m.gpa.dupe(u8, n) else null;
        errdefer if (name_copy) |n| m.gpa.free(n);
        const host_copy = if (host) |h| try m.gpa.dupe(u8, h) else null;
        errdefer if (host_copy) |h| m.gpa.free(h);
        defer m.flushSaves(); // after the unlock below
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const t = m.targets.items[m.find(id) orelse return error.UnknownTarget];
        if (name_copy) |n| {
            m.gpa.free(t.name);
            t.name = n;
        }
        if (tags_copy) |c| {
            freeTags(m.gpa, t.tags);
            t.tags = c;
        }
        if (host_copy) |h| {
            if (std.mem.eql(u8, h, t.host)) {
                m.gpa.free(h);
            } else {
                m.gpa.free(t.host);
                t.host = h;
                t.last = .{};
                t.last_error = null;
                t.addr = null;
                t.addr_expires = 0;
                t.addr_confirmed = 0;
                t.dns = .ok;
                t.dns_error = null;
                t.acked = false;
                t.ok_streak = 0;
            }
        }
        m.version += 1;
        m.saveConfigLocked();
    }

    pub const Action = enum { pause, resume_, ack, unack };

    pub fn apply(m: *Monitor, id: u32, action: Action) Error!void {
        defer m.flushSaves(); // after the unlock below
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const t = m.targets.items[m.find(id) orelse return error.UnknownTarget];
        switch (action) {
            .pause => t.paused = true,
            .resume_ => {
                t.paused = false;
                // The last sample predates the pause; do not show it as now.
                t.last = .{};
            },
            // Like a Nagios acknowledgement: only a problem can be acknowledged.
            .ack => {
                if (t.status() != .down) return error.NotDown;
                t.acked = true;
                t.ok_streak = 0;
            },
            .unack => t.acked = false,
        }
        m.version += 1;
        m.saveConfigLocked();
    }

    // ----- probing ------------------------------------------------------------

    /// Probe forever, one cycle per `cycle_s`, aligned to the wall clock.
    pub fn loop(m: *Monitor) Io.Cancelable!void {
        m.started_at.store(Io.Clock.real.now(m.io).toSeconds(), .monotonic);
        while (true) {
            const now = Io.Clock.real.now(m.io).toSeconds();
            const start = now - @mod(now, m.cycle_s);
            m.runCycle(start);
            const after = Io.Clock.real.now(m.io).toSeconds();
            m.cycle_done_at.store(after, .monotonic);
            // Clamped both ways: a wall clock stepped back during the cycle
            // must not put probing to sleep for that long.
            try m.io.sleep(.fromSeconds(std.math.clamp(start + m.cycle_s - after, 1, m.cycle_s)), .awake);
        }
    }

    pub const Health = struct { ok: bool, probing_ok: bool, last_cycle: i64 };

    /// Healthy while cycles keep finishing (at most `3 * cycle_s` apart,
    /// counted from the start before the first one) and the last one could
    /// open its ICMP socket. Unreachable targets do not make it unhealthy.
    pub fn health(m: *Monitor, now: i64) Health {
        const done = m.cycle_done_at.load(.monotonic);
        const since = if (done == 0) m.started_at.load(.monotonic) else done;
        const probing_ok = m.probing_ok.load(.monotonic);
        return .{ .ok = probing_ok and now - since <= 3 * m.cycle_s, .probing_ok = probing_ok, .last_cycle = done };
    }

    /// One probing cycle. `t` is the cycle's start (unix seconds).
    pub fn runCycle(m: *Monitor, t: i64) void {
        defer m.flushSaves(); // after every unlock below
        var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // 1. Snapshot the active targets, so probing runs without the lock.
        const jobs = blk: {
            m.mutex.lockUncancelable(m.io);
            defer m.mutex.unlock(m.io);
            var list: std.ArrayList(Job) = .empty;
            for (m.targets.items) |target| {
                if (target.paused) continue;
                const host = arena.dupe(u8, target.host) catch return;
                list.append(arena, .{
                    .id = target.id,
                    .host = host,
                    .cached = target.addr,
                    .confirmed = target.addr_confirmed,
                    .due = t >= target.addr_expires,
                    .previous_error = target.last_error,
                }) catch return;
            }
            break :blk list.items;
        };
        if (jobs.len == 0) {
            if (m.demo) {
                m.mutex.lockUncancelable(m.io);
                defer m.mutex.unlock(m.io);
                m.demoFillLocked(t);
                m.version += 1;
            }
            return;
        }

        // 2. Resolve the names whose answer expired (numeric addresses skip DNS).
        resolveAll(m.io, m.gpa, jobs, .{ .now = t, .stale_s = m.dns_stale_s });

        // 3. Ping every resolved target in one paced round.
        if (probe(m.gpa, jobs)) {
            m.probing_ok.store(true, .monotonic);
        } else |err| {
            log.err("probing failed: {t}", .{err});
            m.probing_ok.store(false, .monotonic);
            for (jobs) |*job| if (job.err == null) {
                job.err = "cannot open ICMP socket";
            };
        }

        // 4. Record the results; a target may have been removed meanwhile.
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (jobs) |*job| {
            const i = m.find(job.id) orelse continue;
            m.recordLocked(m.targets.items[i], t, job);
        }
        if (m.demo) m.demoFillLocked(t);
        m.version += 1;
        m.saveHistoryLocked();
    }

    fn recordLocked(m: *Monitor, target: *Target, t: i64, job: *Job) void {
        if (target.paused) return; // paused while this cycle ran
        if (!std.mem.eql(u8, target.host, job.host)) return; // moved to another host meanwhile
        recordDnsLocked(target, job);
        var sample: Sample = .{ .t = t, .sent = probes_per_cycle };
        if (job.err == null) {
            sample.sent = job.sent;
            summarize(&sample, job.rtts[0..job.replies]);
        }
        target.last_error = job.err;
        target.last = sample;
        target.history[m.slot(t)] = sample;

        if (target.acked) {
            if (target.status() == .down) {
                target.ok_streak = 0;
            } else {
                target.ok_streak += 1;
                if (target.ok_streak >= ack_clear_after) {
                    target.acked = false;
                    target.ok_streak = 0;
                    m.saveConfigLocked();
                }
            }
        }
    }

    /// Keeps what the cycle's lookup found, and reports the transitions:
    /// DNS failing (stale or failed), answering again, a new address.
    fn recordDnsLocked(target: *Target, job: *const Job) void {
        if (!job.looked_up) return;
        const before = target.dns;
        const old = target.addr;
        // `err` may be the probe's (no ICMP socket): only the lookup's counts.
        if (job.dns_failed) {
            target.dns = .failed;
            target.addr = null;
            target.dns_error = job.dns_error;
        } else if (job.dns_error) |e| {
            target.dns = .stale;
            target.dns_error = e;
        } else {
            target.dns = .ok;
            target.dns_error = null;
            target.addr = job.addr;
            target.addr_confirmed = job.confirmed;
        }
        target.addr_expires = job.expires;
        if (target.dns != before) switch (target.dns) {
            .ok => _ = events.emit(.info, .dns, .system, null, "action=recovered target={d} host={f} addr={f}", .{ target.id, events.quote(target.host), target.addr.?.toIp() }),
            .stale => _ = events.emit(.warn, .dns, .system, null, "action=stale target={d} host={f} addr={f} error={s}", .{ target.id, events.quote(target.host), target.addr.?.toIp(), target.dns_error.? }),
            .failed => _ = events.emit(.warn, .dns, .system, null, "action=failed target={d} host={f} error={s}", .{ target.id, events.quote(target.host), target.dns_error orelse "NoAddress" }),
        };
        if (target.dns == .ok and old != null and !old.?.toIp().eql(target.addr.?.toIp()))
            _ = events.emit(.info, .dns, .system, null, "action=moved target={d} host={f} from={f} addr={f}", .{ target.id, events.quote(target.host), old.?.toIp(), target.addr.?.toIp() });
    }

    /// Once per hour (and after the first cycle of a run): everything older
    /// than the last hour of real data, or than this run, becomes sample data.
    fn demoFillLocked(m: *Monitor, t: i64) void {
        if (m.demo_since == 0) m.demo_since = t;
        const hour = t - @mod(t, 3600);
        if (hour == m.demo_hour) return;
        m.demo_hour = hour;
        // On a cycle boundary (`t` and `demo_since` are), so the real
        // samples are found below whatever `cycle_s` is.
        const hour_ago = hour - 3600 + @mod(-(hour - 3600), m.cycle_s);
        const live_from = @max(hour_ago, m.demo_since);
        m.demo_from = live_from;
        const oldest = t - (history_len - 1) * m.cycle_s;
        for (m.targets.items) |target| {
            const scenario = target.scenario orelse continue;
            // The sample past is scaled to the target's real median latency.
            var real: [history_len]u32 = undefined;
            var n: usize = 0;
            var at = live_from;
            while (at <= t) : (at += m.cycle_s) {
                const s = target.history[m.slot(at)];
                if (s.t == at and s.recv > 0 and n < real.len) {
                    real[n] = s.rtt_us;
                    n += 1;
                }
            }
            const base_ms: f64 = if (n > 0) @as(f64, @floatFromInt(median(real[0..n]))) / 1000 else 20;

            var when = live_from - m.cycle_s;
            while (when >= oldest) : (when -= m.cycle_s) {
                var rtts: [probes_per_cycle]u32 = undefined;
                const replies = demo.probes(scenario, target.id, when, base_ms, live_from, &rtts);
                var sample: Sample = .{ .t = when, .sent = probes_per_cycle };
                summarize(&sample, rtts[0..replies]);
                target.history[m.slot(when)] = sample;
            }
        }
    }

    // ----- persistence ----------------------------------------------------------

    /// The on-disk target list. Hand-written files may omit everything but
    /// `name` and `host`; a file from 1.0.0 has no `tags`.
    const ConfigFile = struct {
        targets: []const struct {
            id: u32 = 0,
            name: []const u8,
            host: []const u8,
            tags: []const []const u8 = &.{},
            paused: bool = false,
            acked: bool = false,
            /// A `demo.Scenario` name, used with `--demo`.
            demo: ?[]const u8 = null,
        },
    };

    pub fn loadConfig(m: *Monitor) !void {
        const bytes = Io.Dir.cwd().readFileAlloc(m.io, m.config_path, m.gpa, .limited(1 << 20)) catch |err| switch (err) {
            // A writable instance starts empty and writes the file on the
            // first change; a read-only one would show nothing, forever.
            error.FileNotFound => if (m.read_only) return err else return,
            else => return err,
        };
        defer m.gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(ConfigFile, m.gpa, bytes, .{});
        defer parsed.deinit();
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (parsed.value.targets) |entry| {
            try validateName(entry.name);
            try validateHost(entry.host);
            try validateTags(entry.tags);
            const id = if (entry.id != 0 and m.find(entry.id) == null) entry.id else m.next_id;
            _ = try m.addLocked(id, entry.name, entry.host, entry.tags);
            const t = m.targets.items[m.targets.items.len - 1];
            t.paused = entry.paused;
            t.acked = entry.acked;
            if (entry.demo) |name| t.scenario = std.meta.stringToEnum(demo.Scenario, name) orelse return error.InvalidScenario;
        }
    }

    fn saveConfigLocked(m: *Monitor) void {
        if (m.read_only) return;
        var aw: Io.Writer.Allocating = .init(m.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\n  \"targets\": [") catch return;
        for (m.targets.items, 0..) |t, i| {
            w.print("{s}\n    {{ \"id\": {d}, \"name\": {f}, \"host\": {f}, \"paused\": {}, \"acked\": {}", .{
                if (i == 0) "" else ",", t.id, std.json.fmt(t.name, .{}), std.json.fmt(t.host, .{}), t.paused, t.acked,
            }) catch return;
            if (t.tags.len > 0) writeTags(w, t.tags, ", \"tags\": ") catch return;
            if (t.scenario) |sc| w.print(", \"demo\": \"{t}\"", .{sc}) catch return;
            w.writeAll(" }") catch return;
        }
        w.writeAll("\n  ]\n}\n") catch return;
        replacePending(m.gpa, &m.pending_config, aw.toOwnedSlice() catch return);
    }

    /// History file: per target id, the non-empty samples as
    /// `[t, sent, recv, rtt_us, jitter_us]`; files from 1.0.0 lack `jitter_us`.
    const HistoryFile = struct {
        cycle_s: i64,
        targets: []const struct { id: u32, samples: []const []const i64 },
    };

    pub fn loadHistory(m: *Monitor) !void {
        const path = m.history_path orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(m.io, path, m.gpa, .limited(8 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer m.gpa.free(bytes);
        // The history is only nice to have: an unreadable file is moved
        // aside rather than keeping the daemon from starting (a restart
        // loop under systemd until someone notices).
        const parsed = std.json.parseFromSlice(HistoryFile, m.gpa, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                var bad_buf: [Io.Dir.max_path_bytes]u8 = undefined;
                const bad = try std.mem.print(&bad_buf, "{s}.bad", .{path});
                try Io.Dir.rename(.cwd(), path, .cwd(), bad, m.io);
                log.warn("{s} is not a valid history ({t}), moved to {s}; starting without history", .{ path, err, bad });
                return;
            },
        };
        defer parsed.deinit();
        if (parsed.value.cycle_s != m.cycle_s) return; // slots would not line up
        const now = Io.Clock.real.now(m.io).toSeconds();
        const oldest = now - history_len * m.cycle_s;
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        for (parsed.value.targets) |entry| {
            const t = m.targets.items[m.find(entry.id) orelse continue];
            for (entry.samples) |s| {
                if (s.len != 4 and s.len != 5) continue;
                // From before the window, or from the future (a clock that
                // was ahead): neither belongs in the series.
                if (s[0] <= oldest or s[0] > now) continue;
                const sample: Sample = .{
                    .t = s[0],
                    .sent = fileValue(u8, s[1], probes_per_cycle) orelse continue,
                    .recv = fileValue(u8, s[2], probes_per_cycle) orelse continue,
                    .rtt_us = fileValue(u32, s[3], max_file_rtt_us) orelse continue,
                    .jitter_us = if (s.len == 5) fileValue(u32, s[4], max_file_rtt_us) orelse continue else 0,
                };
                // writeSeries computes `sent - recv`.
                if (sample.sent > probes_per_cycle or sample.recv > sample.sent) continue;
                t.history[m.slot(sample.t)] = sample;
                if (sample.t > t.last.t) t.last = sample;
            }
        }
    }

    fn saveHistoryLocked(m: *Monitor) void {
        if (m.history_path == null) return;
        var aw: Io.Writer.Allocating = .init(m.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("{{\"cycle_s\":{d},\"targets\":[", .{m.cycle_s}) catch return;
        for (m.targets.items, 0..) |t, i| {
            w.print("{s}{{\"id\":{d},\"samples\":[", .{ if (i == 0) "" else ",", t.id }) catch return;
            var first = true;
            // Sample data is regenerated, never kept: a history file must
            // not hand made-up outages to an instance without --demo.
            const sample_before = if (m.demo and t.scenario != null) m.demo_from else 0;
            for (t.history) |s| {
                if (s.t == 0 or s.t < sample_before) continue;
                w.print("{s}[{d},{d},{d},{d},{d}]", .{ if (first) "" else ",", s.t, s.sent, s.recv, s.rtt_us, s.jitter_us }) catch return;
                first = false;
            }
            w.writeAll("]}") catch return;
        }
        w.writeAll("]}\n") catch return;
        replacePending(m.gpa, &m.pending_history, aw.toOwnedSlice() catch return);
    }

    fn replacePending(gpa: std.mem.Allocator, slot_ptr: *?[]u8, data: []u8) void {
        if (slot_ptr.*) |old| gpa.free(old);
        slot_ptr.* = data;
    }

    /// Writes the files serialized since the last call. Call with `mutex`
    /// NOT held: the write syncs to disk, which may take a while.
    fn flushSaves(m: *Monitor) void {
        m.save_mutex.lockUncancelable(m.io);
        defer m.save_mutex.unlock(m.io);
        const config, const history = blk: {
            m.mutex.lockUncancelable(m.io);
            defer m.mutex.unlock(m.io);
            const taken = .{ m.pending_config, m.pending_history };
            m.pending_config = null;
            m.pending_history = null;
            break :blk taken;
        };
        if (config) |data| {
            defer m.gpa.free(data);
            writeFileAtomic(m.io, m.config_path, data) catch |err|
                log.err("cannot write {s}: {t}", .{ m.config_path, err });
        }
        if (history) |data| {
            defer m.gpa.free(data);
            const path = m.history_path.?;
            writeFileAtomic(m.io, path, data) catch |err|
                log.err("cannot write {s}: {t}", .{ path, err });
        }
    }

    // ----- web API --------------------------------------------------------------

    /// The tag of the current state: it changes when a cycle is recorded,
    /// a target changes or a new cycle starts (the series shift by one), and
    /// at no other time.
    pub fn stateTag(m: *Monitor) StateTag {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        return m.stateTagLocked();
    }

    fn stateTagLocked(m: *Monitor) StateTag {
        const now = Io.Clock.real.now(m.io).toSeconds();
        return .{ .version = m.version, .end = now - @mod(now, m.cycle_s) };
    }

    /// Everything the page shows, as JSON (see `writeStateLocked`): a
    /// reference to the current snapshot, `release` it when sent. Built once
    /// per tag and shared, never copied per request, so any number of
    /// viewers costs one serialization per change, and slow readers hold at
    /// most the few snapshots made while they read (not one copy each: 256
    /// slow readers of a 64-target state were 256 x 1.4 MB).
    pub fn state(m: *Monitor) error{OutOfMemory}!*Snapshot {
        m.mutex.lockUncancelable(m.io);
        defer m.mutex.unlock(m.io);
        const tag = m.stateTagLocked();
        const current = m.snapshot;
        if (current == null or !std.meta.eql(current.?.tag, tag)) {
            var aw: Io.Writer.Allocating = .init(m.gpa);
            defer aw.deinit();
            m.writeStateLocked(&aw.writer, tag.end) catch return error.OutOfMemory;
            const snap = try m.gpa.create(Snapshot);
            snap.* = .{ .gpa = m.gpa, .tag = tag, .json = &.{} };
            snap.json = aw.toOwnedSlice() catch {
                m.gpa.destroy(snap);
                return error.OutOfMemory;
            };
            if (current) |old| old.release();
            m.snapshot = snap;
        }
        const snap = m.snapshot.?;
        _ = snap.refs.fetchAdd(1, .monotonic);
        return snap;
    }

    /// One `state` result: immutable, freed with its last reference.
    pub const Snapshot = struct {
        gpa: std.mem.Allocator,
        refs: std.atomic.Value(u32) = .init(1),
        tag: StateTag,
        json: []u8,
        /// `json` gzip-compressed, made by the first `gzipped` call.
        gz: ?[]u8 = null,
        gz_done: bool = false,
        gz_mutex: Io.Mutex = .init,

        /// `json` gzip-compressed: compressed by the first caller, shared
        /// by the rest (who wait for it rather than compress it again).
        /// Null if compressing failed (out of memory); send `json` then.
        pub fn gzipped(snap: *Snapshot, io: Io) ?[]const u8 {
            snap.gz_mutex.lockUncancelable(io);
            defer snap.gz_mutex.unlock(io);
            if (!snap.gz_done) {
                snap.gz_done = true;
                snap.gz = compress(snap.gpa, snap.json) catch null;
            }
            return snap.gz;
        }

        pub fn release(snap: *Snapshot) void {
            if (snap.refs.fetchSub(1, .acq_rel) != 1) return;
            snap.gpa.free(snap.json);
            if (snap.gz) |gz| snap.gpa.free(gz);
            snap.gpa.destroy(snap);
        }
    };

    /// Per target, `rtt` (ms), `jitter` (ms) and `loss` (%) hold one entry per cycle of the
    /// last 24 hours, oldest first, the newest at cycle start `newest`;
    /// `null` where there is no sample.
    fn writeStateLocked(m: *Monitor, w: *Io.Writer, newest: i64) Io.Writer.Error!void {
        try w.print(
            "{{\"read_only\":{},\"demo_from\":{d},\"cycle_s\":{d},\"probes\":{d},\"ack_clear_after\":{d},\"end\":{d},\"targets\":[",
            .{ m.read_only, m.demo_from, m.cycle_s, probes_per_cycle, ack_clear_after, newest },
        );
        for (m.targets.items, 0..) |t, i| {
            try w.print(
                "{s}{{\"id\":{d},\"name\":{f},\"host\":{f},\"status\":\"{t}\",\"paused\":{},\"acked\":{},\"ok_streak\":{d},\"error\":{f},\"sample\":{}",
                .{
                    if (i == 0) "" else ",",         t.id,
                    std.json.fmt(t.name, .{}),       std.json.fmt(t.host, .{}),
                    t.status(),                      t.paused,
                    t.acked,                         t.ok_streak,
                    std.json.fmt(t.last_error, .{}), m.demo and t.scenario != null,
                },
            );
            try writeTags(w, t.tags, ",\"tags\":");
            if (t.addr) |a| try w.print(",\"address\":\"{f}\"", .{a.toIp()}) else try w.writeAll(",\"address\":null");
            try w.print(",\"dns\":\"{t}\"", .{t.dns});
            try w.writeAll(",\"rtt\":[");
            try m.writeSeries(w, t, newest, .rtt);
            try w.writeAll("],\"jitter\":[");
            try m.writeSeries(w, t, newest, .jitter);
            try w.writeAll("],\"loss\":[");
            try m.writeSeries(w, t, newest, .loss);
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }

    fn writeSeries(m: *Monitor, w: *Io.Writer, t: *const Target, newest: i64, comptime what: enum { rtt, jitter, loss }) Io.Writer.Error!void {
        var k: i64 = history_len - 1;
        while (k >= 0) : (k -= 1) {
            const at = newest - k * m.cycle_s;
            const s = t.history[m.slot(at)];
            if (k != history_len - 1) try w.writeByte(',');
            if (s.t != at or s.sent == 0) {
                try w.writeAll("null");
            } else switch (what) {
                .rtt => if (s.recv == 0) try w.writeAll("null") else try writeMs(w, s.rtt_us),
                .jitter => if (s.recv < 2) try w.writeAll("null") else try writeMs(w, s.jitter_us),
                .loss => try w.print("{d}", .{@as(u32, s.sent - s.recv) * 100 / s.sent}),
            }
        }
    }
};

// ----- helpers ------------------------------------------------------------------

/// `data` as one gzip member (level 6, zlib's default).
fn compress(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    // The deflate state is ~290 KiB: on the heap, and only while compressing.
    const scratch = try gpa.create(gzip.Scratch);
    defer gpa.destroy(scratch);
    var out: Io.Writer.Allocating = try .initCapacity(gpa, data.len / 4 + 64);
    errdefer out.deinit();
    const w = try scratch.begin(&out.writer, 6);
    try w.writeAll(data);
    try scratch.finish();
    return out.toOwnedSlice();
}

/// Milliseconds, two decimals below 10 ms (LAN targets) and one above.
fn writeMs(w: *Io.Writer, us: u32) Io.Writer.Error!void {
    const v = @as(f64, @floatFromInt(us)) / 1000;
    if (us < 10_000) try w.print("{d:.2}", .{v}) else try w.print("{d:.1}", .{v});
}

/// Sorts `v` (not empty) and returns its median.
fn median(v: []u32) u32 {
    std.mem.sortUnstable(u32, v, {}, std.sort.asc(u32));
    return v[v.len / 2];
}

/// Fills `sample.recv`, `rtt_us` (median) and `jitter_us` from the replies'
/// round-trip times, given in reply order (sorted here).
fn summarize(sample: *Sample, rtts: []u32) void {
    sample.recv = @intCast(rtts.len);
    if (rtts.len == 0) return;
    sample.jitter_us = jitter(rtts);
    sample.rtt_us = median(rtts);
}

/// Mean absolute difference between consecutive round-trip times, in reply
/// order (the usual "jitter" of ping tools); 0 with fewer than two.
fn jitter(rtts: []const u32) u32 {
    if (rtts.len < 2) return 0;
    var sum: u64 = 0;
    for (rtts[1..], rtts[0 .. rtts.len - 1]) |b, a| sum += @max(a, b) - @min(a, b);
    return @intCast(sum / (rtts.len - 1));
}

fn writeTags(w: *Io.Writer, tags: []const []const u8, prefix: []const u8) Io.Writer.Error!void {
    try w.writeAll(prefix);
    try w.writeByte('[');
    for (tags, 0..) |tag, i| try w.print("{s}{f}", .{ if (i == 0) "" else ",", std.json.fmt(tag, .{}) });
    try w.writeByte(']');
}

/// At most `max_tags` tags of 1 to `max_tag_len` bytes, no control
/// characters, spaces or commas (the page splits its input on them).
fn validateTags(tags: []const []const u8) Error!void {
    if (tags.len > max_tags) return error.InvalidTags;
    for (tags) |tag| {
        if (tag.len == 0 or tag.len > max_tag_len) return error.InvalidTags;
        for (tag) |c| if (c <= 0x20 or c == 0x7f or c == ',') return error.InvalidTags;
    }
}

/// A copy of validated `tags`, ASCII-lowercased and without duplicates.
fn dupeTags(gpa: std.mem.Allocator, tags: []const []const u8) error{OutOfMemory}![][]u8 {
    var list: std.ArrayList([]u8) = try .initCapacity(gpa, tags.len);
    errdefer freeTags(gpa, list.items);
    outer: for (tags) |tag| {
        for (list.items) |have| if (std.ascii.eqlIgnoreCase(have, tag)) continue :outer;
        const copy = try gpa.dupe(u8, tag);
        list.appendAssumeCapacity(std.ascii.lowerString(copy, tag));
    }
    return list.toOwnedSlice(gpa);
}

fn freeTags(gpa: std.mem.Allocator, tags: [][]u8) void {
    for (tags) |tag| gpa.free(tag);
    gpa.free(tags);
}

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 64) return error.InvalidName;
    for (name) |c| if (c < 0x20 or c == 0x7f) return error.InvalidName;
}

/// A round-trip time (or jitter) a history file may hold: a probe waits
/// far less; anything above is a damaged file, dropped like one.
const max_file_rtt_us = 60 * std.time.us_per_s;

/// `v` from the history file as a `T` no larger than `max`, or null.
/// Range-checked as i64 first, then narrowed from u64: Zig 0.17's optimized
/// builds miscompile a signed-to-narrower-unsigned `math.cast` (#37131).
fn fileValue(comptime T: type, v: i64, max: u32) ?T {
    if (v < 0 or v > max) return null;
    return @intCast(@as(u64, @bitCast(v)));
}

test "history file values: range-checked, never wrapped" {
    try testing.expectEqual(@as(?u8, 5), fileValue(u8, 5, probes_per_cycle));
    for ([_]i64{ -1, 6, 256, std.math.minInt(i64), std.math.maxInt(i64) }) |v|
        try testing.expectEqual(@as(?u8, null), fileValue(u8, v, probes_per_cycle));
    try testing.expectEqual(@as(?u32, null), fileValue(u32, std.math.maxInt(u32), max_file_rtt_us));
    try testing.expectEqual(@as(?u32, 59_000_000), fileValue(u32, 59_000_000, max_file_rtt_us));
}

/// A numeric address, or a host name valid for DNS.
fn validateHost(host: []const u8) Error!void {
    if (icmp.Addr.parse(host)) |_| return else |_| {}
    _ = Io.net.HostName.init(host) catch return error.InvalidHost;
}

/// A temporary file next to `path`, synced to disk before it is renamed
/// over `path`, then the directory synced: a crash or power loss leaves the
/// old or the new content, never an empty or truncated file.
fn writeFileAtomic(io: Io, path: []const u8, data: []const u8) !void {
    try filestore.writeFileAtomic(io, Io.Dir.cwd(), path, data, .{});
}

/// Per-attempt budget of a name lookup. Explicit, so a lookup is bounded
/// (2 families x 2 attempts x the servers) whatever resolv.conf says.
const lookup_timeout_ms = 2000;
/// Lookups running at once. With the DNS server down every lookup waits
/// out its whole budget: one after another, 64 names took minutes.
const max_lookups = 16;
/// An answer is kept for its TTL, within these bounds (seconds): a name is
/// looked up at most once a minute, at least once an hour. An answer
/// without a TTL (/etc/hosts) is kept `default_ttl_s`.
const min_ttl_s = 60;
const max_ttl_s = 3600;
const default_ttl_s = 300;
/// After a failed lookup, the next try (the stale address is probed meanwhile).
const retry_s = 60;

/// The preferred address of `host` (RFC 6724 order, like getaddrinfo);
/// numeric addresses skip DNS.
pub fn resolve(io: Io, gpa: std.mem.Allocator, host: []const u8) !icmp.Addr {
    if (icmp.Addr.parse(host)) |addr| return addr else |_| {}
    var resolver = dns.Resolver.init(io, gpa, .{ .timeout_ms = lookup_timeout_ms });
    defer resolver.deinit();
    const found = try resolver.lookupIpTtl(host);
    defer gpa.free(found.ips);
    if (found.ips.len == 0) return error.UnknownHostName;
    return icmp.Addr.fromIp(found.ips[0]);
}

const DnsPolicy = struct { now: i64, stale_s: i64 };

/// Sets `addr` (or `err`) of every job, `max_lookups` lookups at a time.
fn resolveAll(io: Io, gpa: std.mem.Allocator, jobs: []Job, policy: DnsPolicy) void {
    var next: std.atomic.Value(usize) = .init(0);
    var group: Io.Group = .init;
    for (0..@min(jobs.len, max_lookups)) |_| {
        group.concurrent(io, resolveJobs, .{ io, gpa, jobs, &next, policy }) catch break;
    }
    // Whatever no task took (no concurrency available) is resolved here.
    resolveJobs(io, gpa, jobs, &next, policy);
    group.await(io) catch group.cancel(io);
    // Canceled (at shutdown) before its lookup finished: say so, rather
    // than record a cycle that sent nothing as if it had.
    for (jobs) |*job| if (job.addr == null and job.err == null) {
        job.err = "name lookup canceled";
    };
}

/// Takes the next job until none is left: a numeric address as it is, a
/// cached one until it expires, else a lookup. A lookup that does not
/// finish (canceled at shutdown) leaves its job unresolved.
fn resolveJobs(io: Io, gpa: std.mem.Allocator, jobs: []Job, next: *std.atomic.Value(usize), policy: DnsPolicy) void {
    // One resolver per task: a `dns.Resolver` belongs to one thread.
    var resolver: ?dns.Resolver = null;
    defer if (resolver) |*r| r.deinit();
    while (true) {
        const i = next.fetchAdd(1, .monotonic);
        if (i >= jobs.len) return;
        const job = &jobs[i];
        if (icmp.Addr.parse(job.host)) |addr| {
            job.addr = addr;
            continue;
        } else |_| {}
        if (!job.due) {
            // A name with no address waits for its retry (`retry_s`, or the
            // negative TTL) with the error it had.
            job.addr = job.cached;
            if (job.cached == null) job.err = job.previous_error orelse "name does not resolve";
            continue;
        }
        if (resolver == null) resolver = dns.Resolver.init(io, gpa, .{ .timeout_ms = lookup_timeout_ms });
        const found = resolver.?.lookupIpTtl(job.host) catch |err| {
            if (err == error.Canceled) return;
            settleFailure(job, err, policy);
            continue;
        };
        defer gpa.free(found.ips);
        settleAnswer(job, found, policy);
    }
}

/// A lookup that got no answer (a timeout, an unreachable server): keep
/// probing the last address while it is younger than `stale_s`.
fn settleFailure(job: *Job, err: anyerror, policy: DnsPolicy) void {
    job.looked_up = true;
    job.dns_error = dnsErrorName(err);
    job.expires = policy.now + retry_s;
    if (job.cached) |addr| if (policy.stale_s > 0 and policy.now - job.confirmed <= policy.stale_s) {
        job.addr = addr;
        return;
    };
    job.err = "DNS lookup failed";
    job.dns_failed = true;
}

/// An answer. An empty one (the name does not exist, or has no address)
/// is authoritative: no stale address is kept for it. Otherwise the cached
/// address stays while it is still in the answer, so a name with several
/// addresses is not probed at a different one every time it expires.
fn settleAnswer(job: *Job, found: dns.Resolver.IpLookup, policy: DnsPolicy) void {
    job.looked_up = true;
    const ttl: i64 = found.ttl_s orelse default_ttl_s;
    job.expires = policy.now + std.math.clamp(ttl, min_ttl_s, max_ttl_s);
    if (found.ips.len == 0) {
        job.err = "name does not resolve";
        job.dns_error = "NoAddress";
        job.dns_failed = true;
        return;
    }
    // One family failed and the kept address is of that family: not a
    // move, a failure of its lookup (else a v6 address would give way to
    // v4 for a cycle whenever AAAA times out, and come back the next).
    if (found.partial) if (job.cached) |c| {
        const kept = for (found.ips) |ip| {
            if (ip.eql(c.toIp())) break true;
        } else false;
        if (!kept) return settleFailure(job, error.PartialAnswer, policy);
    };
    job.confirmed = policy.now;
    job.addr = icmp.Addr.fromIp(found.ips[0]);
    if (job.cached) |c| for (found.ips) |ip| if (ip.eql(c.toIp())) {
        job.addr = c;
        break;
    };
}

/// A static name for a lookup failure, for the page and the log.
fn dnsErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "Timeout",
        error.ServerFailed => "ServerFailed",
        error.PartialAnswer => "PartialAnswer",
        error.NetworkFailed => "NetworkFailed",
        error.MalformedResponse => "MalformedResponse",
        error.OutOfMemory => "OutOfMemory",
        error.BadName, error.NameTooLong => "BadName",
        else => "LookupFailed",
    };
}

/// One target's share of a cycle.
const Job = struct {
    id: u32,
    host: []const u8,
    /// The address to probe, and why there is none.
    addr: ?icmp.Addr = null,
    err: ?[]const u8 = null,
    /// From the target: the address kept from earlier cycles, when DNS last
    /// gave it, and whether its answer expired.
    cached: ?icmp.Addr = null,
    confirmed: i64 = 0,
    due: bool = true,
    /// The target's error from earlier cycles, kept while a failed name
    /// waits for its retry.
    previous_error: ?[]const u8 = null,
    /// Set by a lookup (`looked_up`): when to look again, why it failed,
    /// and whether it left no address at all (`dns_failed`).
    looked_up: bool = false,
    expires: i64 = 0,
    dns_error: ?[]const u8 = null,
    dns_failed: bool = false,
    rtts: [probes_per_cycle]u32 = undefined,
    replies: u8 = 0,
    sent: u8 = 0,
};

/// Ping every job that has an address, `probes_per_cycle` times, in one round.
fn probe(gpa: std.mem.Allocator, jobs: []Job) !void {
    var pinger = try icmp.Pinger.init(gpa, .{
        .mode = .count,
        .count = probes_per_cycle,
        // Spread the probes: 20 ms between any two packets, 1 s between
        // probes to the same host, 1 s to answer, and a random start offset
        // within 500 ms so consecutive cycles do not line up.
        .interval_ns = 20 * std.time.ns_per_ms,
        .perhost_interval_ns = std.time.ns_per_s,
        .timeout_ns = std.time.ns_per_s,
        .jitter_ns = 500 * std.time.ns_per_ms,
    });
    defer pinger.deinit();

    // Pinger target ids are dense indexes; map them back to jobs.
    var index: [max_targets]*Job = undefined;
    var n: usize = 0;
    for (jobs) |*job| {
        const addr = job.addr orelse continue;
        _ = try pinger.addTargetAddr(addr);
        index[n] = job;
        n += 1;
    }
    if (n == 0) return;

    const Collect = struct {
        fn onResult(ctx: ?*anyopaque, id: icmp.TargetId, _: u16, outcome: icmp.Outcome) void {
            const map: *[max_targets]*Job = @ptrCast(@alignCast(ctx.?));
            const job = map[id];
            switch (outcome) {
                .reply => |r| if (job.replies < probes_per_cycle) {
                    job.rtts[job.replies] = @intCast(@min(r.rtt_ns / std.time.ns_per_us, std.math.maxInt(u32)));
                    job.replies += 1;
                },
                else => {},
            }
        }
    };
    pinger.setResultCallback(&index, Collect.onResult);
    try pinger.run();
    for (index[0..n], 0..) |job, id| job.sent = @intCast(pinger.stats(@intCast(id)).sent);
}

// ----- tests ----------------------------------------------------------------------

const testing = std.testing;

fn testMonitor() Monitor {
    return .{ .gpa = testing.allocator, .io = testing.io, .config_path = "unused", .read_only = true };
}

fn fakeCycle(m: *Monitor, id: u32, t: i64, recv: u8) void {
    m.mutex.lockUncancelable(m.io);
    defer m.mutex.unlock(m.io);
    const target = m.targets.items[m.find(id).?];
    var job: Job = .{ .id = id, .host = target.host, .sent = probes_per_cycle, .replies = recv };
    for (0..recv) |i| job.rtts[i] = @intCast(1000 * (i + 1));
    m.recordLocked(target, t, &job);
}

test "status follows the last sample" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    const t = m.targets.items[0];
    try testing.expectEqual(.pending, t.status());
    fakeCycle(&m, id, 60, 5);
    try testing.expectEqual(.up, t.status());
    try testing.expectEqual(@as(u32, 3000), t.last.rtt_us); // median of 1..5 ms
    try testing.expectEqual(@as(u32, 1000), t.last.jitter_us); // 1 ms steps
    fakeCycle(&m, id, 120, 2);
    try testing.expectEqual(.degraded, t.status());
    fakeCycle(&m, id, 180, 0);
    try testing.expectEqual(.down, t.status());
    try m.apply(id, .pause);
    try testing.expectEqual(.paused, t.status());
}

test "acknowledgement needs DOWN and clears after five good cycles" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    fakeCycle(&m, id, 60, 5);
    try testing.expectError(error.NotDown, m.apply(id, .ack));
    fakeCycle(&m, id, 120, 0);
    try m.apply(id, .ack);
    const t = m.targets.items[0];
    // A relapse resets the streak.
    for (0..4) |i| fakeCycle(&m, id, 180 + 60 * @as(i64, @intCast(i)), 5);
    fakeCycle(&m, id, 420, 0);
    try testing.expect(t.acked);
    for (0..ack_clear_after - 1) |i| fakeCycle(&m, id, 480 + 60 * @as(i64, @intCast(i)), 3);
    try testing.expect(t.acked);
    fakeCycle(&m, id, 480 + 60 * (ack_clear_after - 1), 5);
    try testing.expect(!t.acked);
}

test "history keeps 24 hours and reports gaps as null" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    const t0: i64 = 1_700_000_040; // a cycle boundary
    fakeCycle(&m, id, t0, 5);
    fakeCycle(&m, id, t0 + history_len * 60, 4); // same slot, a day later
    const t = m.targets.items[0];
    try testing.expectEqual(t0 + history_len * 60, t.history[m.slot(t0)].t);
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try m.writeSeries(&aw.writer, t, t0 + history_len * 60, .loss);
    try testing.expect(std.mem.endsWith(u8, aw.written(), "null,null,20"));
}

test "the state is built once per change and shared" {
    var m = testMonitor();
    defer m.deinit();
    m.cycle_s = 1 << 30; // no cycle boundary (which changes the tag) during the test
    const id = try m.add("a", "192.0.2.1", &.{});
    const first = try m.state();
    try testing.expectEqual(first.tag, m.stateTag());
    // The same tag: the same snapshot, shared, not rebuilt.
    const again = try m.state();
    try testing.expectEqual(first, again);
    again.release();
    try m.apply(id, .pause);
    try testing.expect(m.stateTag().version != first.tag.version);
    const second = try m.state();
    defer second.release();
    try testing.expect(second != first);
    try testing.expect(std.mem.find(u8, second.json, "\"paused\":true") != null);
    // A reader still holding the old snapshot reads it intact; its last
    // release frees it (the testing allocator reports a leak otherwise).
    try testing.expect(std.mem.find(u8, first.json, "\"paused\":false") != null);
    first.release();

    // Compressed once, and it decompresses to the JSON.
    const gz = second.gzipped(m.io).?;
    try testing.expectEqual(gz.ptr, second.gzipped(m.io).?.ptr);
    var in: Io.Reader = .fixed(gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    const plain = try dec.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings(second.json, plain);
}

test "health: cycles must keep finishing and probing must work" {
    var m = testMonitor();
    defer m.deinit();
    m.started_at.store(1000, .monotonic);
    try testing.expect(m.health(1000 + 3 * 60).ok); // first cycle still running
    try testing.expect(!m.health(1001 + 3 * 60).ok); // ... for too long
    m.cycle_done_at.store(2000, .monotonic);
    try testing.expect(m.health(2000 + 3 * 60).ok);
    try testing.expect(!m.health(2001 + 3 * 60).ok);
    m.probing_ok.store(false, .monotonic);
    try testing.expect(!m.health(2000).ok);
}

test "persistence: missing target list, unusable history, atomic writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [3][128]u8 = undefined;
    const dir = try std.mem.print(&buf[0], ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const config = try std.mem.print(&buf[1], "{s}/targets.json", .{dir});
    const history = try std.mem.print(&buf[2], "{s}/history.json", .{dir});

    // No target list: a writable instance starts empty, a read-only one fails.
    var m: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config, .history_path = history };
    defer m.deinit();
    try m.loadConfig();
    try testing.expectEqual(0, m.targets.items.len);
    m.read_only = true;
    try testing.expectError(error.FileNotFound, m.loadConfig());
    m.read_only = false;

    // The first change writes the list (through a synced temporary file).
    const id = try m.add("a", "192.0.2.1", &.{});
    const saved = try tmp.dir.readFileAlloc(testing.io, "targets.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.find(u8, saved, "\"host\": \"192.0.2.1\"") != null);

    // Garbage is moved aside (with a warning, muted here), the daemon starts
    // without history.
    testing.log_level = .err;
    defer testing.log_level = .warn;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "history.json", .data = "{\"cycle_s\":60,\"tar" });
    try m.loadHistory();
    _ = try tmp.dir.statFile(testing.io, "history.json.bad", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "history.json", .{}));

    // An impossible sample (more replies than probes) is skipped, not served.
    const now = Io.Clock.real.now(testing.io).toSeconds();
    const t = now - @mod(now, 60);
    var json: [256]u8 = undefined;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "history.json", .data = try std.mem.print(
        &json,
        "{{\"cycle_s\":60,\"targets\":[{{\"id\":{d},\"samples\":[[{d},2,5,1000],[{d},5,4,1000],[{d},5,5,900,70],[{d},5]]}}]}}",
        .{ id, t - 180, t - 120, t - 60, t },
    ) });
    try m.loadHistory();
    const target = m.targets.items[0];
    try testing.expectEqual(0, target.history[m.slot(t - 180)].t);
    // A 1.0.0 sample (no jitter) and a current one load; a short one does not.
    try testing.expectEqual(4, target.history[m.slot(t - 120)].recv);
    try testing.expectEqual(0, target.history[m.slot(t - 120)].jitter_us);
    try testing.expectEqual(70, target.history[m.slot(t - 60)].jitter_us);
    try testing.expectEqual(0, target.history[m.slot(t)].t);
}

test "jitter is the mean step between consecutive replies" {
    try testing.expectEqual(0, jitter(&.{}));
    try testing.expectEqual(0, jitter(&.{1000}));
    try testing.expectEqual(0, jitter(&.{ 500, 500, 500 }));
    try testing.expectEqual(1500, jitter(&.{ 1000, 3000, 2000 })); // (2000 + 1000) / 2
}

test "demo: sample data before the real hour, real data kept" {
    var m = testMonitor();
    defer m.deinit();
    m.demo = true;
    const id = try m.add("a", "192.0.2.1", &.{});
    const t = m.targets.items[0];
    t.scenario = .outage;
    const hour: i64 = 1_700_006_400;
    // First run: everything before the first cycle becomes sample data.
    fakeCycle(&m, id, hour + 600, 5); // real: median 3 ms
    m.demoFillLocked(hour + 600);
    try testing.expectEqual(hour + 600, m.demo_from);
    try testing.expectEqual(hour + 540, t.history[m.slot(hour + 540)].t);
    try testing.expectEqual(hour + 600 - (history_len - 1) * 60, t.history[m.slot(hour + 660)].t);
    // The outage 3-3.75 h before the real data is in it, scaled to the real 3 ms.
    try testing.expectEqual(0, t.history[m.slot(hour + 600 - 3 * 3600 - 600)].recv);
    const calm = t.history[m.slot(hour + 600 - 3600)];
    try testing.expect(calm.recv > 0 and calm.rtt_us >= 3000 and calm.rtt_us < 10_000);
    // Later fills keep the last full hour of real data, and this run's.
    for (11..70) |i| fakeCycle(&m, id, hour + 60 * @as(i64, @intCast(i)), 4);
    m.demoFillLocked(hour + 3600 + 540);
    try testing.expectEqual(hour + 600, m.demo_from); // max(hour, first cycle)
    try testing.expectEqual(4, t.history[m.slot(hour + 660)].recv); // real
    for (70..2 * 60 + 10) |i| fakeCycle(&m, id, hour + 60 * @as(i64, @intCast(i)), 4);
    m.demoFillLocked(hour + 2 * 3600 + 540);
    try testing.expectEqual(hour + 3600, m.demo_from);
    try testing.expectEqual(4, t.history[m.slot(hour + 3600)].recv); // real
    // A cycle that does not divide the hour still finds the real samples.
    m.cycle_s = 7;
    const base: i64 = 7 * 242_858_000; // cycle starts are multiples of cycle_s
    m.demo_since = base;
    m.demo_hour = 0;
    const now = base + 7 * 1000; // two hour boundaries later
    for (0..1001) |i| fakeCycle(&m, id, base + 7 * @as(i64, @intCast(i)), 5);
    m.demoFillLocked(now);
    try testing.expectEqual(0, @mod(m.demo_from, 7));
    const calm7 = t.history[m.slot(m.demo_from - 7 * 300)];
    try testing.expect(calm7.recv > 0 and calm7.rtt_us >= 3000 and calm7.rtt_us < 10_000);
}

test "tags: validated, normalized, saved, loaded and served" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [2][128]u8 = undefined;
    const dir = try std.mem.print(&buf[0], ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const config = try std.mem.print(&buf[1], "{s}/targets.json", .{dir});

    var m: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config };
    defer m.deinit();
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{"two words"}));
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{"a,b"}));
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{""}));
    const long: [max_tag_len + 1]u8 = @splat('x');
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &.{&long}));
    const many: [max_tags + 1][]const u8 = @splat("t");
    try testing.expectError(error.InvalidTags, m.add("a", "192.0.2.1", &many));
    try testing.expectEqual(0, m.targets.items.len);

    const id = try m.add("a", "192.0.2.1", &.{ "DNS", "praha-1", "dns" });
    const t = m.targets.items[0];
    try testing.expectEqual(2, t.tags.len);
    try testing.expectEqualStrings("dns", t.tags[0]);
    try testing.expectEqualStrings("praha-1", t.tags[1]);

    try testing.expectError(error.UnknownTarget, m.setTags(id + 1, &.{"x"}));
    try testing.expectError(error.InvalidTags, m.setTags(id, &.{"a b"}));
    try testing.expectEqual(2, t.tags.len); // unchanged
    const before = m.version;
    try m.setTags(id, &.{ "ipv6", "Core" });
    try testing.expect(m.version != before);
    _ = try m.add("b", "192.0.2.2", &.{});

    // Saved with the list (only when there are any), loaded back.
    const saved = try tmp.dir.readFileAlloc(testing.io, "targets.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.find(u8, saved, "\"tags\": [\"ipv6\",\"core\"]") != null);
    try testing.expectEqual(1, std.mem.count(u8, saved, "\"tags\""));
    var m2: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config };
    defer m2.deinit();
    try m2.loadConfig();
    try testing.expectEqualStrings("core", m2.targets.items[0].tags[1]);
    try testing.expectEqual(0, m2.targets.items[1].tags.len);

    // Served in the state, an empty list included.
    const state = try m2.state();
    defer state.release();
    try testing.expect(std.mem.find(u8, state.json, "\"tags\":[\"ipv6\",\"core\"]") != null);
    try testing.expect(std.mem.find(u8, state.json, "\"tags\":[]") != null);

    // A hand-written list with a bad tag is refused, like a bad host.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "targets.json", .data = "{\"targets\":[{\"name\":\"a\",\"host\":\"192.0.2.1\",\"tags\":[\"a b\"]}]}" });
    var m3: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = config };
    defer m3.deinit();
    try testing.expectError(error.InvalidTags, m3.loadConfig());
}

test "edit: rename, move to another host, refuse bad input" {
    var m = testMonitor();
    defer m.deinit();
    const id = try m.add("a", "192.0.2.1", &.{});
    const t = m.targets.items[0];
    fakeCycle(&m, id, 60, 0);
    try m.apply(id, .ack);

    try testing.expectError(error.InvalidName, m.edit(id, "", null, null));
    try testing.expectError(error.InvalidHost, m.edit(id, null, "not a host", null));
    try testing.expectError(error.UnknownTarget, m.edit(id + 1, "b", null, null));
    // All or nothing: a bad tag keeps the good name out too.
    try testing.expectError(error.InvalidTags, m.edit(id, "b", null, &.{"a b"}));
    try testing.expectEqualStrings("a", t.name);

    // A new name keeps everything else.
    try m.edit(id, "router", null, null);
    try testing.expectEqualStrings("router", t.name);
    try testing.expect(t.acked);
    try testing.expectEqual(.down, t.status());
    // The same host again changes nothing.
    try m.edit(id, null, "192.0.2.1", null);
    try testing.expect(t.acked);

    // A new host: history kept, status and acknowledgement not; tags with it.
    try m.edit(id, null, "192.0.2.2", &.{"IPv4"});
    try testing.expectEqualStrings("ipv4", t.tags[0]);
    try testing.expectEqualStrings("192.0.2.2", t.host);
    try testing.expectEqual(.pending, t.status());
    try testing.expect(!t.acked);
    try testing.expectEqual(60, t.history[m.slot(60)].t);

    // A cycle that probed the old host does not land on the new one.
    m.mutex.lockUncancelable(m.io);
    var job: Job = .{ .id = id, .host = "192.0.2.1", .sent = probes_per_cycle, .replies = 5 };
    m.recordLocked(t, 120, &job);
    m.mutex.unlock(m.io);
    try testing.expectEqual(.pending, t.status());
    try testing.expectEqual(0, t.history[m.slot(120)].t);
}

test "names and hosts are validated" {
    var m = testMonitor();
    defer m.deinit();
    try testing.expectError(error.InvalidName, m.add("", "192.0.2.1", &.{}));
    try testing.expectError(error.InvalidName, m.add("a\nb", "192.0.2.1", &.{}));
    try testing.expectError(error.InvalidHost, m.add("a", "not a host", &.{}));
    _ = try m.add("v6", "2001:db8::1", &.{});
    _ = try m.add("dns", "example.com", &.{});
}

test "DNS cache: TTL bounds, a kept address stays, stale while DNS is down, NXDOMAIN drops it" {
    const ip = struct {
        fn of(text: []const u8) netaddr.Ip {
            return netaddr.parseIp(text).?;
        }
    }.of;
    const policy: DnsPolicy = .{ .now = 1000, .stale_s = 3600 };
    var ips = [_]netaddr.Ip{ ip("192.0.2.1"), ip("192.0.2.2") };

    // First answer: its first address; the TTL is held within bounds.
    var job: Job = .{ .id = 1, .host = "example.com" };
    settleAnswer(&job, .{ .ips = &ips, .ttl_s = 5 }, policy);
    try testing.expect(job.addr.?.toIp().eql(ip("192.0.2.1")));
    try testing.expectEqual(1000 + min_ttl_s, job.expires);
    job = .{ .id = 1, .host = "example.com" };
    settleAnswer(&job, .{ .ips = &ips, .ttl_s = 86400 }, policy);
    try testing.expectEqual(1000 + max_ttl_s, job.expires);
    job = .{ .id = 1, .host = "example.com" };
    settleAnswer(&job, .{ .ips = &ips, .ttl_s = null }, policy);
    try testing.expectEqual(1000 + default_ttl_s, job.expires);

    // The cached address is still in the answer: it stays, whatever the order.
    job = .{ .id = 1, .host = "example.com", .cached = .fromIp(ip("192.0.2.2")) };
    settleAnswer(&job, .{ .ips = &ips, .ttl_s = 300 }, policy);
    try testing.expect(job.addr.?.toIp().eql(ip("192.0.2.2")));
    try testing.expectEqual(1000, job.confirmed);

    // No answer: the cached address while it is young enough, else nothing.
    job = .{ .id = 1, .host = "example.com", .cached = .fromIp(ip("192.0.2.2")), .confirmed = 1000 - 3600 };
    settleFailure(&job, error.Timeout, policy);
    try testing.expect(job.addr.?.toIp().eql(ip("192.0.2.2")));
    try testing.expectEqualStrings("Timeout", job.dns_error.?);
    try testing.expect(job.err == null);
    try testing.expectEqual(1000 + retry_s, job.expires);
    job = .{ .id = 1, .host = "example.com", .cached = .fromIp(ip("192.0.2.2")), .confirmed = 1000 - 3601 };
    settleFailure(&job, error.Timeout, policy);
    try testing.expect(job.addr == null and job.err != null);
    job = .{ .id = 1, .host = "example.com", .cached = .fromIp(ip("192.0.2.2")), .confirmed = 1000 };
    settleFailure(&job, error.Timeout, .{ .now = 1000, .stale_s = 0 }); // --dns-stale 0
    try testing.expect(job.addr == null);

    // One family failed and the kept address is of that family: stale, not moved.
    job = .{ .id = 1, .host = "example.com", .cached = .fromIp(ip("2001:db8::1")), .confirmed = 1000 };
    settleAnswer(&job, .{ .ips = &ips, .ttl_s = 300, .partial = true }, policy);
    try testing.expect(job.addr.?.toIp().eql(ip("2001:db8::1")));
    try testing.expectEqualStrings("PartialAnswer", job.dns_error.?);
    try testing.expect(!job.dns_failed);
    // ... but if it is still in the answer, the answer stands.
    job = .{ .id = 1, .host = "example.com", .cached = .fromIp(ip("192.0.2.2")), .confirmed = 1000 };
    settleAnswer(&job, .{ .ips = &ips, .ttl_s = 300, .partial = true }, policy);
    try testing.expect(job.dns_error == null);

    // An empty answer is authoritative: no stale address for it.
    job = .{ .id = 1, .host = "example.com", .cached = .fromIp(ip("192.0.2.2")), .confirmed = 1000 };
    settleAnswer(&job, .{ .ips = &.{}, .ttl_s = 900 }, policy);
    try testing.expect(job.addr == null and job.err != null and job.dns_failed);
}

test "DNS cache: the target keeps the address, its state follows the lookups, a new host resets it" {
    var m = testMonitor();
    defer m.deinit();
    events.level = .err; // the dns events
    defer events.level = .info;
    const id = try m.add("a", "example.com", &.{});
    const t = m.targets.items[0];
    const a1: icmp.Addr = .fromIp(netaddr.parseIp("192.0.2.1").?);

    var job: Job = .{ .id = id, .host = t.host, .looked_up = true, .addr = a1, .confirmed = 60, .expires = 360 };
    Monitor.recordDnsLocked(t, &job);
    try testing.expectEqual(.ok, t.dns);
    try testing.expectEqual(360, t.addr_expires);
    // Due only once the answer expired.
    try testing.expect(t.addr != null);

    job = .{ .id = id, .host = t.host, .looked_up = true, .addr = a1, .dns_error = "Timeout", .expires = 420 };
    Monitor.recordDnsLocked(t, &job);
    try testing.expectEqual(.stale, t.dns);
    try testing.expectEqual(60, t.addr_confirmed); // not confirmed by a failure

    // The probe failing (no ICMP socket) is not a DNS failure.
    job = .{ .id = id, .host = t.host, .looked_up = true, .addr = a1, .confirmed = 420, .expires = 480, .err = "cannot open ICMP socket" };
    Monitor.recordDnsLocked(t, &job);
    try testing.expectEqual(.ok, t.dns);
    job = .{ .id = id, .host = t.host, .looked_up = true, .err = "name does not resolve", .dns_error = "NoAddress", .dns_failed = true, .expires = 480 };
    Monitor.recordDnsLocked(t, &job);
    try testing.expectEqual(.failed, t.dns);
    try testing.expect(t.addr == null);

    // A cycle that only reused the cache changes nothing.
    t.addr = a1;
    job = .{ .id = id, .host = t.host, .addr = a1 };
    Monitor.recordDnsLocked(t, &job);
    try testing.expectEqual(.failed, t.dns);

    try m.edit(id, null, "example.org", null);
    try testing.expect(t.addr == null);
    try testing.expectEqual(.ok, t.dns);
    try testing.expectEqual(0, t.addr_expires);
    try testing.expect(m.addressOf("example.org") == null);
}
