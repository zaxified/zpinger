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
//! in README.md, "Security log"; they are a contract, change them only
//! with a changelog entry. Values that come from a client are quoted and
//! escaped (`"` and `\` with a backslash, every byte outside printable
//! ASCII as `\xNN`) and cut at `max_value_len` (marked `...`): a request can
//! neither forge a second line nor write bytes a parser chokes on.
//!
//! Anything a client can make happen is rate-limited, per client (an IPv6
//! /64) and in total, so a flood can neither fill the journal nor bury
//! other clients' events; what is dropped is counted and reported as
//! `event=log action=dropped` every `flush_interval_s`.

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
    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    writeLine(w, lvl, @tagName(scope), format, args) catch {};
    w.flush() catch {};
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
/// Returns whether the line was written (false: rate-limited).
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
    logFn(lvl, .event, "{s}", .{w.buffered()});
    return true;
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
        if (n > 0) _ = emit(.warn, .log, .system, null, "action=dropped class={t} count={d}", .{ class, n });
    }
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
