const std = @import("std");
const testing = std.testing;

// ============================================================================
// Time Parsing
// ============================================================================

/// Parse a duration string into nanoseconds.
/// Supported suffixes: "h" (hours), "m" (minutes), "s" (seconds),
/// "ms" (milliseconds), "us" (microseconds).
/// A plain number with no suffix is treated as seconds.
/// Returns null for invalid input.
pub fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    // Determine suffix length and multiplier.
    var suffix_len: usize = 0;
    var multiplier: u64 = 0;

    if (std.mem.endsWith(u8, s, "ms")) {
        suffix_len = 2;
        multiplier = std.time.ns_per_ms;
    } else if (std.mem.endsWith(u8, s, "us")) {
        suffix_len = 2;
        multiplier = std.time.ns_per_us;
    } else if (std.mem.endsWith(u8, s, "h")) {
        suffix_len = 1;
        multiplier = std.time.ns_per_hour;
    } else if (std.mem.endsWith(u8, s, "m")) {
        suffix_len = 1;
        multiplier = std.time.ns_per_min;
    } else if (std.mem.endsWith(u8, s, "s")) {
        suffix_len = 1;
        multiplier = std.time.ns_per_s;
    } else {
        // No recognized suffix — treat as seconds if numeric.
        suffix_len = 0;
        multiplier = std.time.ns_per_s;
    }

    const numeric_part = s[0 .. s.len - suffix_len];
    if (numeric_part.len == 0) return null;

    // Try integer parse first.
    if (std.fmt.parseInt(u64, numeric_part, 10)) |int_val| {
        return int_val * multiplier;
    } else |_| {}

    // Try float parse for fractional values.
    if (std.fmt.parseFloat(f64, numeric_part)) |float_val| {
        if (float_val < 0) return null;
        return @intFromFloat(float_val * @as(f64, @floatFromInt(multiplier)));
    } else |_| {}

    return null;
}

// ============================================================================
// Time Formatting
// ============================================================================

/// Format a duration in nanoseconds into a human-readable string.
/// Auto-selects unit: us (< 1ms), ms (< 1s), s (< 1m), m (>= 1m).
/// Output uses two decimal places, e.g. "1.23ms", "456.00us".
/// The caller provides the buffer; the returned slice points into it.
pub fn formatDuration(ns: u64, buf: []u8) []const u8 {
    const ns_f: f64 = @floatFromInt(ns);

    if (ns < std.time.ns_per_ms) {
        // Microseconds.
        const us = ns_f / @as(f64, @floatFromInt(std.time.ns_per_us));
        return std.fmt.bufPrint(buf, "{d:.2}us", .{us}) catch buf[0..0];
    } else if (ns < std.time.ns_per_s) {
        // Milliseconds.
        const ms = ns_f / @as(f64, @floatFromInt(std.time.ns_per_ms));
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{ms}) catch buf[0..0];
    } else if (ns < std.time.ns_per_min) {
        // Seconds.
        const secs = ns_f / @as(f64, @floatFromInt(std.time.ns_per_s));
        return std.fmt.bufPrint(buf, "{d:.2}s", .{secs}) catch buf[0..0];
    } else {
        // Minutes.
        const mins = ns_f / @as(f64, @floatFromInt(std.time.ns_per_min));
        return std.fmt.bufPrint(buf, "{d:.2}m", .{mins}) catch buf[0..0];
    }
}

// ============================================================================
// Number Parsing
// ============================================================================

/// Parse a count/rate string into a raw integer count.
/// Supported suffixes: "k" (1_000), "M" (1_000_000), "G" (1_000_000_000).
/// A plain number with no suffix is returned as-is.
/// Returns null for invalid input.
pub fn parseCount(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    var suffix_len: usize = 0;
    var multiplier: u64 = 1;

    if (std.mem.endsWith(u8, s, "G")) {
        suffix_len = 1;
        multiplier = 1_000_000_000;
    } else if (std.mem.endsWith(u8, s, "M")) {
        suffix_len = 1;
        multiplier = 1_000_000;
    } else if (std.mem.endsWith(u8, s, "k")) {
        suffix_len = 1;
        multiplier = 1_000;
    }

    const numeric_part = s[0 .. s.len - suffix_len];
    if (numeric_part.len == 0) return null;

    // Try integer parse first.
    if (std.fmt.parseInt(u64, numeric_part, 10)) |int_val| {
        return int_val * multiplier;
    } else |_| {}

    // Try float parse for fractional values like "1.5k".
    if (std.fmt.parseFloat(f64, numeric_part)) |float_val| {
        if (float_val < 0) return null;
        return @intFromFloat(float_val * @as(f64, @floatFromInt(multiplier)));
    } else |_| {}

    return null;
}

// ============================================================================
// Number Formatting
// ============================================================================

/// Format a count value into a human-readable string.
/// Auto-selects unit: plain (< 1000), k (< 1M), M (>= 1M).
/// Output uses two decimal places, e.g. "1.00k", "50.00", "1.10k".
/// The caller provides the buffer; the returned slice points into it.
pub fn formatCount(value: f64, buf: []u8) []const u8 {
    if (value >= 1_000_000) {
        const m = value / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}M", .{m}) catch buf[0..0];
    } else if (value >= 1_000) {
        const k = value / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}k", .{k}) catch buf[0..0];
    } else {
        return std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch buf[0..0];
    }
}

