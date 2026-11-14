// SPDX-License-Identifier: MIT

//! What zpinger reads from outside, fuzzed with zig-libs testkit's
//! deterministic driver, each harness generic over its source of choices
//! (`fn(comptime S, *S, gpa)`):
//!
//!   - `history`: a history file (valid, with bytes damaged, numbers swapped
//!     for extremes, maybe cut short) through `Monitor.loadHistoryBytes`,
//!     then the state served from what it loaded;
//!   - `targets`: a targets file, damaged the same way, through
//!     `Monitor.loadConfigBytes`;
//!   - `api`: requests to a writable instance (every route but the traces,
//!     which would start real probing), bodies and query numbers damaged,
//!     Host and X-Forwarded-For varied, through the whole HTTP server.
//!
//! Every input must end in an answer or a refusal: no crash, no leak (the
//! driver's allocator finds leaks), no 5xx, and the monitor's invariants
//! (target count, tags) kept.
//!
//! In every test run: 300 seeds of each, and every outcome reached. For a
//! verdict: `ZPINGER_FUZZ=<runs>[,<first seed>]` on the test binary (testkit:
//! `_MS`, `_SEEDFILE`, `_ONLY`, `_SHRINK`); scripts/release-check.sh runs it.
//! The test binary itself, not `zig build test`: a cached run step reads no
//! environment and runs nothing.

const std = @import("std");
const testing = std.testing;
const testkit = @import("testkit");
const driver = testkit.fuzz.driver;
const monitor_mod = @import("monitor.zig");
const Monitor = monitor_mod.Monitor;
const events = @import("events.zig");
const main = @import("main.zig");

pub const Label = enum { history_rejected, history_loaded, targets_rejected, targets_loaded, api_2xx, api_304, api_4xx };
var reach: [@typeInfo(Label).@"enum".field_names.len]usize = @splat(0);

fn mark(comptime l: Label) void {
    reach[@backingInt(l)] += 1;
    driver.hit(@tagName(l));
}

/// Numbers a damaged file or request may carry instead of a sane one.
const extremes = [_][]const u8{
    "-1",    "0",          "1",          "5",                   "6",                    "255",
    "256",   "4294967295", "4294967296", "9223372036854775807", "-9223372036854775808", "18446744073709551616",
    "1e308", "-0",         "0.5",        "null",                "\"x\"",                "[]",
    "{}",
};

/// `base` copied into `out` with a few edits: a byte set, a number swapped
/// for an extreme, a byte dropped; maybe cut short.
fn damage(comptime S: type, src: *S, out: []u8, base: []const u8) []u8 {
    @memcpy(out[0..base.len], base);
    var len = base.len;
    for (0..src.valueRangeAtMost(u8, 0, 4)) |_| {
        if (len == 0) break;
        const at = src.index(len);
        switch (src.valueRangeAtMost(u8, 0, 3)) {
            0 => out[at] = src.value(u8),
            1 => {
                const e = extremes[src.index(extremes.len)];
                // Over a run of digits from `at`, or inserted there.
                var end = at;
                while (end < len and (std.ascii.isDigit(out[end]) or out[end] == '-')) end += 1;
                if (len - (end - at) + e.len > out.len) continue;
                std.mem.copyBackwards(u8, out[at + e.len ..], out[end..len]);
                @memcpy(out[at..][0..e.len], e);
                len = len - (end - at) + e.len;
            },
            2 => {
                std.mem.copyForwards(u8, out[at .. len - 1], out[at + 1 .. len]);
                len -= 1;
            },
            else => {},
        }
    }
    if (len > 0 and src.valueRangeAtMost(u8, 0, 5) == 0) len = src.index(len) + 1;
    return out[0..len];
}

/// A fixed "now" on a cycle start, so a seed always means the same input.
const now: i64 = 1_800_000_000 - @mod(1_800_000_000, 60);

const history_base = std.fmt.comptimePrint(
    \\{{"cycle_s":60,"targets":[{{"id":1,"samples":[[{d},5,5,12000,300],[{d},5,4,15000],[{d},5,0,0,0]]}},
    \\{{"id":2,"samples":[[{d},5,5,900,70]]}},{{"id":9,"samples":[[{d},5,5,1,1]]}}]}}
, .{ now - 60, now - 120, now - 180, now - 60, now - 60 });

