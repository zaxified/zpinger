//! zpinger — a small ping monitor built on zig-libs.
//!
//! Pings a handful of targets once a minute and serves a web page with the
//! last 24 hours: status, latency and packet loss per target, plus buttons to
//! add, remove, pause and acknowledge targets. `--read-only` turns the page
//! into a public demo: the server refuses every change, not just the page;
//! `--demo` also fills the history older than an hour with sample data.

const std = @import("std");
const Io = std.Io;
const http = @import("http");
const abuseguard = @import("abuseguard");
const Status = std.http.Status;
const Monitor = @import("monitor.zig").Monitor;
const StateTag = @import("monitor.zig").StateTag;
const Tracer = @import("trace.zig").Tracer;
const trace = @import("trace.zig");
const netaddr = @import("netaddr");

const log = std.log.scoped(.web);

const usage =
    \\usage: zpinger [options]
    \\
    \\  --listen ADDR:PORT   web server address (default 127.0.0.1:8080)
    \\  --targets FILE       target list, JSON (default targets.json)
    \\  --history FILE       keep the 24 h history across restarts (default: memory only)
    \\  --read-only          public demo: refuse every change
    \\  --demo               --read-only, plus sample data older than the last hour (see README)
    \\  --allow-host NAME    also answer to this host name (repeatable); see README
    \\  --cycle SECONDS      seconds between probing cycles (default 60)
    \\  --trace-max N        live traces (target detail) running at once (default 4, 0 = off)
    \\  --trace-names on|off reverse-DNS names of the trace hops (default on)
    \\  --trace-idle SECONDS stop a trace nobody watched this long
    \\                       (default 600, read-only 60)
    \\  --trace-age SECONDS  stop every trace this long after it started
    \\                       (default 3600, read-only 600)
    \\  --trust-proxy on|off take the client address of a request from a loopback
    \\                       peer (a reverse proxy) from X-Forwarded-For (default on)
    \\  --version            print the version and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var listen_text: []const u8 = "127.0.0.1:8080";
    var monitor: Monitor = .{ .gpa = gpa, .io = io, .config_path = "targets.json" };
    defer monitor.deinit();
    var hosts: std.ArrayList([]const u8) = .empty;
    defer hosts.deinit(gpa);
    var tracer_state: Tracer = .{ .gpa = gpa, .io = io };
    defer tracer_state.deinit();
    var trace_idle: ?i64 = null;
    var trace_age: ?i64 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--read-only")) {
            monitor.read_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--demo")) {
            monitor.read_only = true;
            monitor.demo = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            print(io, "zpinger {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return fail(io, "");
        if (i + 1 == args.len) return fail(io, "missing value");
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--listen")) {
            listen_text = value;
        } else if (std.mem.eql(u8, arg, "--targets")) {
            monitor.config_path = value;
        } else if (std.mem.eql(u8, arg, "--history")) {
            monitor.history_path = value;
        } else if (std.mem.eql(u8, arg, "--allow-host")) {
            try hosts.append(gpa, value);
        } else if (std.mem.eql(u8, arg, "--cycle")) {
            monitor.cycle_s = std.fmt.parseInt(u31, value, 10) catch return fail(io, "bad --cycle");
            if (monitor.cycle_s < 5) return fail(io, "--cycle must be at least 5");
        } else if (std.mem.eql(u8, arg, "--trace-max")) {
            tracer_state.max_sessions = std.fmt.parseInt(u8, value, 10) catch return fail(io, "bad --trace-max");
            if (tracer_state.max_sessions > trace.max_slots) return fail(io, "--trace-max is at most 16");
        } else if (std.mem.eql(u8, arg, "--trace-names")) {
            if (std.mem.eql(u8, value, "on")) {
                tracer_state.names = true;
            } else if (std.mem.eql(u8, value, "off")) {
                tracer_state.names = false;
            } else return fail(io, "--trace-names is on or off");
        } else if (std.mem.eql(u8, arg, "--trace-idle")) {
            trace_idle = std.fmt.parseInt(u31, value, 10) catch return fail(io, "bad --trace-idle");
            if (trace_idle.? < 10) return fail(io, "--trace-idle must be at least 10");
        } else if (std.mem.eql(u8, arg, "--trace-age")) {
            trace_age = std.fmt.parseInt(u31, value, 10) catch return fail(io, "bad --trace-age");
            if (trace_age.? < 10) return fail(io, "--trace-age must be at least 10");
        } else if (std.mem.eql(u8, arg, "--trust-proxy")) {
            if (std.mem.eql(u8, value, "on")) {
                trust_proxy = true;
            } else if (std.mem.eql(u8, value, "off")) {
                trust_proxy = false;
            } else return fail(io, "--trust-proxy is on or off");
        } else return fail(io, "unknown option");
    }

    allowed_hosts = hosts.items;
    tracer_state.limits = if (monitor.read_only) .read_only else .writable;
    if (trace_idle) |v| tracer_state.limits.idle_s = v;
    if (trace_age) |v| tracer_state.limits.max_age_s = v;
    tracer = &tracer_state;
    monitor.loadConfig() catch |err| fatal(io, "cannot load the targets from {s}: {t}", .{ monitor.config_path, err });
    monitor.loadHistory() catch |err| fatal(io, "cannot load the history from {s}: {t} (move it away to start afresh)", .{ monitor.history_path.?, err });

    const address = Io.net.IpAddress.parseLiteral(listen_text) catch return fail(io, "bad --listen");
    var admission: Admission = .{ .guard = .init(gpa, .{ .max_conns_per_ip = max_connections_per_ip }) };
    defer admission.guard.deinit();
    var server = http.Server.init(io, gpa, .{
        .handler = handle,
        .context = &monitor,
        .on_connect = Admission.onConnect,
        .on_connect_ctx = &admission,
        .on_conn_state = Admission.onConnState,
        .on_conn_state_ctx = &admission,
        .on_error = logError,
        .read_timeout_ms = 10_000,
        // Also bounds the wait for a request, the first one included (an
        // `idle_timeout_ms` would replace it there, on the first one too).
        .request_timeout_ms = 10_000,
        .write_timeout_ms = 10_000,
        .response_timeout_ms = 30_000,
        .max_header_bytes = 8 * 1024,
        .max_body_bytes = max_body_bytes,
        // With keep-alive the timeouts bound each request, not the
        // connection: this bounds how long one connection keeps its thread.
        .max_requests_per_conn = 100,
        .server_name = null,
        .error_headers = &security_headers,
    });
    defer server.deinit();
    // zig-libs request: http — bind with SO_REUSEADDR but without
    // SO_REUSEPORT (Go's default); `bind` offers neither or both. Until
    // then the listener is bound here and handed to the server.
    server.listener = listenExclusive(address) catch |err|
        fatal(io, "cannot listen on {s}: {t}", .{ listen_text, err });
    log.info("zpinger {s} listening on http://{s} ({d} targets{s})", .{
        version, listen_text, monitor.targets.items.len, if (monitor.demo) ", demo" else if (monitor.read_only) ", read-only" else "",
    });

    // The probing loop and every connection run concurrently; with the
    // default threaded Io each one is its own thread. Requests only read
    // what the probing loop recorded: no viewer ever triggers a ping.
    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, probeLoop, .{&monitor});
    server.serve() catch |err| fatal(io, "serving failed: {t}", .{err});
}

