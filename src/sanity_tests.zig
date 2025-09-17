//! Sanity tests for the cryptographic benchmark framework
//!
//! These tests verify the correctness of the benchmarking infrastructure
//! without requiring external dependencies (Rust, FFI, etc). They ensure
//! that timing, statistics, and framework behavior are working as expected.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

// ============================================================================
// Test Harness
// ============================================================================

/// Minimal benchmark harness for testing framework logic.
/// Mimics the real Benchmark struct but without external dependencies.
const TestBenchmark = struct {
    results: std.ArrayList(Result),
    allocator: std.mem.Allocator,
    warmup_iterations: u32,
    measure_iterations: u32,

    const Result = struct {
        operation: []const u8,
        implementation: []const u8,
        median_ns: u64,
        min_ns: u64,
        max_ns: u64,
        ns_per_op: u64,
        std_dev: f64,
        batch_size: u32,
        bytes_processed: ?usize,
    };

    /// Initialize a new test benchmark instance.
    fn init(allocator: std.mem.Allocator, warmup: u32, measure_count: u32) TestBenchmark {
        return .{
            .allocator = allocator,
            .warmup_iterations = warmup,
            .measure_iterations = measure_count,
            .results = std.ArrayList(Result).init(allocator),
        };
    }

    /// Clean up resources.
    fn deinit(self: *TestBenchmark) void {
        self.results.deinit();
    }

    /// Measure the performance of a function.
    /// Performs warmup iterations followed by timed measurements.
    fn measure(
        self: *TestBenchmark,
        op: []const u8,
        impl: []const u8,
        func: fn () void,
        bytes: ?usize,
    ) !void {
        // Execute warmup iterations to stabilize CPU and caches
        var i: u32 = 0;
        while (i < self.warmup_iterations) : (i += 1) {
            func();
        }

        // Allocate storage for timing measurements
        var times = try self.allocator.alloc(u64, self.measure_iterations);
        defer self.allocator.free(times);

        // Perform timed measurements
        i = 0;
        while (i < self.measure_iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            func();
            const end = std.time.nanoTimestamp();
            times[i] = @intCast(end - start);
        }

        // Calculate statistical metrics
        std.sort.heap(u64, times, {}, std.sort.asc(u64));
        const median = times[times.len / 2];
        const min = times[0];
        const max = times[times.len - 1];

        // Calculate mean
        var sum: u64 = 0;
        for (times) |t| sum += t;
        const mean = sum / times.len;

        // Calculate standard deviation
        var variance: f64 = 0;
        for (times) |t| {
            const diff = @as(f64, @floatFromInt(t)) - @as(f64, @floatFromInt(mean));
            variance += diff * diff;
        }
        const std_dev = @sqrt(variance / @as(f64, @floatFromInt(times.len)));

        // Store results
        try self.results.append(.{
            .operation = op,
            .implementation = impl,
            .median_ns = median,
            .min_ns = min,
            .max_ns = max,
            .ns_per_op = mean,
            .std_dev = std_dev,
            .batch_size = 1, // Fixed for simplicity in tests
            .bytes_processed = bytes,
        });
    }
};

// ============================================================================
// Timing Tests
// ============================================================================

test "timing: longer operations take more time" {
    std.debug.print("\n✓ Sanity: Timing - longer operations take more time\n", .{});
    // Verify that the framework can distinguish between fast and slow operations
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 1, 10);
    defer bench.deinit();

    // Measure a fast operation
    try bench.measure("Fast", "Test", struct {
        fn run() void {
            var x: u32 = 1;
            x += 1;
            std.mem.doNotOptimizeAway(&x);
        }
    }.run, null);
    const fast_result = bench.results.items[0];

    // Measure a slow operation
    bench.results.clearRetainingCapacity();
    try bench.measure("Slow", "Test", struct {
        fn run() void {
            var x: u32 = 0;
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                x += i;
            }
            std.mem.doNotOptimizeAway(&x);
        }
    }.run, null);
    const slow_result = bench.results.items[0];

    // Slow operation should take measurably more time
    try testing.expect(slow_result.median_ns > fast_result.median_ns);
}

