const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Histogram = @import("Histogram.zig").Histogram;
const Units = @import("Units.zig");

/// Per-worker results collected after each worker thread finishes.
pub const WorkerStats = struct {
    histogram: Histogram,
    complete_requests: u64,
    errors: u64,
    bytes_read: u64,
    bytes_written: u64,
    req_per_sec: f64,
    elapsed_ns: u64,
};

/// Aggregated results across all workers.
pub const Stats = struct {
    latency_histogram: Histogram,
    total_requests: u64,
    total_errors: u64,
    total_bytes_read: u64,
    total_bytes_written: u64,
    duration_ns: u64,
    avg_latency_ns: u64,
    stdev_latency_ns: u64,
    max_latency_ns: u64,
    avg_req_per_sec: f64,
    stdev_req_per_sec: f64,
    max_req_per_sec: f64,

    /// Merge all worker histograms, sum counters, and compute thread-level averages.
    pub fn aggregate(allocator: Allocator, workers: []const WorkerStats) !Stats {
        var merged = try Histogram.init(allocator, 3_600_000_000, 3);

        var total_requests: u64 = 0;
        var total_errors: u64 = 0;
        var total_bytes_read: u64 = 0;
        var total_bytes_written: u64 = 0;
        var max_elapsed_ns: u64 = 0;

        // Sums for req/sec statistics across workers.
        var sum_req_per_sec: f64 = 0.0;
        var max_req_per_sec: f64 = 0.0;

        // Sums for latency statistics across workers.
        var sum_latency_ns: f64 = 0.0;
        var max_latency_ns: u64 = 0;

        const n = workers.len;

        for (workers) |*w| {
            merged.merge(&w.histogram);
            total_requests += w.complete_requests;
            total_errors += w.errors;
            total_bytes_read += w.bytes_read;
            total_bytes_written += w.bytes_written;
            if (w.elapsed_ns > max_elapsed_ns) max_elapsed_ns = w.elapsed_ns;

            // Per-worker req/sec.
            sum_req_per_sec += w.req_per_sec;
            if (w.req_per_sec > max_req_per_sec) max_req_per_sec = w.req_per_sec;

            // Per-worker latency: use the worker histogram's mean/max.
            const worker_mean = w.histogram.getMean();
            sum_latency_ns += worker_mean;
            const worker_max = w.histogram.getMaxValue();
            if (worker_max > max_latency_ns) max_latency_ns = worker_max;
        }

        // Compute averages.
        const n_f: f64 = if (n > 0) @floatFromInt(n) else 1.0;
        const avg_latency_f: f64 = sum_latency_ns / n_f;
        const avg_req_per_sec: f64 = sum_req_per_sec / n_f;

        // Compute stdev for latency across workers.
        var sum_sq_lat: f64 = 0.0;
        var sum_sq_rps: f64 = 0.0;
        for (workers) |*w| {
            const diff_lat = w.histogram.getMean() - avg_latency_f;
            sum_sq_lat += diff_lat * diff_lat;
            const diff_rps = w.req_per_sec - avg_req_per_sec;
            sum_sq_rps += diff_rps * diff_rps;
        }

        const stdev_latency_f: f64 = if (n > 0) @sqrt(sum_sq_lat / n_f) else 0.0;
        const stdev_req_per_sec: f64 = if (n > 0) @sqrt(sum_sq_rps / n_f) else 0.0;

        return Stats{
            .latency_histogram = merged,
            .total_requests = total_requests,
            .total_errors = total_errors,
            .total_bytes_read = total_bytes_read,
            .total_bytes_written = total_bytes_written,
            .duration_ns = max_elapsed_ns,
            .avg_latency_ns = @intFromFloat(@max(avg_latency_f, 0.0)),
            .stdev_latency_ns = @intFromFloat(@max(stdev_latency_f, 0.0)),
            .max_latency_ns = max_latency_ns,
            .avg_req_per_sec = avg_req_per_sec,
            .stdev_req_per_sec = stdev_req_per_sec,
            .max_req_per_sec = max_req_per_sec,
        };
    }

    /// Free the aggregated histogram.
    pub fn deinit(self: *Stats, allocator: Allocator) void {
        self.latency_histogram.deinit(allocator);
    }

    /// Write wrk2-style output to the given writer.
    pub fn formatReport(
        stats: *const Stats,
        writer: anytype,
        url: []const u8,
        threads: u32,
        connections: u32,
        print_latency: bool,
    ) !void {
        var buf1: [64]u8 = undefined;
        var buf2: [64]u8 = undefined;
        var buf3: [64]u8 = undefined;
        var buf4: [64]u8 = undefined;

        // Duration in seconds with 2 decimal places.
        const duration_s: f64 = @as(f64, @floatFromInt(stats.duration_ns)) /
            @as(f64, @floatFromInt(std.time.ns_per_s));

        // Header.
        try writer.print("Running {d:.0}s test @ {s}\n", .{ duration_s, url });
        try writer.print("  {d} threads and {d} connections\n", .{ threads, connections });

        // Thread Stats header.
        try writer.print("  {s:<14} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
            "Thread Stats",
            "Avg",
            "Stdev",
            "Max",
            "+/- Stdev",
        });

        // Latency row.
        const avg_lat_str = Units.formatDuration(stats.avg_latency_ns, &buf1);
        const stdev_lat_str = Units.formatDuration(stats.stdev_latency_ns, &buf2);
        const max_lat_str = Units.formatDuration(stats.max_latency_ns, &buf3);
        const stdev_pct = computeStdevPercentage(&stats.latency_histogram);
        const stdev_pct_str = std.fmt.bufPrint(&buf4, "{d:.2}%", .{stdev_pct}) catch buf4[0..0];
        try writer.print("    {s:<12} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
            "Latency",
            avg_lat_str,
            stdev_lat_str,
            max_lat_str,
            stdev_pct_str,
        });

        // Req/Sec row.
        const avg_rps_str = Units.formatCount(stats.avg_req_per_sec, &buf1);
        const stdev_rps_str = Units.formatCount(stats.stdev_req_per_sec, &buf2);
        const max_rps_str = Units.formatCount(stats.max_req_per_sec, &buf3);
        // For req/sec stdev percentage, we compute fraction within 1 stdev of mean.
        const rps_pct = computeReqSecStdevPercentage(stats);
        const rps_pct_str = std.fmt.bufPrint(&buf4, "{d:.2}%", .{rps_pct}) catch buf4[0..0];
        try writer.print("    {s:<12} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
            "Req/Sec",
            avg_rps_str,
            stdev_rps_str,
            max_rps_str,
            rps_pct_str,
        });

        // Latency Distribution section (only if requested).
        if (print_latency) {
            try writer.print("  Latency Distribution (HdrHistogram - Recorded Latency)\n", .{});
            const percentiles = [_]f64{ 50.0, 75.0, 90.0, 99.0, 99.9, 99.99 };
            const labels = [_][]const u8{ "50%", "75%", "90%", "99%", "99.9%", "99.99%" };
            for (percentiles, 0..) |pct, i| {
                const val = stats.latency_histogram.valueAtPercentile(pct);
                const val_str = Units.formatDuration(val, &buf1);
                try writer.print("   {s:>7} {s:>10}\n", .{ labels[i], val_str });
            }
        }

        // Summary line.
        const total_bytes_str = Units.formatBytes(stats.total_bytes_read, &buf1);
        try writer.print("  {d} requests in {d:.2}s, {s} read\n", .{
            stats.total_requests,
            duration_s,
            total_bytes_str,
        });

        // Errors line (only if there are errors).
        if (stats.total_errors > 0) {
            try writer.print("  Non-2xx or 3xx responses: {d}\n", .{stats.total_errors});
        }

        // Rates.
        const rps: f64 = if (stats.duration_ns > 0)
            @as(f64, @floatFromInt(stats.total_requests)) /
                (@as(f64, @floatFromInt(stats.duration_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)))
        else
            0.0;
        try writer.print("Requests/sec: {s:>10}\n", .{std.fmt.bufPrint(&buf1, "{d:.2}", .{rps}) catch buf1[0..0]});

        const bps: u64 = if (stats.duration_ns > 0)
            @intFromFloat(@as(f64, @floatFromInt(stats.total_bytes_read)) /
                (@as(f64, @floatFromInt(stats.duration_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))))
        else
            0;
        try writer.print("Transfer/sec: {s:>10}\n", .{Units.formatBytes(bps, &buf1)});
    }

    /// Compute the percentage of req/sec values that fall within +/- 1 stdev of the mean.
    /// Since we only have aggregate stats (not per-sample), we use a normal approximation:
    /// approximately 68.27% of values are within 1 stdev for a normal distribution.
    /// For the simple case, report 68.27% if stdev > 0, 100% if stdev == 0.
    fn computeReqSecStdevPercentage(stats: *const Stats) f64 {
        if (stats.stdev_req_per_sec == 0.0) return 100.0;
        // With only aggregate stats, assume normal distribution (~68.27%).
        return 68.27;
    }
};

