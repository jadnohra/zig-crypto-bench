// Benchmarking framework for fair timing comparison across implementations

const std = @import("std");
const time = std.time;
const builtin = @import("builtin");
const timer = @import("timer.zig");

// Minimal FFI function for overhead checking
extern fn zig_noop_ffi() void;

fn checkFfiOverhead() struct { overhead_ns: i64, has_warning: bool } {
    const iterations = 100000;

    // Measure FFI call overhead
    const ffi_start = timer.nanotime();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        zig_noop_ffi();
    }
    const ffi_end = timer.nanotime();

    // Measure empty loop overhead
    const loop_start = timer.nanotime();
    i = 0;
    while (i < iterations) : (i += 1) {
        // Empty loop
        std.mem.doNotOptimizeAway(&i);
    }
    const loop_end = timer.nanotime();

    // Round to nearest nanosecond (add half divisor before truncating)
    const ffi_total = ffi_end - ffi_start;
    const loop_total = loop_end - loop_start;
    const half = iterations / 2;
    const ffi_time = @divTrunc(ffi_total + half, iterations);
    const loop_time = @divTrunc(loop_total + half, iterations);

    // Calculate the difference (FFI overhead)
    const overhead_i128 = if (ffi_time > loop_time) ffi_time - loop_time else 0;
    const overhead: i64 = @intCast(overhead_i128);

    if (overhead > 20) {  // Only warn if unexpectedly high
        std.debug.print("⚠️  WARNING: FFI overhead is {}ns (expected <20ns)\n", .{overhead});
        std.debug.print("    Results may not be directly comparable.\n", .{});
        return .{ .overhead_ns = overhead, .has_warning = true };
    }
    return .{ .overhead_ns = overhead, .has_warning = false };
}

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    warmup_iterations: u32,
    measure_iterations: u32,
    json_output: bool,
    verbose: bool,
    save_results: bool,
    mode: @import("main.zig").BenchmarkMode,
    ffi_overhead_ns: i64 = 0,
    ffi_has_warning: bool = false,
    results: std.ArrayList(Result),
    cpu_state_before: ?@import("cpu_governor.zig").CpuState = null,

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

    pub fn init(allocator: std.mem.Allocator, config: struct {
        warmup_iterations: u32 = 1000,
        measure_iterations: u32 = 10000,
        json_output: bool = false,
        save_results: bool = false,
        mode: @import("main.zig").BenchmarkMode = .ffi,
    }) Benchmark {
        var bench = Benchmark{
            .allocator = allocator,
            .warmup_iterations = config.warmup_iterations,
            .measure_iterations = config.measure_iterations,
            .json_output = config.json_output,
            .verbose = false,
            .save_results = config.save_results,
            .mode = config.mode,
            .ffi_overhead_ns = 0,
            .ffi_has_warning = false,
            .results = std.ArrayList(Result).init(allocator),
        };

        // Check FFI overhead if in FFI mode (just warn if high)
        if (config.mode == .ffi) {
            const result = checkFfiOverhead();
            bench.ffi_overhead_ns = result.overhead_ns;
            bench.ffi_has_warning = result.has_warning;
        }

        return bench;
    }

    pub fn deinit(self: *Benchmark) void {
        // Free string copies we made
        for (self.results.items) |result| {
            self.allocator.free(result.operation);
            self.allocator.free(result.implementation);
        }
        self.results.deinit();
    }

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

        // Warmup phase: stabilize CPU performance and caches

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

        // Measurement phase: collect timing samples

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

        // Statistical analysis
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

    // Print individual result

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

    // Print comparison summary

    pub fn printSummary(self: *Benchmark) !void {
        if (self.results.items.len == 0) {
            std.debug.print("No benchmark results collected.\n", .{});
            return;
        }

        std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
        std.debug.print("SUMMARY\n", .{});
        std.debug.print("=" ** 60 ++ "\n\n", .{});

        // Show measurement methodology based on mode
        std.debug.print("Measurement Methodology:\n", .{});
        switch (self.mode) {
            .native => {
                std.debug.print("  Mode: Native\n", .{});
            },
            .ffi => {
                std.debug.print("  Mode: FFI (~{}ns overhead)\n", .{self.ffi_overhead_ns});
            },
        }
        std.debug.print("\n", .{});

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

        const main = @import("main.zig");
        for (main.OPERATION_ORDER) |op_name| {
            const entry = operations.get(op_name) orelse continue;
            std.debug.print("Operation: {s}\n", .{op_name});
            std.debug.print("-" ** 50 ++ "\n", .{});

            // Sort with Zig stdlib first, then others
            const results = entry.items;
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

    // Output results as JSON

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

    // Get git commit hash if available
    pub fn getGitCommitHash(allocator: std.mem.Allocator) !?[]const u8 {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "rev-parse", "--short", "HEAD" },
        }) catch {
            // Git not available or not a git repo
            return null;
        };
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            allocator.free(result.stdout);
            return null;
        }

        // Remove trailing newline and create proper allocation
        const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r");
        const hash = try allocator.dupe(u8, trimmed);
        allocator.free(result.stdout);
        return hash;
    }

    // Save timestamped results to markdown

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

        // Framework version
        try writer.writeAll("## Benchmark Framework\n\n");
        const main = @import("main.zig");
        const git_hash = try getGitCommitHash(self.allocator);
        defer if (git_hash) |hash| self.allocator.free(hash);

        if (git_hash) |hash| {
            try writer.print("- Version: {s} (git-{s})\n", .{ main.VERSION, hash });
        } else {
            try writer.print("- Version: {s}\n", .{main.VERSION});
        }
        try writer.writeAll("\n");

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

        // CPU frequency scaling governor state
        const cpu_governor = @import("cpu_governor.zig");
        const governor_state = cpu_governor.checkCpuGovernor(self.allocator) catch .unknown;
        const governor_str = switch (governor_state) {
            .performance => "performance (fixed frequency)",
            .powersave => "powersave (dynamic scaling)",
            .ondemand => "ondemand (dynamic scaling)",
            .unknown => "unknown",
        };
        try writer.print("- **CPU frequency scaling**: {s}\n", .{governor_str});

        // Power source for macOS
        if (builtin.os.tag == .macos and governor_state != .unknown) {
            const power_source = switch (governor_state) {
                .performance => "AC power",
                .powersave => "Battery power",
                else => "Unknown",
            };
            try writer.print("- **Power source**: {s}\n", .{power_source});
        }

        // Thermal throttling state
        const is_throttled = cpu_governor.checkThermalThrottling(self.allocator) catch false;
        if (builtin.os.tag == .linux) {
            try writer.print("- **Thermal throttling**: {s}\n", .{if (is_throttled) "DETECTED" else "none"});
        }
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

        for (main.OPERATION_ORDER) |op_name| {
            const entry = operations.get(op_name) orelse continue;
            try writer.print("### {s}\n\n", .{op_name});

            const results = entry.items;
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

    // Statistical calculations

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

test "FFI overhead check is reasonable" {
    const testing = std.testing;

    std.debug.print("\n✓ Running: FFI overhead check\n", .{});

    // Measure FFI overhead (similar to checkFfiOverhead but returning value for test)
    const iterations = 100000;
    const ffi_start = timer.nanotime();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        zig_noop_ffi();
    }
    const ffi_end = timer.nanotime();

    const loop_start = timer.nanotime();
    i = 0;
    while (i < iterations) : (i += 1) {
        std.mem.doNotOptimizeAway(&i);
    }
    const loop_end = timer.nanotime();

    const ffi_time = @divTrunc(ffi_end - ffi_start, iterations);
    const loop_time = @divTrunc(loop_end - loop_start, iterations);
    const overhead = if (ffi_time > loop_time) ffi_time - loop_time else 0;

    // FFI overhead should be reasonable (typically < 20ns)
    try testing.expect(overhead < 100); // Should be well under 100ns
}