fn historyHarness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void {
    var m: Monitor = .{ .gpa = gpa, .io = testing.io, .config_path = "unused", .read_only = true, .demo = true };
    defer m.deinit();
    _ = try m.add("a", "192.0.2.1", &.{});
    _ = try m.add("b", "2001:db8::1", &.{"x"});
    m.targets.items[0].scenario = .steady;
    var buf: [history_base.len + 256]u8 = undefined;
    const input = damage(S, src, &buf, history_base);
    m.loadHistoryBytes(input, now) catch |err| switch (err) {
        error.InvalidHistory => return mark(.history_rejected),
        error.OutOfMemory => return err,
    };
    mark(.history_loaded);
    for (m.targets.items) |t| for (t.history) |s| {
        if (s.t == 0) continue;
        if (s.sent > monitor_mod.probes_per_cycle or s.recv > s.sent or @mod(s.t, m.cycle_s) != 0) return error.BadSampleLoaded;
    };
    // The state is served from what was loaded, whole and as a delta.
    const whole = try m.state(null);
    defer whole.release();
    const delta = try m.state(whole.tag.end - 60);
    defer delta.release();
    if (!try std.json.validate(gpa, whole.json)) return error.InvalidStateJson;
}

const targets_base =
    \\{"targets":[{"id":3,"name":"router","host":"192.0.2.1","tags":["lab","ipv4"],"paused":false,"acked":true},
    \\{"name":"dns","host":"dns.example","demo":"outage"},{"id":3,"name":"dup","host":"2001:db8::1"}]}
;

fn targetsHarness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void {
    var m: Monitor = .{ .gpa = gpa, .io = testing.io, .config_path = "unused", .read_only = true };
    defer m.deinit();
    m.max_targets = 3; // the limit, reached by the valid file
    var buf: [targets_base.len + 256]u8 = undefined;
    const input = damage(S, src, &buf, targets_base);
    m.loadConfigBytes(input) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return mark(.targets_rejected),
    };
    mark(.targets_loaded);
    try checkTargets(&m);
}

fn checkTargets(m: *Monitor) !void {
    if (m.targets.items.len > m.max_targets) return error.TooManyTargetsKept;
    for (m.targets.items) |t| {
        if (t.tags.len > monitor_mod.max_tags) return error.TooManyTags;
        for (t.tags) |tag| for (tag) |c| if (std.ascii.isUpper(c) or c == ' ' or c == ',') return error.TagNotNormalized;
        if (t.name.len == 0 or t.host.len == 0) return error.EmptyNameKept;
    }
}

const new_target = "{\"name\":\"n\",\"host\":\"192.0.2.9\",\"tags\":[\"Lab\",\"x\"]}";
const an_edit = "{\"name\":\"m\",\"host\":\"2001:db8::9\",\"tags\":[\"y\"]}";
const some_tags = "{\"tags\":[\"a\",\"B\",\"c\"]}";

/// Where an API run writes the target list.
var api_dir: ?testing.TmpDir = null;
var api_path_buf: [128]u8 = undefined;
var api_path: []const u8 = "";