/// A listening socket with SO_REUSEADDR only. std's `listen` sets
/// SO_REUSEPORT together with SO_REUSEADDR, and with it a second instance
/// binds the same port and silently takes part of the requests (a trace
/// then looks unwatched on one, missing on the other). SO_REUSEADDR is kept:
/// this server closes its connections, and a restart must not wait out
/// their TIME_WAIT. Linux only, like the ping sockets.
fn listenExclusive(address: Io.net.IpAddress) error{ AddressInUse, ListenFailed }!Io.net.Server {
    const linux = std.os.linux;
    const rc = linux.socket(switch (address) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    }, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ListenFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    const one: c_int = 1;
    if (linux.errno(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(c_int))) != .SUCCESS)
        return error.ListenFailed;
    const bound = switch (address) {
        .ip4 => |a| blk: {
            const sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) };
            break :blk linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
        },
        .ip6 => |a| blk: {
            const sa: linux.sockaddr.in6 = .{ .port = std.mem.nativeToBig(u16, a.port), .flowinfo = 0, .addr = a.bytes, .scope_id = 0 };
            break :blk linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in6));
        },
    };
    switch (linux.errno(bound)) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => return error.ListenFailed,
    }
    if (linux.errno(linux.listen(fd, 128)) != .SUCCESS) return error.ListenFailed;
    return .{ .socket = .{ .handle = fd, .address = address }, .options = {} };
}