// External Zig FFI function for mode testing
extern fn zig_sha256_ffi(data: [*]const u8, len: usize, output: [*]u8) void;

test "benchmark modes work correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    std.debug.print("\n✓ Running: benchmark modes test\n", .{});

    // Test input
    const input = "test data for hashing";

    // Test native mode
    var bench_native = Benchmark.init(allocator, .{
        .warmup_iterations = 5,
        .measure_iterations = 10,
        .json_output = true,
        .save_results = false,
        .mode = .native,
    });
    defer bench_native.deinit();

    const S1 = struct {
        var input_data: []const u8 = undefined;
    };
    S1.input_data = input;

    try bench_native.measure(
        "test",
        "Zig (stdlib)",
        struct {
            fn run() void {
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(S1.input_data, &hash, .{});
                std.mem.doNotOptimizeAway(&hash);
            }
        }.run,
        input.len,
    );

    // Test FFI mode
    var bench_ffi = Benchmark.init(allocator, .{
        .warmup_iterations = 5,
        .measure_iterations = 10,
        .json_output = true,
        .save_results = false,
        .mode = .ffi,
    });
    defer bench_ffi.deinit();

    const S2 = struct {
        var input_data: []const u8 = undefined;
    };
    S2.input_data = input;

    try bench_ffi.measure(
        "test",
        "Zig (FFI)",
        struct {
            fn run() void {
                var hash: [32]u8 = undefined;
                zig_sha256_ffi(S2.input_data.ptr, S2.input_data.len, &hash);
                std.mem.doNotOptimizeAway(&hash);
            }
        }.run,
        input.len,
    );

    // Get results
    const native_time = bench_native.results.items[0].median_ns;
    const ffi_time = bench_ffi.results.items[0].median_ns;

    // Both times should be reasonable (> 0, < 10000ns for small input)
    try testing.expect(native_time > 0 and native_time < 10000);
    try testing.expect(ffi_time > 0 and ffi_time < 10000);

    // FFI may be slightly slower than native, but should be in same ballpark
    // (within 2x since FFI overhead is negligible)
    const ratio = @as(f64, @floatFromInt(ffi_time)) / @as(f64, @floatFromInt(native_time));
    try testing.expect(ratio < 3.0); // FFI shouldn't be more than 3x slower
}

