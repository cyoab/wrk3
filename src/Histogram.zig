const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A pure-Zig implementation of the HdrHistogram data structure for recording
/// and analyzing sampled data value counts across a configurable range with
/// configurable value precision. Uses logarithmic bucketing with linear
/// sub-buckets within each bucket to achieve constant-space O(1) recording
/// with bounded error determined by the number of significant figures.
pub const Histogram = struct {
    counts: []u64,
    total_count: u64,
    min_value: u64,
    max_value: u64,
    total_value: u128,

    // HdrHistogram structural parameters
    lowest_discernible_value: u64,
    highest_trackable_value: u64,
    significant_figures: u8,
    sub_bucket_half_count_magnitude: u8,
    sub_bucket_count: u32,
    sub_bucket_half_count: u32,
    sub_bucket_mask: u64,
    unit_magnitude: u8,
    bucket_count: u32,
    counts_len: u32,

    /// Allocate and initialize a histogram that can record values in the range
    /// [0 .. highest_trackable_value] with `significant_figures` digits of
    /// precision (1..5). The lowest discernible value is fixed at 1.
    pub fn init(allocator: Allocator, highest_trackable_value: u64, significant_figures: u8) !Histogram {
        std.debug.assert(significant_figures >= 1 and significant_figures <= 5);
        std.debug.assert(highest_trackable_value >= 2);

        const lowest_discernible_value: u64 = 1;

        // Determine sub_bucket_count from significant_figures.
        // We need enough sub-buckets so the resolution at every magnitude
        // is at least 1 part in 10^significant_figures.
        // largest_value_with_single_unit_resolution = 2 * 10^sig_figs
        // sub_bucket_count_magnitude = ceil(log2(that value))
        const largest_value_with_single_unit_resolution: u64 = 2 * math.pow(u64, 10, significant_figures);
        const sub_bucket_count_magnitude: u8 = @intCast(@as(
            u32,
            @intFromFloat(@ceil(math.log2(@as(f64, @floatFromInt(largest_value_with_single_unit_resolution))))),
        ));

        const sub_bucket_half_count_magnitude: u8 = if (sub_bucket_count_magnitude > 1)
            sub_bucket_count_magnitude - 1
        else
            0;

        // unit_magnitude = floor(log2(lowest_discernible_value)).
        // For lowest_discernible_value = 1, this is 0.
        const unit_magnitude: u8 = if (lowest_discernible_value > 1)
            @intCast(63 - @as(u32, @clz(lowest_discernible_value)))
        else
            0;

        const sub_bucket_count: u32 = @as(u32, 1) << @intCast(sub_bucket_half_count_magnitude + 1);
        const sub_bucket_half_count: u32 = sub_bucket_count >> 1;
        const sub_bucket_mask: u64 = (@as(u64, sub_bucket_count) - 1) << @intCast(unit_magnitude);

        // Determine the number of buckets needed to cover highest_trackable_value.
        const bucket_count = bucketsNeeded(highest_trackable_value, sub_bucket_count, unit_magnitude);

        // Total counts array length: (bucket_count + 1) * (sub_bucket_count / 2)
        const counts_len: u32 = (bucket_count + 1) * sub_bucket_half_count;

        const counts = try allocator.alloc(u64, counts_len);
        @memset(counts, 0);

        return Histogram{
            .counts = counts,
            .total_count = 0,
            .min_value = math.maxInt(u64),
            .max_value = 0,
            .total_value = 0,
            .lowest_discernible_value = lowest_discernible_value,
            .highest_trackable_value = highest_trackable_value,
            .significant_figures = significant_figures,
            .sub_bucket_half_count_magnitude = sub_bucket_half_count_magnitude,
            .sub_bucket_count = sub_bucket_count,
            .sub_bucket_half_count = sub_bucket_half_count,
            .sub_bucket_mask = sub_bucket_mask,
            .unit_magnitude = unit_magnitude,
            .bucket_count = bucket_count,
            .counts_len = counts_len,
        };
    }

    /// Free the counts array.
    pub fn deinit(self: *Histogram, allocator: Allocator) void {
        allocator.free(self.counts);
    }

    /// Record a single value. Returns false if the value is out of range.
    pub fn recordValue(self: *Histogram, value: u64) bool {
        return self.recordCountAtValue(1, value);
    }

    /// Record a value with coordinated omission correction.
    /// Backfills synthetic samples for values that would have been recorded
    /// if the system had not been stalled during the measured interval.
    pub fn recordCorrectedValue(self: *Histogram, value: u64, expected_interval: u64) void {
        _ = self.recordValue(value);
        if (expected_interval > 0 and value > expected_interval) {
            var missing_value: u64 = value -| expected_interval;
            while (missing_value >= expected_interval) {
                _ = self.recordValue(missing_value);
                if (missing_value < expected_interval) break;
                missing_value -|= expected_interval;
            }
        }
    }

    /// Return the value at a given percentile (0.0 to 100.0).
    pub fn valueAtPercentile(self: *const Histogram, percentile: f64) u64 {
        if (self.total_count == 0) return 0;

        const requested_percentile = @min(percentile, 100.0);
        var count_at_percentile: u64 = @intFromFloat(
            @ceil(requested_percentile / 100.0 * @as(f64, @floatFromInt(self.total_count))),
        );
        count_at_percentile = @max(count_at_percentile, 1);

        var total: u64 = 0;
        var bucket_idx: u32 = 0;
        while (bucket_idx < self.bucket_count) : (bucket_idx += 1) {
            const start_sub: u32 = if (bucket_idx == 0) 0 else self.sub_bucket_half_count;
            var sub_idx: u32 = start_sub;
            while (sub_idx < self.sub_bucket_count) : (sub_idx += 1) {
                const idx = self.countsIndex(bucket_idx, sub_idx);
                total += self.counts[idx];
                if (total >= count_at_percentile) {
                    const value_from_idx = self.valueFromIndex(bucket_idx, sub_idx);
                    return self.highestEquivalentValue(value_from_idx);
                }
            }
        }
        return 0;
    }

    /// Merge another histogram into this one by adding all of the other
    /// histogram's recorded values.
    pub fn merge(self: *Histogram, other: *const Histogram) void {
        var bucket_idx: u32 = 0;
        while (bucket_idx < other.bucket_count) : (bucket_idx += 1) {
            const start_sub: u32 = if (bucket_idx == 0) 0 else other.sub_bucket_half_count;
            var sub_idx: u32 = start_sub;
            while (sub_idx < other.sub_bucket_count) : (sub_idx += 1) {
                const idx = other.countsIndex(bucket_idx, sub_idx);
                const count = other.counts[idx];
                if (count > 0) {
                    const value = other.valueFromIndex(bucket_idx, sub_idx);
                    _ = self.recordCountAtValue(count, value);
                }
            }
        }
    }

    /// Return the mean of all recorded values.
    pub fn getMean(self: *const Histogram) f64 {
        if (self.total_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_value)) / @as(f64, @floatFromInt(self.total_count));
    }

    /// Return the standard deviation of all recorded values.
    pub fn getStdDeviation(self: *const Histogram) f64 {
        if (self.total_count == 0) return 0.0;
        const mean = self.getMean();
        var geometric_dev_total: f64 = 0.0;

        var bucket_idx: u32 = 0;
        while (bucket_idx < self.bucket_count) : (bucket_idx += 1) {
            const start_sub: u32 = if (bucket_idx == 0) 0 else self.sub_bucket_half_count;
            var sub_idx: u32 = start_sub;
            while (sub_idx < self.sub_bucket_count) : (sub_idx += 1) {
                const idx = self.countsIndex(bucket_idx, sub_idx);
                const count = self.counts[idx];
                if (count > 0) {
                    const value = self.medianEquivalentValue(self.valueFromIndex(bucket_idx, sub_idx));
                    const dev = @as(f64, @floatFromInt(value)) - mean;
                    geometric_dev_total += dev * dev * @as(f64, @floatFromInt(count));
                }
            }
        }

        return @sqrt(geometric_dev_total / @as(f64, @floatFromInt(self.total_count)));
    }

    /// Return total count of all recorded values.
    pub fn getTotalCount(self: *const Histogram) u64 {
        return self.total_count;
    }

    /// Return the maximum recorded value (highest equivalent value of the
    /// largest value that has been recorded).
    pub fn getMaxValue(self: *const Histogram) u64 {
        if (self.max_value == 0 and self.total_count == 0) return 0;
        return self.highestEquivalentValue(self.max_value);
    }

    /// Zero all counts and reset min/max/total tracking values.
    pub fn reset(self: *Histogram) void {
        @memset(self.counts, 0);
        self.total_count = 0;
        self.min_value = math.maxInt(u64);
        self.max_value = 0;
        self.total_value = 0;
    }

    // -- Internal helpers -------------------------------------------------

    fn recordCountAtValue(self: *Histogram, count: u64, value: u64) bool {
        const bucket_idx = self.getBucketIndex(value);
        const sub_bucket_idx = self.getSubBucketIdx(value, bucket_idx);
        const idx = self.countsIndex(bucket_idx, sub_bucket_idx);
        if (idx >= self.counts_len) return false;

        self.counts[idx] += count;
        self.total_count += count;
        self.total_value += @as(u128, value) * @as(u128, count);

        if (value < self.min_value) self.min_value = value;
        if (value > self.max_value) self.max_value = value;

        return true;
    }

    /// Compute the bucket index for a given value using the leading-zero
    /// shortcut from the reference Java HdrHistogram implementation.
    fn getBucketIndex(self: *const Histogram, value: u64) u32 {
        const or_val = value | self.sub_bucket_mask;
        const leading_zeros: u32 = @clz(or_val);
        const leading_zero_count_base: u32 = 64 -
            @as(u32, self.unit_magnitude) -
            (@as(u32, self.sub_bucket_half_count_magnitude) + 1);
        if (leading_zeros >= leading_zero_count_base) return 0;
        return leading_zero_count_base - leading_zeros;
    }

    /// Compute the sub-bucket index for a value within a given bucket.
    fn getSubBucketIdx(self: *const Histogram, value: u64, bucket_idx: u32) u32 {
        const shift: u6 = @intCast(bucket_idx + @as(u32, self.unit_magnitude));
        return @intCast(value >> shift);
    }

    /// Map (bucket, sub_bucket) to a flat index in the counts array.
    fn countsIndex(self: *const Histogram, bucket_idx: u32, sub_bucket_idx: u32) u32 {
        return (bucket_idx + 1) * self.sub_bucket_half_count +
            sub_bucket_idx - self.sub_bucket_half_count;
    }

    /// Recover the value represented by a (bucket, sub_bucket) pair.
    fn valueFromIndex(self: *const Histogram, bucket_idx: u32, sub_bucket_idx: u32) u64 {
        return @as(u64, sub_bucket_idx) << @intCast(bucket_idx + @as(u32, self.unit_magnitude));
    }

    /// The size of the range of values that are equivalent to the given value
    /// (i.e. they map to the same bucket/sub-bucket).
    fn sizeOfEquivalentValueRange(self: *const Histogram, value: u64) u64 {
        const bucket_idx = self.getBucketIndex(value);
        const shift: u6 = @intCast(bucket_idx + @as(u32, self.unit_magnitude));
        return @as(u64, 1) << shift;
    }

    /// The lowest value that is equivalent to the given value.
    fn lowestEquivalentValue(self: *const Histogram, value: u64) u64 {
        const bucket_idx = self.getBucketIndex(value);
        const sub_bucket_idx = self.getSubBucketIdx(value, bucket_idx);
        return self.valueFromIndex(bucket_idx, sub_bucket_idx);
    }

    /// The highest value that is equivalent to the given value.
    fn highestEquivalentValue(self: *const Histogram, value: u64) u64 {
        return self.lowestEquivalentValue(value) +
            self.sizeOfEquivalentValueRange(value) - 1;
    }

    /// The value at the midpoint of the equivalent range for the given value,
    /// used for standard deviation calculation.
    fn medianEquivalentValue(self: *const Histogram, value: u64) u64 {
        return self.lowestEquivalentValue(value) +
            (self.sizeOfEquivalentValueRange(value) >> 1);
    }

    // -- Percentile iteration ---------------------------------------------

    pub const PercentileEntry = struct {
        value: u64,
        count: u64,
        cumulative_count: u64,
        percentile: f64,
    };

    pub const PercentileIterator = struct {
        histogram: *const Histogram,
        bucket_idx: u32,
        sub_idx: u32,
        cumulative_count: u64,
        percentile_to_iterate_to: f64,
        ticks_per_half_distance: f64,
        reached_end: bool,

        pub fn next(self: *PercentileIterator) ?PercentileEntry {
            const h = self.histogram;
            if (h.total_count == 0) return null;
            if (self.reached_end) return null;

            const total_f: f64 = @floatFromInt(h.total_count);

            while (self.bucket_idx < h.bucket_count) {
                const start_sub: u32 = if (self.bucket_idx == 0) 0 else h.sub_bucket_half_count;
                if (self.sub_idx < start_sub) self.sub_idx = start_sub;

                while (self.sub_idx < h.sub_bucket_count) {
                    const idx = h.countsIndex(self.bucket_idx, self.sub_idx);
                    const count = h.counts[idx];
                    self.cumulative_count += count;

                    const value_from_idx = h.valueFromIndex(self.bucket_idx, self.sub_idx);
                    const value = h.highestEquivalentValue(value_from_idx);

                    // Advance sub_idx for next call.
                    self.sub_idx += 1;

                    if (@as(f64, @floatFromInt(self.cumulative_count)) >= self.percentile_to_iterate_to / 100.0 * total_f) {
                        const percentile = @min(self.percentile_to_iterate_to / 100.0, 1.0);
                        // Advance percentile threshold using wrk2's logarithmic stepping.
                        self.advancePercentile();

                        if (self.cumulative_count >= h.total_count) {
                            self.reached_end = true;
                            return PercentileEntry{
                                .value = value,
                                .count = count,
                                .cumulative_count = self.cumulative_count,
                                .percentile = 1.0,
                            };
                        }

                        return PercentileEntry{
                            .value = value,
                            .count = count,
                            .cumulative_count = self.cumulative_count,
                            .percentile = percentile,
                        };
                    }
                }
                self.bucket_idx += 1;
                self.sub_idx = self.histogram.sub_bucket_half_count;
            }

            // If we exhausted all buckets without reaching total_count
            // (shouldn't happen for a well-formed histogram), mark as done.
            if (!self.reached_end and self.cumulative_count > 0) {
                self.reached_end = true;
                return PercentileEntry{
                    .value = h.getMaxValue(),
                    .count = 0,
                    .cumulative_count = self.cumulative_count,
                    .percentile = 1.0,
                };
            }
            return null;
        }

        fn advancePercentile(self: *PercentileIterator) void {
            const pct = self.percentile_to_iterate_to;
            // wrk2's logarithmic stepping for fine tail resolution.
            const remaining = 100.0 - pct;
            if (remaining <= 0.0) return;
            const half_distance = math.pow(f64, 2, @floor(math.log2(100.0 / remaining)) + 1);
            const step = 100.0 / (self.ticks_per_half_distance * half_distance);
            self.percentile_to_iterate_to = @min(pct + step, 100.0);
        }
    };

    pub fn percentileIterator(self: *const Histogram) PercentileIterator {
        return .{
            .histogram = self,
            .bucket_idx = 0,
            .sub_idx = 0,
            .cumulative_count = 0,
            .percentile_to_iterate_to = 0.0,
            .ticks_per_half_distance = 5.0,
            .reached_end = false,
        };
    }

    // -- Static helpers for init ------------------------------------------

    fn bucketsNeeded(highest_trackable_value: u64, sub_bucket_count: u32, unit_mag: u8) u32 {
        var smallest_untrackable: u64 = @as(u64, sub_bucket_count) << @intCast(unit_mag);
        var buckets_needed: u32 = 1;
        while (smallest_untrackable <= highest_trackable_value) {
            if (smallest_untrackable > math.maxInt(u64) / 2) break;
            smallest_untrackable <<= 1;
            buckets_needed += 1;
        }
        return buckets_needed;
    }
};