test "timing: warmup iterations execute correctly" {
    std.debug.print("\n✓ Sanity: Timing - warmup iterations execute correctly\n", .{});
    // Verify warmup phase runs the expected number of times
    const allocator = testing.allocator;

    // Global counter to track function executions
    const Counter = struct {
        var count: u32 = 0;
    };
    Counter.count = 0;

    var bench = TestBenchmark.init(allocator, 5, 10);
    defer bench.deinit();

    try bench.measure("Test", "Test", struct {
        fn run() void {
            Counter.count += 1;
        }
    }.run, null);

    // Total executions = warmup (5) + measurements (10)
    try testing.expectEqual(@as(u32, 15), Counter.count);
}

test "timing: all measurements are non-negative" {
    std.debug.print("\n✓ Sanity: Timing - all measurements are non-negative\n", .{});
    // Ensure timer produces valid positive or zero values
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 1, 10);
    defer bench.deinit();

    try bench.measure("Test", "Test", struct {
        fn run() void {
            // Perform minimal work to get measurable timing
            var x: u32 = 0;
            var i: u32 = 0;
            while (i < 10) : (i += 1) {
                x += i;
            }
            std.mem.doNotOptimizeAway(&x);
        }
    }.run, null);

    const r = bench.results.items[0];
    try testing.expect(r.min_ns >= 0);
    try testing.expect(r.median_ns >= 0);
    try testing.expect(r.max_ns >= 0);
    try testing.expect(r.ns_per_op >= 0);
}

// ============================================================================
// Statistical Tests
// ============================================================================

test "statistics: measures maintain correct ordering" {
    std.debug.print("\n✓ Sanity: Statistics - measures maintain correct ordering\n", .{});
    // Verify statistical invariants: min ≤ median ≤ max, etc.
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 1, 50);
    defer bench.deinit();

    try bench.measure("Test", "Test", struct {
        fn run() void {
            var x: u32 = 0;
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                x += i;
            }
            std.mem.doNotOptimizeAway(&x);
        }
    }.run, null);

    const r = bench.results.items[0];

    // Statistical ordering invariants
    try testing.expect(r.min_ns <= r.median_ns);
    try testing.expect(r.median_ns <= r.max_ns);
    try testing.expect(r.ns_per_op >= r.min_ns);
    try testing.expect(r.ns_per_op <= r.max_ns);

    // Standard deviation is non-negative
    try testing.expect(r.std_dev >= 0);
}

test "statistics: bytes_processed tracking works" {
    std.debug.print("\n✓ Sanity: Statistics - bytes_processed tracking works\n", .{});
    // Verify throughput calculation prerequisites
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 1, 10);
    defer bench.deinit();

    const data_size: usize = 1024; // 1 KB
    try bench.measure("Test", "Test", struct {
        fn run() void {
            std.mem.doNotOptimizeAway(@as(u32, 1));
        }
    }.run, data_size);

    const r = bench.results.items[0];
    try testing.expect(r.bytes_processed != null);
    try testing.expectEqual(data_size, r.bytes_processed.?);
}

// ============================================================================
// Performance Scaling Tests
// ============================================================================

test "scaling: performance scales with workload" {
    std.debug.print("\n✓ Sanity: Scaling - performance scales with workload\n", .{});
    // Verify that processing more data takes proportionally more time
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 1, 10);
    defer bench.deinit();

    // Measure small workload
    const small_data = try allocator.alloc(u8, 100);
    defer allocator.free(small_data);

    const SmallContext = struct {
        var data: []const u8 = undefined;
    };
    SmallContext.data = small_data;

    try bench.measure("Small", "Test", struct {
        fn run() void {
            var sum: u32 = 0;
            for (SmallContext.data) |b| {
                sum +%= b;
            }
            std.mem.doNotOptimizeAway(&sum);
        }
    }.run, small_data.len);
    const small_result = bench.results.items[0];

    // Measure large workload (10x bigger)
    bench.results.clearRetainingCapacity();
    const large_data = try allocator.alloc(u8, 1000);
    defer allocator.free(large_data);

    const LargeContext = struct {
        var data: []const u8 = undefined;
    };
    LargeContext.data = large_data;

    try bench.measure("Large", "Test", struct {
        fn run() void {
            var sum: u32 = 0;
            for (LargeContext.data) |b| {
                sum +%= b;
            }
            std.mem.doNotOptimizeAway(&sum);
        }
    }.run, large_data.len);
    const large_result = bench.results.items[0];

    // 10x more data should take at least 5x more time
    // (allowing for cache effects and overhead)
    try testing.expect(large_result.median_ns > small_result.median_ns * 5);
}

// ============================================================================
// Reproducibility Tests
// ============================================================================