test "version information is accessible" {
    const testing = std.testing;
    const main = @import("main.zig");

    std.debug.print("\n✓ Running: version information is accessible\n", .{});

    // Test that VERSION constant exists and is not empty
    try testing.expect(main.VERSION.len > 0);
    try testing.expect(std.mem.startsWith(u8, main.VERSION, "v"));
}

test "git commit hash retrieval" {
    const testing = std.testing;
    // Use a non-tracking allocator for this test due to trimming behavior
    const allocator = std.heap.page_allocator;

    std.debug.print("\n✓ Running: git commit hash retrieval\n", .{});

    // Test that getGitCommitHash returns a value (may be null in non-git environments)
    const hash = try Benchmark.getGitCommitHash(allocator);
    if (hash) |h| {
        defer allocator.free(h);
        // If we get a hash, it should be non-empty
        try testing.expect(h.len > 0);
    }
    // null is also acceptable (e.g., not in a git repo)
}

// External Rust function for testing
extern fn rust_sha256(data: [*]const u8, len: usize, output: [*]u8) void;

test "benchmark smoke test - minimal iterations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    std.debug.print("\n✓ Running: benchmark smoke test - minimal iterations\n", .{});

    // Create benchmark with ultra-minimal iterations for fast testing
    var bench = Benchmark.init(allocator, .{
        .warmup_iterations = 1,
        .measure_iterations = 2,
        .json_output = true, // Suppress output
        .save_results = false,
    });
    defer bench.deinit();

    // Just test with one small size for speed
    const input = try allocator.alloc(u8, 64);
    defer allocator.free(input);
    @memset(input, 'A');

    // Test Zig implementation
    {
        const S = struct {
            var input_data: []const u8 = undefined;
        };
        S.input_data = input;

        try bench.measure(
            "SHA256 Test",
            if (bench.mode == .native) "Zig (stdlib)" else "Zig (FFI)",
            struct {
                fn run() void {
                    var hash: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(S.input_data, &hash, .{});
                    std.mem.doNotOptimizeAway(&hash);
                }
            }.run,
            input.len,
        );
    }

    // Test Rust implementation
    {
        const S = struct {
            var input_data: []const u8 = undefined;
        };
        S.input_data = input;

        try bench.measure(
            "SHA256 Test",
            "Rust (sha2)",
            struct {
                fn run() void {
                    var hash: [32]u8 = undefined;
                    rust_sha256(S.input_data.ptr, S.input_data.len, &hash);
                    std.mem.doNotOptimizeAway(&hash);
                }
            }.run,
            input.len,
        );
    }

    // Verify both implementations produce the same output (correctness check)
    var zig_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &zig_hash, .{});

    var rust_hash: [32]u8 = undefined;
    rust_sha256(input.ptr, input.len, &rust_hash);

    try testing.expectEqualSlices(u8, &zig_hash, &rust_hash);

    // Verify we got results
    try testing.expect(bench.results.items.len == 2);

    // Check that results are reasonable and different implementations were tested
    var found_zig = false;
    var found_rust = false;
    for (bench.results.items) |result| {
        // Check timing values are reasonable
        try testing.expect(result.ns_per_op > 0);
        try testing.expect(result.median_ns > 0);
        try testing.expect(result.min_ns <= result.median_ns);
        try testing.expect(result.median_ns <= result.max_ns);

        // Check we have both implementations
        if (std.mem.eql(u8, result.implementation, "Zig (stdlib)") or
            std.mem.eql(u8, result.implementation, "Zig (FFI)")) found_zig = true;
        if (std.mem.eql(u8, result.implementation, "Rust (sha2)")) found_rust = true;
    }

    try testing.expect(found_zig);
    try testing.expect(found_rust);

    std.debug.print("  Smoke test passed: Zig and Rust both tested, hashes match\n", .{});
}

