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
const events = @import("events.zig");

const log = std.log.scoped(.web);

pub const std_options: std.Options = .{
    .logFn = events.logFn,
    // Filtered at run time (`--log-level`), so every level is compiled in.
    .log_level = .debug,
};

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
    \\  --dns-stale SECONDS  keep probing a name's last address this long while
    \\                       DNS does not answer (default 86400, 0 = never)
    \\  --access-log refused|all|off
    \\                       requests logged as events: refused ones (status 400
    \\                       and up, the default), all, or none; see README
    \\  --log-level err|warn|info|debug  (default info)
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
        } else if (std.mem.eql(u8, arg, "--dns-stale")) {
            monitor.dns_stale_s = std.fmt.parseInt(u31, value, 10) catch return fail(io, "bad --dns-stale");
        } else if (std.mem.eql(u8, arg, "--access-log")) {
            access_log = std.meta.stringToEnum(AccessLog, value) orelse return fail(io, "--access-log is refused, all or off");
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            events.level = std.meta.stringToEnum(std.log.Level, value) orelse return fail(io, "--log-level is err, warn, info or debug");
        } else return fail(io, "unknown option");
    }

    allowed_hosts = hosts.items;
    events.journal = events.stderrIsJournal(init.environ_map.get("JOURNAL_STREAM"));
    events.init(gpa);
    defer events.deinit();
    tracer_state.addresses = &monitor;
    tracer_state.limits = if (monitor.read_only) .read_only else .writable;
    if (trace_idle) |v| tracer_state.limits.idle_s = v;
    if (trace_age) |v| tracer_state.limits.max_age_s = v;
    tracer = &tracer_state;
    monitor.loadConfig() catch |err| fatal(io, "cannot load the targets from {s}: {t}", .{ monitor.config_path, err });
    monitor.loadHistory() catch |err| fatal(io, "cannot load the history from {s}: {t} (move it away to start afresh)", .{ monitor.history_path.?, err });

    const address = Io.net.IpAddress.parseLiteral(listen_text) catch return fail(io, "bad --listen");
    var admission: Admission = .{ .io = io, .gpa = gpa, .guard = .init(gpa, .{ .max_conns_per_ip = max_connections_per_ip }) };
    defer admission.deinit();
    var server = http.Server.init(io, gpa, .{
        .handler = handle,
        .context = &monitor,
        .on_connect = Admission.onConnect,
        .on_connect_ctx = &admission,
        .on_conn_state = Admission.onConnState,
        .on_conn_state_ctx = &admission,
        .on_error = onError,
        .read_timeout_ms = read_timeout_ms,
        // Also bounds the wait for a request, the first one included (an
        // `idle_timeout_ms` would replace it there, on the first one too).
        .request_timeout_ms = read_timeout_ms,
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
    _ = events.emit(.info, .start, .system, null, "version={s} listen={s} targets={d} mode={s} trust_proxy={} allow_host={d} trace_max={d} access_log={t} dns_stale={d}", .{
        version,                                                                          listen_text, monitor.targets.items.len,
        if (monitor.demo) "demo" else if (monitor.read_only) "read-only" else "writable", trust_proxy, allowed_hosts.len,
        tracer_state.max_sessions,                                                        access_log,  monitor.dns_stale_s,
    });

    // The probing loop and every connection run concurrently; with the
    // default threaded Io each one is its own thread. Requests only read
    // what the probing loop recorded: no viewer ever triggers a ping.
    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, probeLoop, .{&monitor});
    try tasks.concurrent(io, events.flushLoop, .{io});
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
///
/// It also follows every connection to its end, to report one that closes
/// without a single request: a slowloris holding a thread until the read
/// timeout, a port scan, a TLS client on the plain-HTTP port.
/// zig-libs request: http — no report of a timeout once a request has
/// started (a body sent a byte at a time, a response read that slowly):
/// only a connection with no request at all is seen here.
const Admission = struct {
    io: Io,
    gpa: std.mem.Allocator,
    guard: abuseguard.Guard,
    open: std.atomic.Value(u32) = .init(0),
    mutex: Io.Mutex = .init,
    /// Open connections by peer address and port: when it started, and
    /// how many requests it sent.
    live: std.AutoHashMapUnmanaged(ConnKey, Conn) = .empty,

    const ConnKey = [18]u8;
    const Conn = struct { started_ns: i96, requests: u32 = 0 };

    fn deinit(a: *Admission) void {
        a.live.deinit(a.gpa);
        a.guard.deinit();
    }

    fn keyOf(peer: Io.net.IpAddress) ConnKey {
        var k: ConnKey = undefined;
        k[0..16].* = ipOf(peer).as16();
        std.mem.writeInt(u16, k[16..18], peer.getPort(), .big);
        return k;
    }

    fn onConnect(ctx: ?*anyopaque, peer: Io.net.IpAddress) http.Server.ConnDecision {
        const a: *Admission = @ptrCast(@alignCast(ctx.?));
        const ip = ipOf(peer);
        if (a.open.fetchAdd(1, .monotonic) >= max_connections) {
            _ = a.open.fetchSub(1, .monotonic);
            _ = events.emit(.warn, .conn, .conn, .of(ip), "action=refused reason=total_cap", .{});
            return .reject;
        }
        if (ip.isLoopback()) return .accept;
        const verdict = a.guard.admit(ip);
        switch (verdict) {
            .admitted, .admitted_untracked => return .accept,
            else => {
                _ = a.open.fetchSub(1, .monotonic);
                _ = events.emit(.warn, .conn, .conn, .of(ip), "action=refused reason={t}", .{verdict});
                return .reject;
            },
        }
    }

    /// Every admitted connection reports `.new` and, at its end, `.closed`
    /// exactly once; `.active` once per request.
    fn onConnState(ctx: ?*anyopaque, peer_or_null: ?Io.net.IpAddress, state: http.Server.ConnState) void {
        const a: *Admission = @ptrCast(@alignCast(ctx.?));
        const peer = peer_or_null orelse {
            if (state == .closed) _ = a.open.fetchSub(1, .monotonic);
            return;
        };
        const now = Io.Clock.awake.now(a.io).nanoseconds;
        switch (state) {
            .new => {
                a.mutex.lockUncancelable(a.io);
                defer a.mutex.unlock(a.io);
                a.live.put(a.gpa, keyOf(peer), .{ .started_ns = now }) catch {}; // untracked: not reported
            },
            .active => {
                a.mutex.lockUncancelable(a.io);
                defer a.mutex.unlock(a.io);
                if (a.live.getPtr(keyOf(peer))) |c| c.requests += 1;
            },
            .idle => {},
            .closed => {
                _ = a.open.fetchSub(1, .monotonic);
                const ip = ipOf(peer);
                if (!ip.isLoopback()) a.guard.connClosed(ip);
                const conn = blk: {
                    a.mutex.lockUncancelable(a.io);
                    defer a.mutex.unlock(a.io);
                    break :blk (a.live.fetchRemove(keyOf(peer)) orelse return).value;
                };
                if (conn.requests > 0) return;
                const ms: i64 = @intCast(@divTrunc(now - conn.started_ns, std.time.ns_per_ms));
                // Held to the read timeout, or closed by the client itself.
                const timed_out = ms >= read_timeout_ms - 500;
                if (timed_out) {
                    _ = events.emit(.warn, .conn, .conn, .of(ip), "action=closed reason=timeout requests=0 ms={d}", .{ms});
                } else {
                    _ = events.emit(.info, .conn, .conn, .of(ip), "action=closed reason=no_request requests=0 ms={d}", .{ms});
                }
            },
        }
    }
};

/// How long a read may stall, and the whole request may take.
const read_timeout_ms = 10_000;

fn ipOf(address: Io.net.IpAddress) netaddr.Ip {
    return switch (address) {
        .ip4 => |a| .{ .v4 = a.bytes },
        .ip6 => |a| .{ .v6 = a.bytes },
    };
}

/// Requests the server refused before the handler (a malformed or
/// oversized head, a body over the cap), handler and server failures. The
/// request was not parsed, so only the socket peer is known.
fn onError(_: ?*anyopaque, kind: http.Server.ErrorKind, err: ?anyerror, status: u16, peer: ?Io.net.IpAddress) void {
    switch (kind) {
        .request_refused => _ = events.emit(.warn, .http, .client, if (peer) |p| .of(ipOf(p)) else null, "status={d} reason=bad_request_head", .{status}),
        .handler_failed, .server_failed => _ = events.emit(.err, .http, .client, if (peer) |p| .of(ipOf(p)) else null, "status={d} reason={t} error={t}", .{
            status, kind, err orelse error.Unknown,
        }),
        .accept_failed => log.warn("accept: {t}", .{err orelse error.Unknown}),
    }
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
    const started = Io.Clock.awake.now(monitor.io).nanoseconds;
    reason = "";
    defer logRequest(req, rw, monitor.io, started);
    return route(monitor, req, rw, arena_state.allocator());
}

/// Which requests become `event=http` lines (`--access-log`).
const AccessLog = enum { refused, all, off };
var access_log: AccessLog = .refused;

/// Why the handler refused the request: a reason code (README, "Security
/// log"), set by `sendError` for `logRequest`. Per thread: a request is
/// handled on its connection's thread from start to end.
threadlocal var reason: []const u8 = "";

fn logRequest(req: *const Request, rw: *const ResponseWriter, io: Io, started: i96) void {
    const status = rw.status;
    if (access_log == .off or (access_log == .refused and status < 400)) return;
    const c = clientOf(req);
    const ms = @divTrunc(Io.Clock.awake.now(io).nanoseconds - started, std.time.ns_per_ms);
    // Keys only some lines have: the X-Forwarded-For a client sent where no
    // proxy is trusted, the name a refused Host header asked for.
    var extra_buf: [1024]u8 = undefined;
    var extra: Io.Writer = .fixed(&extra_buf);
    if (c.xff_ignored) extra.print(" xff_ignored={f}", .{events.quote(req.header("x-forwarded-for") orelse "")}) catch {};
    if (std.mem.eql(u8, reason, "host_not_allowed")) extra.print(" host={f}", .{events.quote(req.header("host") orelse "")}) catch {};
    // What parsers match on comes first: a long line is cut at its end.
    const fields = "status={d} reason={s} method={f} path={f} ms={d} bytes={d} ua={f}{s}";
    const args = .{
        status,                                           if (reason.len > 0) reason else "-", events.quote(req.methodName()),
        events.quote(req.target),                         ms,                                  rw.bodyBytesSent() orelse 0,
        events.quote(req.header("user-agent") orelse ""), extra.buffered(),
    };
    // An error only when the server failed; a 503 for a full trace cap is a refusal.
    if (status >= 500 and reason.len == 0) {
        _ = events.emit(.err, .http, .client, c.who, fields, args);
    } else if (status >= 400) {
        _ = events.emit(.warn, .http, .client, c.who, fields, args);
    } else {
        _ = events.emit(.info, .http, .access, c.who, fields, args);
    }
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
        return sendError(rw, .misdirected_request, "host_not_allowed", "unknown host name; start the server with --allow-host NAME");

    const who = clientOf(req).who;
    if (traceTarget(path)) |id| return routeTrace(monitor, req, rw, id, who, arena);

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
        return sendError(rw, .not_found, "not_found", "not found");
    }

    if (!std.mem.startsWith(u8, path, "/api/targets")) return sendError(rw, .not_found, "not_found", "not found");
    if (monitor.read_only) return sendError(rw, .forbidden, "read_only", "this is a read-only demo");
    // A cross-site form cannot send a JSON content type without a CORS
    // preflight, which this server never approves: a cheap CSRF guard.
    const content_type = req.header("content-type") orelse "";
    if (!std.mem.startsWith(u8, content_type, "application/json"))
        return sendError(rw, .unsupported_media_type, "not_json", "send application/json");

    // POST /api/targets                {"name": ..., "host": ..., "tags": [...]}
    if (method == .post and std.mem.eql(u8, path, "/api/targets")) {
        const NewTarget = struct { name: []const u8, host: []const u8, tags: []const []const u8 = &.{} };
        const body = try readBody(req, arena);
        const parsed = std.json.parseFromSliceLeaky(NewTarget, arena, body, .{}) catch
            return sendError(rw, .bad_request, "bad_json", "expected {\"name\": ..., \"host\": ..., \"tags\": [...]}");
        const id = monitor.add(parsed.name, parsed.host, parsed.tags) catch |err| return sendMonitorError(rw, err);
        _ = events.emit(.info, .audit, .writer, who, "action=add target={d} name={f} host={f} tags={d}", .{
            id, events.quote(parsed.name), events.quote(parsed.host), parsed.tags.len,
        });
        return send(rw, .created, "application/json", try arena.print("{{\"id\":{d}}}", .{id}));
    }

    // DELETE /api/targets/ID, PATCH /api/targets/ID {"name": ..., "host": ..., "tags": [...]},
    // POST /api/targets/ID/{pause,resume,ack,unack},
    // POST /api/targets/ID/tags {"tags": [...]}
    var parts = std.mem.tokenizeScalar(u8, path["/api/targets".len..], '/');
    const id = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return sendError(rw, .not_found, "not_found", "not found");
    const verb = parts.next();
    if (parts.next() != null) return sendError(rw, .not_found, "not_found", "not found");
    // For the audit line: what the target was before the change.
    var was_buf: [256]u8 = undefined;
    const was = monitor.hostOf(id, &was_buf) orelse "";
    if (method == .delete and verb == null) {
        monitor.remove(id) catch |err| return sendMonitorError(rw, err);
        _ = events.emit(.info, .audit, .writer, who, "action=remove target={d} host={f}", .{ id, events.quote(was) });
    } else if (method == .patch and verb == null) {
        const Edit = struct { name: ?[]const u8 = null, host: ?[]const u8 = null, tags: ?[]const []const u8 = null };
        const body = try readBody(req, arena);
        const parsed = std.json.parseFromSliceLeaky(Edit, arena, body, .{}) catch
            return sendError(rw, .bad_request, "bad_json", "expected {\"name\": ..., \"host\": ..., \"tags\": [...]}");
        monitor.edit(id, parsed.name, parsed.host, parsed.tags) catch |err| return sendMonitorError(rw, err);
        var extra_buf: [2048]u8 = undefined;
        var extra: Io.Writer = .fixed(&extra_buf);
        if (parsed.name) |n| extra.print(" name={f}", .{events.quote(n)}) catch {};
        if (parsed.host) |h| extra.print(" host={f} host_was={f}", .{ events.quote(h), events.quote(was) }) catch {};
        if (parsed.tags) |t| extra.print(" tags={d}", .{t.len}) catch {};
        _ = events.emit(.info, .audit, .writer, who, "action=edit target={d}{s}", .{ id, extra.buffered() });
    } else if (method == .post and verb != null and std.mem.eql(u8, verb.?, "tags")) {
        const Tags = struct { tags: []const []const u8 };
        const body = try readBody(req, arena);
        const parsed = std.json.parseFromSliceLeaky(Tags, arena, body, .{}) catch
            return sendError(rw, .bad_request, "bad_json", "expected {\"tags\": [...]}");
        monitor.setTags(id, parsed.tags) catch |err| return sendMonitorError(rw, err);
        _ = events.emit(.info, .audit, .writer, who, "action=tags target={d} host={f} tags={d}", .{ id, events.quote(was), parsed.tags.len });
    } else if (method == .post and verb != null) {
        const action = std.meta.stringToEnum(enum { pause, @"resume", ack, unack }, verb.?) orelse
            return sendError(rw, .not_found, "not_found", "not found");
        monitor.apply(id, switch (action) {
            .pause => .pause,
            .@"resume" => .resume_,
            .ack => .ack,
            .unack => .unack,
        }) catch |err| return sendMonitorError(rw, err);
        _ = events.emit(.info, .audit, .writer, who, "action={t} target={d} host={f}", .{ action, id, events.quote(was) });
    } else return sendError(rw, .method_not_allowed, "bad_method", "method not allowed");
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

/// Who a request comes from: the peer address, or behind a proxy on
/// loopback the last `X-Forwarded-For` entry, the one the proxy itself
/// added (earlier ones come from the client and prove nothing). A peer
/// outside loopback cannot get its header trusted (`xff_ignored`).
fn clientOf(req: *const Request) struct { who: events.Who, xff_ignored: bool } {
    // Served over a socket, a request always has its peer; without one
    // (tests), the unspecified address.
    const peer: netaddr.Ip = if (req.peerAddress()) |p| ipOf(p) else .{ .v4 = @splat(0) };
    var headers = req.iterateHeaders();
    var last: ?[]const u8 = null;
    while (headers.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "x-forwarded-for")) {
        last = h.value;
    };
    const list = last orelse return .{ .who = .of(peer), .xff_ignored = false };
    if (!trust_proxy or !peer.isLoopback()) return .{ .who = .of(peer), .xff_ignored = true };
    const entry = list[if (std.mem.findScalarLast(u8, list, ',')) |c| c + 1 else 0..];
    const client = netaddr.parseIp(std.mem.trim(u8, entry, " \t")) orelse peer;
    return .{ .who = .{ .client = client, .peer = peer }, .xff_ignored = false };
}