/// Limits for a server reachable from the internet. Every connection holds
/// a thread, so at most `max_connections` are open at once, at most
/// `max_connections_per_ip` from one client (an IPv6 /64), and more are
/// closed unanswered. The server's timeouts bound how long each one lasts:
/// a client that sends its request a byte at a time, or never, is cut off
/// after 10 s. Per-client request rates belong in a reverse proxy.
const max_connections = 256;
const max_connections_per_ip = 16;
/// The largest request body: a target is a few hundred bytes of JSON.
const max_body_bytes = 4096;

/// Admission at accept time: the global cap here, the per-client cap in an
/// `abuseguard.Guard`. A peer on loopback is the reverse proxy, carrying
/// every client on one address: only the global cap applies to it.
const Admission = struct {
    guard: abuseguard.Guard,
    open: std.atomic.Value(u32) = .init(0),

    fn onConnect(ctx: ?*anyopaque, peer: Io.net.IpAddress) http.Server.ConnDecision {
        const a: *Admission = @ptrCast(@alignCast(ctx.?));
        if (a.open.fetchAdd(1, .monotonic) >= max_connections) {
            _ = a.open.fetchSub(1, .monotonic);
            return .reject;
        }
        const ip = ipOf(peer);
        if (ip.isLoopback()) return .accept;
        return switch (a.guard.admit(ip)) {
            .admitted, .admitted_untracked => .accept,
            else => {
                _ = a.open.fetchSub(1, .monotonic);
                return .reject;
            },
        };
    }

    /// Every admitted connection reports `.closed` exactly once.
    fn onConnState(ctx: ?*anyopaque, peer: ?Io.net.IpAddress, state: http.Server.ConnState) void {
        if (state != .closed) return;
        const a: *Admission = @ptrCast(@alignCast(ctx.?));
        _ = a.open.fetchSub(1, .monotonic);
        const ip = ipOf(peer orelse return);
        if (!ip.isLoopback()) a.guard.connClosed(ip);
    }
};

fn ipOf(address: Io.net.IpAddress) netaddr.Ip {
    return switch (address) {
        .ip4 => |a| .{ .v4 = a.bytes },
        .ip6 => |a| .{ .v6 = a.bytes },
    };
}

fn logError(_: ?*anyopaque, kind: http.Server.ErrorKind, err: ?anyerror, status: u16, _: ?Io.net.IpAddress) void {
    if (err) |e| log.debug("{t}: {t} ({d})", .{ kind, e, status }) else log.debug("{t} ({d})", .{ kind, status });
}

fn fail(io: Io, msg: []const u8) noreturn {
    if (msg.len > 0) eprint(io, "zpinger: {s}\n", .{msg});
    eprint(io, usage, .{});
    std.process.exit(2);
}

