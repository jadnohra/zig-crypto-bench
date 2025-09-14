// Main benchmark runner entry point

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness.zig");
const cpu_governor = @import("cpu_governor.zig");

// Framework version
pub const VERSION = "v0.1.0";

// Benchmark result display order
pub const OPERATION_ORDER = [_][]const u8{
    "SHA256 32 B",
    "SHA256 64 B",
    "SHA256 128 B",
    "SHA256 256 B",
    "SHA256 1 KB",
    "SHA256 1 MB",
    "SHA256 10 MB",
    "SHA512 32 B",
    "SHA512 64 B",
    "SHA512 128 B",
    "SHA512 256 B",
    "SHA512 1 KB",
    "SHA512 1 MB",
    "SHA512 10 MB",
};

// Import individual benchmark modules
const sha256_bench = @import("benchmarks/sha256.zig");
const sha512_bench = @import("benchmarks/sha512.zig");
// Future benchmarks:
// const keccak256_bench = @import("benchmarks/keccak256.zig");
// const secp256k1_bench = @import("benchmarks/secp256k1.zig");
// const blake2b_bench = @import("benchmarks/blake2b.zig");

// Configuration from command-line arguments
const Config = struct {
    filter: ?[]const u8 = null,
    json_output: bool = false,
    iterations: u32 = 500,
    warmup: u32 = 50,
    save_results: bool = false,
    help: bool = false,
};

pub fn main() !void {
    // Using GeneralPurposeAllocator for debug builds to catch leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const config = try parseArgs(allocator);
    defer {
        // Free duplicated filter string if present
        if (config.filter) |f| {
            allocator.free(f);
        }
    }

    // Show help if requested
    if (config.help) {
        printHelp();
        return;
    }

    // Print header
    if (!config.json_output) {
        printHeader();

        // Show system information
        std.debug.print("System Information:\n", .{});

        // Date and time
        const timestamp = std.time.timestamp();
        std.debug.print("  Date:               {} (Unix timestamp)\n", .{timestamp});

        // CPU info
        const cpu_model = builtin.cpu.model.name;
        std.debug.print("  CPU:                {s}\n", .{cpu_model});
        std.debug.print("  Architecture:       {s}\n", .{@tagName(builtin.cpu.arch)});

        // OS info
        std.debug.print("  OS:                 {s}\n", .{@tagName(builtin.os.tag)});

        // Zig version
        std.debug.print("  Zig version:        {}\n", .{builtin.zig_version});

        // Build mode
        std.debug.print("  Build mode:         {s}\n", .{@tagName(builtin.mode)});

        // Timer precision
        const timer_name = switch (builtin.os.tag) {
            .macos => "mach_absolute_time",
            .linux => "clock_gettime(CLOCK_MONOTONIC)",
            .windows => "QueryPerformanceCounter",
            else => "std.time.nanoTimestamp",
        };
        std.debug.print("  Timer:              High-resolution ({s})\n", .{timer_name});

        // Check CPU frequency governor
        const governor_state = cpu_governor.checkCpuGovernor(allocator) catch .unknown;
        cpu_governor.printGovernorWarning(governor_state);

        // Check thermal throttling
        const is_throttled = cpu_governor.checkThermalThrottling(allocator) catch false;
        if (is_throttled) {
            std.debug.print("  Thermal state:      Throttling detected - WARNING\n", .{});
        }

        std.debug.print("\n", .{});

        // Library versions and build configuration (formal specification)
        std.debug.print("Library Versions & Build Configuration:\n", .{});
        std.debug.print("  Zig stdlib:         {} (target: {s}-{s}, cpu: {s}, optimize: {s})\n", .{ builtin.zig_version, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), builtin.cpu.model.name, @tagName(builtin.mode) });
        std.debug.print("                       Flags not set: -Dcpu=baseline, -Dzig-backend=stage2_c\n", .{});
        std.debug.print("                       Performance target: OPTIMAL\n", .{});
        std.debug.print("  Rust sha2:          0.10.9 (features: asm,default,sha2-asm,std, RUSTFLAGS: -C target-cpu=native)\n", .{});
        std.debug.print("                       Performance target: OPTIMAL\n", .{});

        std.debug.print("\n", .{});

        // Show configuration
        std.debug.print("Benchmark Configuration:\n", .{});
        std.debug.print("  Warmup iterations:  {d}\n", .{config.warmup});
        std.debug.print("  Measure iterations: {d}\n", .{config.iterations});
        if (config.filter) |f| {
            std.debug.print("  Filter:             {s}\n", .{f});
        }
        std.debug.print("\n", .{});
    }

    // Initialize benchmark harness
    var bench = harness.Benchmark.init(allocator, .{
        .warmup_iterations = config.warmup,
        .measure_iterations = config.iterations,
        .json_output = config.json_output,
        .save_results = config.save_results,
    });
    defer bench.deinit();

    // Capture CPU state before benchmarking
    bench.cpu_state_before = cpu_governor.captureCpuState(allocator);

    // Run benchmarks (each module checks the filter internally)

    var benchmarks_run: u32 = 0;

    // SHA256 benchmark
    if (shouldRun("sha256", config.filter)) {
        try sha256_bench.run(&bench);
        benchmarks_run += 1;
    }

    // SHA512 benchmark
    if (shouldRun("sha512", config.filter)) {
        try sha512_bench.run(&bench);
        benchmarks_run += 1;
    }

    // Future benchmarks - uncomment as implemented:
    // if (shouldRun("keccak256", config.filter)) {
    //     try keccak256_bench.run(&bench);
    //     benchmarks_run += 1;
    // }
    //
    // if (shouldRun("secp256k1", config.filter)) {
    //     try secp256k1_bench.run(&bench);
    //     benchmarks_run += 1;
    // }
    //
    // if (shouldRun("blake2b", config.filter)) {
    //     try blake2b_bench.run(&bench);
    //     benchmarks_run += 1;
    // }

    // Check if any benchmarks were run
    if (benchmarks_run == 0) {
        if (!config.json_output) {
            if (config.filter) |f| {
                std.debug.print("No benchmarks matched filter: '{s}'\n", .{f});
                std.debug.print("Available benchmarks: sha256, sha512\n", .{}); // Add more as implemented
            } else {
                std.debug.print("No benchmarks available to run.\n", .{});
            }
        } else {
            // Empty JSON output
            try bench.outputJson(std.io.getStdOut().writer());
        }
        return;
    }

    // Output results
    if (config.json_output) {
        // Machine-readable JSON to stdout
        try bench.outputJson(std.io.getStdOut().writer());
    } else {
        // Human-readable summary
        try bench.printSummary();
    }

    // Save results
    if (config.save_results) {
        const filename = try bench.saveMarkdownResults();
        defer allocator.free(filename);
        if (!config.json_output) {
            std.debug.print("\nResults saved to {s}\n", .{filename});
        }
    }

    // Check if CPU frequency changed during benchmarking
    if (bench.cpu_state_before) |before| {
        const after_state = cpu_governor.captureCpuState(allocator);
        if (after_state) |after| {
            if (cpu_governor.didFrequencyChange(before, after)) {
                if (!config.json_output) {
                    std.debug.print("\n⚠️  WARNING: CPU frequency changed during benchmarking\n", .{});
                    if (before.frequency) |f1| {
                        if (after.frequency) |f2| {
                            std.debug.print("  Before: {d:.2} GHz, After: {d:.2} GHz\n", .{
                                @as(f64, @floatFromInt(f1)) / 1_000_000_000.0,
                                @as(f64, @floatFromInt(f2)) / 1_000_000_000.0,
                            });
                        }
                    }
                }
            }
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "--filter") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --filter requires an argument\n", .{});
                std.process.exit(1);
            }
            // Need to duplicate the string since args will be freed
            config.filter = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            config.json_output = true;
        } else if (std.mem.eql(u8, arg, "--save-results")) {
            config.save_results = true;
        } else if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --iterations requires a number\n", .{});
                std.process.exit(1);
            }
            config.iterations = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid iteration count: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--warmup") or std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --warmup requires a number\n", .{});
                std.process.exit(1);
            }
            config.warmup = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid warmup count: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else {
            std.debug.print("Error: Unknown argument: {s}\n", .{arg});
            std.debug.print("Use --help for usage information\n", .{});
            std.process.exit(1);
        }
    }

    return config;
}