// =========================================================================
// Tests
// =========================================================================

test "record and retrieve percentiles" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Record values 1 through 10_000
    var i: u64 = 1;
    while (i <= 10_000) : (i += 1) {
        _ = h.recordValue(i);
    }

    // p50 should be around 5000
    const p50 = h.valueAtPercentile(50.0);
    try testing.expect(p50 >= 4900 and p50 <= 5100);

    // p99 should be around 9900
    const p99 = h.valueAtPercentile(99.0);
    try testing.expect(p99 >= 9800 and p99 <= 10_100);

    // p99.9 should be around 9990
    const p999 = h.valueAtPercentile(99.9);
    try testing.expect(p999 >= 9900 and p999 <= 10_100);

    // Total count should be exactly 10_000
    try testing.expectEqual(@as(u64, 10_000), h.getTotalCount());
}

test "coordinated omission correction" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Record a stalled value of 10_000 with expected interval of 1_000.
    // This should record: 10_000, 9_000, 8_000, 7_000, 6_000, 5_000,
    //                      4_000, 3_000, 2_000, 1_000
    // That is 10 values total.
    h.recordCorrectedValue(10_000, 1_000);

    try testing.expectEqual(@as(u64, 10), h.getTotalCount());

    // The median should be around 5000-6000.
    const p50 = h.valueAtPercentile(50.0);
    try testing.expect(p50 >= 4500 and p50 <= 6000);
}