/// A startup error: one readable line (systemd shows it), no stack trace.
fn fatal(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    eprint(io, "zpinger: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn print(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn probeLoop(monitor: *Monitor) void {
    monitor.loop() catch {}; // canceled at shutdown
}

// ----- HTTP ---------------------------------------------------------------------

const version = @import("build_options").version;

const index_html = @embedFile("web/index.html");
const app_js = @embedFile("web/app.js");
const style_css = @embedFile("web/style.css");
const favicon_svg = @embedFile("web/favicon.svg");

/// Sent with every response. The page loads nothing from other origins and
/// has no inline script, so the policy can be strict.
const security_headers = [_]http.Header{
    .{ .name = "content-security-policy", .value = "default-src 'self'; frame-ancestors 'none'" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
};

const Request = http.Server.Request;
const ResponseWriter = http.Server.ResponseWriter;

/// The server's handler; `Request.context` is the monitor.
fn handle(req: *Request, rw: *ResponseWriter) anyerror!void {
    const monitor: *Monitor = @ptrCast(@alignCast(req.context.?));
    var arena_state: std.heap.ArenaAllocator = .init(monitor.gpa);
    defer arena_state.deinit();
    return route(monitor, req, rw, arena_state.allocator());
}

/// The live traces; set once before the server starts.
var tracer: *Tracer = undefined;

/// Host names a writable instance answers to besides IP literals and
/// `localhost` (`--allow-host`); set once before the server starts.
var allowed_hosts: []const []const u8 = &.{};

/// DNS rebinding guard for a writable instance. A web page on another site
/// can point its own name at 127.0.0.1 and then talk to this server as its
/// own origin, so the JSON content type check stops nothing. Its requests
/// still carry its name in `Host`: answer only to IP literals (an origin
/// that cannot be rebound), `localhost` and the `--allow-host` names. A
/// read-only instance changes nothing and shows only what it publishes, so
/// it answers to any name and its proxy needs no configuration.
fn hostAllowed(req: *const Request) bool {
    return hostNameAllowed(req.header("host") orelse return false, allowed_hosts);
}

fn hostNameAllowed(host: []const u8, allowed: []const []const u8) bool {
    if (Io.net.IpAddress.parseLiteral(host)) |_| return true else |_| {}
    var name = host[0 .. std.mem.findScalar(u8, host, ':') orelse host.len];
    if (std.mem.endsWith(u8, name, ".")) name = name[0 .. name.len - 1];
    if (std.ascii.eqlIgnoreCase(name, "localhost")) return true;
    for (allowed) |a| if (std.ascii.eqlIgnoreCase(name, a)) return true;
    return false;
}

test "writable instance: Host header guard" {
    const allowed: []const []const u8 = &.{"ping.example.org"};
    for ([_][]const u8{ "127.0.0.1", "127.0.0.1:8080", "[::1]:8080", "192.0.2.7", "localhost:8080", "LOCALHOST.", "ping.example.org", "Ping.Example.Org:443" }) |h|
        try std.testing.expect(hostNameAllowed(h, allowed));
    for ([_][]const u8{ "", "evil.example", "evil.example:8080", "localhost.evil.example", "127.0.0.1.evil.example", "ping.example.org.evil.example" }) |h|
        try std.testing.expect(!hostNameAllowed(h, allowed));
}

fn route(monitor: *Monitor, req: *Request, rw: *ResponseWriter, arena: std.mem.Allocator) !void {
    const method = req.method;
    const path = req.path;
    if (!monitor.read_only and !hostAllowed(req))
        return sendError(rw, .misdirected_request, "unknown host name; start the server with --allow-host NAME");

    if (traceTarget(path)) |id| return routeTrace(monitor, req, rw, id, viewerOf(req), arena);

    if (method == .get or method == .head) {
        if (std.mem.eql(u8, path, "/")) return send(rw, .ok, "text/html; charset=utf-8", index_html);
        if (std.mem.eql(u8, path, "/app.js")) return send(rw, .ok, "text/javascript", app_js);
        if (std.mem.eql(u8, path, "/style.css")) return send(rw, .ok, "text/css", style_css);
        if (std.mem.eql(u8, path, "/favicon.svg")) return send(rw, .ok, "image/svg+xml", favicon_svg);
        if (std.mem.eql(u8, path, "/api/state")) return sendState(monitor, req, rw);
        if (std.mem.eql(u8, path, "/healthz")) {
            const h = monitor.health(Io.Clock.real.now(monitor.io).toSeconds());
            return send(rw, if (h.ok) .ok else .service_unavailable, "application/json", try arena.print(
                "{{\"ok\":{},\"probing_ok\":{},\"last_cycle\":{d},\"read_only\":{},\"demo\":{},\"version\":\"{s}\"}}",
                .{ h.ok, h.probing_ok, h.last_cycle, monitor.read_only, monitor.demo, version },
            ));
        }
        return sendError(rw, .not_found, "not found");
    }

    if (!std.mem.startsWith(u8, path, "/api/targets")) return sendError(rw, .not_found, "not found");
    if (monitor.read_only) return sendError(rw, .forbidden, "this is a read-only demo");
    // A cross-site form cannot send a JSON content type without a CORS
    // preflight, which this server never approves: a cheap CSRF guard.
    const content_type = req.header("content-type") orelse "";
    if (!std.mem.startsWith(u8, content_type, "application/json"))
        return sendError(rw, .unsupported_media_type, "send application/json");

    // POST /api/targets                {"name": ..., "host": ..., "tags": [...]}
    if (method == .post and std.mem.eql(u8, path, "/api/targets")) {
        const NewTarget = struct { name: []const u8, host: []const u8, tags: []const []const u8 = &.{} };
        const body = try readBody(req, arena);
        const parsed = std.json.parseFromSliceLeaky(NewTarget, arena, body, .{}) catch
            return sendError(rw, .bad_request, "expected {\"name\": ..., \"host\": ..., \"tags\": [...]}");
        const id = monitor.add(parsed.name, parsed.host, parsed.tags) catch |err| return sendMonitorError(rw, err);
        return send(rw, .created, "application/json", try arena.print("{{\"id\":{d}}}", .{id}));
    }

    // DELETE /api/targets/ID, PATCH /api/targets/ID {"name": ..., "host": ..., "tags": [...]},
    // POST /api/targets/ID/{pause,resume,ack,unack},
    // POST /api/targets/ID/tags {"tags": [...]}
    var parts = std.mem.tokenizeScalar(u8, path["/api/targets".len..], '/');
    const id = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return sendError(rw, .not_found, "not found");
    const verb = parts.next();
    if (parts.next() != null) return sendError(rw, .not_found, "not found");
    if (method == .delete and verb == null) {
        monitor.remove(id) catch |err| return sendMonitorError(rw, err);
    } else if (method == .patch and verb == null) {
        const Edit = struct { name: ?[]const u8 = null, host: ?[]const u8 = null, tags: ?[]const []const u8 = null };
        const body = try readBody(req, arena);
        const parsed = std.json.parseFromSliceLeaky(Edit, arena, body, .{}) catch
            return sendError(rw, .bad_request, "expected {\"name\": ..., \"host\": ..., \"tags\": [...]}");
        monitor.edit(id, parsed.name, parsed.host, parsed.tags) catch |err| return sendMonitorError(rw, err);
    } else if (method == .post and verb != null and std.mem.eql(u8, verb.?, "tags")) {
        const Tags = struct { tags: []const []const u8 };
        const body = try readBody(req, arena);
        const parsed = std.json.parseFromSliceLeaky(Tags, arena, body, .{}) catch
            return sendError(rw, .bad_request, "expected {\"tags\": [...]}");
        monitor.setTags(id, parsed.tags) catch |err| return sendMonitorError(rw, err);
    } else if (method == .post and verb != null) {
        const action = std.meta.stringToEnum(enum { pause, @"resume", ack, unack }, verb.?) orelse
            return sendError(rw, .not_found, "not found");
        monitor.apply(id, switch (action) {
            .pause => .pause,
            .@"resume" => .resume_,
            .ack => .ack,
            .unack => .unack,
        }) catch |err| return sendMonitorError(rw, err);
    } else return sendError(rw, .method_not_allowed, "method not allowed");
    return send(rw, .ok, "application/json", "{}");
}

/// The target id of `/api/targets/ID/trace`.
fn traceTarget(path: []const u8) ?u32 {
    const prefix = "/api/targets/";
    const suffix = "/trace";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    if (path.len < prefix.len + suffix.len) return null;
    return std.fmt.parseInt(u32, path[prefix.len .. path.len - suffix.len], 10) catch null;
}

/// Take the client address of a request from a loopback peer (the reverse
/// proxy) from `X-Forwarded-For` (`--trust-proxy`); set before the server starts.
var trust_proxy = true;

/// The viewer a trace request comes from: the peer address, or behind a
/// proxy on loopback the last `X-Forwarded-For` entry, the one the proxy
/// itself added (earlier ones come from the client and prove nothing). A
/// peer outside loopback cannot get its header trusted.
fn viewerOf(req: *const Request) trace.Viewer {
    // Served over a socket, a request always has its peer.
    const ip = ipOf(req.peerAddress().?);
    if (trust_proxy and ip.isLoopback()) {
        var headers = req.iterateHeaders();
        var last: ?[]const u8 = null;
        while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-for")) {
            last = h.value;
        };
        if (last) |list| {
            const entry = list[if (std.mem.findScalarLast(u8, list, ',')) |c| c + 1 else 0..];
            if (netaddr.parseIp(std.mem.trim(u8, entry, " \t"))) |client| return trace.viewerOf(client);
        }
    }
    return trace.viewerOf(ip);
}

/// A live trace measures, it changes nothing: a read-only instance offers it
/// too, bounded by the Tracer (one session per host, a global cap, a start
/// rate, a per-viewer cap, idle and age limits). GET reads it (and keeps
/// watching it), POST starts or joins it, DELETE stops watching it.
fn routeTrace(monitor: *Monitor, req: *Request, rw: *ResponseWriter, id: u32, viewer: trace.Viewer, arena: std.mem.Allocator) !void {
    var buf: [256]u8 = undefined;
    const host = monitor.hostOf(id, &buf) orelse return sendError(rw, .not_found, "no such target");
    switch (req.method) {
        .get => {
            const found = tracer.json(host, viewer, arena) catch |err| return sendTraceError(rw, err);
            const body = found orelse return sendError(rw, .not_found, "no trace running");
            return send(rw, .ok, "application/json", body);
        },
        .post => {
            // The same CSRF guard as the other writes.
            const content_type = req.header("content-type") orelse "";
            if (!std.mem.startsWith(u8, content_type, "application/json"))
                return sendError(rw, .unsupported_media_type, "send application/json");
            tracer.start(host, viewer) catch |err| return sendTraceError(rw, err);
            return send(rw, .accepted, "application/json", "{}");
        },
        .delete => {
            tracer.stop(host, viewer);
            return send(rw, .ok, "application/json", "{}");
        },
        else => return sendError(rw, .method_not_allowed, "method not allowed"),
    }
}

fn sendTraceError(rw: *ResponseWriter, err: anyerror) !void {
    return switch (err) {
        error.TraceDisabled => sendError(rw, .forbidden, "live traces are disabled on this server"),
        error.TooManyTraces => sendError(rw, .service_unavailable, "too many live traces running; try again in a minute"),
        error.RateLimited => sendError(rw, .too_many_requests, "too many live traces started in the last minute; try again shortly"),
        error.ViewerLimit => sendError(rw, .too_many_requests, std.fmt.comptimePrint("you are watching {d} live traces already; stop one first", .{trace.max_per_viewer})),
        else => err,
    };
}

test "trace viewer: X-Forwarded-For only from a loopback peer, last entry" {
    const Case = struct { peer: []const u8, xff: ?[]const u8, want: []const u8 };
    for ([_]Case{
        .{ .peer = "127.0.0.1", .xff = "198.51.100.7", .want = "198.51.100.7" },
        .{ .peer = "127.0.0.1", .xff = "203.0.113.1, 198.51.100.7", .want = "198.51.100.7" },
        .{ .peer = "::1", .xff = "2001:db8::5", .want = "2001:db8::9" }, // same /64
        .{ .peer = "127.0.0.1", .xff = "junk", .want = "127.0.0.1" },
        .{ .peer = "127.0.0.1", .xff = null, .want = "127.0.0.1" },
        .{ .peer = "192.0.2.9", .xff = "198.51.100.7", .want = "192.0.2.9" }, // not a proxy
    }) |c| {
        var raw_buf: [256]u8 = undefined;
        const raw = if (c.xff) |x|
            try std.fmt.bufPrint(&raw_buf, "GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: {s}\r\n\r\n", .{x})
        else
            "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
        const peer: Io.net.IpAddress = switch (netaddr.parseIp(c.peer).?) {
            .v4 => |q| .{ .ip4 = .{ .bytes = q, .port = 40000 } },
            .v6 => |q| .{ .ip6 = .{ .bytes = q, .port = 40000 } },
        };
        var rec = try http.httptest.record(std.testing.allocator, .{ .handler = ViewerProbe.handle, .peer = peer }, raw, .{});
        defer rec.deinit();
        try std.testing.expectEqual(trace.viewerOf(netaddr.parseIp(c.want).?), ViewerProbe.got);
    }
}

const ViewerProbe = struct {
    var got: trace.Viewer = undefined;
    fn handle(req: *Request, _: *ResponseWriter) anyerror!void {
        got = viewerOf(req);
    }
};

test "trace route" {
    try std.testing.expectEqual(@as(?u32, 7), traceTarget("/api/targets/7/trace"));
    for ([_][]const u8{ "/api/targets/trace", "/api/targets//trace", "/api/targets/x/trace", "/api/targets/7/tracex", "/api/targets/7/8/trace", "/api/targets/7" }) |p|
        try std.testing.expectEqual(@as(?u32, null), traceTarget(p));
}

fn readBody(req: *Request, arena: std.mem.Allocator) ![]u8 {
    return req.reader().allocRemaining(arena, .limited(max_body_bytes));
}

/// GET /api/state. The page polls more often than a cycle runs; the ETag
/// lets a poll that finds nothing new end as `304 Not Modified`, no body.
/// The state compresses to a fifth with gzip: compressed once per state,
/// not per request (see `Snapshot.gzipped`).
fn sendState(monitor: *Monitor, req: *Request, rw: *ResponseWriter) !void {
    var buf: [64]u8 = undefined;
    const accepts_gzip = http.gzip.acceptsGzip(req.header("accept-encoding"));
    // A 304 names the representation this client gets.
    const current = etagOf(&buf, monitor.stateTag(), accepts_gzip);
    if (ifNoneMatch(req, current))
        return respond(rw, "", .{ .status = .not_modified, .cache_control = "no-cache", .etag = current, .vary = true });
    const state = try monitor.state();
    defer state.release();
    const gzip = if (accepts_gzip) state.gzipped(monitor.io) else null;
    return respond(rw, gzip orelse state.json, .{
        .content_type = "application/json",
        .cache_control = "no-cache",
        .etag = etagOf(&buf, state.tag, gzip != null),
        .gzip = gzip != null,
        .vary = true,
    });
}

/// `"version-end"`, `"version-end-gzip"` for the compressed body: a
/// different representation needs a different ETag.
fn etagOf(buf: *[64]u8, tag: StateTag, gzip: bool) []const u8 {
    return std.mem.print(buf, "\"{d}-{d}{s}\"", .{ tag.version, tag.end, if (gzip) "-gzip" else "" }) catch unreachable;
}

/// Whether an If-None-Match header lists `etag` (a weak comparison, as
/// RFC 9110 asks for it). Also accepted: a suffix after the tag
/// (`"1-2-gzip"`), as a compressing proxy may rewrite the ETag it passes on.
fn ifNoneMatch(req: *const Request, etag: []const u8) bool {
    const bare = etag[1 .. etag.len - 1];
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "if-none-match")) continue;
        var tags = std.mem.tokenizeAny(u8, h.value, ", ");
        while (tags.next()) |raw| {
            const t = std.mem.trim(u8, if (std.mem.startsWith(u8, raw, "W/")) raw[2..] else raw, "\"");
            if (std.mem.eql(u8, t, bare)) return true;
            if (std.mem.startsWith(u8, t, bare) and t[bare.len] == '-') return true;
        }
    }
    return false;
}

