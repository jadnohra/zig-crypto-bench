// SHA512 benchmark comparing Zig stdlib vs Rust sha2 crate

const std = @import("std");
const harness = @import("../harness.zig");
const crypto = std.crypto;

// External Rust function
extern fn rust_sha512(data: [*]const u8, len: usize, output: [*]u8) void;

// External Zig FFI function (for fair comparison)
extern fn zig_sha512_ffi(data: [*]const u8, len: usize, output: [*]u8) void;

// Run SHA512 benchmarks
pub fn run(bench: *harness.Benchmark) !void {
    // Print benchmark header
    if (!bench.json_output) {
        std.debug.print("\n", .{});
        std.debug.print("┌────────────────────────────────────┐\n", .{});
        std.debug.print("│       SHA512 Benchmarks            │\n", .{});
        std.debug.print("└────────────────────────────────────┘\n", .{});
    }

    // Test different input sizes for cache effects and throughput scaling
    const test_cases = [_]struct {
        size: usize,
        name: []const u8,
        iterations_override: ?u32, // Optional: fewer iterations for large inputs
    }{
        .{ .size = 32, .name = "32 B", .iterations_override = null }, // Minimum input
        .{ .size = 64, .name = "64 B", .iterations_override = null }, // Half SHA512 block
        .{ .size = 128, .name = "128 B", .iterations_override = null }, // One SHA512 block
        .{ .size = 256, .name = "256 B", .iterations_override = null }, // Two blocks
        .{ .size = 1024, .name = "1 KB", .iterations_override = null }, // Small message
        .{ .size = 1024 * 1024, .name = "1 MB", .iterations_override = null }, // Medium message
        .{ .size = 10 * 1024 * 1024, .name = "10 MB", .iterations_override = 1000 }, // Large (fewer iterations)
    };

    // Run benchmarks for each size
    for (test_cases) |test_case| {
        try benchmarkSize(bench, test_case.size, test_case.name, test_case.iterations_override);
    }

    // Verify all implementations produce identical output
    if (!bench.json_output) {
        std.debug.print("\nVerifying output correctness...\n", .{});
        try verifyCorrectness(bench.allocator);
        std.debug.print("✓ All implementations produce identical output\n", .{});
    }
}

// Benchmark implementations for a specific input size
fn benchmarkSize(
    bench: *harness.Benchmark,
    size: usize,
    size_name: []const u8,
    iterations_override: ?u32,
) !void {
    // Allocate input buffer
    const input = try bench.allocator.alloc(u8, size);
    defer bench.allocator.free(input);

    // Fill with deterministic pseudorandom data
    // (Not just zeros or repeated patterns which might optimize differently)
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();
    random.bytes(input);

    // Format operation name
    const operation_name = try std.fmt.allocPrint(bench.allocator, "SHA512 {s}", .{size_name});
    defer bench.allocator.free(operation_name);

    // Override iterations for large inputs (they take longer)
    const original_iterations = bench.measure_iterations;
    if (iterations_override) |override| {
        bench.measure_iterations = override;
    }
    defer {
        bench.measure_iterations = original_iterations;
    }

    // Benchmark Zig implementation (native or FFI based on mode)
    {
        // Use a global variable to pass data to the comptime function
        const S = struct {
            var input_data: []const u8 = undefined;
        };
        S.input_data = input;

        switch (bench.mode) {
            .native => {
                // Use native Zig implementation
                try bench.measure(
                    operation_name,
                    "Zig (stdlib)",
                    struct {
                        fn run() void {
                            var hash: [64]u8 = undefined;
                            crypto.hash.sha2.Sha512.hash(S.input_data, &hash, .{});
                            std.mem.doNotOptimizeAway(&hash);
                        }
                    }.run,
                    size,
                );
            },
            .ffi => {
                // Use FFI wrapper for fair comparison
                try bench.measure(
                    operation_name,
                    "Zig (FFI)",
                    struct {
                        fn run() void {
                            var hash: [64]u8 = undefined;
                            zig_sha512_ffi(S.input_data.ptr, S.input_data.len, &hash);
                            std.mem.doNotOptimizeAway(&hash);
                        }
                    }.run,
                    size,
                );
            },
        }
    }

    // Benchmark Rust sha2 implementation
    {
        // Use a global variable to pass data to the comptime function
        const S = struct {
            var input_data: []const u8 = undefined;
        };
        S.input_data = input;

        try bench.measure(
            operation_name,
            "Rust (sha2)",
            struct {
                fn run() void {
                    var hash: [64]u8 = undefined;
                    rust_sha512(S.input_data.ptr, S.input_data.len, &hash);
                    std.mem.doNotOptimizeAway(&hash);
                }
            }.run,
            size,
        );
    }
}

// Correctness verification
fn verifyCorrectness(allocator: std.mem.Allocator) !void {
    // Test vectors from NIST
    const test_vectors = [_]struct {
        input: []const u8,
        expected: []const u8, // Hex string
    }{
        .{
            .input = "abc",
            .expected = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        },
        .{
            .input = "",
            .expected = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
        },
        .{
            .input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            .expected = "204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c33596fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445",
        },
    };

    for (test_vectors) |vector| {
        // Test Zig implementation
        var zig_hash: [64]u8 = undefined;
        crypto.hash.sha2.Sha512.hash(vector.input, &zig_hash, .{});

        // Test Rust implementation
        var rust_hash: [64]u8 = undefined;
        if (vector.input.len > 0) {
            rust_sha512(vector.input.ptr, vector.input.len, &rust_hash);
        } else {
            // Handle empty input case
            rust_sha512(@ptrFromInt(1), 0, &rust_hash);
        }

        // Convert expected from hex
        var expected_bytes: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected_bytes, vector.expected);

        // Verify Zig matches expected
        if (!std.mem.eql(u8, &zig_hash, &expected_bytes)) {
            std.debug.print("Zig SHA512 mismatch for input: {s}\n", .{vector.input});
            std.debug.print("  Expected: {s}\n", .{vector.expected});
            std.debug.print("  Got:      {any}\n", .{std.fmt.fmtSliceHexLower(&zig_hash)});
            return error.VerificationFailed;
        }

        // Verify Rust matches expected
        if (!std.mem.eql(u8, &rust_hash, &expected_bytes)) {
            std.debug.print("Rust SHA512 mismatch for input: {s}\n", .{vector.input});
            std.debug.print("  Expected: {s}\n", .{vector.expected});
            std.debug.print("  Got:      {any}\n", .{std.fmt.fmtSliceHexLower(&rust_hash)});
            return error.VerificationFailed;
        }

        // Verify Zig and Rust match each other
        if (!std.mem.eql(u8, &zig_hash, &rust_hash)) {
            std.debug.print("Zig and Rust SHA512 outputs differ for input: {s}\n", .{vector.input});
            return error.VerificationFailed;
        }
    }

    // Also test with larger random input
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();

    const large_input = try allocator.alloc(u8, 1024 * 16); // 16KB
    defer allocator.free(large_input);
    random.bytes(large_input);

    var zig_large: [64]u8 = undefined;
    crypto.hash.sha2.Sha512.hash(large_input, &zig_large, .{});

    var rust_large: [64]u8 = undefined;
    rust_sha512(large_input.ptr, large_input.len, &rust_large);

    if (!std.mem.eql(u8, &zig_large, &rust_large)) {
        std.debug.print("Zig and Rust differ on large random input\n", .{});
        return error.VerificationFailed;
    }
}
