// build.zig - Zig Build Configuration for Zig vs Rust benchmarks
// ================================================================
// Hermetic build - no system dependencies, just Zig and Rust

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard build options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the Rust library first with native CPU optimizations
    const cargo_build = b.addSystemCommand(&.{
        "env", "RUSTFLAGS=-C target-cpu=native",
        "cargo", "build", "--release", "--manifest-path", "rust-crypto/Cargo.toml"
    });

    // Main benchmark executable - always use ReleaseFast for benchmarks
    const bench_exe = b.addExecutable(.{
        .name = "zig-crypto-bench",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // Make sure Rust library is built before linking
    bench_exe.step.dependOn(&cargo_build.step);

    // Link the Rust static library
    bench_exe.addLibraryPath(b.path("rust-crypto/target/release"));
    bench_exe.linkSystemLibrary("rust_crypto");

    // Need libc for Rust interop
    bench_exe.linkLibC();

    // Install the executable
    b.installArtifact(bench_exe);

    // Create run step
    const run_cmd = b.addRunArtifact(bench_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward command-line arguments
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Custom commands
    const bench_step = b.step("bench", "Run cryptographic benchmarks");
    bench_step.dependOn(&run_cmd.step);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.step.dependOn(&cargo_build.step);
    unit_tests.linkLibC();
    unit_tests.addLibraryPath(b.path("rust-crypto/target/release"));
    unit_tests.linkSystemLibrary("rust_crypto");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Check compilation
    const check_step = b.step("check", "Check if code compiles");
    const check_exe = b.addExecutable(.{
        .name = "check",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    check_exe.step.dependOn(&cargo_build.step);
    check_exe.linkLibC();
    check_exe.addLibraryPath(b.path("rust-crypto/target/release"));
    check_exe.linkSystemLibrary("rust_crypto");
    check_step.dependOn(&check_exe.step);

    // Format commands
    const fmt_step = b.step("fmt", "Format all source files");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const fmt_check_step = b.step("fmt-check", "Check formatting");
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });
    fmt_check_step.dependOn(&fmt_check.step);

    // Default command
    b.default_step = bench_step;
}