test "merge histograms" {
    const allocator = testing.allocator;
    var h1 = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h1.deinit(allocator);
    var h2 = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h2.deinit(allocator);

    // Record low values in h1
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        _ = h1.recordValue(i);
    }

    // Record high values in h2
    i = 901;
    while (i <= 1000) : (i += 1) {
        _ = h2.recordValue(i);
    }

    // Merge h2 into h1
    h1.merge(&h2);

    try testing.expectEqual(@as(u64, 200), h1.getTotalCount());

    // p50: the 100th value out of 200 total should be near the top of
    // the low group.
    const p50 = h1.valueAtPercentile(50.0);
    try testing.expect(p50 >= 90 and p50 <= 110);

    // p99 should be in the high range
    const p99 = h1.valueAtPercentile(99.0);
    try testing.expect(p99 >= 950 and p99 <= 1050);
}

test "mean and stddev" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Record 1000 copies of value 1000 and 1000 copies of value 2000.
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        _ = h.recordValue(1000);
        _ = h.recordValue(2000);
    }

    // Mean should be ~1500
    const mean = h.getMean();
    try testing.expect(mean > 1400.0 and mean < 1600.0);

    // Stddev: for half at 1000 and half at 2000, theoretical stddev = 500.
    // HdrHistogram bucket widths introduce some error; allow tolerance.
    const stddev = h.getStdDeviation();
    try testing.expect(stddev > 400.0 and stddev < 600.0);
}

