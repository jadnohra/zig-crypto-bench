//! Build configuration for the cryptographic benchmark suite
//!
//! This build script manages compilation of both Zig and Rust components
//! for comparative performance benchmarking. It ensures proper optimization
//! flags and cross-platform compatibility.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ========================================================================
    // Build Configuration
    // ========================================================================

    // Target and optimization settings
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // External Dependencies
    // ========================================================================

    // Build Rust cryptographic library with native CPU optimizations
    // This ensures maximum performance for the Rust implementations
    const cargo_build = b.addSystemCommand(&.{
        "env",
        "RUSTFLAGS=-C target-cpu=native",
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        "rust-crypto/Cargo.toml"
    });

    // ========================================================================
    // Zig Libraries
    // ========================================================================

    // Build FFI wrapper library for Zig implementations
    // This provides C ABI exports for fair comparison with Rust FFI
    const zig_ffi_lib = b.addStaticLibrary(.{
        .name = "zig_crypto_ffi",
        .root_source_file = b.path("src/zig_ffi.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // ========================================================================
    // Main Benchmark Executable
    // ========================================================================

    // Primary benchmark runner - always optimized for accurate measurements
    const bench_exe = b.addExecutable(.{
        .name = "zig-crypto-bench",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,  // Critical for benchmark accuracy
    });

    // Ensure Rust library is built before linking
    bench_exe.step.dependOn(&cargo_build.step);

    // Link required libraries
    bench_exe.addLibraryPath(b.path("rust-crypto/target/release"));
    bench_exe.linkSystemLibrary("rust_crypto");
    bench_exe.linkLibrary(zig_ffi_lib);
    bench_exe.linkLibC();  // Required for Rust FFI

    // Platform-specific linking requirements
    if (target.result.os.tag == .linux) {
        // Linux requires additional libraries for Rust stack unwinding
        bench_exe.linkSystemLibrary("unwind");
        bench_exe.linkSystemLibrary("gcc_s");
    }

    // Install the benchmark executable
    b.installArtifact(bench_exe);

    // ========================================================================
    // Build Commands
    // ========================================================================

    // Primary benchmark command: 'zig build bench'
    const run_cmd = b.addRunArtifact(bench_exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward command-line arguments to the benchmark runner
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run cryptographic benchmarks");
    bench_step.dependOn(&run_cmd.step);

    // ========================================================================
    // Testing Infrastructure
    // ========================================================================

    // Main test step that runs all test suites
    const test_step = b.step("test", "Run all tests (unit, harness, sanity)");

    // Unit tests from main.zig
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.step.dependOn(&cargo_build.step);
    unit_tests.linkLibC();
    unit_tests.addLibraryPath(b.path("rust-crypto/target/release"));
    unit_tests.linkSystemLibrary("rust_crypto");
    unit_tests.linkLibrary(zig_ffi_lib);

    if (target.result.os.tag == .linux) {
        unit_tests.linkSystemLibrary("unwind");
        unit_tests.linkSystemLibrary("gcc_s");
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Harness tests - integration tests with Rust dependencies
    const harness_tests = b.addTest(.{
        .root_source_file = b.path("src/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness_tests.step.dependOn(&cargo_build.step);
    harness_tests.linkLibC();
    harness_tests.addLibraryPath(b.path("rust-crypto/target/release"));
    harness_tests.linkSystemLibrary("rust_crypto");
    harness_tests.linkLibrary(zig_ffi_lib);

    if (target.result.os.tag == .linux) {
        harness_tests.linkSystemLibrary("unwind");
        harness_tests.linkSystemLibrary("gcc_s");
    }

    const run_harness_tests = b.addRunArtifact(harness_tests);
    test_step.dependOn(&run_harness_tests.step);

    // Sanity tests - pure Zig tests without external dependencies
    // These verify framework correctness without requiring Rust
    const sanity_tests = b.addTest(.{
        .root_source_file = b.path("src/sanity_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_sanity_tests = b.addRunArtifact(sanity_tests);

    // Include sanity tests in main test suite
    test_step.dependOn(&run_sanity_tests.step);

    // Provide dedicated command for running only sanity tests
    const sanity_step = b.step("sanity", "Run sanity tests only (no Rust dependencies)");
    sanity_step.dependOn(&run_sanity_tests.step);

    // ========================================================================
    // Development Commands
    // ========================================================================

    // Compilation check without running
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

    if (target.result.os.tag == .linux) {
        check_exe.linkSystemLibrary("unwind");
        check_exe.linkSystemLibrary("gcc_s");
    }

    check_step.dependOn(&check_exe.step);

    // Code formatting commands
    const fmt_step = b.step("fmt", "Format all source files");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const fmt_check_step = b.step("fmt-check", "Check formatting (CI)");
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });
    fmt_check_step.dependOn(&fmt_check.step);

    // ========================================================================
    // Default Command
    // ========================================================================

    // Running 'zig build' without arguments executes benchmarks
    b.default_step = bench_step;
}