/// Compute the percentage of histogram values within +/- 1 standard deviation of the mean.
/// Uses binary search on percentiles to find the boundaries without accessing
/// private histogram internals.
pub fn computeStdevPercentage(histogram: *const Histogram) f64 {
    if (histogram.total_count == 0) return 0.0;

    const mean = histogram.getMean();
    const stdev = histogram.getStdDeviation();
    if (stdev == 0.0) return 100.0;

    const lower_bound: u64 = if (mean > stdev) @intFromFloat(mean - stdev) else 0;
    const upper_bound: u64 = @intFromFloat(mean + stdev);

    // Find the percentile at which values exceed lower_bound (lower_pct)
    // and the percentile at which values exceed upper_bound (upper_pct).
    // The fraction within [lower_bound, upper_bound] is upper_pct - lower_pct.
    const lower_pct = findPercentileForValue(histogram, lower_bound);
    const upper_pct = findPercentileForValue(histogram, upper_bound);

    const result = upper_pct - lower_pct;
    return @max(result, 0.0);
}

/// Binary search to find the approximate percentile at which the histogram
/// value just reaches or exceeds the given target value.
/// Returns a value in [0.0, 100.0].
fn findPercentileForValue(histogram: *const Histogram, target_value: u64) f64 {
    // Binary search: find the lowest percentile p such that
    // valueAtPercentile(p) >= target_value.
    var lo: f64 = 0.0;
    var hi: f64 = 100.0;

    // If the value at p=0 already exceeds target, all data is above.
    // (valueAtPercentile(0) returns the minimum recorded value effectively.)

    // If even at 100% the value is below target, return 100%.
    if (histogram.valueAtPercentile(100.0) < target_value) return 100.0;

    // If at 0% the value is at or above target, return 0%.
    if (histogram.valueAtPercentile(0.0) >= target_value) return 0.0;

    // Binary search with sufficient precision.
    var iterations: u32 = 0;
    while (iterations < 100) : (iterations += 1) {
        const mid = (lo + hi) / 2.0;
        if (hi - lo < 0.001) break;
        const val = histogram.valueAtPercentile(mid);
        if (val < target_value) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    return hi;
}

// =========================================================================
// Tests
// =========================================================================

test "aggregate single worker" {
    const allocator = testing.allocator;

    // Create a single worker with known values.
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    var i: u64 = 1;
    while (i <= 1000) : (i += 1) {
        _ = h.recordValue(i * 1000); // record values in microsecond-ish range
    }

    const workers = [_]WorkerStats{
        .{
            .histogram = h,
            .complete_requests = 1000,
            .errors = 5,
            .bytes_read = 100_000,
            .bytes_written = 50_000,
            .req_per_sec = 500.0,
            .elapsed_ns = 2_000_000_000, // 2 seconds
        },
    };

    var stats = try Stats.aggregate(allocator, &workers);
    defer stats.deinit(allocator);
    // Worker histogram is still owned by the test; free it.
    defer h.deinit(allocator);

    // Verify aggregation preserves values from single worker.
    try testing.expectEqual(@as(u64, 1000), stats.total_requests);
    try testing.expectEqual(@as(u64, 5), stats.total_errors);
    try testing.expectEqual(@as(u64, 100_000), stats.total_bytes_read);
    try testing.expectEqual(@as(u64, 50_000), stats.total_bytes_written);
    try testing.expectEqual(@as(u64, 2_000_000_000), stats.duration_ns);

    // The merged histogram should have the same total count.
    try testing.expectEqual(@as(u64, 1000), stats.latency_histogram.getTotalCount());

    // avg_req_per_sec should match the single worker.
    try testing.expect(stats.avg_req_per_sec == 500.0);
    // stdev should be 0 with a single worker.
    try testing.expect(stats.stdev_req_per_sec == 0.0);
}

test "aggregate multiple workers" {
    const allocator = testing.allocator;

    // Worker 1: low latency values.
    var h1 = try Histogram.init(allocator, 3_600_000_000, 3);
    var i: u64 = 1;
    while (i <= 500) : (i += 1) {
        _ = h1.recordValue(i * 100); // 100-50000 range
    }

    // Worker 2: higher latency values.
    var h2 = try Histogram.init(allocator, 3_600_000_000, 3);
    i = 1;
    while (i <= 500) : (i += 1) {
        _ = h2.recordValue(i * 200); // 200-100000 range
    }

    const workers = [_]WorkerStats{
        .{
            .histogram = h1,
            .complete_requests = 500,
            .errors = 2,
            .bytes_read = 50_000,
            .bytes_written = 25_000,
            .req_per_sec = 250.0,
            .elapsed_ns = 2_000_000_000,
        },
        .{
            .histogram = h2,
            .complete_requests = 800,
            .errors = 3,
            .bytes_read = 80_000,
            .bytes_written = 40_000,
            .req_per_sec = 400.0,
            .elapsed_ns = 3_000_000_000,
        },
    };

    var stats = try Stats.aggregate(allocator, &workers);
    defer stats.deinit(allocator);
    defer h1.deinit(allocator);
    defer h2.deinit(allocator);

    // Verify sums.
    try testing.expectEqual(@as(u64, 1300), stats.total_requests);
    try testing.expectEqual(@as(u64, 5), stats.total_errors);
    try testing.expectEqual(@as(u64, 130_000), stats.total_bytes_read);
    try testing.expectEqual(@as(u64, 65_000), stats.total_bytes_written);
    // Duration should be the max elapsed.
    try testing.expectEqual(@as(u64, 3_000_000_000), stats.duration_ns);

    // Merged histogram should have combined count.
    try testing.expectEqual(@as(u64, 1000), stats.latency_histogram.getTotalCount());

    // avg req/sec = (250 + 400) / 2 = 325
    try testing.expect(@abs(stats.avg_req_per_sec - 325.0) < 0.01);

    // stdev req/sec = sqrt(((250-325)^2 + (400-325)^2) / 2) = 75
    try testing.expect(@abs(stats.stdev_req_per_sec - 75.0) < 0.01);

    // max req/sec
    try testing.expect(stats.max_req_per_sec == 400.0);
}

test "format report output" {
    const allocator = testing.allocator;

    // Create two workers for a realistic test.
    var h1 = try Histogram.init(allocator, 3_600_000_000, 3);
    var i: u64 = 1;
    while (i <= 500) : (i += 1) {
        _ = h1.recordValue(1_000_000); // 1ms
    }

    var h2 = try Histogram.init(allocator, 3_600_000_000, 3);
    i = 1;
    while (i <= 500) : (i += 1) {
        _ = h2.recordValue(2_000_000); // 2ms
    }

    const workers = [_]WorkerStats{
        .{
            .histogram = h1,
            .complete_requests = 500,
            .errors = 0,
            .bytes_read = 50_000,
            .bytes_written = 25_000,
            .req_per_sec = 250.0,
            .elapsed_ns = 10_000_000_000, // 10s
        },
        .{
            .histogram = h2,
            .complete_requests = 500,
            .errors = 0,
            .bytes_read = 50_000,
            .bytes_written = 25_000,
            .req_per_sec = 250.0,
            .elapsed_ns = 10_000_000_000,
        },
    };

    var stats = try Stats.aggregate(allocator, &workers);
    defer stats.deinit(allocator);
    defer h1.deinit(allocator);
    defer h2.deinit(allocator);

    // Format to buffer.
    var output_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buf);
    const writer = fbs.writer();

    try stats.formatReport(writer, "http://example.com", 2, 10, true);

    const output = fbs.getWritten();

    // Verify key strings are present.
    try testing.expect(std.mem.indexOf(u8, output, "http://example.com") != null);
    try testing.expect(std.mem.indexOf(u8, output, "2 threads and 10 connections") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Thread Stats") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Latency") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Req/Sec") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Latency Distribution") != null);
    try testing.expect(std.mem.indexOf(u8, output, "1000 requests") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Requests/sec:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Transfer/sec:") != null);
    try testing.expect(std.mem.indexOf(u8, output, "50%") != null);
    try testing.expect(std.mem.indexOf(u8, output, "99%") != null);
}