test "edge cases" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Zero value
    try testing.expect(h.recordValue(0));
    try testing.expectEqual(@as(u64, 1), h.getTotalCount());

    // Percentile on single zero-value: highest equivalent of 0 is 0
    const p50 = h.valueAtPercentile(50.0);
    try testing.expect(p50 == 0);

    // Max boundary value
    try testing.expect(h.recordValue(3_600_000_000));
    try testing.expectEqual(@as(u64, 2), h.getTotalCount());

    // Value beyond max might or might not fit depending on bucket alignment.
    // We just ensure it does not crash.
    _ = h.recordValue(3_600_000_001);

    // Single value histogram
    var h2 = try Histogram.init(allocator, 100, 3);
    defer h2.deinit(allocator);
    _ = h2.recordValue(42);
    try testing.expectEqual(@as(u64, 1), h2.getTotalCount());
    const val = h2.valueAtPercentile(100.0);
    try testing.expect(val >= 42);
    try testing.expect(h2.getMean() >= 42.0 and h2.getMean() <= 43.0);
}

test "reset" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Record some values
    var i: u64 = 1;
    while (i <= 1000) : (i += 1) {
        _ = h.recordValue(i);
    }

    try testing.expectEqual(@as(u64, 1000), h.getTotalCount());

    // Reset
    h.reset();

    try testing.expectEqual(@as(u64, 0), h.getTotalCount());
    try testing.expectEqual(@as(u64, 0), h.getMaxValue());
    try testing.expectEqual(@as(f64, 0.0), h.getMean());
    try testing.expectEqual(@as(u64, 0), h.valueAtPercentile(50.0));

    // Should be able to record again after reset
    _ = h.recordValue(500);
    try testing.expectEqual(@as(u64, 1), h.getTotalCount());
}

