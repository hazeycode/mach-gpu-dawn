const std = @import("std");
const Builder = std.build.Builder;

pub fn Sdk(comptime deps: anytype) type {
    return struct {
        pub const LinuxWindowManager = enum {
            X11,
            Wayland,
        };

        pub const Options = struct {
            /// Defaults to X11 on Linux.
            linux_window_manager: ?LinuxWindowManager = null,

            /// Defaults to true on Windows
            d3d12: ?bool = null,

            /// Defaults to true on Darwin
            metal: ?bool = null,

            /// Defaults to true on Linux
            vulkan: ?bool = null,

            /// Detects the default options to use for the given target.
            pub fn detectDefaults(self: Options, target: std.Target) Options {
                const tag = target.os.tag;
                const linux_desktop_like = isLinuxDesktopLike(target);

                var options = self;
                if (options.linux_window_manager == null and linux_desktop_like) options.linux_window_manager = .X11;
                if (options.d3d12 == null) options.d3d12 = tag == .windows;
                if (options.metal == null) options.metal = tag.isDarwin();
                if (options.vulkan == null) options.vulkan = linux_desktop_like;

                return options;
            }

            pub fn appendFlags(self: Options, flags: *std.ArrayList([]const u8), is_cpp: bool) !void {
                if (is_cpp) try flags.append("-std=c++17");
                if (self.linux_window_manager != null and self.linux_window_manager.? == .X11)
                    try flags.append("-DDAWN_USE_X11");
            }
        };

        pub fn link(b: *Builder, step: *std.build.LibExeObjStep, options: Options) !void {
            const opt = options.detectDefaults(step.target_info.target);
            try linkFromSource(b, step, opt);
        }

        fn linkFromSource(b: *Builder, step: *std.build.LibExeObjStep, options: Options) !void {
            // branch: generated-2022-11-04
            try ensureGitRepoCloned(
                b.allocator,
                "https://github.com/michal-z/dawn",
                "762e368b218678e19b6c1030075ec82e370806cc",
                sdkPath("/libs/dawn"),
            );

            // branch: release-1.7.2207
            try ensureGitRepoCloned(
                b.allocator,
                "https://github.com/michal-z/DirectXShaderCompiler",
                "516b26406ff515d28b42c3e61b497058e81622ba",
                sdkPath("/libs/DirectXShaderCompiler"),
            );

            step.addIncludePath(sdkPath("/libs/dawn/out/Debug/gen/include"));
            step.addIncludePath(sdkPath("/libs/dawn/include"));
            step.addIncludePath(sdkPath("/src/dawn"));

            const lib_dawn = b.addStaticLibrary("dawn", null);
            lib_dawn.setBuildMode(.ReleaseFast);
            lib_dawn.setTarget(step.target);
            lib_dawn.strip = true;
            lib_dawn.linkSystemLibraryName("c++");
            lib_dawn.install();
            step.linkLibrary(lib_dawn);

            _ = try buildLibDawnCommon(b, lib_dawn, options);
            _ = try buildLibDawnPlatform(b, lib_dawn, options);
            _ = try buildLibAbseilCpp(b, lib_dawn, options);
            _ = try buildLibDawnNative(b, lib_dawn, options);
            _ = try buildLibDawnUtils(b, lib_dawn, options);
            _ = try buildLibSPIRVTools(b, lib_dawn, options);
            _ = try buildLibTint(b, lib_dawn, options);
            if (options.d3d12.?) _ = try buildLibDxcompiler(b, lib_dawn, options);
        }

        fn ensureGitRepoCloned(
            allocator: std.mem.Allocator,
            clone_url: []const u8,
            revision: []const u8,
            dir: []const u8,
        ) !void {
            ensureGit(allocator);

            if (std.fs.openDirAbsolute(dir, .{})) |_| {
                const current_revision = try getCurrentGitRevision(allocator, dir);
                if (!std.mem.eql(u8, current_revision, revision)) {
                    // Reset to the desired revision
                    exec(allocator, &[_][]const u8{ "git", "fetch" }, dir) catch |err| std.debug.print(
                        "warning: failed to 'git fetch' in {s}: {s}\n",
                        .{ dir, @errorName(err) },
                    );
                    try exec(allocator, &[_][]const u8{ "git", "reset", "--quiet", "--hard", revision }, dir);
                    // NOTE(mziulek): We don't need submodules.
                    //try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
                }
                return;
            } else |err| return switch (err) {
                error.FileNotFound => {
                    std.log.info("cloning required dependency..\ngit clone {s} {s}..\n", .{ clone_url, dir });

                    try exec(allocator, &[_][]const u8{ "git", "clone", "-c", "core.longpaths=true", clone_url, dir }, sdkPath("/"));
                    try exec(allocator, &[_][]const u8{ "git", "reset", "--quiet", "--hard", revision }, dir);
                    // NOTE(mziulek): We don't need submodules.
                    //try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
                    return;
                },
                else => err,
            };
        }

        fn exec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !void {
            var child = std.ChildProcess.init(argv, allocator);
            child.cwd = cwd;
            _ = try child.spawnAndWait();
        }

        fn getCurrentGitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
            const result = try std.ChildProcess.exec(
                .{ .allocator = allocator, .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = cwd },
            );
            allocator.free(result.stderr);
            if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
            return result.stdout;
        }

        fn ensureGit(allocator: std.mem.Allocator) void {
            const argv = &[_][]const u8{ "git", "--version" };
            const result = std.ChildProcess.exec(.{
                .allocator = allocator,
                .argv = argv,
                .cwd = ".",
            }) catch { // e.g. FileNotFound
                std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
                std.process.exit(1);
            };
            defer {
                allocator.free(result.stderr);
                allocator.free(result.stdout);
            }
            if (result.term.Exited != 0) {
                std.log.err("mach: error: 'git --version' failed. Is git not installed?", .{});
                std.process.exit(1);
            }
        }

        fn isLinuxDesktopLike(target: std.Target) bool {
            const tag = target.os.tag;
            return !tag.isDarwin() and tag != .windows and tag != .fuchsia and tag != .emscripten and
                !target.isAndroid();
        }

        // Builds common sources; derived from src/common/BUILD.gn
        fn buildLibDawnCommon(
            b: *Builder,
            lib: *std.build.LibExeObjStep,
            options: Options,
        ) !*std.build.LibExeObjStep {
            var flags = std.ArrayList([]const u8).init(b.allocator);
            try flags.appendSlice(&.{
                include("libs/dawn/src"),
                include("libs/dawn/out/Debug/gen/include"),
                include("libs/dawn/out/Debug/gen/src"),
            });
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/dawn/common/",
                    "libs/dawn/out/Debug/gen/src/dawn/common/",
                },
                .flags = flags.items,
                .excluding_contains = &.{
                    "test",
                    "benchmark",
                    "mock",
                    "WindowsUtils.cpp",
                },
            });

            var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
            if (lib.target_info.target.os.tag == .macos) {
                deps.system_sdk.include(b, lib, .{});
                lib.linkFramework("Foundation");
                const abs_path = sdkPath("/libs/dawn/src/dawn/common/SystemUtils_mac.mm");
                try cpp_sources.append(abs_path);
            }
            if (lib.target_info.target.os.tag == .windows) {
                const abs_path = sdkPath("/libs/dawn/src/dawn/common/WindowsUtils.cpp");
                try cpp_sources.append(abs_path);
            }

            var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
            try cpp_flags.appendSlice(flags.items);
            try options.appendFlags(&cpp_flags, true);
            lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
            return lib;
        }

        // Build dawn platform sources; derived from src/dawn/platform/BUILD.gn
        fn buildLibDawnPlatform(
            b: *Builder,
            lib: *std.build.LibExeObjStep,
            options: Options,
        ) !*std.build.LibExeObjStep {
            var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
            try options.appendFlags(&cpp_flags, true);
            try cpp_flags.appendSlice(&.{
                include("libs/dawn/src"),
                include("libs/dawn/include"),

                include("libs/dawn/out/Debug/gen/include"),
            });

            var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
            inline for ([_][]const u8{
                "src/dawn/platform/DawnPlatform.cpp",
                "src/dawn/platform/WorkerThread.cpp",
                "src/dawn/platform/tracing/EventTracer.cpp",
            }) |path| {
                const abs_path = sdkPath("/libs/dawn/" ++ path);
                try cpp_sources.append(abs_path);
            }

            lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
            return lib;
        }

        fn appendDawnEnableBackendTypeFlags(flags: *std.ArrayList([]const u8), options: Options) !void {
            const d3d12 = "-DDAWN_ENABLE_BACKEND_D3D12";
            const metal = "-DDAWN_ENABLE_BACKEND_METAL";
            const vulkan = "-DDAWN_ENABLE_BACKEND_VULKAN";

            if (options.d3d12.?) try flags.append(d3d12);
            if (options.metal.?) try flags.append(metal);
            if (options.vulkan.?) try flags.append(vulkan);
        }

        const dawn_d3d12_flags = &[_][]const u8{
            "-DDAWN_NO_WINDOWS_UI",
            "-D__EMULATE_UUID=1",
            "-Wno-nonportable-include-path",
            "-Wno-extern-c-compat",
            "-Wno-invalid-noreturn",
            "-Wno-pragma-pack",
            "-Wno-microsoft-template-shadow",
            "-Wno-unused-command-line-argument",
            "-Wno-microsoft-exception-spec",
            "-Wno-implicit-exception-spec-mismatch",
            "-Wno-unknown-attributes",
            "-Wno-c++20-extensions",
            "-D_CRT_SECURE_NO_WARNINGS",
            "-DWIN32_LEAN_AND_MEAN",
            "-DD3D10_ARBITRARY_HEADER_ORDERING",
            "-DNOMINMAX",
        };

        // Builds dawn native sources; derived from src/dawn/native/BUILD.gn
        fn buildLibDawnNative(
            b: *Builder,
            lib: *std.build.LibExeObjStep,
            options: Options,
        ) !*std.build.LibExeObjStep {
            deps.system_sdk.include(b, lib, .{});

            var flags = std.ArrayList([]const u8).init(b.allocator);
            try appendDawnEnableBackendTypeFlags(&flags, options);
            try flags.appendSlice(&.{
                include("libs/dawn"),
                include("libs/dawn/src"),
                include("libs/dawn/include"),
                include("libs/dawn/third_party/vulkan-deps/spirv-tools/src/include"),
                include("libs/dawn/third_party/abseil-cpp"),
                include("libs/dawn/third_party/khronos"),

                "-DTINT_BUILD_SPV_READER=1",
                "-DTINT_BUILD_SPV_WRITER=1",
                "-DTINT_BUILD_WGSL_READER=1",
                "-DTINT_BUILD_WGSL_WRITER=1",
                "-DTINT_BUILD_MSL_WRITER=1",
                "-DTINT_BUILD_HLSL_WRITER=1",
                "-DTINT_BUILD_GLSL_WRITER=0",

                include("libs/dawn/"),
                include("libs/dawn/include/tint"),
                include("libs/dawn/third_party/vulkan-deps/vulkan-tools/src/"),

                include("libs/dawn/out/Debug/gen/include"),
                include("libs/dawn/out/Debug/gen/src"),
            });
            if (options.d3d12.?) try flags.appendSlice(dawn_d3d12_flags);

            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/out/Debug/gen/src/dawn/",
                    "libs/dawn/src/dawn/native/",
                    "libs/dawn/src/dawn/native/utils/",
                    "libs/dawn/src/dawn/native/stream/",
                },
                .flags = flags.items,
                .excluding_contains = &.{
                    "test",
                    "benchmark",
                    "mock",
                    "SpirvValidation.cpp",
                    "XlibXcbFunctions.cpp",
                },
            });

            // dawn_native_gen
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/out/Debug/gen/src/dawn/native/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "benchmark", "mock", "webgpu_dawn_native_proc.cpp" },
            });

            // TODO(build-system): could allow enable_vulkan_validation_layers here. See src/dawn/native/BUILD.gn

            var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
            if (options.d3d12.?) {
                lib.linkSystemLibraryName("dxgi");
                lib.linkSystemLibraryName("dxguid");

                inline for ([_][]const u8{
                    "src/dawn/mingw_helpers.cpp",
                }) |path| {
                    const abs_path = sdkPath("/" ++ path);
                    try cpp_sources.append(abs_path);
                }

                try appendLangScannedSources(b, lib, options, .{
                    .rel_dirs = &.{
                        "libs/dawn/src/dawn/native/d3d12/",
                    },
                    .flags = flags.items,
                    .excluding_contains = &.{ "test", "benchmark", "mock" },
                });
            }
            if (options.metal.?) {
                lib.linkFramework("Metal");
                lib.linkFramework("CoreGraphics");
                lib.linkFramework("Foundation");
                lib.linkFramework("IOKit");
                lib.linkFramework("IOSurface");
                lib.linkFramework("QuartzCore");

                try appendLangScannedSources(b, lib, options, .{
                    .objc = true,
                    .rel_dirs = &.{
                        "libs/dawn/src/dawn/native/metal/",
                        "libs/dawn/src/dawn/native/",
                    },
                    .flags = flags.items,
                    .excluding_contains = &.{ "test", "benchmark", "mock" },
                });
            }

            if (options.linux_window_manager != null and options.linux_window_manager.? == .X11) {
                lib.linkSystemLibraryName("X11");
                inline for ([_][]const u8{
                    "src/dawn/native/XlibXcbFunctions.cpp",
                }) |path| {
                    const abs_path = sdkPath("/libs/dawn/" ++ path);
                    try cpp_sources.append(abs_path);
                }
            }

            if (options.vulkan.?) {
                inline for ([_][]const u8{
                    "src/dawn/native/SpirvValidation.cpp",
                }) |path| {
                    const abs_path = sdkPath("/libs/dawn/" ++ path);
                    try cpp_sources.append(abs_path);
                }
            }

            if (options.vulkan.?) {
                try appendLangScannedSources(b, lib, options, .{
                    .rel_dirs = &.{
                        "libs/dawn/src/dawn/native/vulkan/",
                    },
                    .flags = flags.items,
                    .excluding_contains = &.{ "test", "benchmark", "mock" },
                });

                if (isLinuxDesktopLike(lib.target_info.target)) {
                    inline for ([_][]const u8{
                        "src/dawn/native/vulkan/external_memory/MemoryService.cpp",
                        "src/dawn/native/vulkan/external_memory/MemoryServiceOpaqueFD.cpp",
                        "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceFD.cpp",
                    }) |path| {
                        const abs_path = sdkPath("/libs/dawn/" ++ path);
                        try cpp_sources.append(abs_path);
                    }
                } else if (lib.target_info.target.os.tag == .fuchsia) {
                    inline for ([_][]const u8{
                        "src/dawn/native/vulkan/external_memory/MemoryServiceZirconHandle.cpp",
                        "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceZirconHandle.cpp",
                    }) |path| {
                        const abs_path = sdkPath("/libs/dawn/" ++ path);
                        try cpp_sources.append(abs_path);
                    }
                } else {
                    inline for ([_][]const u8{
                        "src/dawn/native/vulkan/external_memory/MemoryServiceNull.cpp",
                        "src/dawn/native/vulkan/external_semaphore/SemaphoreServiceNull.cpp",
                    }) |path| {
                        const abs_path = sdkPath("/libs/dawn/" ++ path);
                        try cpp_sources.append(abs_path);
                    }
                }
            }

            if (options.d3d12.?) {
                inline for ([_][]const u8{
                    "src/dawn/native/d3d12/D3D12Backend.cpp",
                }) |path| {
                    const abs_path = sdkPath("/libs/dawn/" ++ path);
                    try cpp_sources.append(abs_path);
                }
            }
            if (options.vulkan.?) {
                inline for ([_][]const u8{
                    "src/dawn/native/vulkan/VulkanBackend.cpp",
                }) |path| {
                    const abs_path = sdkPath("/libs/dawn/" ++ path);
                    try cpp_sources.append(abs_path);
                }
            }

            var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
            try cpp_flags.appendSlice(flags.items);
            try options.appendFlags(&cpp_flags, true);
            lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
            return lib;
        }

        // Builds tint sources; derived from src/tint/BUILD.gn
        fn buildLibTint(b: *Builder, lib: *std.build.LibExeObjStep, options: Options) !*std.build.LibExeObjStep {
            var flags = std.ArrayList([]const u8).init(b.allocator);
            try flags.appendSlice(&.{
                "-DTINT_BUILD_SPV_READER=1",
                "-DTINT_BUILD_SPV_WRITER=1",
                "-DTINT_BUILD_WGSL_READER=1",
                "-DTINT_BUILD_WGSL_WRITER=1",
                "-DTINT_BUILD_MSL_WRITER=1",
                "-DTINT_BUILD_HLSL_WRITER=1",
                "-DTINT_BUILD_GLSL_WRITER=0",

                include("libs/dawn/"),
                include("libs/dawn/include/tint"),

                include("libs/dawn/third_party/vulkan-deps"),
                include("libs/dawn/third_party/vulkan-deps/spirv-tools/src"),
                include("libs/dawn/third_party/vulkan-deps/spirv-tools/src/include"),
                include("libs/dawn/third_party/vulkan-deps/spirv-headers/src/include"),
                include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src"),
                include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src/include"),
                include("libs/dawn/include"),
            });

            // libtint_core_all_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint",
                    "libs/dawn/src/tint/diagnostic/",
                    "libs/dawn/src/tint/inspector/",
                    "libs/dawn/src/tint/resolver/",
                    "libs/dawn/src/tint/utils/",
                    "libs/dawn/src/tint/text/",
                    "libs/dawn/src/tint/transform/",
                    "libs/dawn/src/tint/transform/utils",
                    "libs/dawn/src/tint/reader/",
                    "libs/dawn/src/tint/writer/",
                    "libs/dawn/src/tint/ast/",
                },
                .flags = flags.items,
                .excluding_contains = &.{
                    "test",
                    "bench",
                    "printer_windows",
                    "printer_linux",
                    "printer_other",
                    "glsl.cc",
                },
            });

            var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
            switch (lib.target_info.target.os.tag) {
                .windows => try cpp_sources.append(sdkPath("/libs/dawn/src/tint/diagnostic/printer_windows.cc")),
                .linux => try cpp_sources.append(sdkPath("/libs/dawn/src/tint/diagnostic/printer_linux.cc")),
                else => try cpp_sources.append(sdkPath("/libs/dawn/src/tint/diagnostic/printer_other.cc")),
            }

            // libtint_sem_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint/sem/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "benchmark" },
            });

            // libtint_spv_reader_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint/reader/spirv/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "benchmark" },
            });

            // libtint_spv_writer_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint/writer/spirv/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "bench" },
            });

            // libtint_wgsl_reader_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint/reader/wgsl/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "bench" },
            });

            // libtint_wgsl_writer_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint/writer/wgsl/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "bench" },
            });

            // libtint_msl_writer_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint/writer/msl/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "bench" },
            });

            // libtint_hlsl_writer_src
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/src/tint/writer/hlsl/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "bench" },
            });

            var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
            try cpp_flags.appendSlice(flags.items);
            try options.appendFlags(&cpp_flags, true);
            lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
            return lib;
        }

        // Builds third_party/vulkan-deps/spirv-tools sources;
        // derived from third_party/vulkan-deps/spirv-tools/src/BUILD.gn
        fn buildLibSPIRVTools(
            b: *Builder,
            lib: *std.build.LibExeObjStep,
            options: Options,
        ) !*std.build.LibExeObjStep {
            var flags = std.ArrayList([]const u8).init(b.allocator);
            try flags.appendSlice(&.{
                include("libs/dawn"),
                include("libs/dawn/third_party/vulkan-deps/spirv-tools/src"),
                include("libs/dawn/third_party/vulkan-deps/spirv-tools/src/include"),
                include("libs/dawn/third_party/vulkan-deps/spirv-headers/src/include"),
                include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src"),
                include("libs/dawn/out/Debug/gen/third_party/vulkan-deps/spirv-tools/src/include"),
                include("libs/dawn/third_party/vulkan-deps/spirv-headers/src/include/spirv/unified1"),
            });

            // spvtools
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/",
                    "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/util/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "benchmark" },
            });

            // spvtools_val
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/val/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "benchmark" },
            });

            // spvtools_opt
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/opt/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "benchmark" },
            });

            // spvtools_link
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/third_party/vulkan-deps/spirv-tools/src/source/link/",
                },
                .flags = flags.items,
                .excluding_contains = &.{ "test", "benchmark" },
            });
            return lib;
        }

        // Builds third_party/abseil sources; derived from:
        //
        // ```
        // $ find third_party/abseil-cpp/absl | grep '\.cc' | grep -v 'test' | grep -v 'benchmark' | grep -v gaussian_distribution_gentables | grep -v print_hash_of | grep -v chi_square
        // ```
        //
        fn buildLibAbseilCpp(
            b: *Builder,
            lib: *std.build.LibExeObjStep,
            options: Options,
        ) !*std.build.LibExeObjStep {
            deps.system_sdk.include(b, lib, .{});

            const target = lib.target_info.target;
            if (target.os.tag == .macos) lib.linkFramework("CoreFoundation");
            if (target.os.tag == .windows) lib.linkSystemLibraryName("bcrypt");

            var flags = std.ArrayList([]const u8).init(b.allocator);
            try flags.appendSlice(&.{
                include("libs/dawn"),
                include("libs/dawn/third_party/abseil-cpp"),
            });
            if (target.os.tag == .windows) try flags.appendSlice(&.{
                "-DABSL_FORCE_THREAD_IDENTITY_MODE=2",
                "-DWIN32_LEAN_AND_MEAN",
                "-DD3D10_ARBITRARY_HEADER_ORDERING",
                "-D_CRT_SECURE_NO_WARNINGS",
                "-DNOMINMAX",
                include("src/dawn/zig_mingw_pthread"),
            });

            // absl
            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/dawn/third_party/abseil-cpp/absl/strings/",
                    "libs/dawn/third_party/abseil-cpp/absl/strings/internal/",
                    "libs/dawn/third_party/abseil-cpp/absl/strings/internal/str_format/",
                    "libs/dawn/third_party/abseil-cpp/absl/numeric/",
                    "libs/dawn/third_party/abseil-cpp/absl/base/internal/",
                    "libs/dawn/third_party/abseil-cpp/absl/base/",

                    // NOTE(mziulek): Still builds fine without those and saves ~1.5 MB
                    //"libs/dawn/third_party/abseil-cpp/absl/types/",
                    //"libs/dawn/third_party/abseil-cpp/absl/flags/internal/",
                    //"libs/dawn/third_party/abseil-cpp/absl/flags/",
                    //"libs/dawn/third_party/abseil-cpp/absl/synchronization/",
                    //"libs/dawn/third_party/abseil-cpp/absl/synchronization/internal/",
                    //"libs/dawn/third_party/abseil-cpp/absl/hash/internal/",
                    //"libs/dawn/third_party/abseil-cpp/absl/debugging/",
                    //"libs/dawn/third_party/abseil-cpp/absl/debugging/internal/",
                    //"libs/dawn/third_party/abseil-cpp/absl/status/",
                    //"libs/dawn/third_party/abseil-cpp/absl/time/internal/cctz/src/",
                    //"libs/dawn/third_party/abseil-cpp/absl/time/",
                    //"libs/dawn/third_party/abseil-cpp/absl/container/internal/",
                    //"libs/dawn/third_party/abseil-cpp/absl/random/",
                    //"libs/dawn/third_party/abseil-cpp/absl/random/internal/",
                },
                .flags = flags.items,
                .excluding_contains = &.{
                    "_test",
                    "_testing",
                    "benchmark",
                    "print_hash_of.cc",
                    "gaussian_distribution_gentables.cc",
                },
            });
            return lib;
        }

        // Builds dawn utils sources; derived from src/dawn/utils/BUILD.gn
        fn buildLibDawnUtils(
            b: *Builder,
            lib: *std.build.LibExeObjStep,
            options: Options,
        ) !*std.build.LibExeObjStep {
            var flags = std.ArrayList([]const u8).init(b.allocator);
            try appendDawnEnableBackendTypeFlags(&flags, options);
            try flags.appendSlice(&.{
                include(deps.glfw_include_dir),
                include("libs/dawn/src"),
                include("libs/dawn/include"),
                include("libs/dawn/out/Debug/gen/include"),
            });

            var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
            inline for ([_][]const u8{
                "src/dawn/utils/BackendBinding.cpp",
            }) |path| {
                const abs_path = sdkPath("/libs/dawn/" ++ path);
                try cpp_sources.append(abs_path);
            }

            if (options.d3d12.?) {
                inline for ([_][]const u8{
                    "src/dawn/utils/D3D12Binding.cpp",
                }) |path| {
                    const abs_path = sdkPath("/libs/dawn/" ++ path);
                    try cpp_sources.append(abs_path);
                }
                try flags.appendSlice(dawn_d3d12_flags);
            }
            if (options.metal.?) {
                inline for ([_][]const u8{
                    "src/dawn/utils/MetalBinding.mm",
                }) |path| {
                    const abs_path = sdkPath("/libs/dawn/" ++ path);
                    try cpp_sources.append(abs_path);
                }
            }

            if (options.vulkan.?) {
                inline for ([_][]const u8{
                    "src/dawn/utils/VulkanBinding.cpp",
                }) |path| {
                    const abs_path = sdkPath("/libs/dawn/" ++ path);
                    try cpp_sources.append(abs_path);
                }
            }

            var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
            try cpp_flags.appendSlice(flags.items);
            try options.appendFlags(&cpp_flags, true);
            lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);
            return lib;
        }

        // Buids dxcompiler sources; derived from libs/DirectXShaderCompiler/CMakeLists.txt
        fn buildLibDxcompiler(
            b: *Builder,
            lib: *std.build.LibExeObjStep,
            options: Options,
        ) !*std.build.LibExeObjStep {
            deps.system_sdk.include(b, lib, .{});

            lib.linkSystemLibraryName("ole32");
            lib.linkSystemLibraryName("dxguid");
            lib.linkSystemLibraryName("c++");

            var flags = std.ArrayList([]const u8).init(b.allocator);
            try flags.appendSlice(&.{
                include("libs/"),
                include("libs/DirectXShaderCompiler/include/llvm/llvm_assert"),
                include("libs/DirectXShaderCompiler/include"),
                include("libs/DirectXShaderCompiler/build/include"),
                include("libs/DirectXShaderCompiler/build/lib/HLSL"),
                include("libs/DirectXShaderCompiler/build/lib/DxilPIXPasses"),
                include("libs/DirectXShaderCompiler/build/include"),
                "-DUNREFERENCED_PARAMETER(x)=",
                "-Wno-inconsistent-missing-override",
                "-Wno-missing-exception-spec",
                "-Wno-switch",
                "-Wno-deprecated-declarations",
                "-Wno-macro-redefined", // regex2.h and regcomp.c requires this for OUT redefinition
                "-DMSFT_SUPPORTS_CHILD_PROCESSES=1",
                "-DHAVE_LIBPSAPI=1",
                "-DHAVE_LIBSHELL32=1",
                "-DLLVM_ON_WIN32=1",
            });

            try appendLangScannedSources(b, lib, options, .{
                .rel_dirs = &.{
                    "libs/DirectXShaderCompiler/lib/DxcSupport",

                    // NOTE(mziulek): We don't need it for now.
                    //"libs/DirectXShaderCompiler/lib/Analysis/IPA",
                    //"libs/DirectXShaderCompiler/lib/Analysis",
                    //"libs/DirectXShaderCompiler/lib/AsmParser",
                    //"libs/DirectXShaderCompiler/lib/Bitcode/Writer",
                    //"libs/DirectXShaderCompiler/lib/DxcBindingTable",
                    //"libs/DirectXShaderCompiler/lib/DxilContainer",
                    //"libs/DirectXShaderCompiler/lib/DxilPIXPasses",
                    //"libs/DirectXShaderCompiler/lib/DxilRootSignature",
                    //"libs/DirectXShaderCompiler/lib/DXIL",
                    //"libs/DirectXShaderCompiler/lib/DxrFallback",
                    //"libs/DirectXShaderCompiler/lib/HLSL",
                    //"libs/DirectXShaderCompiler/lib/IRReader",
                    //"libs/DirectXShaderCompiler/lib/IR",
                    //"libs/DirectXShaderCompiler/lib/Linker",
                    //"libs/DirectXShaderCompiler/lib/Miniz",
                    //"libs/DirectXShaderCompiler/lib/Option",
                    //"libs/DirectXShaderCompiler/lib/PassPrinters",
                    //"libs/DirectXShaderCompiler/lib/Passes",
                    //"libs/DirectXShaderCompiler/lib/ProfileData",
                    //"libs/DirectXShaderCompiler/lib/Target",
                    //"libs/DirectXShaderCompiler/lib/Transforms/InstCombine",
                    //"libs/DirectXShaderCompiler/lib/Transforms/IPO",
                    //"libs/DirectXShaderCompiler/lib/Transforms/Scalar",
                    //"libs/DirectXShaderCompiler/lib/Transforms/Utils",
                    //"libs/DirectXShaderCompiler/lib/Transforms/Vectorize",
                },
                .flags = flags.items,
            });

            if (false) { // NOTE(mziulek): We don't need it for now.
                try appendLangScannedSources(b, lib, options, .{
                    .rel_dirs = &.{
                        "libs/DirectXShaderCompiler/lib/Support",
                    },
                    .flags = flags.items,
                    .excluding_contains = &.{
                        "DynamicLibrary.cpp", // ignore, HLSL_IGNORE_SOURCES
                        "PluginLoader.cpp", // ignore, HLSL_IGNORE_SOURCES
                        "Path.cpp", // ignore, LLVM_INCLUDE_TESTS
                        "DynamicLibrary.cpp", // ignore
                    },
                });

                try appendLangScannedSources(b, lib, options, .{
                    .rel_dirs = &.{
                        "libs/DirectXShaderCompiler/lib/Bitcode/Reader",
                    },
                    .flags = flags.items,
                    .excluding_contains = &.{
                        "BitReader.cpp", // ignore
                    },
                });
            }

            // NOTE(mziulek): The only file we need for now.
            var cpp_sources = std.ArrayList([]const u8).init(b.allocator);
            inline for ([_][]const u8{
                "lib/Support/ThreadLocal.cpp",
            }) |path| {
                const abs_path = sdkPath("/libs/DirectXShaderCompiler/" ++ path);
                try cpp_sources.append(abs_path);
            }

            var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
            try cpp_flags.appendSlice(flags.items);
            try options.appendFlags(&cpp_flags, true);
            lib.addCSourceFiles(cpp_sources.items, cpp_flags.items);

            return lib;
        }

        fn appendLangScannedSources(
            b: *Builder,
            step: *std.build.LibExeObjStep,
            options: Options,
            args: struct {
                flags: []const []const u8,
                rel_dirs: []const []const u8 = &.{},
                objc: bool = false,
                excluding: []const []const u8 = &.{},
                excluding_contains: []const []const u8 = &.{},
            },
        ) !void {
            var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
            try cpp_flags.appendSlice(args.flags);
            try options.appendFlags(&cpp_flags, true);
            const cpp_extensions: []const []const u8 = if (args.objc) &.{".mm"} else &.{ ".cpp", ".cc" };
            try appendScannedSources(b, step, .{
                .flags = cpp_flags.items,
                .rel_dirs = args.rel_dirs,
                .extensions = cpp_extensions,
                .excluding = args.excluding,
                .excluding_contains = args.excluding_contains,
            });

            var flags = std.ArrayList([]const u8).init(b.allocator);
            try flags.appendSlice(args.flags);
            try options.appendFlags(&flags, false);
            const c_extensions: []const []const u8 = if (args.objc) &.{".m"} else &.{".c"};
            try appendScannedSources(b, step, .{
                .flags = flags.items,
                .rel_dirs = args.rel_dirs,
                .extensions = c_extensions,
                .excluding = args.excluding,
                .excluding_contains = args.excluding_contains,
            });
        }

        fn appendScannedSources(b: *Builder, step: *std.build.LibExeObjStep, args: struct {
            flags: []const []const u8,
            rel_dirs: []const []const u8 = &.{},
            extensions: []const []const u8,
            excluding: []const []const u8 = &.{},
            excluding_contains: []const []const u8 = &.{},
        }) !void {
            var sources = std.ArrayList([]const u8).init(b.allocator);
            for (args.rel_dirs) |rel_dir| {
                try scanSources(b, &sources, rel_dir, args.extensions, args.excluding, args.excluding_contains);
            }
            step.addCSourceFiles(sources.items, args.flags);
        }

        /// Scans rel_dir for sources ending with one of the provided extensions, excluding relative paths
        /// listed in the excluded list.
        /// Results are appended to the dst ArrayList.
        fn scanSources(
            b: *Builder,
            dst: *std.ArrayList([]const u8),
            rel_dir: []const u8,
            extensions: []const []const u8,
            excluding: []const []const u8,
            excluding_contains: []const []const u8,
        ) !void {
            const abs_dir = try std.fs.path.join(b.allocator, &.{ sdkPath("/"), rel_dir });
            defer b.allocator.free(abs_dir);
            var dir = try std.fs.openIterableDirAbsolute(abs_dir, .{});
            defer dir.close();
            var dir_it = dir.iterate();
            while (try dir_it.next()) |entry| {
                if (entry.kind != .File) continue;
                var abs_path = try std.fs.path.join(b.allocator, &.{ abs_dir, entry.name });
                abs_path = try std.fs.realpathAlloc(b.allocator, abs_path);

                const allowed_extension = blk: {
                    const ours = std.fs.path.extension(entry.name);
                    for (extensions) |ext| {
                        if (std.mem.eql(u8, ours, ext)) break :blk true;
                    }
                    break :blk false;
                };
                if (!allowed_extension) continue;

                const excluded = blk: {
                    for (excluding) |excluded| {
                        if (std.mem.eql(u8, entry.name, excluded)) break :blk true;
                    }
                    break :blk false;
                };
                if (excluded) continue;

                const excluded_contains = blk: {
                    for (excluding_contains) |contains| {
                        if (std.mem.containsAtLeast(u8, entry.name, 1, contains)) break :blk true;
                    }
                    break :blk false;
                };
                if (excluded_contains) continue;

                try dst.append(abs_path);
            }
        }

        fn include(comptime rel: []const u8) []const u8 {
            return comptime "-I" ++ sdkPath("/" ++ rel);
        }

        fn sdkPath(comptime suffix: []const u8) []const u8 {
            if (suffix[0] != '/') @compileError("suffix must be an absolute path");
            return comptime blk: {
                const root_dir = std.fs.path.dirname(@src().file) orelse ".";
                break :blk root_dir ++ suffix;
            };
        }
    };
}
