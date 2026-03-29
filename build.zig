const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zigamp",
        .root_module = root_module,
    });
    exe.subsystem = .Windows;

    root_module.linkSystemLibrary("user32", .{});
    root_module.linkSystemLibrary("gdi32", .{});
    root_module.linkSystemLibrary("opengl32", .{});
    root_module.linkSystemLibrary("comdlg32", .{});
    root_module.linkSystemLibrary("shell32", .{});
    root_module.linkSystemLibrary("winmm", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Zig audio player");
    run_step.dependOn(&run_cmd.step);
}