fn apiHarness(comptime S: type, src: *S, gpa: std.mem.Allocator) anyerror!void {
    if (api_dir == null) {
        api_dir = testing.tmpDir(.{});
        api_path = try std.mem.print(&api_path_buf, ".zig-cache/tmp/{s}/targets.json", .{api_dir.?.sub_path});
    }
    var m: Monitor = .{ .gpa = gpa, .io = testing.io, .config_path = api_path };
    defer m.deinit();
    m.max_targets = 4;
    _ = try m.add("a", "192.0.2.1", &.{"x"});
    _ = try m.add("b", "2001:db8::1", &.{});
    const end = m.stateTag().end;
    const level = events.level;
    events.level = .err; // the refusals' event lines
    defer events.level = level;

    for (0..src.valueRangeAtMost(u8, 1, 4)) |_| {
        var wire_buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&wire_buf);
        var body_buf: [256]u8 = undefined;
        var body: []const u8 = "";
        const id: u64 = switch (src.valueRangeAtMost(u8, 0, 5)) {
            0 => 0,
            1 => 99,
            2 => std.math.maxInt(u64),
            else => src.valueRangeAtMost(u64, 1, 4),
        };
        const number = struct {
            fn pick(comptime T: type, s: *S, e: i64, b: *[32]u8) []const u8 {
                return switch (s.valueRangeAtMost(u8, 0, 3)) {
                    0 => extremes[s.index(extremes.len)],
                    1 => std.fmt.bufPrint(b, "{d}", .{e - 60 * @as(i64, s.valueRangeAtMost(u8, 0, 3))}) catch unreachable,
                    else => std.fmt.bufPrint(b, "{d}", .{s.value(T)}) catch unreachable,
                };
            }
        };
        var n1: [32]u8 = undefined;
        var n2: [32]u8 = undefined;
        switch (src.valueRangeAtMost(u8, 0, 9)) {
            0 => try w.print("GET /api/state?since={s} HTTP/1.1\r\n", .{number.pick(i64, src, end, &n1)}),
            1 => try w.print("GET /api/live?cycle={s}&from={s} HTTP/1.1\r\n", .{ number.pick(i64, src, end, &n1), number.pick(u32, src, 0, &n2) }),
            2 => {
                body = damage(S, src, &body_buf, new_target);
                try w.writeAll("POST /api/targets HTTP/1.1\r\n");
            },
            3 => {
                body = damage(S, src, &body_buf, an_edit);
                try w.print("PATCH /api/targets/{d} HTTP/1.1\r\n", .{id});
            },
            4 => {
                body = damage(S, src, &body_buf, some_tags);
                try w.print("POST /api/targets/{d}/tags HTTP/1.1\r\n", .{id});
            },
            5 => {
                body = "{}";
                const action = ([_][]const u8{ "pause", "resume", "ack", "unack", "nothing" })[src.index(5)];
                try w.print("POST /api/targets/{d}/{s} HTTP/1.1\r\n", .{ id, action });
            },
            6 => try w.print("DELETE /api/targets/{d} HTTP/1.1\r\n", .{id}),
            // (Not /healthz: 503 without a probing loop, and an error line.)
            7 => try w.print("GET {s} HTTP/1.1\r\n", .{([_][]const u8{ "/", "/app.js", "/favicon-down.svg", "/api/state", "/nope", "/style.css" })[src.index(6)]}),
            8 => {
                // A path of random printable bytes (never a trace: that would
                // start real probing).
                var p: [24]u8 = undefined;
                for (&p) |*c| c.* = src.valueRangeAtMost(u8, 0x21, 0x7e);
                if (std.mem.find(u8, &p, "trace") != null) p[0] = '/';
                try w.print("GET /{s} HTTP/1.1\r\n", .{p[0..src.valueRangeAtMost(u8, 0, 24)]});
            },
            else => try w.print("HEAD /api/state HTTP/1.1\r\nIf-None-Match: \"{d}-{d}\"\r\n", .{ m.stateTag().version, end }),
        }
        // A writable instance answers only to IP literals and localhost.
        switch (src.valueRangeAtMost(u8, 0, 4)) {
            0 => try w.writeAll("Host: evil.example\r\n"),
            1 => try w.writeAll("Host: localhost:8080\r\n"),
            else => try w.writeAll("Host: 127.0.0.1\r\n"),
        }
        if (src.valueRangeAtMost(u8, 0, 2) == 0) try w.writeAll("Accept-Encoding: gzip\r\n");
        switch (src.valueRangeAtMost(u8, 0, 4)) {
            0 => try w.writeAll("X-Forwarded-For: 2001:db8::7, 198.51.100.4\r\n"),
            1 => {
                var x: [16]u8 = undefined;
                for (&x) |*c| c.* = src.valueRangeAtMost(u8, 0x20, 0x7e);
                try w.print("X-Forwarded-For: {s}\r\n", .{&x});
            },
            else => {},
        }
        if (body.len > 0 or src.valueRangeAtMost(u8, 0, 3) == 0) {
            try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ if (src.valueRangeAtMost(u8, 0, 5) == 0) "text/plain" else "application/json", body.len });
        }
        try w.writeAll("\r\n");
        try w.writeAll(body);

        var rec = try main.testRequest(&m, w.buffered());
        defer rec.deinit();
        const r = try rec.only();
        if (r.status >= 500) {
            std.debug.print("5xx for:\n{s}\n", .{w.buffered()});
            return error.ServerError;
        }
        if (r.status == 304) mark(.api_304) else if (r.status < 300) mark(.api_2xx) else mark(.api_4xx);
        try checkTargets(&m);
    }
}

