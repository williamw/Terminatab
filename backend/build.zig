const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WebSocket dependency
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "terminatab-server",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    exe.linkLibC();
    // forkpty() lives in libutil on Linux
    if (exe.rootModuleTarget().os.tag == .linux) {
        exe.linkSystemLibrary("util");
    }
    // macOS menu bar app (NSApplication + NSStatusItem)
    if (exe.rootModuleTarget().os.tag == .macos) {
        exe.addCSourceFile(.{
            .file = b.path("src/macos_app.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.linkFramework("Cocoa");
    }
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_modules = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "protocol", .path = "src/protocol.zig" },
        .{ .name = "pty", .path = "src/pty.zig" },
        .{ .name = "session", .path = "src/session.zig" },
        .{ .name = "ws_handler", .path = "src/ws_handler.zig" },
    };

    const test_step = b.step("test", "Run unit tests");

    for (test_modules) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod.path),
            .target = target,
            .optimize = optimize,
        });
        unit_test.linkLibC();
        if (unit_test.rootModuleTarget().os.tag == .linux) {
            unit_test.linkSystemLibrary("util");
        }

        // Add cross-module imports so tests can reference sibling modules
        unit_test.root_module.addImport("websocket", websocket_dep.module("websocket"));

        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}
