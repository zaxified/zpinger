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
const datefmt = @import("datefmt");
const ratelimit = @import("ratelimit");
const accesslog = @import("accesslog");

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
    _ = sink_users.fetchAdd(1, .acquire);
    if (queue_on.load(.acquire)) {
        const queued = sink.log(line);
        _ = sink_users.fetchSub(1, .release);
        if (queued) return true;
        _ = dropped.getPtr(class).fetchAdd(1, .monotonic);
        return false;
    }
    _ = sink_users.fetchSub(1, .release);
    var sbuf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&sbuf);
    defer std.debug.unlockStderr();
    const sw = &stderr.file_writer.interface;
    sw.writeAll(line) catch {};
    sw.flush() catch {};
    return true;
}

// ----- the queue ------------------------------------------------------------------

/// Lines wait here for the writer task, so that no thread ever blocks on
/// stderr: under systemd it is a socket to journald, and when journald
/// falls behind a write blocks. The accept loop emits refusals, and a
/// blocked write there would stop the server accepting anything. When the
/// queue is full, lines are dropped and counted like rate-limited ones.
/// (zig-libs accesslog `AsyncSink`.)
const queue_size = 64 * 1024;
var sink: accesslog.AsyncSink = undefined;
var queue_on: std.atomic.Value(bool) = .init(false);
/// Threads inside `sink.log`: `stopQueue` waits for them before it frees
/// the sink.
var sink_users: std.atomic.Value(u32) = .init(0);

/// Starts the queue and its writer task; from now on `put` queues lines for
/// `w`. Without room for the queue (or a task) lines keep going straight to
/// stderr.
fn startQueue(gpa: std.mem.Allocator, io: Io, w: *Io.Writer) void {
    sink.init(gpa, io, w, .{ .max_bytes = queue_size, .max_lines = 4096 }) catch return;
    queue_on.store(true, .release);
}

/// Writes out what is queued; from now on lines go straight to stderr.
/// Callable from any thread (before an exit), and twice.
pub fn stopQueue() void {
    if (!queue_on.swap(false, .acq_rel)) return;
    while (sink_users.load(.acquire) != 0) std.atomic.spinLoopHint();
    sink.deinit(); // drains
}

var stderr_buf: [4096]u8 = undefined;
var stderr_writer: Io.File.Writer = undefined;

/// Writes the queued lines to stderr until canceled; while it runs, no
/// log call writes stderr itself. Lines queued at cancelation are written
/// before it returns, later ones go straight to stderr again.
pub fn writeLoop(gpa: std.mem.Allocator, io: Io) Io.Cancelable!void {
    stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
    startQueue(gpa, io, &stderr_writer.interface);
    defer stopQueue();
    while (true) try io.sleep(.fromSeconds(3600), .awake);
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
    var buf: [datefmt.rfc3339_max_len]u8 = undefined;
    // A clock outside years 0..9999 has no RFC 3339 form: the epoch stands in.
    const text = datefmt.bufRfc3339(&buf, datefmt.unixToParts(unix_s), 0) catch "1970-01-01T00:00:00Z";
    try w.writeAll(text);
}

// ----- events ---------------------------------------------------------------------

