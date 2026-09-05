// freepro GUI build — Zig 0.16.0, standard library only.
const std = @import("std");

const module_names = [_][]const u8{
    "models",
    "rotator",
    "config",
    "proxy",
    "upstream",
    "metrics",
    "logger",
    "netwin",
    "freeproxy",
    "responses",
    "dashboard",
    "updater",
    "ui",
};

/// Test roots that live outside src/*.zig: the library index plus the src/ui/
/// index (which re-exports all four view files, so the whole subdirectory is
/// type-checked through one src/-rooted binary). Each is compiled as its own
/// `zig test` binary with the full named import table wired, mirroring the exe.
const extra_test_roots = [_][]const u8{
    "src/root.zig",
    "src/ui.zig",
};

const release_targets = [_][]const u8{
    "x86_64-windows",
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-macos",
    "aarch64-macos",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // GUI binary (std-only serve+open-browser, fully offline).
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
    });
    if (target.result.os.tag == .windows) gui_mod.linkSystemLibrary("ws2_32", .{});
    addInternalModules(b, gui_mod, target, optimize);
    const gui_exe = b.addExecutable(.{
        .name = "freepro-gui",
        .root_module = gui_mod,
    });
    b.installArtifact(gui_exe);

    const gui_run = b.addRunArtifact(gui_exe);
    gui_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| gui_run.addArgs(args);
    const run_step = b.step("run", "Run the GUI app");
    run_step.dependOn(&gui_run.step);
    const gui_run_step = b.step("run-gui", "Run the windowed GUI binary");
    gui_run_step.dependOn(&gui_run.step);
    const gui_step = b.step("gui", "Build the windowed GUI binary");
    gui_step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit tests for every internal module");
    var previous_test: ?*std.Build.Step = null;
    for (module_names) |name| {
        if (std.mem.eql(u8, name, "netwin") and target.result.os.tag != .windows) continue;
        previous_test = addUnitTest(b, test_step, b.fmt("src/{s}.zig", .{name}), target, optimize, previous_test);
    }
    for (extra_test_roots) |root| {
        previous_test = addUnitTest(b, test_step, root, target, optimize, previous_test);
    }

    const release_all = b.step("release-all", "Cross-compile optimized binaries for all supported targets");
    for (release_targets) |query_string| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = query_string }) catch @panic("invalid release target query");
        const release_target = b.resolveTargetQuery(query);
        const release_mod = b.createModule(.{
            .root_source_file = b.path("src/gui_main.zig"),
            .target = release_target,
            .optimize = .ReleaseSafe,
            .link_libc = release_target.result.os.tag != .windows,
        });
        const release_exe = b.addExecutable(.{
            .name = "freepro",
            .root_module = release_mod,
        });
        if (release_target.result.os.tag == .windows) release_mod.linkSystemLibrary("ws2_32", .{});
        addInternalModules(b, release_mod, release_target, .ReleaseSafe);
        const install = b.addInstallArtifact(release_exe, .{
            .dest_sub_path = b.fmt("{s}/{s}{s}", .{
                query_string,
                "freepro",
                if (std.mem.endsWith(u8, query_string, "windows")) ".exe" else "",
            }),
        });
        release_all.dependOn(&install.step);
    }
}

fn addInternalModules(
    b: *std.Build,
    exe_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    for (module_names) |name| {
        const mod = b.addModule(name, .{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag != .windows,
        });
        exe_mod.addImport(name, mod);
    }
}

/// One `zig test` binary per root source file. The binary's module carries
/// the same named sibling imports as the exe, so test roots may use either
/// relative or `@import("<name>")` style for siblings.
fn addUnitTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    previous: ?*std.Build.Step,
) *std.Build.Step {
    const test_mod = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
    });
    for (module_names) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag != .windows,
        });
        test_mod.addImport(name, mod);
    }
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    if (target.result.os.tag == .windows) test_mod.linkSystemLibrary("ws2_32", .{});
    const run_unit_tests = b.addRunArtifact(unit_tests);
    // Compile independently, but keep socket-owning test executables isolated.
    if (previous) |step| run_unit_tests.step.dependOn(step);
    test_step.dependOn(&run_unit_tests.step);
    return &run_unit_tests.step;
}