/// The viewer a trace request counts against: its client, an IPv6 one by /64.
fn viewerOf(req: *const Request) trace.Viewer {
    return trace.viewerOf(clientOf(req).who.client);
}

/// A live trace measures, it changes nothing: a read-only instance offers it
/// too, bounded by the Tracer (one session per host, a global cap, a start
/// rate, a per-viewer cap, idle and age limits). GET reads it (and keeps
/// watching it), POST starts or joins it, DELETE stops watching it.
fn routeTrace(monitor: *Monitor, req: *Request, rw: *ResponseWriter, id: u32, who: events.Who, arena: std.mem.Allocator) !void {
    const viewer = trace.viewerOf(who.client);
    var buf: [256]u8 = undefined;
    const host = monitor.hostOf(id, &buf) orelse return sendError(rw, .not_found, "no_such_target", "no such target");
    switch (req.method) {
        .get => {
            const found = tracer.json(host, viewer, arena) catch |err| return sendTraceError(rw, err);
            const body = found orelse return sendError(rw, .not_found, "no_trace", "no trace running");
            return send(rw, .ok, "application/json", body);
        },
        .post => {
            // The same CSRF guard as the other writes.
            const content_type = req.header("content-type") orelse "";
            if (!std.mem.startsWith(u8, content_type, "application/json"))
                return sendError(rw, .unsupported_media_type, "not_json", "send application/json");
            tracer.start(host, viewer) catch |err| return sendTraceError(rw, err);
            _ = events.emit(.info, .trace, .client, who, "action=start target={d} host={f}", .{ id, events.quote(host) });
            return send(rw, .accepted, "application/json", "{}");
        },
        .delete => {
            tracer.stop(host, viewer);
            _ = events.emit(.info, .trace, .client, who, "action=stop target={d} host={f}", .{ id, events.quote(host) });
            return send(rw, .ok, "application/json", "{}");
        },
        else => return sendError(rw, .method_not_allowed, "bad_method", "method not allowed"),
    }
}

