const std = @import("std");
const crypto = std.crypto;
const timer = @import("src/timer.zig");

// External Rust function
extern fn rust_sha256(data: [*]const u8, len: usize, output: [*]u8) void;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create 32 byte input
    const input = try allocator.alloc(u8, 32);
    defer allocator.free(input);
    @memset(input, 'A');

    var zig_hash: [32]u8 = undefined;
    var rust_hash: [32]u8 = undefined;

    // Time single Zig hash
    const zig_start = timer.nanotime();
    crypto.hash.sha2.Sha256.hash(input, &zig_hash, .{});
    const zig_end = timer.nanotime();

    // Time single Rust hash
    const rust_start = timer.nanotime();
    rust_sha256(input.ptr, input.len, &rust_hash);
    const rust_end = timer.nanotime();

    std.debug.print("Single operation timing (32 bytes):\n", .{});
    std.debug.print("  Zig:  {} ns\n", .{zig_end - zig_start});
    std.debug.print("  Rust: {} ns\n", .{rust_end - rust_start});

    // Verify they produce the same result
    if (std.mem.eql(u8, &zig_hash, &rust_hash)) {
        std.debug.print("✓ Both produce identical output\n", .{});
    } else {
        std.debug.print("✗ Different outputs!\n", .{});
    }

    // Now time 1000 operations to get better average
    const iterations = 1000;

    const zig_batch_start = timer.nanotime();
    for (0..iterations) |_| {
        crypto.hash.sha2.Sha256.hash(input, &zig_hash, .{});
        std.mem.doNotOptimizeAway(&zig_hash);
    }
    const zig_batch_end = timer.nanotime();

    const rust_batch_start = timer.nanotime();
    for (0..iterations) |_| {
        rust_sha256(input.ptr, input.len, &rust_hash);
        std.mem.doNotOptimizeAway(&rust_hash);
    }
    const rust_batch_end = timer.nanotime();

    std.debug.print("\n{} iterations timing:\n", .{iterations});
    std.debug.print("  Zig:  {} ns total, {} ns/op\n", .{
        zig_batch_end - zig_batch_start,
        @divTrunc(zig_batch_end - zig_batch_start, iterations)
    });
    std.debug.print("  Rust: {} ns total, {} ns/op\n", .{
        rust_batch_end - rust_batch_start,
        @divTrunc(rust_batch_end - rust_batch_start, iterations)
    });
}