// High-resolution timer for benchmarking
// Uses the best available timer for each platform

const std = @import("std");
const builtin = @import("builtin");

// Get the highest resolution timer available
pub const Timer = if (builtin.os.tag == .windows)
    WindowsTimer
else if (builtin.os.tag == .macos)
    MachTimer
else
    PosixTimer;

// macOS: Use mach_absolute_time for nanosecond precision
const MachTimer = struct {
    const c = @cImport({
        @cInclude("mach/mach_time.h");
    });

    var timebase_info: c.mach_timebase_info_data_t = undefined;
    var timebase_initialized = false;

    fn ensureTimebase() void {
        if (!timebase_initialized) {
            _ = c.mach_timebase_info(&timebase_info);
            timebase_initialized = true;
        }
    }

    pub fn read() i128 {
        ensureTimebase();
        const ticks = c.mach_absolute_time();
        // Convert to nanoseconds
        return @divTrunc(@as(i128, ticks) * @as(i128, timebase_info.numer), @as(i128, timebase_info.denom));
    }
};

// Linux: Use clock_gettime with CLOCK_MONOTONIC
const PosixTimer = struct {
    pub fn read() i128 {
        var ts: std.posix.timespec = undefined;
        std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) catch {
            // Fallback to timestamp
            return std.time.nanoTimestamp();
        };
        return @as(i128, ts.tv_sec) * 1_000_000_000 + ts.tv_nsec;
    }
};

// Windows: Use QueryPerformanceCounter
const WindowsTimer = struct {
    const windows = std.os.windows;

    var frequency: i64 = 0;
    var freq_initialized = false;

    fn ensureFrequency() void {
        if (!freq_initialized) {
            _ = windows.QueryPerformanceFrequency(&frequency);
            freq_initialized = true;
        }
    }

    pub fn read() i128 {
        ensureFrequency();
        var counter: i64 = undefined;
        _ = windows.QueryPerformanceCounter(&counter);
        // Convert to nanoseconds
        return @divTrunc(@as(i128, counter) * 1_000_000_000, @as(i128, frequency));
    }
};

// Simple wrapper function
pub fn nanotime() i128 {
    return Timer.read();
}