fn sendTraceError(rw: *ResponseWriter, err: anyerror) !void {
    return switch (err) {
        error.TraceDisabled => sendError(rw, .forbidden, "trace_disabled", "live traces are disabled on this server"),
        error.TooManyTraces => sendError(rw, .service_unavailable, "trace_cap", "too many live traces running; try again in a minute"),
        error.RateLimited => sendError(rw, .too_many_requests, "trace_rate", "too many live traces started in the last minute; try again shortly"),
        error.ViewerLimit => sendError(rw, .too_many_requests, "trace_viewer_limit", std.fmt.comptimePrint("you are watching {d} live traces already; stop one first", .{trace.max_per_viewer})),
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

/// An error answer: `{"error": msg}`, and `code` (README, "Security log")
/// for the request's event line.
fn sendError(rw: *ResponseWriter, status: Status, comptime code: []const u8, msg: []const u8) !void {
    reason = code;
    var buf: [256]u8 = undefined;
    const body = std.mem.print(&buf, "{{\"error\":{f}}}", .{std.json.fmt(msg, .{})}) catch unreachable;
    return send(rw, status, "application/json", body);
}

fn sendMonitorError(rw: *ResponseWriter, err: anyerror) !void {
    return switch (err) {
        error.UnknownTarget => sendError(rw, .not_found, "no_such_target", "no such target"),
        error.InvalidName => sendError(rw, .bad_request, "invalid_name", "name: 1-64 printable characters"),
        error.InvalidHost => sendError(rw, .bad_request, "invalid_host", "host: an IP address or a DNS name"),
        error.InvalidTags => sendError(rw, .bad_request, "invalid_tags", "tags: at most 8, each 1-32 characters, no spaces or commas"),
        error.TooManyTargets => sendError(rw, .conflict, "too_many_targets", "too many targets"),
        error.NotDown => sendError(rw, .conflict, "not_down", "only a DOWN target can be acknowledged"),
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
    events.level = .err; // the refusals' event lines
    defer events.level = .info;
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