fn shouldRun(benchmark_name: []const u8, filter: ?[]const u8) bool {
    if (filter) |f| {
        // Case-insensitive substring match
        return std.ascii.indexOfIgnoreCase(benchmark_name, f) != null;
    }
    return true; // No filter means run everything
}

fn printHeader() void {
    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║          Cryptographic Benchmark Suite                 ║\n", .{});
    std.debug.print("║                    zig-crypto-bench                    ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

fn printFooter() void {
    std.debug.print("\n", .{});
    std.debug.print("─" ** 60 ++ "\n", .{});
    std.debug.print("Tips:\n", .{});
    std.debug.print("• For best results: sudo cpupower frequency-set -g performance\n", .{});
    std.debug.print("• Run with --json for machine-readable output\n", .{});
    std.debug.print("• Use --filter to run specific benchmarks\n", .{});
    std.debug.print("• Increase --iterations for more accurate results\n", .{});
    std.debug.print("\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\Usage: zig-crypto-bench [OPTIONS]
        \\
        \\Benchmark cryptographic primitives across different implementations.
        \\
        \\OPTIONS:
        \\  -h, --help              Show this help message
        \\  -f, --filter NAME       Run only benchmarks containing NAME
        \\  -i, --iterations N      Number of iterations (default: 500, auto-scales for large inputs)
        \\  -w, --warmup N          Number of warmup iterations (default: 50)
        \\  -j, --json              Output results as JSON
        \\  --save-results          Save timestamped results to results/ directory
        \\
        \\EXAMPLES:
        \\  zig-crypto-bench                    # Run all benchmarks
        \\  zig-crypto-bench --filter sha       # Run SHA benchmarks only
        \\  zig-crypto-bench --json             # Output as JSON
        \\  zig-crypto-bench -i 50000 -w 5000   # More iterations
        \\
        \\AVAILABLE BENCHMARKS:
        \\  sha256      SHA-256 hash function
        \\  sha512      SHA-512 hash function
        \\  keccak256   Keccak-256 hash function (coming soon)
        \\  secp256k1   Elliptic curve operations (coming soon)
        \\  blake2b     BLAKE2b hash function (coming soon)
        \\
        \\For more information: https://github.com/jadnohra/zig-crypto-bench
        \\
    , .{});
}