const Response = struct {
    status: Status = .ok,
    content_type: ?[]const u8 = null,
    cache_control: []const u8 = "no-store",
    etag: ?[]const u8 = null,
    /// The body is gzip-compressed.
    gzip: bool = false,
    /// The body depends on Accept-Encoding.
    vary: bool = false,
};

fn respond(rw: *ResponseWriter, body: []const u8, r: Response) !void {
    rw.setStatus(@backingInt(r.status));
    for (security_headers) |h| try rw.setHeader(h.name, h.value);
    try rw.setHeader("cache-control", r.cache_control);
    if (r.content_type) |v| try rw.setHeader("content-type", v);
    if (r.etag) |v| try rw.setHeader("etag", v);
    if (r.gzip) try rw.setHeader("content-encoding", "gzip");
    if (r.vary) try rw.setHeader("vary", "accept-encoding");
    // A 304 has no body and must not claim a length of 0.
    if (r.status == .not_modified) return;
    // An exact length rather than chunked framing past the response buffer.
    var len: [20]u8 = undefined;
    try rw.setHeader("content-length", std.mem.print(&len, "{d}", .{body.len}) catch unreachable);
    try rw.writeAll(body);
}

fn send(rw: *ResponseWriter, status: Status, content_type: []const u8, body: []const u8) !void {
    return respond(rw, body, .{ .status = status, .content_type = content_type });
}