test "fuzz driver: ZPINGER_FUZZ" {
    defer if (api_dir) |*d| {
        d.cleanup();
        api_dir = null;
    };
    try driver.runAll(.{
        .{ historyHarness, .{ .prefix = "ZPINGER_FUZZ", .name = "history" } },
        .{ targetsHarness, .{ .prefix = "ZPINGER_FUZZ", .name = "targets" } },
        .{ apiHarness, .{ .prefix = "ZPINGER_FUZZ", .name = "api", .scale = 4 } },
    });
}

test "fuzz harnesses: 300 seeds in every test run, and they get everywhere" {
    defer if (api_dir) |*d| {
        d.cleanup();
        api_dir = null;
    };
    reach = @splat(0);
    for (0..300) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var rng: driver.Rng = .{ .r = prng.random() };
        try historyHarness(driver.Rng, &rng, testing.allocator);
        try targetsHarness(driver.Rng, &rng, testing.allocator);
        try apiHarness(driver.Rng, &rng, testing.allocator);
    }
    for (reach, 0..) |n, i| if (n == 0) {
        std.debug.print("reach: {t} never hit in 300 seeds\n", .{@as(Label, @fromBackingInt(@intCast(i)))});
        return error.HarnessDoesNotReach;
    };
}

/// Every allocation failing in turn, through what a cycle and a viewer do:
/// an error comes back, nothing leaks, nothing crashes.
fn allocationRound(gpa: std.mem.Allocator) !void {
    var m: Monitor = .{ .gpa = gpa, .io = testing.io, .config_path = "unused", .read_only = true };
    defer m.deinit();
    _ = try m.add("a", "192.0.2.1", &.{"x"});
    _ = try m.add("b", "2001:db8::1", &.{});
    try m.loadHistoryBytes(history_base, now);
    const whole = try m.state(null);
    defer whole.release();
    const delta = try m.state(whole.tag.end - 60);
    defer delta.release();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    m.writeLive(&aw.writer, .{}) catch return error.OutOfMemory;
    try m.setTags(1, &.{"y"});
    try m.edit(2, "c", null, null);
}

test "every allocation failing in turn: no leak, no crash" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationRound, .{});
}

test "the shape of a delta and of the live view (API contract, doc/api.md)" {
    var m: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = "unused", .read_only = true };
    defer m.deinit();
    m.cycle_s = 1 << 30; // no cycle boundary during the test
    _ = try m.add("a", "192.0.2.1", &.{"lab"});
    const d = try m.state(m.stateTag().end);
    defer d.release();
    // `end`/`since` depend on the clock: masked.
    var buf: [2048]u8 = undefined;
    const got = try maskNumbers(&buf, d.json, &.{ "\"end\":", "\"since\":" });
    try testkit.expectBytes(
        \\{"read_only":true,"version":1,"demo_from":0,"demo_fills":0,"cycle_s":1073741824,"probes":5,"ack_clear_after":5,"end":N,"since":N,"targets":[{"id":1,"name":"a","host":"192.0.2.1","status":"pending","paused":false,"acked":false,"ok_streak":0,"error":null,"sample":false,"tags":["lab"],"address":null,"dns":"ok","rtt":[null],"jitter":[null],"loss":[null]}]}
    , got);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try m.writeLive(&aw.writer, .{});
    const live = try maskNumbers(&buf, aw.written(), &.{"\"now\":"});
    try testkit.expectBytes(
        \\{"now":N,"cycle":0,"cycle_s":1073741824,"version":1,"targets":[],"count":0,"from":0,"probes":[]}
    , live);
}

/// `json` with the number after each of `keys` replaced by `N`.
fn maskNumbers(out: []u8, json: []const u8, keys: []const []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    var i: usize = 0;
    outer: while (i < json.len) {
        for (keys) |k| if (std.mem.startsWith(u8, json[i..], k)) {
            try w.writeAll(k);
            i += k.len;
            while (i < json.len and (std.ascii.isDigit(json[i]) or json[i] == '-')) i += 1;
            try w.writeByte('N');
            continue :outer;
        };
        try w.writeByte(json[i]);
        i += 1;
    }
    return w.buffered();
}
