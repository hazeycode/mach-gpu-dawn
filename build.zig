const std = @import("std");
const Builder = std.build.Builder;
const system_sdk = @import("libs/system_sdk.zig");
const gpu_dawn_sdk = @import("sdk.zig");

pub fn build(b: *Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const gpu_dawn = gpu_dawn_sdk.Sdk(.{
        .glfw_include_dir = "libs/glfw/include",
        .system_sdk = system_sdk,
    });

    const options = gpu_dawn.Options{
        .install_libs = true,
        .from_source = true,
    };

    const exe = b.addExecutable("exe", null);
    exe.setBuildMode(mode);
    exe.setTarget(target);
    try gpu_dawn.link(b, exe, options);
}
