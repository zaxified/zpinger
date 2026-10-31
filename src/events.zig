//! Logging: the process's log function, and security and audit events.
//!
//! Every line goes to stderr. Under systemd (`JOURNAL_STREAM` set) a line
//! starts with its syslog priority (`<4>`), which journald turns into the
//! entry's priority (`journalctl -p warning`); elsewhere it starts with a UTC
//! timestamp and the level.
//!
//! An event is one line in a fixed shape, for people and for log parsers
//! (CrowdSec, see deploy/crowdsec/):
//!
//!     event=<kind> client=<address> [peer=<address>] key=value ...
//!
//! `client` is the address the request is attributed to: the socket peer,
//! or behind a reverse proxy on loopback the address it forwarded;
//! `peer` follows only when it differs. Keys and reason codes are listed
//! in doc/security-log.md; they are a contract, change them only
//! with a changelog entry. Values that come from a client are quoted and
//! escaped (`"` and `\` with a backslash, every byte outside printable
//! ASCII as `\xNN`) and cut at `max_value_len` (marked `...`): a request can
//! neither forge a second line nor write bytes a parser chokes on.
//!
//! Anything a client can make happen is rate-limited, per client (an IPv6
//! /64) and in total, so a flood can neither fill the journal nor bury
//! other clients' events. No thread waits for stderr: lines go through a
//! queue that `writeLoop` writes out. What is dropped, by a rate limit or
//! a full queue, is counted and reported as `event=log action=dropped`
//! every `flush_interval_s`.

const std = @import("std");
const Io = std.Io;
const netaddr = @import("netaddr");
const ratelimit = @import("ratelimit");

/// Lines below this level are not written (`--log-level`).
pub var level: std.log.Level = .info;
/// Stderr is the journal: write syslog priorities instead of timestamps.
pub var journal = false;

/// `std.Options.logFn`.
pub fn logFn(
    comptime lvl: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(lvl) > @backingInt(level)) return;
    _ = put(lvl, scope, .system, format, args);
}

/// The longest line; a longer one is cut, marked ` ...`.
const max_line = 4096 + 64;

/// Writes one line: into the queue while `writeLoop` runs, else straight
/// to stderr. Returns false when the queue was full (the line is counted
/// as dropped in `class`).
fn put(
    comptime lvl: std.log.Level,
    comptime scope: @EnumLiteral(),
    class: Class,
    comptime format: []const u8,
    args: anytype,
) bool {
    var buf: [max_line]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    writeLine(&w, lvl, @tagName(scope), format, args) catch {
        w.end = buf.len - 5;
        @memcpy(buf[w.end..][0..5], " ...\n");
        w.end = buf.len;
    };
    const line = w.buffered();
    if (queue_on.load(.acquire)) {
        if (enqueue(line)) return true;
        _ = dropped.getPtr(class).fetchAdd(1, .monotonic);
        return false;
    }
    var sbuf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&sbuf);
    defer std.debug.unlockStderr();
    const sw = &stderr.file_writer.interface;
    sw.writeAll(line) catch {};
    sw.flush() catch {};
    return true;
}

// ----- the queue ------------------------------------------------------------------

/// Lines wait here for `writeLoop`, so that no thread ever blocks on
/// stderr: under systemd it is a socket to journald, and when journald
/// falls behind a write blocks. The accept loop emits refusals, and a
/// blocked write there would stop the server accepting anything. When the
/// queue is full, lines are dropped and counted like rate-limited ones.
const queue_size = 64 * 1024;
var queue_buf: [queue_size]u8 = undefined;
var queue_len: usize = 0;
var queue_lock: std.atomic.Mutex = .unlocked;
/// Bumped on every enqueue; `writeLoop` sleeps on it.
var queue_seq: std.atomic.Value(u32) = .init(0);
var queue_on: std.atomic.Value(bool) = .init(false);
/// What `writeLoop` writes out, taken from the queue in one piece.
/// Guarded by the stderr lock (`flushQueue`).
var out_buf: [queue_size]u8 = undefined;

fn enqueue(line: []const u8) bool {
    {
        while (!queue_lock.tryLock()) std.atomic.spinLoopHint();
        defer queue_lock.unlock();
        if (queue_size - queue_len < line.len) return false;
        @memcpy(queue_buf[queue_len..][0..line.len], line);
        queue_len += line.len;
    }
    _ = queue_seq.fetchAdd(1, .release);
    std.Options.debug_io.futexWake(u32, &queue_seq.raw, 1);
    return true;
}

/// Takes what is queued into `out_buf`; the caller holds the stderr lock.
fn take() []const u8 {
    while (!queue_lock.tryLock()) std.atomic.spinLoopHint();
    defer queue_lock.unlock();
    const n = queue_len;
    @memcpy(out_buf[0..n], queue_buf[0..n]);
    queue_len = 0;
    return out_buf[0..n];
}