// ============================================================================
// Byte Formatting
// ============================================================================

/// Format a byte count into a human-readable string.
/// Auto-selects unit: B, KB, MB, GB.
/// Output uses two decimal places, e.g. "3.50MB", "119.47KB".
/// The caller provides the buffer; the returned slice points into it.
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const bytes_f: f64 = @floatFromInt(bytes);

    if (bytes >= 1024 * 1024 * 1024) {
        const gb = bytes_f / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2}GB", .{gb}) catch buf[0..0];
    } else if (bytes >= 1024 * 1024) {
        const mb = bytes_f / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2}MB", .{mb}) catch buf[0..0];
    } else if (bytes >= 1024) {
        const kb = bytes_f / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.2}KB", .{kb}) catch buf[0..0];
    } else {
        return std.fmt.bufPrint(buf, "{d:.2}B", .{bytes_f}) catch buf[0..0];
    }
}

// ============================================================================
// Tests
// ============================================================================

test "parse duration seconds" {
    try testing.expectEqual(@as(u64, 10_000_000_000), parseDuration("10s").?);
    try testing.expectEqual(@as(u64, 1_000_000_000), parseDuration("1s").?);
    try testing.expectEqual(@as(u64, 30_000_000_000), parseDuration("30s").?);
}

test "parse duration milliseconds" {
    try testing.expectEqual(@as(u64, 500_000_000), parseDuration("500ms").?);
    try testing.expectEqual(@as(u64, 100_000_000), parseDuration("100ms").?);
}

test "parse duration microseconds" {
    try testing.expectEqual(@as(u64, 100_000), parseDuration("100us").?);
}

test "parse duration minutes/hours" {
    try testing.expectEqual(@as(u64, 60_000_000_000), parseDuration("1m").?);
    try testing.expectEqual(@as(u64, 3_600_000_000_000), parseDuration("1h").?);
}

test "parse duration no suffix" {
    try testing.expectEqual(@as(u64, 10_000_000_000), parseDuration("10").?);
}

test "parse duration invalid" {
    try testing.expectEqual(@as(?u64, null), parseDuration("abc"));
    try testing.expectEqual(@as(?u64, null), parseDuration(""));
    try testing.expectEqual(@as(?u64, null), parseDuration("10x"));
}

test "format duration auto-ranging" {
    var buf: [64]u8 = undefined;

    // Microseconds (< 1ms).
    try testing.expectEqualStrings("500.00us", formatDuration(500_000, &buf));

    // Milliseconds (< 1s).
    try testing.expectEqualStrings("15.30ms", formatDuration(15_300_000, &buf));

    // Seconds (< 1m).
    try testing.expectEqualStrings("2.10s", formatDuration(2_100_000_000, &buf));

    // Minutes (>= 1m).
    try testing.expectEqualStrings("1.50m", formatDuration(90_000_000_000, &buf));
}

test "parse count with suffixes" {
    try testing.expectEqual(@as(u64, 100_000), parseCount("100k").?);
    try testing.expectEqual(@as(u64, 1_000_000), parseCount("1M").?);
    try testing.expectEqual(@as(u64, 1_000_000_000), parseCount("1G").?);
}

test "parse count plain" {
    try testing.expectEqual(@as(u64, 500), parseCount("500").?);
    try testing.expectEqual(@as(u64, 1000), parseCount("1000").?);
}

test "parse count invalid" {
    try testing.expectEqual(@as(?u64, null), parseCount("abc"));
}

test "format count" {
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("50.00", formatCount(50.0, &buf));
    try testing.expectEqualStrings("1.00k", formatCount(1000.0, &buf));
    try testing.expectEqualStrings("1.10k", formatCount(1100.0, &buf));
    try testing.expectEqualStrings("1.00M", formatCount(1_000_000.0, &buf));
}

test "format bytes" {
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("512.00B", formatBytes(512, &buf));
    try testing.expectEqualStrings("119.47KB", formatBytes(122_340, &buf));
    try testing.expectEqualStrings("3.50MB", formatBytes(3_670_016, &buf));
    try testing.expectEqualStrings("1.00GB", formatBytes(1_073_741_824, &buf));
}

test "round-trip duration" {
    // Parse "10s" -> 10_000_000_000 ns -> format -> "10.00s" -> parse back.
    const original_ns = parseDuration("10s").?;
    try testing.expectEqual(@as(u64, 10_000_000_000), original_ns);

    var buf: [64]u8 = undefined;
    const formatted = formatDuration(original_ns, &buf);
    try testing.expectEqualStrings("10.00s", formatted);

    const round_tripped = parseDuration(formatted).?;
    // Allow small rounding tolerance (within 1 microsecond).
    const diff = if (round_tripped > original_ns) round_tripped - original_ns else original_ns - round_tripped;
    try testing.expect(diff < std.time.ns_per_us);
}
