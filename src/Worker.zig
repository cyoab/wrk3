const std = @import("std");
const posix = std.posix;

const EventLoop = @import("EventLoop.zig").EventLoop;
const Connection = @import("Connection.zig").Connection;
const Histogram = @import("Histogram.zig").Histogram;
const Scheduler = @import("Scheduler.zig").Scheduler;
const Stats = @import("Stats.zig");
const Config = @import("Config.zig").Config;
const ScriptLoader = @import("ScriptLoader.zig").ScriptLoader;
const ScriptApi = @import("ScriptApi.zig");

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

    // Script support
    so_path: ?[]const u8,
    script_loader: ?ScriptLoader,
    thread_index: u32,

    /// Initialize a Worker. Allocates connections, schedulers, and histogram.
    /// Does not start the thread or connect anything.
    pub fn init(allocator: std.mem.Allocator, config: Config, thread_index: u32, stop_flag: *std.atomic.Value(bool), so_path: ?[]const u8) !Worker {
        const base_conns = config.connections / config.threads;
        const remainder = config.connections % config.threads;
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
                0,
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
            .so_path = so_path,
            .script_loader = null,
            .thread_index = thread_index,
        };
    }

    /// Free all resources owned by the Worker.
    pub fn deinit(self: *Worker) void {
        for (self.connections) |*conn| {
            conn.deinit();
        }

        if (self.duration_timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.duration_timer_fd = null;
        }

        // Skip dlclose — Worker.deinit() only runs at process exit, and
        // dlclose on Zig-compiled .so files can segfault due to runtime
        // destructor ordering. The OS reclaims all resources on exit.
        self.script_loader = null;

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

    /// The thread entry point.
    fn threadMain(self: *Worker) void {
        self.start_ns = getMonotonicNs();

        // Load script if provided.
        if (self.so_path) |path| {
            self.script_loader = ScriptLoader.load(self.allocator, path) catch null;
        }

        // Call setup() hook if the script provides one.
        if (self.script_loader) |loader| {
            if (loader.setup_fn) |setup_fn| {
                var ctx = ScriptApi.ThreadContext{
                    .thread_id = self.thread_index,
                    .thread_count = self.threads,
                    .connections_per_thread = self.connections_per_thread,
                };
                setup_fn(&ctx);
            }
        }

        // Update schedulers and fix up histogram/script pointers.
        for (self.schedulers) |*sched| {
            sched.thread_start_ns = self.start_ns;
        }
        for (self.connections) |*conn| {
            conn.latency_histogram = &self.histogram;

            if (self.script_loader) |loader| {
                conn.script_request_fn = loader.request_fn;
                conn.script_response_fn = loader.response_fn;
            }
        }

        for (self.connections) |*conn| {
            conn.connect();
        }

        self.duration_timer_fd = self.event_loop.addTimer(
            self.duration_ns,
            0,
            &onDurationComplete,
            @ptrCast(self),
        );

        self.event_loop.runUntilStopped(self.stop_flag);

        self.collectResults();
    }

    fn onDurationComplete(context: *anyopaque, _: u32) void {
        const self: *Worker = @ptrCast(@alignCast(context));

        if (self.duration_timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.duration_timer_fd = null;
        }

        self.event_loop.stop();
    }

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

    var worker = try Worker.init(testing.allocator, config, 0, &stop, null);
    defer worker.deinit();

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
    try testing.expect(worker.so_path == null);
    try testing.expect(worker.script_loader == null);

    for (worker.connections) |*conn| {
        try testing.expect(conn.latency_histogram != null);
        try testing.expect(conn.expected_interval > 0);
        try testing.expectEqual(Connection.State.disconnected, conn.state);
    }
}

test "worker connection distribution uneven" {
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

    var w0 = try Worker.init(testing.allocator, config, 0, &stop, null);
    defer w0.deinit();
    var w1 = try Worker.init(testing.allocator, config, 1, &stop, null);
    defer w1.deinit();
    var w2 = try Worker.init(testing.allocator, config, 2, &stop, null);
    defer w2.deinit();

    try testing.expectEqual(@as(u32, 3), w0.connections_per_thread);
    try testing.expectEqual(@as(u32, 2), w1.connections_per_thread);
    try testing.expectEqual(@as(u32, 2), w2.connections_per_thread);
}

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
    const listen_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = net.Address.listen(listen_addr, .{
        .reuse_address = true,
    }) catch return;
    defer server.deinit();

    const bound_port = server.listen_address.getPort();

    var server_running = std.atomic.Value(bool).init(true);

    const server_thread = std.Thread.spawn(.{}, struct {
        fn run(srv: *net.Server, running: *std.atomic.Value(bool)) void {
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
                    conn.stream.close();
                }
            }

            for (handlers[0..handler_count]) |h| {
                h.join();
            }
        }
    }.run, .{ &server, &server_running }) catch return;

    defer {
        server_running.store(false, .release);
        if (net.tcpConnectToAddress(net.Address.initIp4(.{ 127, 0, 0, 1 }, bound_port))) |stream| {
            stream.close();
        } else |_| {}
        server_thread.join();
    }

    const config = Config{
        .threads = 1,
        .connections = 1,
        .duration_ns = 500_000_000,
        .rate = 20,
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

    var worker = try Worker.init(testing.allocator, config, 0, &stop, null);
    defer worker.deinit();

    try worker.start();
    const result = worker.join();

    try testing.expect(result.complete_requests > 0);
    try testing.expect(result.bytes_read > 0);
    try testing.expect(result.bytes_written > 0);
    try testing.expect(result.elapsed_ns > 0);
    try testing.expect(result.req_per_sec > 0.0);
    try testing.expect(result.histogram.total_count > 0);
}
