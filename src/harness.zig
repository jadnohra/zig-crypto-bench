// src/harness.zig - Benchmarking Measurement Framework
// =====================================================
// This module provides fair, accurate timing for comparing
// cryptographic implementations across languages

const std = @import("std");
const time = std.time;
const builtin = @import("builtin");
const timer = @import("timer.zig");

// ===== CONFIGURATION STRUCTURE =====
// What users can control about benchmarks

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    warmup_iterations: u32,
    measure_iterations: u32,
    json_output: bool,
    verbose: bool,
    save_results: bool,
    results: std.ArrayList(Result),

    // ===== RESULT STRUCTURE =====
    // All the data we collect for each benchmark

    const Result = struct {
        operation: []const u8, // e.g., "SHA256 1MB"
        implementation: []const u8, // e.g., "OpenSSL"

        // Core timing metrics (in nanoseconds)
        ns_per_op: u64, // Mean time
        median_ns: u64, // Middle value (most reliable)
        std_dev: f64, // Consistency measure
        min_ns: u64, // Best case
        max_ns: u64, // Worst case

        // Optional: for throughput calculation
        bytes_processed: ?usize, // If processing data

        // Measurement metadata
        batch_size: u32, // How many ops per measurement

        // Helper function: Calculate throughput if applicable
        fn throughputMBps(self: Result) ?f64 {
            if (self.bytes_processed) |bytes| {
                // Convert ns/op to ops/sec
                const ops_per_sec = 1_000_000_000.0 / @as(f64, @floatFromInt(self.median_ns));
                // Convert to MB/s
                return (@as(f64, @floatFromInt(bytes)) * ops_per_sec) / (1024.0 * 1024.0);
            }
            return null;
        }

        // Helper function: Operations per second
        fn opsPerSec(self: Result) f64 {
            return 1_000_000_000.0 / @as(f64, @floatFromInt(self.median_ns));
        }
    };

    // ===== INITIALIZATION =====
    // Create a new benchmark instance

    pub fn init(allocator: std.mem.Allocator, config: struct {
        warmup_iterations: u32 = 1000,
        measure_iterations: u32 = 10000,
        json_output: bool = false,
        save_results: bool = false,
    }) Benchmark {
        return .{
            .allocator = allocator,
            .warmup_iterations = config.warmup_iterations,
            .measure_iterations = config.measure_iterations,
            .json_output = config.json_output,
            .verbose = false,
            .save_results = config.save_results,
            .results = std.ArrayList(Result).init(allocator),
        };
    }

    // ===== CLEANUP =====
    // Free allocated memory

    pub fn deinit(self: *Benchmark) void {
        // Free string copies we made
        for (self.results.items) |result| {
            self.allocator.free(result.operation);
            self.allocator.free(result.implementation);
        }
        self.results.deinit();
    }

    // ===== CORE MEASUREMENT FUNCTION =====
    // This is where the actual timing happens

    pub fn measure(
        self: *Benchmark,
        operation: []const u8,
        implementation: []const u8,
        comptime func: fn () void, // Function to benchmark
        bytes_processed: ?usize, // Optional: for throughput
    ) !void {
        // Adaptive iteration scaling based on data size
        // Scale down iterations for larger data to keep total runtime reasonable
        var actual_iterations = self.measure_iterations;
        var actual_warmup = self.warmup_iterations;

        if (bytes_processed) |bytes| {
            // For every 10x increase in data size, reduce iterations by 2x
            // This gives us: 32B->full, 1KB->full, 1MB->50, 10MB->25
            if (bytes >= 1024 * 1024) { // >= 1MB
                const scale_factor = @min(4, bytes / (256 * 1024)); // Max 4x reduction
                actual_iterations = @max(10, self.measure_iterations / scale_factor);
                actual_warmup = @max(5, self.warmup_iterations / scale_factor);
            }
        }
        // Always show progress (unless JSON output)
        if (!self.json_output) {
            std.debug.print("\n{s} - {s}:\n", .{ operation, implementation });
            // Flush stderr to show immediately
            std.io.getStdErr().writer().writeAll("") catch {};
        }

        // ===== WARMUP PHASE =====
        // Run the function many times to warm up CPU caches,
        // trigger frequency scaling, and stabilize performance

        if (self.verbose and !self.json_output) {
            std.debug.print("  Warmup: {d} iterations...", .{actual_warmup});
        }

        var i: u32 = 0;
        while (i < actual_warmup) : (i += 1) {
            func();
            // Prevent compiler from optimizing away the loop
            std.mem.doNotOptimizeAway(&i);
        }

        if (self.verbose and !self.json_output) {
            std.debug.print(" done\n", .{});
        }

        // ===== MEASUREMENT PHASE =====
        // Collect many samples for statistical analysis

        if (self.verbose and !self.json_output) {
            std.debug.print("  Measuring: {d} iterations...", .{actual_iterations});
        }

        // Automatically determine batch size for measurable timing
        // Batch size = how many operations to run per timing measurement
        // This solves timer resolution issues for very fast operations
        // With our high-resolution timer, we can measure down to ~50ns accurately
        // We set a threshold of 100ns to avoid noise from very fast operations
        const min_measurement_ns: i128 = 100;
        var batch_size: u32 = 1;

        // Start with 1, then try 10, 100, 1000, etc.
        while (batch_size <= 100000) {
            const test_start = timer.nanotime();
            var b: u32 = 0;
            while (b < batch_size) : (b += 1) {
                func();
            }
            const test_end = timer.nanotime();
            const elapsed = test_end - test_start;

            // If we got a measurable time, we're good
            if (elapsed >= min_measurement_ns) {
                break;
            }

            // Try 10x more operations
            batch_size *= 10;
        }

        if (self.verbose and !self.json_output and batch_size > 1) {
            std.debug.print(" (batching {d} ops per measurement)", .{batch_size});
        }

        // Now measure with the determined batch size
        // We want actual_iterations total operations, not actual_iterations * batch_size!
        // So we need fewer samples when batching
        const num_samples = @max(10, actual_iterations / batch_size);

        // Allocate samples array based on actual number of samples we'll collect
        const samples = try self.allocator.alloc(u64, num_samples);
        defer self.allocator.free(samples);

        i = 0;
        while (i < num_samples) : (i += 1) {
            const start = timer.nanotime();
            var b: u32 = 0;
            while (b < batch_size) : (b += 1) {
                func();
            }
            const end = timer.nanotime();
            // Divide by batch size to get per-operation time
            const total_time = end - start;
            // Properly round when dividing
            const time_per_op = @divTrunc(total_time + @as(i128, batch_size / 2), batch_size);
            samples[i] = @intCast(time_per_op);
        }

        if (self.verbose and !self.json_output) {
            std.debug.print(" done\n", .{});
        }

        // ===== STATISTICAL ANALYSIS =====
        // Calculate median, mean, std dev from samples

        const stats = calculateStats(samples);

        // Store the result
        try self.results.append(.{
            .operation = try self.allocator.dupe(u8, operation),
            .implementation = try self.allocator.dupe(u8, implementation),
            .ns_per_op = stats.mean,
            .std_dev = stats.std_dev,
            .min_ns = stats.min,
            .max_ns = stats.max,
            .median_ns = stats.median,
            .bytes_processed = bytes_processed,
            .batch_size = batch_size,
        });

        // Print immediate feedback if not in JSON mode
        if (!self.json_output) {
            const result = self.results.items[self.results.items.len - 1];
            self.printResult(result);
        }
    }

    // ===== RESULT PRINTING =====
    // Human-readable output for single result

    fn printResult(self: *Benchmark, result: Result) void {
        // Results right after the header
        std.debug.print("  Median:      {d} ns/op\n", .{result.median_ns});
        std.debug.print("  Mean:        {d} ns/op\n", .{result.ns_per_op});
        std.debug.print("  Std Dev:     {d:.2} ns\n", .{result.std_dev});
        std.debug.print("  Min:         {d} ns\n", .{result.min_ns});
        std.debug.print("  Max:         {d} ns\n", .{result.max_ns});

        // Show throughput if we processed data
        if (result.throughputMBps()) |mbps| {
            std.debug.print("  Throughput:  {d:.2} MB/s\n", .{mbps});
        } else {
            std.debug.print("  Ops/sec:     {d:.2}\n", .{result.opsPerSec()});
        }

        // Show batch size only in verbose mode if we had to batch operations
        if (self.verbose and result.batch_size > 1) {
            std.debug.print("  Batch size:  {d} ops/measurement (timer resolution ~{d}ns)\n", .{
                result.batch_size,
                result.min_ns * result.batch_size, // Estimate timer resolution from min time
            });
        }
    }

    // ===== SUMMARY TABLE =====
    // Compare all results at the end

    pub fn printSummary(self: *Benchmark) !void {
        if (self.results.items.len == 0) {
            std.debug.print("No benchmark results collected.\n", .{});
            return;
        }

        std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
        std.debug.print("SUMMARY\n", .{});
        std.debug.print("=" ** 60 ++ "\n\n", .{});

        // Group results by operation for comparison
        var operations = std.StringHashMap(std.ArrayList(Result)).init(self.allocator);
        defer {
            var it = operations.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            operations.deinit();
        }

        // Organize results by operation name
        for (self.results.items) |result| {
            const entry = try operations.getOrPut(result.operation);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(Result).init(self.allocator);
            }
            try entry.value_ptr.append(result);
        }

        // Print comparison table for each operation
        var op_it = operations.iterator();
        while (op_it.next()) |entry| {
            std.debug.print("Operation: {s}\n", .{entry.key_ptr.*});
            std.debug.print("-" ** 50 ++ "\n", .{});

            // Sort with Zig stdlib first, then others
            const results = entry.value_ptr.items;
            std.mem.sort(Result, results, {}, struct {
                fn lessThan(_: void, a: Result, b: Result) bool {
                    // Always put Zig stdlib first
                    if (std.mem.eql(u8, a.implementation, "Zig stdlib")) return true;
                    if (std.mem.eql(u8, b.implementation, "Zig stdlib")) return false;
                    // For others, sort alphabetically
                    return std.mem.lessThan(u8, a.implementation, b.implementation);
                }
            }.lessThan);

            // Print comparison table
            std.debug.print("{s:<20} {s:>12} {s:>12} {s:>12}\n", .{ "Implementation", "Median (ns)", "Throughput", "Relative" });
            std.debug.print("{s:<20} {s:>12} {s:>12} {s:>12}\n", .{ "-" ** 20, "-" ** 12, "-" ** 12, "-" ** 12 });

            // Use Zig stdlib as baseline for relative comparison
            var zig_baseline: ?u64 = null;
            for (results) |result| {
                if (std.mem.eql(u8, result.implementation, "Zig stdlib")) {
                    zig_baseline = result.median_ns;
                    break;
                }
            }
            const baseline = zig_baseline orelse results[0].median_ns;
            for (results) |result| {
                // Calculate speed ratio: baseline/result
                // Faster = 1.0, slower = < 1.0
                const relative = @as(f64, @floatFromInt(baseline)) /
                    @as(f64, @floatFromInt(result.median_ns));

                // Format throughput appropriately
                const throughput_str = if (result.throughputMBps()) |mbps|
                    std.fmt.allocPrint(self.allocator, "{d:.2} MB/s", .{mbps}) catch "N/A"
                else
                    std.fmt.allocPrint(self.allocator, "{d:.0} ops/s", .{result.opsPerSec()}) catch "N/A";
                defer self.allocator.free(throughput_str);

                std.debug.print("{s:<20} {d:>12} {s:>12} {d:>11.2}x\n", .{
                    result.implementation,
                    result.median_ns,
                    throughput_str,
                    relative,
                });
            }
            std.debug.print("\n", .{});
        }
    }

    // ===== JSON OUTPUT =====
    // Machine-readable format for tools/CI

    pub fn outputJson(self: *Benchmark, writer: anytype) !void {
        try writer.writeAll("{\n");

        // Metadata about the benchmark run
        try writer.writeAll("  \"metadata\": {\n");
        try writer.print("    \"warmup_iterations\": {d},\n", .{self.warmup_iterations});
        try writer.print("    \"measure_iterations\": {d},\n", .{self.measure_iterations});
        try writer.print("    \"timestamp\": {d},\n", .{time.timestamp()});
        try writer.writeAll("    \"platform\": \"");
        try writer.writeAll(@tagName(builtin.os.tag));
        try writer.writeAll("\",\n    \"arch\": \"");
        try writer.writeAll(@tagName(builtin.cpu.arch));
        try writer.writeAll("\"\n  },\n");

        // Results array
        try writer.writeAll("  \"results\": [\n");
        for (self.results.items, 0..) |result, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"operation\": \"{s}\",\n", .{result.operation});
            try writer.print("      \"implementation\": \"{s}\",\n", .{result.implementation});
            try writer.print("      \"median_ns\": {d},\n", .{result.median_ns});
            try writer.print("      \"mean_ns\": {d},\n", .{result.ns_per_op});
            try writer.print("      \"std_dev\": {d:.2},\n", .{result.std_dev});
            try writer.print("      \"min_ns\": {d},\n", .{result.min_ns});
            try writer.print("      \"max_ns\": {d},\n", .{result.max_ns});
            try writer.print("      \"ops_per_sec\": {d:.2}", .{result.opsPerSec()});

            if (result.throughputMBps()) |mbps| {
                try writer.print(",\n      \"mb_per_sec\": {d:.2}", .{mbps});
            }

            try writer.writeAll("\n    }");
            if (i < self.results.items.len - 1) {
                try writer.writeAll(",");
            }
            try writer.writeAll("\n");
        }
        try writer.writeAll("  ]\n}\n");
    }

    // ===== MARKDOWN RESULTS SAVING =====
    // Save timestamped results to results/ directory

    pub fn saveMarkdownResults(self: *Benchmark) ![]const u8 {
        if (self.results.items.len == 0) return "";

        // Create results directory if it doesn't exist
        std.fs.cwd().makeDir("results") catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK, directory exists
            else => return err,
        };

        // Generate timestamp for filename using Zig stdlib date functions
        const timestamp = std.time.timestamp();
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        // Calculate time components
        const seconds_today = @as(u64, @intCast(timestamp)) % (24 * 60 * 60);
        const hour = @as(u32, @intCast(seconds_today / 3600));
        const minute = @as(u32, @intCast((seconds_today % 3600) / 60));
        const second = @as(u32, @intCast(seconds_today % 60));

        const filename = try std.fmt.allocPrint(self.allocator, "results/{d}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}.md", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, hour, minute, second });

        // Open file for writing
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        const writer = file.writer();

        // Write markdown header
        try writer.writeAll("# Cryptographic Benchmark Results\n\n");

        // System information
        try writer.writeAll("## System Information\n\n");
        try writer.print("- **Date**: {} (Unix timestamp)\n", .{timestamp});
        try writer.print("- **CPU**: {s}\n", .{builtin.cpu.model.name});
        try writer.print("- **Architecture**: {s}\n", .{@tagName(builtin.cpu.arch)});
        try writer.print("- **OS**: {s}\n", .{@tagName(builtin.os.tag)});
        try writer.print("- **Zig version**: {}\n", .{builtin.zig_version});
        try writer.print("- **Build mode**: {s}\n", .{@tagName(builtin.mode)});

        const timer_name = switch (builtin.os.tag) {
            .macos => "mach_absolute_time",
            .linux => "clock_gettime(CLOCK_MONOTONIC)",
            .windows => "QueryPerformanceCounter",
            else => "std.time.nanoTimestamp",
        };
        try writer.print("- **Timer**: High-resolution ({s})\n", .{timer_name});
        try writer.writeAll("\n");

        // Library versions and build configuration
        try writer.writeAll("## Library Versions & Build Configuration\n\n");
        try writer.print("- **Zig stdlib**: {} (target: {s}-{s}, cpu: {s}, optimize: {s})\n", .{ builtin.zig_version, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), builtin.cpu.model.name, @tagName(builtin.mode) });
        try writer.writeAll("  - Flags not set: -Dcpu=baseline, -Dzig-backend=stage2_c\n");
        try writer.writeAll("  - Performance target: OPTIMAL\n");
        try writer.writeAll("- **Rust sha2**: 0.10.9 (features: asm,default,sha2-asm,std, RUSTFLAGS: -C target-cpu=native)\n");
        try writer.writeAll("  - Performance target: OPTIMAL\n");
        try writer.writeAll("\n");

        // Benchmark configuration
        try writer.writeAll("## Benchmark Configuration\n\n");
        try writer.print("- **Warmup iterations**: {d}\n", .{self.warmup_iterations});
        try writer.print("- **Measure iterations**: {d}\n", .{self.measure_iterations});
        try writer.writeAll("\n");

        // Results tables grouped by operation
        try writer.writeAll("## Results\n\n");

        // Group results by operation
        var operations = std.StringHashMap(std.ArrayList(Result)).init(self.allocator);
        defer {
            var it = operations.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            operations.deinit();
        }

        for (self.results.items) |result| {
            const entry = try operations.getOrPut(result.operation);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(Result).init(self.allocator);
            }
            try entry.value_ptr.append(result);
        }

        // Write markdown table for each operation
        var op_it = operations.iterator();
        while (op_it.next()) |entry| {
            try writer.print("### {s}\n\n", .{entry.key_ptr.*});

            const results = entry.value_ptr.items;
            // Sort with Zig stdlib first
            std.mem.sort(Result, results, {}, struct {
                fn lessThan(_: void, a: Result, b: Result) bool {
                    if (std.mem.eql(u8, a.implementation, "Zig stdlib")) return true;
                    if (std.mem.eql(u8, b.implementation, "Zig stdlib")) return false;
                    return std.mem.lessThan(u8, a.implementation, b.implementation);
                }
            }.lessThan);

            // Markdown table header
            try writer.writeAll("| Implementation | Median (ns) | Throughput | Relative |\n");
            try writer.writeAll("|---|---:|---:|---:|\n");

            // Calculate baseline for relative comparison
            var zig_baseline: ?u64 = null;
            for (results) |result| {
                if (std.mem.eql(u8, result.implementation, "Zig stdlib")) {
                    zig_baseline = result.median_ns;
                    break;
                }
            }
            const baseline = zig_baseline orelse results[0].median_ns;

            // Write table rows
            for (results) |result| {
                const relative = @as(f64, @floatFromInt(baseline)) /
                    @as(f64, @floatFromInt(result.median_ns));

                const throughput_str = if (result.throughputMBps()) |mbps|
                    try std.fmt.allocPrint(self.allocator, "{d:.2} MB/s", .{mbps})
                else
                    try std.fmt.allocPrint(self.allocator, "{d:.0} ops/s", .{result.opsPerSec()});
                defer self.allocator.free(throughput_str);

                try writer.print("| {s} | {d} | {s} | {d:.2}x |\n", .{
                    result.implementation,
                    result.median_ns,
                    throughput_str,
                    relative,
                });
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll("---\n");

        return filename;
    }

    // ===== STATISTICAL CALCULATIONS =====
    // Core math for analyzing samples

    const Stats = struct {
        mean: u64,
        median: u64,
        std_dev: f64,
        min: u64,
        max: u64,
    };

    fn calculateStats(samples: []u64) Stats {
        // Sort for median calculation
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));

        // Median is middle value (or average of two middle values)
        const median = if (samples.len % 2 == 0)
            (samples[samples.len / 2 - 1] + samples[samples.len / 2]) / 2
        else
            samples[samples.len / 2];

        // Calculate mean and find min/max
        var sum: u64 = 0;
        var min = samples[0];
        var max = samples[0];

        for (samples) |sample| {
            sum += sample;
            if (sample < min) min = sample;
            if (sample > max) max = sample;
        }

        const mean = sum / samples.len;

        // Calculate standard deviation
        // Sqrt of average of squared differences from mean
        var variance: f64 = 0;
        for (samples) |sample| {
            const diff = @as(f64, @floatFromInt(sample)) - @as(f64, @floatFromInt(mean));
            variance += diff * diff;
        }
        variance /= @as(f64, @floatFromInt(samples.len));
        const std_dev = @sqrt(variance);

        return .{
            .mean = mean,
            .median = median,
            .std_dev = std_dev,
            .min = min,
            .max = max,
        };
    }
};