fn sendError(rw: *ResponseWriter, status: Status, msg: []const u8) !void {
    var buf: [256]u8 = undefined;
    const body = std.mem.print(&buf, "{{\"error\":{f}}}", .{std.json.fmt(msg, .{})}) catch unreachable;
    return send(rw, status, "application/json", body);
}

fn sendMonitorError(rw: *ResponseWriter, err: anyerror) !void {
    return switch (err) {
        error.UnknownTarget => sendError(rw, .not_found, "no such target"),
        error.InvalidName => sendError(rw, .bad_request, "name: 1-64 printable characters"),
        error.InvalidHost => sendError(rw, .bad_request, "host: an IP address or a DNS name"),
        error.InvalidTags => sendError(rw, .bad_request, "tags: at most 8, each 1-32 characters, no spaces or commas"),
        error.TooManyTargets => sendError(rw, .conflict, "too many targets"),
        error.NotDown => sendError(rw, .conflict, "only a DOWN target can be acknowledged"),
        else => err,
    };
}

/// One request through the real handler, as a client sees the answer.
fn testRequest(monitor: *Monitor, wire: []const u8) !http.httptest.Recording {
    return http.httptest.record(std.testing.allocator, .{
        .handler = handle,
        .context = monitor,
        .max_body_bytes = max_body_bytes,
        .server_name = null,
        .error_headers = &security_headers,
    }, wire, .{});
}