test "percentile iterator basic" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Record values 1 through 10_000
    var i: u64 = 1;
    while (i <= 10_000) : (i += 1) {
        _ = h.recordValue(i);
    }

    var iter = h.percentileIterator();
    var count: usize = 0;
    var prev_percentile: f64 = -1.0;
    var prev_cumulative: u64 = 0;
    var last_percentile: f64 = 0.0;

    while (iter.next()) |entry| {
        // Percentile must be monotonically non-decreasing.
        try testing.expect(entry.percentile >= prev_percentile);
        // Cumulative count must be monotonically non-decreasing.
        try testing.expect(entry.cumulative_count >= prev_cumulative);
        prev_percentile = entry.percentile;
        prev_cumulative = entry.cumulative_count;
        last_percentile = entry.percentile;
        count += 1;
    }

    // Must have produced entries and ended at percentile 1.0.
    try testing.expect(count > 0);
    try testing.expectEqual(@as(f64, 1.0), last_percentile);
}

test "percentile iterator empty histogram" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    var iter = h.percentileIterator();
    try testing.expectEqual(@as(?Histogram.PercentileEntry, null), iter.next());
}

test "percentile iterator single value" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    _ = h.recordValue(42);

    var iter = h.percentileIterator();
    var count: usize = 0;
    var last_percentile: f64 = 0.0;

    while (iter.next()) |entry| {
        last_percentile = entry.percentile;
        count += 1;
    }

    // Should yield at least one entry ending at 1.0.
    try testing.expect(count >= 1);
    try testing.expectEqual(@as(f64, 1.0), last_percentile);
}

test "percentile iterator ordering" {
    const allocator = testing.allocator;
    var h = try Histogram.init(allocator, 3_600_000_000, 3);
    defer h.deinit(allocator);

    // Record a spread of values.
    var i: u64 = 100;
    while (i <= 50_000) : (i += 100) {
        _ = h.recordValue(i);
    }

    var iter = h.percentileIterator();
    var prev_percentile: f64 = -1.0;
    var entry_count: usize = 0;

    while (iter.next()) |entry| {
        if (entry_count > 0) {
            // Each entry's percentile must be > previous (strict increase after first).
            try testing.expect(entry.percentile > prev_percentile);
        }
        prev_percentile = entry.percentile;
        entry_count += 1;
    }

    try testing.expect(entry_count > 1);
}
