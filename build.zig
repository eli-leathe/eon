const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("temporal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "temporal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "temporal", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.addPassthruArgs();

    run_cmd.step.dependOn(b.getInstallStep());

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const snapshot_exe = b.addExecutable(.{
        .name = "temporal-snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/snapshot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "temporal", .module = mod },
            },
        }),
    });
    const cases_path = b.path("tests/cases");
    b.dependOnDirectory(cases_path);

    const generate_snapshots = b.addRunArtifact(snapshot_exe);
    generate_snapshots.rename_step_with_output_arg = false;
    generate_snapshots.step.name = "generate snapshots";
    generate_snapshots.addDirectoryArg(cases_path);
    addSnapshotInputs(b, generate_snapshots);
    const generated_snapshot = generate_snapshots.addOutputFileArg("parser-tokenizer.snap");

    const snapshot_diff = b.addSystemCommand(&.{
        "git",
        "diff",
        "--no-index",
        "--exit-code",
        "--",
    });
    generate_snapshots.rename_step_with_output_arg = false;
    generate_snapshots.step.name = "snapshot diff";
    snapshot_diff.addFileArg(b.path("tests/snapshots/parser-tokenizer.snap"));
    snapshot_diff.addFileInput(b.path("tests/snapshots/parser-tokenizer.snap"));
    snapshot_diff.addFileArg(generated_snapshot);

    const test_step = b.step("test", "Run unit and snapshot tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&snapshot_diff.step);

    const update_snapshots = b.addRunArtifact(snapshot_exe);
    update_snapshots.addDirectoryArg(b.path("tests/cases"));
    update_snapshots.addArg("tests/snapshots/parser-tokenizer.snap");
    update_snapshots.has_side_effects = true;

    const update_snapshots_step = b.step("update-snapshots", "Accept current parser and tokenizer snapshots");
    update_snapshots_step.dependOn(&update_snapshots.step);
}

fn addSnapshotInputs(b: *std.Build, run: *std.Build.Step.Run) void {
    var cases_dir = b.root.openDir(b.graph.io, "tests/cases", .{ .iterate = true }) catch
        @panic("unable to open tests/cases");
    defer cases_dir.close(b.graph.io);

    var iterator = cases_dir.iterateAssumeFirstIteration();
    while (iterator.next(b.graph.io) catch @panic("unable to iterate tests/cases")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".eon")) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ "tests/cases", entry.name })));
    }
}
