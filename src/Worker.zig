const std = @import("std");
const posix = std.posix;

const EventLoop = @import("EventLoop.zig").EventLoop;
const Connection = @import("Connection.zig").Connection;
const Histogram = @import("Histogram.zig").Histogram;
const Scheduler = @import("Scheduler.zig").Scheduler;
const Stats = @import("Stats.zig");
const Config = @import("Config.zig").Config;

pub const Worker = struct {
    // Configuration (from Config)
    host: []const u8,
    port: u16,
    path: []const u8,
    use_tls: bool,
    headers: []const Config.Header,
    rate: u64,
    threads: u32,
    connections_per_thread: u32,
    duration_ns: u64,
    timeout_ns: u64,

    // Thread-local state
    event_loop: *EventLoop,
    connections: []Connection,
    schedulers: []Scheduler,
    histogram: Histogram,
    allocator: std.mem.Allocator,

    // Thread
    thread: ?std.Thread,

    // Results (filled after run)
    result: ?Stats.WorkerStats,

    // Duration timer
    duration_timer_fd: ?posix.fd_t,
    start_ns: u64,

    // External stop flag (for graceful shutdown via signal)
    stop_flag: *std.atomic.Value(bool),

    /// Initialize a Worker. Allocates connections, schedulers, and histogram.
    /// Does not start the thread or connect anything.
    ///
    /// `thread_index` is 0-based; the last thread may get extra connections if
    /// `config.connections` is not evenly divisible by `config.threads`.
    pub fn init(allocator: std.mem.Allocator, config: Config, thread_index: u32, stop_flag: *std.atomic.Value(bool)) !Worker {
        const base_conns = config.connections / config.threads;
        const remainder = config.connections % config.threads;
        // Distribute the remainder across the first `remainder` threads.
        const connections_per_thread: u32 = if (thread_index < remainder)
            base_conns + 1
        else
            base_conns;

        const event_loop = try EventLoop.init();
        errdefer event_loop.deinit();

        var histogram = try Histogram.init(allocator, 3_600_000_000, 3);
        errdefer histogram.deinit(allocator);

        const schedulers = try allocator.alloc(Scheduler, connections_per_thread);
        errdefer allocator.free(schedulers);

        for (schedulers, 0..) |*sched, i| {
            sched.* = Scheduler.init(
                config.rate,
                config.threads,
                connections_per_thread,
                @intCast(i),
                0, // thread_start_ns will be set in threadMain
            );
        }

        const connections = try allocator.alloc(Connection, connections_per_thread);
        errdefer allocator.free(connections);

        for (connections, 0..) |*conn, i| {
            conn.* = Connection.init(
                config.url.host,
                config.url.port,
                config.url.path,
                config.url.scheme == .https,
                config.headers,
                &schedulers[i],
                event_loop,
                config.timeout_ns,
            );
            conn.latency_histogram = &histogram;
            conn.expected_interval = schedulers[i].expectedInterval();
        }

        return Worker{
            .host = config.url.host,
            .port = config.url.port,
            .path = config.url.path,
            .use_tls = config.url.scheme == .https,
            .headers = config.headers,
            .rate = config.rate,
            .threads = config.threads,
            .connections_per_thread = connections_per_thread,
            .duration_ns = config.duration_ns,
            .timeout_ns = config.timeout_ns,
            .event_loop = event_loop,
            .connections = connections,
            .schedulers = schedulers,
            .histogram = histogram,
            .allocator = allocator,
            .thread = null,
            .result = null,
            .duration_timer_fd = null,
            .start_ns = 0,
            .stop_flag = stop_flag,
        };
    }

    /// Free all resources owned by the Worker.
    pub fn deinit(self: *Worker) void {
        // Deinit all connections (removes from event loop, closes sockets).
        for (self.connections) |*conn| {
            conn.deinit();
        }

        // Remove duration timer if still active.
        if (self.duration_timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.duration_timer_fd = null;
        }

        self.allocator.free(self.connections);
        self.allocator.free(self.schedulers);
        self.histogram.deinit(self.allocator);
        self.event_loop.deinit();
    }

    /// Spawn an OS thread that runs the worker's event loop.
    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Wait for the worker thread to finish and return the collected stats.
    pub fn join(self: *Worker) Stats.WorkerStats {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        return self.result orelse Stats.WorkerStats{
            .histogram = self.histogram,
            .complete_requests = 0,
            .errors = 0,
            .bytes_read = 0,
            .bytes_written = 0,
            .req_per_sec = 0.0,
            .elapsed_ns = 0,
        };
    }

    /// The thread entry point. Connects all connections, sets up a duration
    /// timer, runs the event loop until the duration elapses, then collects
    /// results.
    fn threadMain(self: *Worker) void {
        // Record start time.
        self.start_ns = getMonotonicNs();

        // Update all schedulers with the actual thread start time, and fix up
        // histogram pointers (they may have been invalidated if the Worker
        // struct was moved after init returned).
        for (self.schedulers) |*sched| {
            sched.thread_start_ns = self.start_ns;
        }
        for (self.connections) |*conn| {
            conn.latency_histogram = &self.histogram;
        }

        // Connect all connections.
        for (self.connections) |*conn| {
            conn.connect();
        }

        // Set up a one-shot duration timer that stops the event loop.
        self.duration_timer_fd = self.event_loop.addTimer(
            self.duration_ns,
            0, // one-shot
            &onDurationComplete,
            @ptrCast(self),
        );

        // Run the event loop until the duration timer fires, stop() is called,
        // or the external stop flag is set (e.g. by a signal handler).
        self.event_loop.runUntilStopped(self.stop_flag);

        // Collect results from all connections.
        self.collectResults();
    }

    /// Duration timer callback. Stops the event loop.
    fn onDurationComplete(context: *anyopaque, _: u32) void {
        const self: *Worker = @ptrCast(@alignCast(context));

        // Clean up the timer.
        if (self.duration_timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.duration_timer_fd = null;
        }

        self.event_loop.stop();
    }

    /// Aggregate metrics from all connections into a WorkerStats result.
    fn collectResults(self: *Worker) void {
        const end_ns = getMonotonicNs();
        const elapsed_ns = if (end_ns > self.start_ns) end_ns - self.start_ns else 0;

        var total_requests: u64 = 0;
        var total_errors: u64 = 0;
        var total_bytes_read: u64 = 0;
        var total_bytes_written: u64 = 0;

        for (self.connections) |*conn| {
            total_requests += conn.complete_requests;
            total_errors += conn.errors;
            total_bytes_read += conn.bytes_read;
            total_bytes_written += conn.bytes_written;
        }

        const elapsed_s: f64 = if (elapsed_ns > 0)
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0
        else
            0.0;

        const req_per_sec: f64 = if (elapsed_s > 0)
            @as(f64, @floatFromInt(total_requests)) / elapsed_s
        else
            0.0;

        self.result = Stats.WorkerStats{
            .histogram = self.histogram,
            .complete_requests = total_requests,
            .errors = total_errors,
            .bytes_read = total_bytes_read,
            .bytes_written = total_bytes_written,
            .req_per_sec = req_per_sec,
            .elapsed_ns = elapsed_ns,
        };
    }

    /// Get the current monotonic clock time in nanoseconds.
    fn getMonotonicNs() u64 {
        const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const net = std.net;
const linux = std.os.linux;

test "worker init and deinit" {
    const config = Config{
        .threads = 2,
        .connections = 10,
        .duration_ns = 1_000_000_000, // 1s
        .rate = 100,
        .timeout_ns = 2_000_000_000,
        .print_latency = false,
        .headers = &.{},
        .url = .{
            .scheme = .http,
            .host = "127.0.0.1",
            .port = 8080,
            .path = "/",
        },
    };

    var stop = std.atomic.Value(bool).init(false);

    // Thread 0 gets 5 connections (10 / 2).
    var worker = try Worker.init(testing.allocator, config, 0, &stop);
    defer worker.deinit();

    // Verify field values.
    try testing.expectEqual(@as(u32, 5), worker.connections_per_thread);
    try testing.expectEqual(@as(usize, 5), worker.connections.len);
    try testing.expectEqual(@as(usize, 5), worker.schedulers.len);
    try testing.expectEqualStrings("127.0.0.1", worker.host);
    try testing.expectEqual(@as(u16, 8080), worker.port);
    try testing.expectEqualStrings("/", worker.path);
    try testing.expectEqual(false, worker.use_tls);
    try testing.expectEqual(@as(u64, 100), worker.rate);
    try testing.expectEqual(@as(u64, 1_000_000_000), worker.duration_ns);
    try testing.expect(worker.thread == null);
    try testing.expect(worker.result == null);
    try testing.expect(worker.duration_timer_fd == null);

    // Each connection should have a histogram pointer set.
    for (worker.connections) |*conn| {
        try testing.expect(conn.latency_histogram != null);
        try testing.expect(conn.expected_interval > 0);
        try testing.expectEqual(Connection.State.disconnected, conn.state);
    }
}

test "worker connection distribution uneven" {
    // 7 connections across 3 threads:
    // Thread 0: ceil(7/3) = 3  (7 % 3 = 1, thread 0 < 1 => gets 2+1=3)
    // Actually: base = 7/3 = 2, remainder = 7%3 = 1
    // Thread 0: 2+1 = 3 (index 0 < remainder 1)
    // Thread 1: 2     (index 1 >= remainder 1)
    // Thread 2: 2     (index 2 >= remainder 1)
    const config = Config{
        .threads = 3,
        .connections = 7,
        .duration_ns = 1_000_000_000,
        .rate = 100,
        .timeout_ns = 2_000_000_000,
        .print_latency = false,
        .headers = &.{},
        .url = .{
            .scheme = .http,
            .host = "127.0.0.1",
            .port = 8080,
            .path = "/",
        },
    };

    var stop = std.atomic.Value(bool).init(false);

    var w0 = try Worker.init(testing.allocator, config, 0, &stop);
    defer w0.deinit();
    var w1 = try Worker.init(testing.allocator, config, 1, &stop);
    defer w1.deinit();
    var w2 = try Worker.init(testing.allocator, config, 2, &stop);
    defer w2.deinit();

    try testing.expectEqual(@as(u32, 3), w0.connections_per_thread);
    try testing.expectEqual(@as(u32, 2), w1.connections_per_thread);
    try testing.expectEqual(@as(u32, 2), w2.connections_per_thread);
}

/// Helper for the test server: serves a single accepted connection in its own
/// thread, reading HTTP requests and writing HTTP 200 responses.
fn serveConnection(conn_stream: net.Stream, running: *std.atomic.Value(bool)) void {
    defer conn_stream.close();
    var buf: [4096]u8 = undefined;
    while (running.load(.acquire)) {
        const n = posix.read(conn_stream.handle, &buf) catch break;
        if (n == 0) break;
        const response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK";
        _ = posix.write(conn_stream.handle, response) catch break;
    }
}

test "worker with local server" {
    // Start a simple HTTP server on localhost.
    const listen_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = net.Address.listen(listen_addr, .{
        .reuse_address = true,
    }) catch return; // skip if we can't listen
    defer server.deinit();

    const bound_port = server.listen_address.getPort();

    // Flag to signal the server thread to stop.
    var server_running = std.atomic.Value(bool).init(true);

    // Server accept thread: accepts connections and spawns a handler thread
    // for each one. This allows reconnections to work during the test.
    const server_thread = std.Thread.spawn(.{}, struct {
        fn run(srv: *net.Server, running: *std.atomic.Value(bool)) void {
            // Track handler threads so we can join them on shutdown.
            var handlers: [32]std.Thread = undefined;
            var handler_count: usize = 0;

            while (running.load(.acquire)) {
                const conn = srv.accept() catch {
                    if (!running.load(.acquire)) break;
                    continue;
                };
                if (handler_count < handlers.len) {
                    handlers[handler_count] = std.Thread.spawn(
                        .{},
                        serveConnection,
                        .{ conn.stream, running },
                    ) catch {
                        conn.stream.close();
                        continue;
                    };
                    handler_count += 1;
                } else {
                    // Too many connections; just close.
                    conn.stream.close();
                }
            }

            // Join all handler threads.
            for (handlers[0..handler_count]) |h| {
                h.join();
            }
        }
    }.run, .{ &server, &server_running }) catch return;

    defer {
        server_running.store(false, .release);
        // Connect once to unblock a potentially blocking accept().
        if (net.tcpConnectToAddress(net.Address.initIp4(.{ 127, 0, 0, 1 }, bound_port))) |stream| {
            stream.close();
        } else |_| {}
        server_thread.join();
    }

    const config = Config{
        .threads = 1,
        .connections = 1,
        .duration_ns = 500_000_000, // 500ms
        .rate = 20, // 20 req/s
        .timeout_ns = 2_000_000_000,
        .print_latency = false,
        .headers = &.{},
        .url = .{
            .scheme = .http,
            .host = "127.0.0.1",
            .port = bound_port,
            .path = "/",
        },
    };

    var stop = std.atomic.Value(bool).init(false);

    var worker = try Worker.init(testing.allocator, config, 0, &stop);
    defer worker.deinit();

    try worker.start();
    const result = worker.join();

    // With 20 req/s over 500ms, we expect roughly 10 requests.
    // Allow for timing variance; just verify some requests completed.
    try testing.expect(result.complete_requests > 0);
    try testing.expect(result.bytes_read > 0);
    try testing.expect(result.bytes_written > 0);
    try testing.expect(result.elapsed_ns > 0);
    try testing.expect(result.req_per_sec > 0.0);

    // The histogram should have recorded latency values.
    try testing.expect(result.histogram.total_count > 0);
}