/// The `event=` of a line.
pub const Kind = enum {
    /// Started (the settings that matter for security).
    start,
    /// Stopping on SIGTERM or SIGINT, the history written.
    stop,
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

    /// Always quoted, every byte outside printable ASCII as `\xNN`, cut at
    /// `max_value_len` and marked (zig-libs accesslog `writeLogfmtValue`).
    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        try accesslog.writeLogfmtValue(w, q.s, .{ .quote = .always, .escape = .hex_x, .max_len = max_value_len, .cut_marker = "..." });
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

/// The per-client key: the address (IPv4 as IPv4-mapped), an IPv6 one cut
/// to its /64, the prefix one subscriber gets. Also a trace's viewer.
pub fn keyOf(ip: netaddr.Ip) [16]u8 {
    const u = ip.unmap();
    return switch (u) {
        .v4 => u.as16(),
        .v6 => u.key(64),
    };
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

/// Tests: a destination for the queue that keeps what it gets and can be
/// held shut (the writer task then stalls, as on a journal that fell behind).
pub const TestCapture = struct {
    interface: Io.Writer,
    out: std.ArrayList(u8) = .empty,
    open: std.atomic.Value(bool) = .init(true),
    /// Bytes at the front of `out` that `take` already returned.
    served: usize = 0,

    pub fn start(c: *TestCapture) void {
        c.* = .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} } };
        startQueue(testing.allocator, testing.io, &c.interface);
    }

    /// Writes out the queue; the capture is closed after this.
    pub fn stop(c: *TestCapture) void {
        c.open.store(true, .release);
        stopQueue();
        c.out.deinit(testing.allocator);
    }

    /// The lines written since the last call (waits for the writer; open it first).
    pub fn take(c: *TestCapture) []const u8 {
        sink.flush();
        // What the last call returned is dropped now, not before it is read
        // (clearing poisons the memory in safe builds).
        c.out.replaceRange(testing.allocator, 0, c.served, &.{}) catch unreachable;
        c.served = c.out.items.len;
        return c.out.items;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const c: *TestCapture = @alignCast(@fieldParentPtr("interface", w));
        while (!c.open.load(.acquire)) std.Thread.yield() catch {};
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            c.out.appendSlice(testing.allocator, d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| c.out.appendSlice(testing.allocator, last) catch return error.WriteFailed;
        return n + last.len * splat;
    }
};

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
    var cap: TestCapture = undefined;
    cap.start();
    defer cap.stop();
    _ = dropped.getPtr(.system).swap(0, .monotonic);
    try testing.expect(emit(.warn, .log, .system, null, "x={d}", .{1}));
    try testing.expect(std.mem.endsWith(u8, cap.take(), "event=log x=1\n"));
    // The destination stalls: lines queue up to the bound, then are dropped.
    cap.open.store(false, .release);
    const long: [3000]u8 = @splat('a');
    var queued: usize = 0;
    while (emit(.warn, .log, .system, null, "{s}", .{&long})) : (queued += 1) try testing.expect(queued < 100);
    try testing.expect(queued >= queue_size / 4000);
    try testing.expectEqual(1, dropped.getPtr(.system).load(.monotonic));
    while (emit(.warn, .log, .system, null, "x", .{})) {} // the rest, to the last byte that fits
    try testing.expectEqual(2, dropped.getPtr(.system).load(.monotonic));
    flushDropped(); // no room (the report is longer than "x"): kept, plus the report's own drop
    try testing.expectEqual(3, dropped.getPtr(.system).load(.monotonic));
    cap.open.store(true, .release);
    _ = cap.take();
    flushDropped();
    try testing.expect(std.mem.endsWith(u8, cap.take(), "action=dropped class=system count=3\n"));
    try testing.expectEqual(0, dropped.getPtr(.system).load(.monotonic));
}

test "quote: byte for byte what the own escaper wrote before zig-libs writeLogfmtValue" {
    // The escaper this module had (a log-parser contract, doc/security-log.md).
    const Old = struct {
        fn write(w: *Io.Writer, v: []const u8) Io.Writer.Error!void {
            try w.writeByte('"');
            const cut = v.len > max_value_len;
            for (v[0..@min(v.len, max_value_len)]) |c| switch (c) {
                '"', '\\' => try w.print("\\{c}", .{c}),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
                else => try w.print("\\x{x:0>2}", .{c}),
            };
            if (cut) try w.writeAll("...");
            try w.writeByte('"');
        }
    };
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    const exact: [max_value_len]u8 = @splat('e');
    const one_over: [max_value_len + 1]u8 = @splat('o');
    const many: [3 * max_value_len]u8 = @splat('"'); // escapes double the size past the cut
    const cases = [_][]const u8{ "", "plain", "a b", "\"", "\\", "a=b", "\n\r\t\x00\x1f\x7f", &all, "\xc3\xa9", &exact, &one_over, &many };
    for (cases) |v| {
        var a: [4096]u8 = undefined;
        var b: [4096]u8 = undefined;
        var wa: Io.Writer = .fixed(&a);
        var wb: Io.Writer = .fixed(&b);
        try Old.write(&wa, v);
        try wb.print("{f}", .{quote(v)});
        try testing.expectEqualStrings(wa.buffered(), wb.buffered());
    }
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