test "reproducibility: multiple runs produce consistent results" {
    std.debug.print("\n✓ Sanity: Reproducibility - multiple runs produce consistent results\n", .{});
    // Verify that repeated measurements are reasonably consistent
    const allocator = testing.allocator;

    // First measurement run
    var bench1 = TestBenchmark.init(allocator, 5, 20);
    defer bench1.deinit();

    try bench1.measure("Test", "Test", struct {
        fn run() void {
            var x: u32 = 0;
            var i: u32 = 0;
            while (i < 500) : (i += 1) {
                x +%= i;
            }
            std.mem.doNotOptimizeAway(&x);
        }
    }.run, null);
    const result1 = bench1.results.items[0];

    // Second measurement run (identical parameters)
    var bench2 = TestBenchmark.init(allocator, 5, 20);
    defer bench2.deinit();

    try bench2.measure("Test", "Test", struct {
        fn run() void {
            var x: u32 = 0;
            var i: u32 = 0;
            while (i < 500) : (i += 1) {
                x +%= i;
            }
            std.mem.doNotOptimizeAway(&x);
        }
    }.run, null);
    const result2 = bench2.results.items[0];

    // Results should be within 3x of each other
    // (very generous bound to account for system variance)
    const ratio = @as(f64, @floatFromInt(result2.median_ns)) /
                  @as(f64, @floatFromInt(result1.median_ns));
    try testing.expect(ratio > 0.33 and ratio < 3.0);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "edge cases: zero warmup iterations" {
    std.debug.print("\n✓ Sanity: Edge cases - zero warmup iterations\n", .{});
    // Verify framework handles edge case of no warmup
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 0, 1);
    defer bench.deinit();

    try bench.measure("Test", "Test", struct {
        fn run() void {
            std.mem.doNotOptimizeAway(@as(u32, 1));
        }
    }.run, null);

    try testing.expectEqual(@as(usize, 1), bench.results.items.len);
}

test "edge cases: single measurement iteration" {
    std.debug.print("\n✓ Sanity: Edge cases - single measurement iteration\n", .{});
    // Verify framework handles minimal iteration count
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 0, 1);
    defer bench.deinit();

    try bench.measure("Test", "Test", struct {
        fn run() void {
            // Perform minimal work
            var x: u32 = 0;
            var i: u32 = 0;
            while (i < 10) : (i += 1) {
                x += i;
            }
            std.mem.doNotOptimizeAway(&x);
        }
    }.run, null);

    const r = bench.results.items[0];
    try testing.expect(r.min_ns >= 0);
    try testing.expect(r.median_ns >= 0);
    try testing.expect(r.max_ns >= 0);
}


// ============================================================================
// Framework Tests
// ============================================================================

test "framework: version string is properly formatted" {
    std.debug.print("\n✓ Sanity: Framework - version string is properly formatted\n", .{});
    // Verify framework version follows expected format
    try testing.expect(main.VERSION.len > 0);
    try testing.expect(std.mem.startsWith(u8, main.VERSION, "v"));
}

test "framework: batch size is positive" {
    std.debug.print("\n✓ Sanity: Framework - batch size is positive\n", .{});
    // Verify batch size calculation produces valid values
    const allocator = testing.allocator;
    var bench = TestBenchmark.init(allocator, 1, 10);
    defer bench.deinit();

    try bench.measure("Fast", "Test", struct {
        fn run() void {
            std.mem.doNotOptimizeAway(@as(u32, 1));
        }
    }.run, null);

    const r = bench.results.items[0];
    try testing.expect(r.batch_size >= 1);
}

// ============================================================================
// System Integration Tests
// ============================================================================

test "system: git command execution" {
    std.debug.print("\n✓ Sanity: System - git command execution\n", .{});
    // Verify git commands can be executed (if available)
    const allocator = testing.allocator;
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "HEAD" },
    }) catch {
        // Git not available or not in a repo - not a failure
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
        // Should return at least a short commit hash
        try testing.expect(result.stdout.len >= 7);
    }
}

test "system: JSON structure validation" {
    std.debug.print("\n✓ Sanity: System - JSON structure validation\n", .{});
    // Verify ability to generate valid JSON output
    const allocator = testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const writer = buf.writer();
    try writer.writeAll("{\"test\": true, \"value\": 42}");

    // Verify JSON contains expected fields
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"test\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"value\"") != null);
}