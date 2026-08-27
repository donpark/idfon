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
    artifacts.exe.step.dependOn(&cargo.step);
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
    artifacts.tests.root_module.linkFramework("SystemConfiguration", .{});
    if (b.sysroot) |sysroot| {
        const frameworks: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) };
        artifacts.exe.root_module.addFrameworkPath(frameworks);
        artifacts.tests.root_module.addFrameworkPath(frameworks);
    }

    const runner = app.module.root_source_file orelse @panic("Generated runner missing");
    const patch = b.addSystemCommand(&.{ "python3", "patch_ts_runner.py" });
    patch.addFileArg(runner);
    app.compile.step.dependOn(&patch.step);
    artifacts.tests.step.dependOn(&patch.step);
}