/// Writes out what is queued; returns whether there was anything.
fn flushQueue() bool {
    var sbuf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&sbuf);
    defer std.debug.unlockStderr();
    const lines = take();
    if (lines.len == 0) return false;
    const sw = &stderr.file_writer.interface;
    sw.writeAll(lines) catch {};
    sw.flush() catch {};
    return true;
}

/// Writes out what is queued; from now on lines go straight to stderr.
/// Callable from any thread (before an exit).
pub fn stopQueue() void {
    queue_on.store(false, .release);
    _ = flushQueue();
}

/// Writes the queued lines to stderr until canceled; while it runs, no
/// log call writes stderr itself. Lines queued at cancelation are written
/// before it returns, later ones go straight to stderr again.
pub fn writeLoop(io: Io) Io.Cancelable!void {
    queue_on.store(true, .release);
    defer stopQueue();
    while (true) {
        const seen = queue_seq.load(.acquire);
        if (flushQueue()) continue;
        try io.futexWait(u32, &queue_seq.raw, seen);
    }
}

fn writeLine(w: *Io.Writer, comptime lvl: std.log.Level, scope: []const u8, comptime format: []const u8, args: anytype) Io.Writer.Error!void {
    if (journal) {
        // sd-daemon(3) priorities: err 3, warning 4, info 6, debug 7.
        try w.print("<{d}>{s}: ", .{ @as(u8, switch (lvl) {
            .err => 3,
            .warn => 4,
            .info => 6,
            .debug => 7,
        }), scope });
    } else {
        try writeTime(w, Io.Clock.real.now(std.Options.debug_io).toSeconds());
        try w.print(" {s} {s}: ", .{ @tagName(lvl), scope });
    }
    try w.print(format ++ "\n", args);
}

/// RFC 3339, UTC, whole seconds.
fn writeTime(w: *Io.Writer, unix_s: i64) Io.Writer.Error!void {
    const secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix_s, 0)) };
    const year_day = secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = secs.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,         month_day.month.numeric(), @as(u32, month_day.day_index) + 1,
        day.getHoursIntoDay(), day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
    });
}

// ----- events ---------------------------------------------------------------------

/// The `event=` of a line.
pub const Kind = enum {
    /// Started (the settings that matter for security), or stopping.
    start,
    /// A connection refused at accept, or closed before it sent a request.
    conn,
    /// A request: refused ones always, the rest with `--access-log all`.
    http,
    /// A change to the targets (a writable instance).
    audit,
    /// A live trace started, joined, left, or ended.
    trace,
    /// A target's name stopped resolving, resolves again, or moved.
    dns,
    /// Lines dropped by the rate limits.
    log,
};

/// Who an event is about: `client`, and the socket `peer` when they differ.
pub const Who = struct {
    client: netaddr.Ip,
    peer: ?netaddr.Ip = null,

    pub fn of(peer: netaddr.Ip) Who {
        return .{ .client = peer };
    }
};

/// Rate-limit classes, each with its own budgets, so one kind of line
/// cannot crowd out another: `.client` refusals and traces, `.conn`
/// connection events, `.access` requests that were answered (with
/// `--access-log all`), `.writer` changes on a writable instance; `.system`
/// events come from the daemon itself, bounded by its own work.
pub const Class = enum { client, conn, access, writer, system };

/// Emits `event=<kind> [client=... [peer=...]] <fields>`, where `fields` is
/// `format` with `args` (use `quote` for any text a client chose).
/// Returns whether the line was written (false: rate-limited, or the queue
/// was full).
pub fn emit(
    comptime lvl: std.log.Level,
    comptime kind: Kind,
    class: Class,
    who: ?Who,
    comptime format: []const u8,
    args: anytype,
) bool {
    if (@backingInt(lvl) > @backingInt(level)) return false;
    if (!admit(class, who)) return false;
    // Room for every value at its longest, escaped (4x `max_value_len`).
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    writeEvent(&w, @tagName(kind), who, format, args) catch {
        // Cut at the buffer, marked; the line stays one line, but the
        // fields past the cut are lost (the parsed ones come first).
        w.end = buf.len - 4;
        @memcpy(buf[w.end..][0..4], " ...");
        w.end = buf.len;
    };
    return put(lvl, .event, class, "{s}", .{w.buffered()});
}

fn writeEvent(w: *Io.Writer, kind: []const u8, who: ?Who, comptime format: []const u8, args: anytype) Io.Writer.Error!void {
    try w.print("event={s}", .{kind});
    if (who) |x| {
        try w.print(" client={f}", .{x.client});
        if (x.peer) |p| if (!p.eql(x.client)) try w.print(" peer={f}", .{p});
    }
    if (format.len > 0) try w.print(" " ++ format, args);
}

