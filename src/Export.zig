const std = @import("std");
const math = std.math;
const Histogram = @import("Histogram.zig").Histogram;
const Config = @import("Config.zig").Config;
const testing = std.testing;

/// Export histogram data to a file in the specified format.
pub fn exportHistogram(histogram: *const Histogram, config: Config.ExportConfig) !void {
    const file = try std.fs.cwd().createFile(config.path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;

    switch (config.format) {
        .csv => try writeCsv(histogram, w),
        .json => try writeJson(histogram, w),
    }
    try w.flush();
}

fn writeCsv(histogram: *const Histogram, writer: anytype) !void {
    try writer.writeAll("Value,Percentile,TotalCount,1/(1-Percentile)\n");

    var iter = histogram.percentileIterator();
    while (iter.next()) |entry| {
        const value_ms: f64 = @as(f64, @floatFromInt(entry.value)) / 1_000_000.0;
        try writer.print("{d:.3},{d:.6},{d},", .{
            value_ms,
            entry.percentile,
            entry.cumulative_count,
        });
        if (entry.percentile >= 1.0) {
            try writer.writeAll("inf\n");
        } else {
            try writer.print("{d:.2}\n", .{1.0 / (1.0 - entry.percentile)});
        }
    }
}

fn writeJson(histogram: *const Histogram, writer: anytype) !void {
    const mean = histogram.getMean();
    const max_val = histogram.getMaxValue();
    const stddev = histogram.getStdDeviation();

    try writer.writeAll("{\n  \"metadata\": {\n");
    try writer.print("    \"total_count\": {d},\n", .{histogram.total_count});
    try writer.print("    \"mean_ms\": {d:.3},\n", .{mean / 1_000_000.0});
    try writer.print("    \"max_ms\": {d:.3},\n", .{@as(f64, @floatFromInt(max_val)) / 1_000_000.0});
    try writer.print("    \"stddev_ms\": {d:.3}\n", .{stddev / 1_000_000.0});
    try writer.writeAll("  },\n  \"data\": [\n");

    var iter = histogram.percentileIterator();
    var first = true;
    while (iter.next()) |entry| {
        if (!first) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
        first = false;

        const value_ms: f64 = @as(f64, @floatFromInt(entry.value)) / 1_000_000.0;
        if (entry.percentile >= 1.0) {
            try writer.print("    {{\"value_ms\": {d:.3}, \"percentile\": {d:.6}, \"total_count\": {d}, \"inv_percentile\": null}}", .{
                value_ms,
                entry.percentile,
                entry.cumulative_count,
            });
        } else {
            try writer.print("    {{\"value_ms\": {d:.3}, \"percentile\": {d:.6}, \"total_count\": {d}, \"inv_percentile\": {d:.2}}}", .{
                value_ms,
                entry.percentile,
                entry.cumulative_count,
                1.0 / (1.0 - entry.percentile),
            });
        }
    }

    if (!first) {
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ]\n}\n");
}

// =========================================================================
// Tests
// =========================================================================

test "csv export format" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Record some known values (in nanoseconds).
    _ = h.recordValue(1_000_000); // 1ms
    _ = h.recordValue(5_000_000); // 5ms
    _ = h.recordValue(10_000_000); // 10ms

    var output_buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&output_buf);
    const w = stream.writer();
    try writeCsv(&h, w);

    const output = stream.getWritten();

    // Check header.
    try testing.expect(std.mem.startsWith(u8, output, "Value,Percentile,TotalCount,1/(1-Percentile)\n"));

    // Check it contains data rows.
    const line_count = std.mem.count(u8, output, "\n");
    try testing.expect(line_count > 1);

    // Check last line contains "inf" (percentile 1.0).
    const trimmed = std.mem.trimRight(u8, output, "\n");
    const last_newline = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse 0;
    const last_line = trimmed[last_newline..];
    try testing.expect(std.mem.indexOf(u8, last_line, "inf") != null);
}

test "json export format" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    _ = h.recordValue(1_000_000);
    _ = h.recordValue(5_000_000);
    _ = h.recordValue(10_000_000);

    var output_buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&output_buf);
    const w = stream.writer();
    try writeJson(&h, w);

    const output = stream.getWritten();

    // Verify basic JSON structure.
    try testing.expect(std.mem.indexOf(u8, output, "\"metadata\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"total_count\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"mean_ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"max_ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"stddev_ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"data\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"value_ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"percentile\"") != null);
}

test "empty histogram export" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // CSV: should produce only header.
    {
        var output_buf: [16384]u8 = undefined;
        var stream = std.io.fixedBufferStream(&output_buf);
        const w = stream.writer();
        try writeCsv(&h, w);

        const output = stream.getWritten();
        try testing.expectEqualStrings("Value,Percentile,TotalCount,1/(1-Percentile)\n", output);
    }

    // JSON: should produce valid structure with empty data array.
    {
        var output_buf: [16384]u8 = undefined;
        var stream = std.io.fixedBufferStream(&output_buf);
        const w = stream.writer();
        try writeJson(&h, w);

        const output = stream.getWritten();
        try testing.expect(std.mem.indexOf(u8, output, "\"data\": [\n  ]") != null);
        try testing.expect(std.mem.indexOf(u8, output, "\"total_count\": 0") != null);
    }
}