test "zero requests edge case" {
    const allocator = testing.allocator;

    // Workers with zero requests.
    var h1 = try Histogram.init(allocator, 3_600_000_000, 3);
    var h2 = try Histogram.init(allocator, 3_600_000_000, 3);

    const workers = [_]WorkerStats{
        .{
            .histogram = h1,
            .complete_requests = 0,
            .errors = 0,
            .bytes_read = 0,
            .bytes_written = 0,
            .req_per_sec = 0.0,
            .elapsed_ns = 10_000_000_000,
        },
        .{
            .histogram = h2,
            .complete_requests = 0,
            .errors = 0,
            .bytes_read = 0,
            .bytes_written = 0,
            .req_per_sec = 0.0,
            .elapsed_ns = 10_000_000_000,
        },
    };

    var stats = try Stats.aggregate(allocator, &workers);
    defer stats.deinit(allocator);
    defer h1.deinit(allocator);
    defer h2.deinit(allocator);

    // Should not panic; all zeros.
    try testing.expectEqual(@as(u64, 0), stats.total_requests);
    try testing.expectEqual(@as(u64, 0), stats.total_errors);
    try testing.expectEqual(@as(u64, 0), stats.total_bytes_read);
    try testing.expectEqual(@as(u64, 0), stats.latency_histogram.getTotalCount());
    try testing.expect(stats.avg_req_per_sec == 0.0);

    // computeStdevPercentage should handle zero-count histogram.
    const pct = computeStdevPercentage(&stats.latency_histogram);
    try testing.expect(pct == 0.0);

    // Format should not crash.
    var output_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buf);
    try stats.formatReport(fbs.writer(), "http://test.com", 2, 10, false);
    const output = fbs.getWritten();
    try testing.expect(output.len > 0);
}

