// FFI wrappers for Zig crypto implementations
// These provide C-compatible exports to ensure fair comparison with Rust FFI

const std = @import("std");
const crypto = std.crypto;

/// Minimal noop function for FFI overhead calibration
export fn zig_noop_ffi() void {
    // Intentionally empty - used to measure FFI calling overhead
}

/// SHA256 FFI wrapper matching Rust's signature
export fn zig_sha256_ffi(data: [*]const u8, len: usize, output: [*]u8) void {
    const input = data[0..len];
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(input, &hash, .{});
    @memcpy(output[0..32], &hash);
}

/// SHA512 FFI wrapper matching Rust's signature
export fn zig_sha512_ffi(data: [*]const u8, len: usize, output: [*]u8) void {
    const input = data[0..len];
    var hash: [64]u8 = undefined;
    crypto.hash.sha2.Sha512.hash(input, &hash, .{});
    @memcpy(output[0..64], &hash);
}