const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hyprland-displays",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    generateAndLinkXdgFiles(b, exe);

    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn generateAndLinkXdgFiles(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const out_dir = "zig-out/wayland-generated";
    const xdg_xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
    const h_out = b.pathJoin(&.{ out_dir, "xdg-shell-client-protocol.h" });
    const c_out = b.pathJoin(&.{ out_dir, "xdg-shell-protocol.c" });

    const mk_gen_dir = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        out_dir,
    });

    const gen_header = b.addSystemCommand(&.{
        "wayland-scanner",
        "client-header",
        xdg_xml,
        h_out,
    });
    gen_header.step.dependOn(&mk_gen_dir.step);
    exe.step.dependOn(&gen_header.step);

    const gen_code = b.addSystemCommand(&.{
        "wayland-scanner",
        "private-code",
        xdg_xml,
        c_out,
    });
    gen_code.step.dependOn(&mk_gen_dir.step);
    exe.step.dependOn(&gen_code.step);

    exe.addIncludePath(.{ .src_path = .{
        .sub_path = out_dir,
        .owner = b,
    } });

    exe.addCSourceFile(.{
        .file = .{ .src_path = .{ .sub_path = c_out, .owner = b } },
        .flags = &[_][]const u8{},
    });
}
