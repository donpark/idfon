const std = @import("std");
const native_sdk = @import("native_sdk");

const AppCode = struct { module: *std.Build.Module, compile: *std.Build.Step.Compile };

fn appCode(exe: *std.Build.Step.Compile) AppCode {
    for (exe.root_module.link_objects.items) |link| switch (link) {
        .other_step => |step| if (step.root_module.root_source_file != null) return .{ .module = step.root_module, .compile = step },
        else => {},
    };
    @panic("TypeScript app code object not found");
}

fn hostModule(b: *std.Build, parent: *std.Build.Module, sdk: *std.Build.Module) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path("src/iroh_ffi.zig"), .target = parent.resolved_target.?, .optimize = parent.optimize.? });
    module.addImport("native_sdk", sdk);
    module.addIncludePath(b.path("vendor/iroh-c-ffi"));
    module.link_libc = true;
    return module;
}

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "Nufon", .manifest = "app.json" });
    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--manifest-path", "vendor/iroh-c-ffi/Cargo.toml" });
    const daemon = b.addSystemCommand(&.{ "cargo", "build", "--release", "-p", "nufond" });
    const daemon_rpath = b.addSystemCommand(&.{ "install_name_tool", "-add_rpath", "/usr/lib/swift", "../target/release/nufond" });
    daemon_rpath.step.dependOn(&daemon.step);
    artifacts.exe.step.dependOn(&cargo.step);
    artifacts.exe.step.dependOn(&daemon_rpath.step);
    artifacts.tests.step.dependOn(&cargo.step);

    const app = appCode(artifacts.exe);
    const app_sdk = app.module.import_table.get("native_sdk") orelse @panic("Native SDK module missing");
    app.module.addImport("iroh_host", hostModule(b, app.module, app_sdk));
    const test_sdk = artifacts.tests.root_module.import_table.get("native_sdk") orelse @panic("Native SDK test module missing");
    artifacts.tests.root_module.addImport("iroh_host", hostModule(b, artifacts.tests.root_module, test_sdk));

    const archive = b.path("vendor/iroh-c-ffi/target/release/libiroh_c_ffi.a");
    artifacts.exe.root_module.addObjectFile(archive);
    artifacts.tests.root_module.addObjectFile(archive);
    artifacts.exe.root_module.linkFramework("SystemConfiguration", .{});
    artifacts.exe.root_module.linkFramework("CoreAudio", .{});
    artifacts.exe.root_module.linkFramework("AudioToolbox", .{});
    artifacts.tests.root_module.linkFramework("SystemConfiguration", .{});
    artifacts.tests.root_module.linkFramework("CoreAudio", .{});
    artifacts.tests.root_module.linkFramework("AudioToolbox", .{});
    if (b.sysroot) |sysroot| {
        const frameworks: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) };
        artifacts.exe.root_module.addFrameworkPath(frameworks);
        artifacts.tests.root_module.addFrameworkPath(frameworks);
        // cpal's macOS backend uses the Swift Dispatch bridge. Rust links it
        // transitively, but the final Zig link must provide the Swift runtime.
        const developer_dir = std.mem.trimEnd(u8, b.run(&.{ "xcode-select", "--print-path" }), "\r\n");
        const swift_dir = b.pathJoin(&.{ developer_dir, "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift" });
        const swift_core: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ swift_dir, "libswiftCore.tbd" }) };
        const swift_dispatch: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ swift_dir, "libswiftDispatch.tbd" }) };
        const swift_core_foundation: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ swift_dir, "libswiftCoreFoundation.tbd" }) };
        const swift_iokit: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ swift_dir, "libswiftIOKit.tbd" }) };
        const swift_objc: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ swift_dir, "libswiftObjectiveC.tbd" }) };
        const swift_xpc: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ swift_dir, "libswiftXPC.tbd" }) };
        const swift_float: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ swift_dir, "libswift_Builtin_float.tbd" }) };
        for ([_]std.Build.LazyPath{ swift_core, swift_dispatch, swift_core_foundation, swift_iokit, swift_objc, swift_xpc, swift_float }) |library| {
            artifacts.exe.root_module.addObjectFile(library);
            artifacts.tests.root_module.addObjectFile(library);
        }
    }

    const runner = app.module.root_source_file orelse @panic("Generated runner missing");
    const patch = b.addSystemCommand(&.{ "python3", "patch_ts_runner.py" });
    patch.addFileArg(runner);
    app.compile.step.dependOn(&patch.step);
    artifacts.tests.step.dependOn(&patch.step);
}