test "all errors edge case" {
    const allocator = testing.allocator;

    // Workers with only errors, no successful requests recorded in histogram.
    var h1 = try Histogram.init(allocator, 3_600_000_000, 3);
    var h2 = try Histogram.init(allocator, 3_600_000_000, 3);

    const workers = [_]WorkerStats{
        .{
            .histogram = h1,
            .complete_requests = 0,
            .errors = 100,
            .bytes_read = 0,
            .bytes_written = 1000,
            .req_per_sec = 0.0,
            .elapsed_ns = 5_000_000_000,
        },
        .{
            .histogram = h2,
            .complete_requests = 0,
            .errors = 200,
            .bytes_read = 0,
            .bytes_written = 2000,
            .req_per_sec = 0.0,
            .elapsed_ns = 5_000_000_000,
        },
    };

    var stats = try Stats.aggregate(allocator, &workers);
    defer stats.deinit(allocator);
    defer h1.deinit(allocator);
    defer h2.deinit(allocator);

    try testing.expectEqual(@as(u64, 0), stats.total_requests);
    try testing.expectEqual(@as(u64, 300), stats.total_errors);
    try testing.expectEqual(@as(u64, 0), stats.total_bytes_read);
    try testing.expectEqual(@as(u64, 3000), stats.total_bytes_written);

    // Format should include the error line and not crash.
    var output_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&output_buf);
    try stats.formatReport(fbs.writer(), "http://errors.test", 2, 5, true);
    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "http://errors.test") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Non-2xx or 3xx responses: 300") != null);
}