test "routes: pages, HEAD, state with ETag and gzip, read-only, Host guard, body cap" {
    const testing = std.testing;
    var m: Monitor = .{ .gpa = testing.allocator, .io = testing.io, .config_path = "unused", .read_only = true };
    defer m.deinit();
    m.cycle_s = 1 << 30; // no new cycle (a new ETag) during the test
    _ = try m.add("a", "192.0.2.1", &.{}); // read-only: never saved

    {
        var rec = try testRequest(&m, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        defer rec.deinit();
        const r = try rec.only();
        try testing.expectEqual(200, r.status);
        try testing.expectEqualStrings(index_html, r.body);
        try testing.expectEqualStrings("nosniff", r.header("x-content-type-options").?);
        try testing.expect(r.header("transfer-encoding") == null);
    }
    {
        var rec = try testRequest(&m, "HEAD /app.js HTTP/1.1\r\nHost: x\r\n\r\n");
        defer rec.deinit();
        const r = try rec.only();
        try testing.expectEqual(200, r.status);
        try testing.expectEqual(0, r.body.len);
    }
    var etag_buf: [64]u8 = undefined;
    const etag = blk: {
        var rec = try testRequest(&m, "GET /api/state HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, br\r\n\r\n");
        defer rec.deinit();
        const r = try rec.only();
        try testing.expectEqual(200, r.status);
        try testing.expectEqualStrings("gzip", r.header("content-encoding").?);
        try testing.expectEqualStrings("accept-encoding", r.header("vary").?);
        try testing.expect(std.mem.endsWith(u8, r.header("etag").?, "-gzip\""));
        const e = r.header("etag").?;
        @memcpy(etag_buf[0..e.len], e);
        break :blk etag_buf[0..e.len];
    };
    {
        var rec = try testRequest(&m, "GET /api/state HTTP/1.1\r\nHost: x\r\n\r\n");
        defer rec.deinit();
        const r = try rec.only();
        try testing.expect(r.header("content-encoding") == null);
        try testing.expect(std.mem.startsWith(u8, r.body, "{\"read_only\":true"));
    }
    {
        var wire: [256]u8 = undefined;
        var rec = try testRequest(&m, try std.mem.print(&wire, "GET /api/state HTTP/1.1\r\nHost: x\r\nIf-None-Match: {s}\r\n\r\n", .{etag}));
        defer rec.deinit();
        const r = try rec.only();
        try testing.expectEqual(304, r.status);
        try testing.expect(r.header("content-length") == null);
    }
    {
        var rec = try testRequest(&m, "POST /api/targets HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
        defer rec.deinit();
        try testing.expectEqual(403, (try rec.only()).status);
    }
    {
        var rec = try testRequest(&m, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n");
        defer rec.deinit();
        try testing.expectEqual(404, (try rec.only()).status);
    }

    // A writable instance: the Host guard, the body cap, the CSRF guard
    // (each refuses before anything is changed or saved).
    m.read_only = false;
    defer m.read_only = true;
    {
        var rec = try testRequest(&m, "GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n");
        defer rec.deinit();
        try testing.expectEqual(421, (try rec.only()).status);
    }
    {
        var rec = try testRequest(&m, "POST /api/targets HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 5000\r\n\r\n");
        defer rec.deinit();
        const r = try rec.only();
        try testing.expectEqual(413, r.status);
        try testing.expectEqualStrings("nosniff", r.header("x-content-type-options").?);
    }
    {
        var rec = try testRequest(&m, "POST /api/targets/1/pause HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n");
        defer rec.deinit();
        try testing.expectEqual(415, (try rec.only()).status);
    }
}

test {
    _ = @import("monitor.zig");
    _ = @import("demo.zig");
    _ = @import("trace.zig");
}