/// The longest value written; longer ones are cut and end in `...`.
pub const max_value_len = 200;

/// A quoted, escaped value for client-chosen text: `{f}`.
pub fn quote(s: []const u8) Quoted {
    return .{ .s = s };
}

pub const Quoted = struct {
    s: []const u8,

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('"');
        const cut = q.s.len > max_value_len;
        for (q.s[0..@min(q.s.len, max_value_len)]) |c| switch (c) {
            '"', '\\' => try w.print("\\{c}", .{c}),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
            else => try w.print("\\x{x:0>2}", .{c}),
        };
        if (cut) try w.writeAll("...");
        try w.writeByte('"');
    }
};

// ----- rate limits ----------------------------------------------------------------

/// Per client (a /64 for IPv6) and class: a burst of 20, then 2 lines a
/// second. `key` only matters to ratelimit's middleware; keys are given here.
const per_client: ratelimit.Options = .{ .rate_per_s = 2, .burst = 20, .max_keys = 4096, .key = .forwarded_ip };
/// In total, per class: a burst, then a steady rate.
const totals = std.EnumArray(Class, ?ratelimit.TokenBucket.Config).init(.{
    .client = .{ .rate_per_s = 50, .burst = 500 },
    .conn = .{ .rate_per_s = 50, .burst = 500 },
    .access = .{ .rate_per_s = 100, .burst = 1000 },
    .writer = .{ .rate_per_s = 10, .burst = 200 },
    .system = null,
});
/// How often dropped lines are reported.
pub const flush_interval_s = 10;

var lock: std.atomic.Mutex = .unlocked;
var buckets: std.EnumArray(Class, ratelimit.TokenBucket) = .initFill(.{ .tokens = 0, .updated_ns = 0 });
var started = false;
var clients: std.EnumArray(Class, ?ratelimit.Limiter) = .initFill(null);
var dropped: std.EnumArray(Class, std.atomic.Value(u64)) = .initFill(.init(0));

/// Sets up the per-client limit; without it only the totals apply.
pub fn init(gpa: std.mem.Allocator) void {
    for (std.enums.values(Class)) |class| if (totals.get(class) != null) clients.set(class, .init(gpa, per_client));
}

pub fn deinit() void {
    for (&clients.values) |*c| if (c.*) |*l| {
        l.deinit();
        c.* = null;
    };
}

/// Whether stderr is the journal: `JOURNAL_STREAM` (`device:inode`, set by
/// systemd) names the file stderr is (systemd.exec(5)); a variable merely
/// inherited by a shell on a terminal does not.
pub fn stderrIsJournal(journal_stream: ?[]const u8) bool {
    const value = journal_stream orelse return false;
    const colon = std.mem.findScalar(u8, value, ':') orelse return false;
    const dev = std.fmt.parseInt(u64, value[0..colon], 10) catch return false;
    const ino = std.fmt.parseInt(u64, value[colon + 1 ..], 10) catch return false;
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(2, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &st)) != .SUCCESS) return false;
    return makedev(st.dev_major, st.dev_minor) == dev and st.ino == ino;
}

/// The `st_dev` number of a major:minor pair (glibc's `makedev`).
fn makedev(major: u64, minor: u64) u64 {
    return ((major & 0xfffff000) << 32) | ((major & 0xfff) << 8) | ((minor & 0xffffff00) << 12) | (minor & 0xff);
}

test "journal check: only the stream systemd named" {
    try testing.expect(!stderrIsJournal(null));
    try testing.expect(!stderrIsJournal("garbage"));
    try testing.expect(!stderrIsJournal("1:1"));
    try testing.expectEqual(@as(u64, 0x00000801), makedev(8, 1));
}

fn nowNs() u64 {
    const ns = Io.Clock.awake.now(std.Options.debug_io).nanoseconds;
    return @intCast(@max(ns, 0));
}

fn admit(class: Class, who: ?Who) bool {
    const cfg = totals.get(class) orelse return true;
    const now = nowNs();
    if (who) |x| if (clients.getPtr(class).*) |*c| {
        const key = keyOf(x.client);
        if (!c.allowAt(&key, now).allowed) {
            _ = dropped.getPtr(class).fetchAdd(1, .monotonic);
            return false;
        }
    };
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    if (!started) {
        started = true;
        for (std.enums.values(Class)) |k| if (totals.get(k)) |c| buckets.set(k, .full(c, now));
    }
    if (buckets.getPtr(class).allowAt(cfg, now).allowed) return true;
    _ = dropped.getPtr(class).fetchAdd(1, .monotonic);
    return false;
}

