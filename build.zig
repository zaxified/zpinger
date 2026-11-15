const std = @import("std");

// zig-libs is a package dependency; its modules are taken from it by name.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default: every safety check stays on, which is what a
    // network-facing daemon wants.
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode (default: safe)") orelse .safe;
    // LLVM unless -Dselfhosted: the self-hosted backend is for the edit loop only.
    const selfhosted = b.option(bool, "selfhosted", "Use Zig's self-hosted backend (edit loop only)") orelse false;
    const use_llvm: ?bool = if (selfhosted) null else true;
    const strip = b.option(bool, "strip", "Strip debug info (bundle.sh does)");

    const version = @import("build.zig.zon").version;
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // No DNS over HTTPS or TLS: trace hop names use the system resolver, and
    // the http/TLS stack either one needs would quadruple the code.
    const zig_libs = b.dependency("zig_libs", .{ .target = target, .optimize = optimize, .@"dns-doh" = false, .@"dns-dot" = false });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "abuseguard", .module = zig_libs.module("abuseguard") },
            .{ .name = "datefmt", .module = zig_libs.module("datefmt") },
            .{ .name = "dns", .module = zig_libs.module("dns") },
            .{ .name = "filestore", .module = zig_libs.module("filestore") },
            .{ .name = "http", .module = zig_libs.module("http") },
            .{ .name = "icmp", .module = zig_libs.module("icmp") },
            .{ .name = "netaddr", .module = zig_libs.module("netaddr") },
            .{ .name = "netlink", .module = zig_libs.module("netlink") },
            .{ .name = "ratelimit", .module = zig_libs.module("ratelimit") },
            .{ .name = "security-headers", .module = zig_libs.module("security-headers") },
            .{ .name = "traceroute", .module = zig_libs.module("traceroute") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{ .name = "zpinger", .root_module = mod, .use_llvm = use_llvm });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run (pass options after --, e.g. -- --listen 127.0.0.1:8080)").dependOn(&run.step);

    // The tests also get zig-libs testkit (fuzz driver, goldens), which the
    // daemon never links: a module of their own with one more import.
    const test_mod = b.createModule(.{
        .root_source_file = mod.root_source_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "testkit", .module = zig_libs.module("testkit") }},
    });
    var it = mod.import_table.iterator();
    while (it.next()) |e| test_mod.addImport(e.key_ptr.*, e.value_ptr.*);
    const tests = b.addTest(.{ .name = "zpinger-test", .root_module = test_mod, .use_llvm = use_llvm });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The test binary itself, for a fuzz verdict (src/fuzz_test.zig): a run
    // step is cached and reads no environment, so ZPINGER_FUZZ needs the binary.
    b.step("test-bin", "Install the unit test binary (zig-out/bin/zpinger-test)").dependOn(&b.addInstallArtifact(tests, .{}).step);

    // The about page for a demo hub, from deploy/about.json, into
    // zig-out/about/ (scripts/package.sh ships it in the .deb). A host tool, not
    // part of the daemon.
    const about_mod = b.createModule(.{
        .root_source_file = b.path("tools/about.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    const about_tool = b.addExecutable(.{ .name = "about", .root_module = about_mod, .use_llvm = use_llvm });
    const gen = b.addRunArtifact(about_tool);
    gen.addFileArg(b.path("deploy/about.json"));
    gen.addArg(version);
    const about_step = b.step("about", "Generate the about page into zig-out/about/");
    inline for (.{ "about.json", "about.html", "about-card.html" }) |name|
        about_step.dependOn(&b.addInstallFile(gen.addOutputFileArg(name), "about/" ++ name).step);
    about_step.dependOn(&b.addInstallFile(b.path("doc/screenshot.png"), "about/screenshot.png").step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = about_mod, .use_llvm = use_llvm })).step);
}