test "markdown results file contains version and git hash" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const main = @import("main.zig");

    std.debug.print("\n✓ Running: markdown results file contains version and git hash\n", .{});

    // Create temp directory for test
    const temp_dir_name = "test_results_temp";
    std.fs.cwd().makeDir(temp_dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(temp_dir_name) catch {};

    // Create test directory
    var test_dir = try std.fs.cwd().openDir(temp_dir_name, .{});
    defer test_dir.close();

    // Create a minimal benchmark instance
    var bench = Benchmark.init(allocator, .{
        .warmup_iterations = 1,
        .measure_iterations = 1,
        .json_output = false,
        .save_results = true,
    });
    defer bench.deinit();

    // Add a dummy result with properly allocated strings
    const op_name = try allocator.dupe(u8, "Test Op");
    const impl_name = try allocator.dupe(u8, "Test Impl");
    try bench.results.append(.{
        .operation = op_name,
        .implementation = impl_name,
        .ns_per_op = 100,
        .median_ns = 100,
        .std_dev = 10.0,
        .min_ns = 90,
        .max_ns = 110,
        .bytes_processed = 1024,
        .batch_size = 1,
    });

    // Change to temp dir, save, then change back
    const original_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd);

    try std.posix.chdir(temp_dir_name);
    defer std.posix.chdir(original_cwd) catch {};

    // Save to file
    const filename = try bench.saveMarkdownResults();
    defer allocator.free(filename);

    // Read and verify content
    const file = try test_dir.openFile(filename, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Verify structure and content
    // 1. Check markdown header
    try testing.expect(std.mem.indexOf(u8, content, "# Cryptographic Benchmark Results") != null);

    // 2. Check version section exists
    const version_section = std.mem.indexOf(u8, content, "## Benchmark Framework");
    try testing.expect(version_section != null);

    // 3. Check version line format (should be near the top)
    const version_line = std.mem.indexOf(u8, content, "- Version:");
    try testing.expect(version_line != null);

    // 4. Check VERSION constant is included
    try testing.expect(std.mem.indexOf(u8, content, main.VERSION) != null);

    // 5. If we have a git hash, verify format is "Version: vX.X.X (git-HASH)"
    const git_hash = try Benchmark.getGitCommitHash(allocator);
    if (git_hash) |hash| {
        defer allocator.free(hash);
        const expected_format = try std.fmt.allocPrint(allocator, "- Version: {s} (git-{s})", .{ main.VERSION, hash });
        defer allocator.free(expected_format);
        try testing.expect(std.mem.indexOf(u8, content, expected_format) != null);
    } else {
        // No git, should just have version
        const expected_format = try std.fmt.allocPrint(allocator, "- Version: {s}", .{main.VERSION});
        defer allocator.free(expected_format);
        try testing.expect(std.mem.indexOf(u8, content, expected_format) != null);
    }

    // 6. Verify version info appears before results
    const results_section = std.mem.indexOf(u8, content, "## Results");
    if (results_section) |results_pos| {
        try testing.expect(version_line.? < results_pos);
    }
}
