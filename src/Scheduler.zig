const std = @import("std");
const testing = std.testing;

// ============================================================================
// Scheduler — constant-throughput request pacer
// ============================================================================

/// Controls when a single connection should send its next request in order to
/// maintain a constant aggregate throughput across all threads and connections.
/// Each connection gets its own Scheduler instance.  The design deliberately
/// decouples *scheduled* send times from *actual* send times so that slow
/// responses do not suppress future requests — this is what solves the
/// coordinated omission problem.
pub const Scheduler = struct {
    interval_ns: u64, // nanoseconds between requests for this connection
    thread_start_ns: u64, // when the thread started (monotonic clock)
    offset_ns: u64, // stagger offset for this connection
    scheduled_count: u64, // how many requests have been scheduled so far

    /// Create a new Scheduler for a single connection.
    ///
    /// * `rate`                   — total target requests/sec across *all* threads
    /// * `threads`                — number of worker threads
    /// * `connections_per_thread` — connections each thread manages
    /// * `connection_index`       — index of this connection within its thread (0-based)
    /// * `thread_start_ns`        — monotonic timestamp of the owning thread's start
    pub fn init(
        rate: u64,
        threads: u32,
        connections_per_thread: u32,
        connection_index: u32,
        thread_start_ns: u64,
    ) Scheduler {
        const total_connections: u64 = @as(u64, threads) * @as(u64, connections_per_thread);

        // Requests per second assigned to this single connection.
        var rate_per_connection: u64 = rate / total_connections;
        if (rate_per_connection == 0) rate_per_connection = 1; // minimum 1 req/s

        const interval_ns: u64 = 1_000_000_000 / rate_per_connection;

        // Stagger: spread connections within a thread evenly across one
        // connection-level interval so their requests don't bunch up.
        const offset_ns: u64 = @as(u64, connection_index) * (interval_ns / @as(u64, connections_per_thread));

        return Scheduler{
            .interval_ns = interval_ns,
            .thread_start_ns = thread_start_ns,
            .offset_ns = offset_ns,
            .scheduled_count = 0,
        };
    }

    /// Returns the monotonic timestamp at which the next request should be sent.
    pub fn nextSendTime(self: *const Scheduler) u64 {
        return self.thread_start_ns + self.offset_ns + self.scheduled_count * self.interval_ns;
    }

    /// Advance the scheduler after a request has been sent (or accounted for).
    pub fn advance(self: *Scheduler) void {
        self.scheduled_count += 1;
    }

    /// Returns the expected interval between requests.  This is used by the
    /// coordinated-omission correction logic in the histogram recorder.
    pub fn expectedInterval(self: *const Scheduler) u64 {
        return self.interval_ns;
    }

    /// Reset the scheduler — typically called after a reconnection so the
    /// connection resumes pacing from the new baseline without a burst of
    /// catch-up requests.
    pub fn reset(self: *Scheduler, new_start_ns: u64) void {
        self.thread_start_ns = new_start_ns;
        self.scheduled_count = 0;
    }

    /// Skip past any scheduled send times before `now_ns`. Returns the
    /// number of slots skipped. Used to prevent catch-up bursts after a
    /// stall — the corrected histogram already accounts for missed slots
    /// via backfilling.
    pub fn skipPast(self: *Scheduler, now_ns: u64) u64 {
        const next = self.nextSendTime();
        if (next >= now_ns) return 0;

        const behind = now_ns - next;
        const skip = behind / self.interval_ns;
        self.scheduled_count += skip;
        return skip;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "correct interval at 100 req/s" {
    // 100 req/s, 2 threads, 5 connections/thread → 10 connections total
    // rate_per_connection = 100 / 10 = 10 req/s → interval = 100 ms
    const s = Scheduler.init(100, 2, 5, 0, 0);
    try testing.expectEqual(@as(u64, 100_000_000), s.interval_ns);
}

test "correct interval at 1000 req/s" {
    // 1000 req/s, 2 threads, 5 connections/thread → 10 connections total
    // rate_per_connection = 1000 / 10 = 100 req/s → interval = 10 ms
    const s = Scheduler.init(1000, 2, 5, 0, 0);
    try testing.expectEqual(@as(u64, 10_000_000), s.interval_ns);
}

test "nextSendTime advances linearly" {
    var s = Scheduler.init(100, 2, 5, 0, 1_000_000);
    const interval = s.interval_ns; // 100 ms

    for (0..10) |i| {
        const expected: u64 = 1_000_000 + 0 + i * interval;
        try testing.expectEqual(expected, s.nextSendTime());
        s.advance();
    }
}

test "staggering across connections" {
    const thread_start: u64 = 5_000_000_000;
    const rate: u64 = 100; // 100 req/s total
    const threads: u32 = 2;
    const conns: u32 = 5;

    // interval_ns for each connection = 100_000_000 (100 ms)
    // stagger step = interval_ns / connections_per_thread = 100_000_000 / 5 = 20_000_000

    var first_times: [5]u64 = undefined;
    for (0..5) |i| {
        const s = Scheduler.init(rate, threads, conns, @intCast(i), thread_start);
        first_times[i] = s.nextSendTime();
    }

    // Each connection's first send time should be stagger_step apart.
    const stagger_step: u64 = 100_000_000 / 5; // 20 ms
    for (0..5) |i| {
        const expected: u64 = thread_start + i * stagger_step;
        try testing.expectEqual(expected, first_times[i]);
    }
}

test "expectedInterval matches config" {
    const s = Scheduler.init(500, 1, 5, 2, 0);
    // rate_per_connection = 500 / (1*5) = 100 → interval = 10 ms
    try testing.expectEqual(@as(u64, 10_000_000), s.expectedInterval());
    try testing.expectEqual(s.interval_ns, s.expectedInterval());
}

test "high rate 1M/s" {
    // 1_000_000 req/s, 4 threads, 25 connections/thread → 100 connections
    // rate_per_connection = 10_000 → interval = 100_000 ns (100 us)
    const s = Scheduler.init(1_000_000, 4, 25, 0, 0);
    try testing.expectEqual(@as(u64, 100_000), s.interval_ns);

    // Verify no overflow in nextSendTime even after many requests.
    var s2 = Scheduler.init(1_000_000, 4, 25, 0, 0);
    s2.scheduled_count = 1_000_000;
    const t = s2.nextSendTime();
    // 1_000_000 * 100_000 = 100_000_000_000 = 100 seconds — well within u64 range.
    try testing.expectEqual(@as(u64, 100_000_000_000), t);
}

test "low rate 1/s" {
    // 1 req/s, 1 thread, 1 connection → rate_per_connection = 1
    // interval = 1_000_000_000 (1 second)
    const s = Scheduler.init(1, 1, 1, 0, 0);
    try testing.expectEqual(@as(u64, 1_000_000_000), s.interval_ns);
}

test "reset" {
    var s = Scheduler.init(100, 2, 5, 0, 0);

    // Advance several times.
    for (0..5) |_| {
        s.advance();
    }
    try testing.expectEqual(@as(u64, 5), s.scheduled_count);

    // After reset, scheduled_count should be back to zero and start_ns updated.
    const new_start: u64 = 9_000_000_000;
    s.reset(new_start);
    try testing.expectEqual(@as(u64, 0), s.scheduled_count);
    try testing.expectEqual(new_start, s.thread_start_ns);

    // nextSendTime should reflect the new baseline.
    try testing.expectEqual(new_start + s.offset_ns, s.nextSendTime());
}

test "skipPast when on time" {
    var s = Scheduler.init(100, 2, 5, 0, 1_000_000_000);
    const before = s.scheduled_count;
    const skipped = s.skipPast(s.nextSendTime());
    try testing.expectEqual(@as(u64, 0), skipped);
    try testing.expectEqual(before, s.scheduled_count);
}

test "skipPast when behind by several intervals" {
    // 100 req/s, 2 threads, 5 conns → interval = 100ms
    var s = Scheduler.init(100, 2, 5, 0, 0);
    const interval = s.interval_ns; // 100_000_000

    // Simulate being 550ms behind (5.5 intervals)
    const now_ns: u64 = 550_000_000;
    const skipped = s.skipPast(now_ns);
    try testing.expectEqual(@as(u64, 5), skipped);
    try testing.expectEqual(@as(u64, 5), s.scheduled_count);

    // nextSendTime should now be within one interval of now_ns
    const next = s.nextSendTime();
    try testing.expect(next <= now_ns);
    try testing.expect(next + interval > now_ns);
}

test "skipPast when behind by less than one interval" {
    var s = Scheduler.init(100, 2, 5, 0, 0);
    // 50ms behind with 100ms interval — less than one full interval
    const skipped = s.skipPast(50_000_000);
    try testing.expectEqual(@as(u64, 0), skipped);
    try testing.expectEqual(@as(u64, 0), s.scheduled_count);
}

test "skipPast when nextSendTime is in the future" {
    var s = Scheduler.init(100, 2, 5, 0, 1_000_000_000);
    // now_ns is before thread_start_ns, so nextSendTime is in the future
    const skipped = s.skipPast(500_000_000);
    try testing.expectEqual(@as(u64, 0), skipped);
    try testing.expectEqual(@as(u64, 0), s.scheduled_count);
}
