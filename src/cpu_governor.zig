// CPU frequency governor detection for consistent benchmarks

const std = @import("std");
const builtin = @import("builtin");

pub const CpuGovernorState = enum {
    performance, // Optimal for benchmarking
    powersave, // Will throttle
    ondemand, // Will throttle
    unknown, // Can't determine
};

// Simple struct to capture CPU state for comparison
pub const CpuState = struct {
    frequency: ?u64 = null, // Current frequency in Hz (if available)
    timestamp: i64, // When measured
};

pub fn checkCpuGovernor(allocator: std.mem.Allocator) !CpuGovernorState {
    if (builtin.os.tag == .linux) {
        return checkLinuxGovernor(allocator);
    } else if (builtin.os.tag == .macos) {
        return checkMacGovernor(allocator);
    }
    return .unknown;
}

fn checkLinuxGovernor(allocator: std.mem.Allocator) !CpuGovernorState {
    // Check scaling governor for CPU0 (usually representative)
    const governor_path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor";

    const file = std.fs.openFileAbsolute(governor_path, .{}) catch {
        // File doesn't exist - might be in a VM or container
        return .unknown;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 256);
    defer allocator.free(content);

    const governor = std.mem.trimRight(u8, content, "\n\r ");

    if (std.mem.eql(u8, governor, "performance")) {
        return .performance;
    } else if (std.mem.eql(u8, governor, "powersave")) {
        return .powersave;
    } else if (std.mem.eql(u8, governor, "ondemand")) {
        return .ondemand;
    } else if (std.mem.eql(u8, governor, "schedutil")) {
        return .ondemand; // Dynamic scaling
    } else if (std.mem.eql(u8, governor, "conservative")) {
        return .ondemand; // Dynamic scaling
    }

    return .unknown;
}

fn checkMacGovernor(allocator: std.mem.Allocator) !CpuGovernorState {
    // On macOS, check if we're on battery (throttles) or AC power
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "pmset", "-g", "batt" },
    }) catch {
        return .unknown;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Look for "AC Power" in output
    if (std.mem.indexOf(u8, result.stdout, "AC Power") != null) {
        // On AC power - less likely to throttle
        return .performance;
    } else if (std.mem.indexOf(u8, result.stdout, "Battery Power") != null) {
        // On battery - likely to throttle
        return .powersave;
    }

    return .unknown;
}

pub fn printGovernorWarning(state: CpuGovernorState) void {
    switch (state) {
        .performance => {
            std.debug.print("  CPU freq scaling:   performance (fixed frequency)\n", .{});
        },
        .powersave => {
            std.debug.print("  CPU freq scaling:   powersave (dynamic scaling) - WARNING\n", .{});
        },
        .ondemand => {
            std.debug.print("  CPU freq scaling:   ondemand (dynamic scaling) - WARNING\n", .{});
        },
        .unknown => {
            // Don't print anything if we can't determine
        },
    }
}

// Also check if system is thermally throttled
pub fn checkThermalThrottling(allocator: std.mem.Allocator) !bool {
    if (builtin.os.tag == .linux) {
        // Check thermal throttle flag
        const throttle_path = "/sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count";

        const file = std.fs.openFileAbsolute(throttle_path, .{}) catch {
            return false; // Can't check
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 256) catch return false;
        defer allocator.free(content);

        const count = std.fmt.parseInt(u64, std.mem.trimRight(u8, content, "\n\r "), 10) catch 0;
        return count > 0;
    }

    return false;
}

// Capture current CPU frequency (best effort)
pub fn captureCpuState(allocator: std.mem.Allocator) ?CpuState {
    var state = CpuState{
        .timestamp = std.time.milliTimestamp(),
    };

    if (builtin.os.tag == .linux) {
        // Read current frequency from CPU0
        const freq_path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq";
        const file = std.fs.openFileAbsolute(freq_path, .{}) catch {
            return state; // Can't read, return without frequency
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 256) catch return state;
        defer allocator.free(content);

        // Parse frequency (in kHz from sysfs)
        const freq_khz = std.fmt.parseInt(u64, std.mem.trimRight(u8, content, "\n\r "), 10) catch 0;
        state.frequency = freq_khz * 1000; // Convert to Hz
    } else if (builtin.os.tag == .macos) {
        // macOS: Use sysctl to get current frequency
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sysctl", "-n", "hw.cpufrequency" },
        }) catch {
            // Try alternative for Apple Silicon
            const alt_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "sysctl", "-n", "hw.cpufrequency_max" },
            }) catch {
                return state;
            };
            defer allocator.free(alt_result.stdout);
            defer allocator.free(alt_result.stderr);

            const freq = std.fmt.parseInt(u64, std.mem.trimRight(u8, alt_result.stdout, "\n\r "), 10) catch 0;
            state.frequency = freq;
            return state;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const freq = std.fmt.parseInt(u64, std.mem.trimRight(u8, result.stdout, "\n\r "), 10) catch 0;
        state.frequency = freq;
    }

    return state;
}

// Check if CPU frequency changed significantly
pub fn didFrequencyChange(before: CpuState, after: CpuState) bool {
    if (before.frequency == null or after.frequency == null) {
        return false; // Can't determine
    }

    const freq_before = before.frequency.?;
    const freq_after = after.frequency.?;

    // Consider it changed if difference is more than 10%
    const diff = if (freq_after > freq_before)
        freq_after - freq_before
    else
        freq_before - freq_after;

    const threshold = freq_before / 10; // 10% threshold
    return diff > threshold;
}

test "cpu governor detection doesn't crash" {
    const testing = std.testing;
    const allocator = testing.allocator;

    std.debug.print("\n✓ Running: CPU governor detection\n", .{});

    // Should not crash even if files don't exist
    const state = try checkCpuGovernor(allocator);
    try testing.expect(@intFromEnum(state) >= 0);

    // Thermal check should not crash
    const is_throttled = try checkThermalThrottling(allocator);
    _ = is_throttled;

    // Frequency capture should not crash
    const cpu_state = captureCpuState(allocator);
    _ = cpu_state;
}

test "frequency change detection logic" {
    const testing = std.testing;

    std.debug.print("\n✓ Running: Frequency change detection logic\n", .{});

    // Test no change scenario
    const state1 = CpuState{
        .frequency = 2000000000, // 2.0 GHz
        .timestamp = 1000,
    };
    const state2 = CpuState{
        .frequency = 2000000000, // Same
        .timestamp = 2000,
    };
    try testing.expect(!didFrequencyChange(state1, state2));

    // Test small change (5%) - should not trigger
    const state3 = CpuState{
        .frequency = 2100000000, // 2.1 GHz (5% increase)
        .timestamp = 3000,
    };
    try testing.expect(!didFrequencyChange(state1, state3));

    // Test significant change (15%) - should trigger
    const state4 = CpuState{
        .frequency = 2300000000, // 2.3 GHz (15% increase)
        .timestamp = 4000,
    };
    try testing.expect(didFrequencyChange(state1, state4));

    // Test decrease (20%) - should trigger
    const state5 = CpuState{
        .frequency = 1600000000, // 1.6 GHz (20% decrease)
        .timestamp = 5000,
    };
    try testing.expect(didFrequencyChange(state1, state5));

    // Test with null frequencies - should not crash
    const state6 = CpuState{
        .frequency = null,
        .timestamp = 6000,
    };
    const state7 = CpuState{
        .frequency = null,
        .timestamp = 7000,
    };
    try testing.expect(!didFrequencyChange(state6, state7));
    try testing.expect(!didFrequencyChange(state1, state6));
}
