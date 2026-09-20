const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux) @panic("LightHouse currently supports Linux only");
    const ghostty_debug = b.option(bool, "ghostty-debug", "Enable Ghostty's expensive internal debug checks") orelse false;
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        // Keep our code debuggable without running upstream's full page
        // integrity scans on every terminal update. ReleaseSafe retains safety.
        .optimize = if (optimize == .Debug and !ghostty_debug) .ReleaseSafe else optimize,
        .@"vt-features" = "-kitty-graphics",
    });
    const toolkit = b.addModule("lighthouse-ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") }},
    });
    const core = b.addModule("LightHouse", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
            .{ .name = "lighthouse-ui", .module = toolkit },
        },
    });
    const exe = b.addExecutable(.{
        .name = "lighthouse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "LightHouse", .module = core }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run LightHouse in the current terminal").dependOn(&run.step);
    const test_filter = b.option([]const u8, "test-filter", "Run unit tests whose names contain this text");
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{ .root_module = core, .filters = filters });
    const ui_tests = b.addTest(.{ .root_module = toolkit, .filters = filters });
    const check_ui = b.addRunArtifact(ui_tests);
    const test_step = b.step("test", "Run application and UI library unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&check_ui.step);
    b.step("test-ui", "Test the UI library independently of the application").dependOn(&check_ui.step);
    const integration_step = b.step("test-integration", "Run Linux PTY integration checks (requires Python 3)");
    for ([_][]const u8{ "tests/pty_smoke.py", "tests/browsing.py", "tests/operations.py", "tests/insertion.py" }) |script| {
        const integration = b.addSystemCommand(&.{ "python3", "-u" });
        integration.addFileArg(b.path(script));
        integration.addArtifactArg(exe);
        integration_step.dependOn(&integration.step);
    }
    const format = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" } });
    b.step("fmt", "Format Zig sources").dependOn(&format.step);
    const format_check = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" }, .check = true });
    b.step("fmt-check", "Check Zig source formatting").dependOn(&format_check.step);
}
