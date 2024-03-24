const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Define a freestanding x86_64 cross-compilation target.
    const target: std.zig.CrossTarget = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    _ = target;

    var query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none
    };

    // Disable CPU features that require additional initialization
    // like MMX, SSE/2 and AVX. That requires us to enable the soft-float feature.
    const Features = std.Target.x86.Feature;
    query.cpu_features_sub.addFeature(@intFromEnum(Features.mmx));
    query.cpu_features_sub.addFeature(@intFromEnum(Features.sse));
    query.cpu_features_sub.addFeature(@intFromEnum(Features.sse2));
    query.cpu_features_sub.addFeature(@intFromEnum(Features.avx));
    query.cpu_features_sub.addFeature(@intFromEnum(Features.avx2));
    query.cpu_features_add.addFeature(@intFromEnum(Features.soft_float));

    const target2 = b.resolveTargetQuery(query);

    // Build the kernel itself.
    const optimize = b.standardOptimizeOption(.{});
    const limine = b.dependency("limine", .{});
    const nasm_dep = b.dependency("nasm", .{ .optimize = .ReleaseFast });
    const nasm_exe = nasm_dep.artifact("nasm");

    const nasm_run = b.addRunArtifact(nasm_exe);

    // nasm requires a trailing slash on include directories
    //const include_dir = b.fmt("-I{s}/", .{std.fs.path.dirname(input_file).?});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target2,
        .optimize = optimize,
        .code_model = .kernel,
        
    });

    nasm_run.addArgs(&.{
        "-Wall",
        "-f",
        "elf64",
        "-o"
    });

    const opath = nasm_run.addOutputFileArg("src/interrupts.o");
    
    kernel.addObjectFile(opath);

    nasm_run.addFileArg(.{ .path = "src/interrupts.asm" });

    kernel.root_module.addImport("limine", limine.module("limine"));

    //kernel.addModule("limine", limine.module("limine"));
    //kernel.setLinkerScriptPath(.{ .path = "linker.ld" });
    kernel.setLinkerScript(.{ .path = "linker.ld"});
    kernel.pie = true;

    b.installArtifact(kernel);
}