/// The per-client key: the address, an IPv6 one cut to its /64.
fn keyOf(ip: netaddr.Ip) [16]u8 {
    var k = ip.as16();
    if (ip.unmap() == .v6) @memset(k[8..], 0);
    return k;
}

/// Reports what the rate limits dropped since the last call.
pub fn flushDropped() void {
    for (std.enums.values(Class)) |class| {
        const n = dropped.getPtr(class).swap(0, .monotonic);
        if (n == 0) continue;
        // The queue is full: report them next time.
        if (!emit(.warn, .log, .system, null, "action=dropped class={t} count={d}", .{ class, n }))
            _ = dropped.getPtr(class).fetchAdd(n, .monotonic);
    }
}

/// Tests: queue lines instead of writing them, for `takeForTest`.
pub fn captureForTest(on: bool) void {
    queue_len = 0;
    queue_on.store(on, .release);
}

/// Tests: the lines queued since the last call.
pub fn takeForTest() []const u8 {
    return take();
}

/// Calls `flushDropped` every `flush_interval_s` until canceled.
pub fn flushLoop(io: Io) Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromSeconds(flush_interval_s), .awake);
        flushDropped();
    }
}

// ----- tests ----------------------------------------------------------------------

const testing = std.testing;

test "quote: escapes, cuts, never breaks the line" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{quote("a \"b\"\\\n\r\x00\xff=x")});
    try testing.expectEqualStrings("\"a \\\"b\\\"\\\\\\x0a\\x0d\\x00\\xff=x\"", w.buffered());
    w.end = 0;
    const long: [max_value_len + 5]u8 = @splat('a');
    try w.print("{f}", .{quote(&long)});
    try testing.expectEqual(max_value_len + 5, w.buffered().len); // 2 quotes + "..."
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "a...\""));
}

test "event line: kind, client, peer only when it differs" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const client = netaddr.parseIp("198.51.100.7").?;
    const proxy = netaddr.parseIp("127.0.0.1").?;
    try writeEvent(&w, "http", .{ .client = client, .peer = proxy }, "status={d} path={f}", .{ 429, quote("/x y") });
    try testing.expectEqualStrings("event=http client=198.51.100.7 peer=127.0.0.1 status=429 path=\"/x y\"", w.buffered());
    w.end = 0;
    try writeEvent(&w, "conn", .of(client), "reason=x", .{});
    try testing.expectEqualStrings("event=conn client=198.51.100.7 reason=x", w.buffered());
}

test "queue: never blocks; a full queue drops and counts, the report waits for room" {
    captureForTest(true);
    defer captureForTest(false);
    _ = dropped.getPtr(.system).swap(0, .monotonic);
    try testing.expect(emit(.warn, .log, .system, null, "x={d}", .{1}));
    try testing.expect(std.mem.endsWith(u8, takeForTest(), "event=log x=1\n"));
    const long: [3000]u8 = @splat('a');
    try testing.expect(emit(.warn, .log, .system, null, "{s}", .{&long}));
    const line_len = takeForTest().len;
    var queued: usize = 0;
    while (emit(.warn, .log, .system, null, "{s}", .{&long})) queued += 1;
    try testing.expectEqual(queue_size / line_len, queued);
    while (emit(.warn, .log, .system, null, "x", .{})) {} // the rest, to the last byte that fits
    try testing.expectEqual(2, dropped.getPtr(.system).load(.monotonic));
    flushDropped(); // no room (the report is longer than "x"): kept, plus the report itself
    try testing.expectEqual(3, dropped.getPtr(.system).load(.monotonic));
    _ = takeForTest();
    flushDropped();
    try testing.expect(std.mem.endsWith(u8, takeForTest(), "action=dropped class=system count=3\n"));
    try testing.expectEqual(0, dropped.getPtr(.system).load(.monotonic));
}

test "time: RFC 3339 UTC" {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeTime(&w, 1_793_440_260);
    try testing.expectEqualStrings("2026-10-31T09:51:00Z", w.buffered());
}

test "rate limits: per client first, then the total; drops are counted" {
    init(testing.allocator);
    defer deinit();
    const a = Who.of(netaddr.parseIp("2001:db8::1").?);
    const same64 = Who.of(netaddr.parseIp("2001:db8::2").?);
    const b = Who.of(netaddr.parseIp("192.0.2.1").?);
    _ = dropped.getPtr(.client).swap(0, .monotonic);
    var allowed: usize = 0;
    for (0..per_client.burst + 10) |i| {
        if (admit(.client, if (i % 2 == 0) a else same64)) allowed += 1;
    }
    try testing.expectEqual(per_client.burst, allowed); // one /64, one budget
    try testing.expect(admit(.client, b)); // another client is not affected
    try testing.expectEqual(10, dropped.getPtr(.client).load(.monotonic));
    try testing.expect(admit(.system, null)); // never limited
}
