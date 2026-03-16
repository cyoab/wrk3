const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const Socket = @import("Socket.zig");
const HttpParser = @import("HttpParser.zig").HttpParser;
const Scheduler = @import("Scheduler.zig").Scheduler;
const EventLoop = @import("EventLoop.zig").EventLoop;
const Config = @import("Config.zig").Config;
const Histogram = @import("Histogram.zig").Histogram;
const ScriptApi = @import("ScriptApi.zig");
const ScriptLoader = @import("ScriptLoader.zig").ScriptLoader;

pub const Connection = struct {
    socket: Socket,
    parser: HttpParser,
    scheduler: *Scheduler,
    event_loop: *EventLoop,

    // Request state
    host: []const u8,
    port: u16,
    path: []const u8,
    use_tls: bool,
    headers: []const Config.Header,

    // Timing
    intended_start_ns: u64,

    // Script support (null when no script)
    script_request_fn: ?ScriptLoader.RequestFn = null,
    script_response_fn: ?ScriptLoader.ResponseFn = null,

    // Buffers for script request customization
    script_path_buf: [2048]u8 = undefined,
    script_headers_buf: [4096]u8 = undefined,
    script_body_buf: [8192]u8 = undefined,

    // Response buffering (only used when script_response_fn is set)
    response_headers_buf: [4096]u8 = undefined,
    response_headers_len: usize = 0,
    response_body_buf: [8192]u8 = undefined,
    response_body_len: usize = 0,
    response_status: u16 = 0,

    // Buffers
    recv_buf: [16384]u8,
    recv_len: usize,

    // Send buffer for partial writes (16KB for scripted POST bodies)
    send_buf: [16384]u8,
    send_len: usize,
    send_pos: usize,

    // Metrics
    bytes_read: u64,
    bytes_written: u64,
    complete_requests: u64,
    errors: u64,

    // State
    state: State,
    timer_fd: ?posix.fd_t,
    timeout_ns: u64,

    // Latency recording (optional, set by Worker)
    latency_histogram: ?*Histogram,
    expected_interval: u64,

    pub const State = enum {
        disconnected,
        connecting,
        tls_handshake,
        sending,
        receiving,
        waiting,
    };

    /// Initialize connection state without connecting.
    pub fn init(
        host: []const u8,
        port: u16,
        path: []const u8,
        use_tls: bool,
        headers: []const Config.Header,
        scheduler: *Scheduler,
        event_loop: *EventLoop,
        timeout_ns: u64,
    ) Connection {
        return Connection{
            .socket = Socket{
                .fd = -1,
                .tls_client = null,
                .state = .disconnected,
                .tls_state = null,
            },
            .parser = HttpParser.init(),
            .scheduler = scheduler,
            .event_loop = event_loop,
            .host = host,
            .port = port,
            .path = path,
            .use_tls = use_tls,
            .headers = headers,
            .intended_start_ns = 0,
            .recv_buf = undefined,
            .recv_len = 0,
            .send_buf = undefined,
            .send_len = 0,
            .send_pos = 0,
            .bytes_read = 0,
            .bytes_written = 0,
            .complete_requests = 0,
            .errors = 0,
            .state = .disconnected,
            .timer_fd = null,
            .timeout_ns = timeout_ns,
            .latency_histogram = null,
            .expected_interval = 0,
        };
    }

    /// Initiate a TCP connection and register with the event loop.
    pub fn connect(self: *Connection) void {
        self.socket = Socket.initTcp(self.host, self.port) catch {
            self.errors += 1;
            return;
        };

        if (self.socket.state == .connecting) {
            self.state = .connecting;
            self.event_loop.addFd(
                self.socket.fd,
                linux.EPOLL.OUT,
                &onEvent,
                @ptrCast(self),
            );
        } else {
            self.handleConnected();
        }
    }

    /// Clean up socket, remove from event loop, cancel any pending timer.
    pub fn deinit(self: *Connection) void {
        if (self.timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.timer_fd = null;
        }

        if (self.socket.fd >= 0) {
            if (self.state != .disconnected) {
                self.event_loop.removeFd(self.socket.fd);
            }
            self.socket.deinit();
        }

        self.state = .disconnected;
    }

    /// Main event callback registered with epoll.
    pub fn onEvent(context: *anyopaque, events: u32) void {
        const self: *Connection = @ptrCast(@alignCast(context));

        if (events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
            self.errors += 1;
            self.reconnect();
            return;
        }

        switch (self.state) {
            .connecting => {
                if (events & linux.EPOLL.OUT != 0) {
                    const connected = self.socket.checkConnect() catch {
                        self.errors += 1;
                        self.reconnect();
                        return;
                    };
                    if (connected) {
                        self.handleConnected();
                    }
                }
            },
            .tls_handshake => {
                self.errors += 1;
                self.reconnect();
            },
            .sending => {
                if (events & linux.EPOLL.OUT != 0) {
                    self.continueSend();
                }
            },
            .receiving => {
                if (events & linux.EPOLL.IN != 0) {
                    self.handleRecv();
                }
            },
            .waiting, .disconnected => {},
        }
    }

    /// Timer callback: time to send the next request.
    pub fn onTimerEvent(context: *anyopaque, _: u32) void {
        const self: *Connection = @ptrCast(@alignCast(context));

        if (self.timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.timer_fd = null;
        }

        self.sendRequest();
    }

    /// Schedule the next request based on the scheduler's timing.
    pub fn scheduleNextRequest(self: *Connection) void {
        // Skip past missed scheduled times. The corrected histogram recording
        // already accounts for missed slots via backfilling, so sending
        // catch-up requests would double-count the correction.
        if (self.expected_interval > 0) {
            _ = self.scheduler.skipPast(getMonotonicNs());
        }

        self.intended_start_ns = self.scheduler.nextSendTime();
        self.scheduler.advance();

        const now_ns = getMonotonicNs();

        if (self.intended_start_ns <= now_ns) {
            self.sendRequest();
        } else {
            const delay_ns = self.intended_start_ns - now_ns;
            self.state = .waiting;

            self.event_loop.modifyFd(
                self.socket.fd,
                0,
                &onEvent,
                @ptrCast(self),
            );

            self.timer_fd = self.event_loop.addTimer(
                delay_ns,
                0,
                &onTimerEvent,
                @ptrCast(self),
            );
        }
    }

    /// Format and send an HTTP request. When a script request function is
    /// set, the script gets to customize method, path, headers, and body.
    pub fn sendRequest(self: *Connection) void {
        if (self.script_request_fn) |request_fn| {
            const path_len = @min(self.path.len, self.script_path_buf.len);
            @memcpy(self.script_path_buf[0..path_len], self.path[0..path_len]);

            const host_header_len = formatHostHeader(&self.script_headers_buf, self.host);

            var req = ScriptApi.Request{
                .method = .GET,
                .path = .{ .ptr = &self.script_path_buf, .len = path_len, .cap = self.script_path_buf.len },
                .headers = .{ .ptr = &self.script_headers_buf, .len = host_header_len, .cap = self.script_headers_buf.len },
                .body = .{ .ptr = &self.script_body_buf, .len = 0, .cap = self.script_body_buf.len },
            };

            request_fn(&req);

            const len = formatScriptRequest(&self.send_buf, &req, self.host);
            self.send_len = len;
        } else {
            const len = formatRequest(
                &self.send_buf,
                self.path,
                self.host,
                self.headers,
            );
            self.send_len = len;
        }
        self.send_pos = 0;

        self.state = .sending;
        self.parser = HttpParser.init();
        self.recv_len = 0;

        self.response_headers_len = 0;
        self.response_body_len = 0;
        self.response_status = 0;

        self.continueSend();
    }

    /// Continue sending any remaining data in the send buffer.
    fn continueSend(self: *Connection) void {
        while (self.send_pos < self.send_len) {
            const sent = self.socket.send(self.send_buf[self.send_pos..self.send_len]) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        self.event_loop.modifyFd(
                            self.socket.fd,
                            linux.EPOLL.OUT,
                            &onEvent,
                            @ptrCast(self),
                        );
                        return;
                    },
                    else => {
                        self.errors += 1;
                        self.reconnect();
                        return;
                    },
                }
            };

            if (sent == 0) {
                self.errors += 1;
                self.reconnect();
                return;
            }

            self.send_pos += sent;
            self.bytes_written += sent;
        }

        self.state = .receiving;
        self.event_loop.modifyFd(
            self.socket.fd,
            linux.EPOLL.IN,
            &onEvent,
            @ptrCast(self),
        );
    }

    /// Read data from the socket, feed it to the parser, and handle events.
    pub fn handleRecv(self: *Connection) void {
        while (true) {
            const n = self.socket.recv(self.recv_buf[self.recv_len..]) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    else => {
                        self.errors += 1;
                        self.reconnect();
                        return;
                    },
                }
            };

            if (n == 0) {
                if (self.state == .receiving) {
                    self.errors += 1;
                }
                self.reconnect();
                return;
            }

            self.recv_len += n;
            self.bytes_read += n;

            if (!self.processRecvBuffer()) return;
        }
    }

    /// Feed the receive buffer to the parser, processing events.
    fn processRecvBuffer(self: *Connection) bool {
        while (true) {
            const event = self.parser.feed(self.recv_buf[0..self.recv_len]);
            const consumed = self.parser.consumed;

            if (consumed > 0 and consumed < self.recv_len) {
                std.mem.copyForwards(u8, &self.recv_buf, self.recv_buf[consumed..self.recv_len]);
                self.recv_len -= consumed;
            } else if (consumed >= self.recv_len) {
                self.recv_len = 0;
            }

            switch (event) {
                .message_complete => {
                    self.complete_requests += 1;

                    // Call script response hook if present.
                    if (self.script_response_fn) |response_fn| {
                        const resp = ScriptApi.Response{
                            .status = self.response_status,
                            .headers = .{ .ptr = &self.response_headers_buf, .len = self.response_headers_len },
                            .body = .{ .ptr = &self.response_body_buf, .len = self.response_body_len },
                        };
                        response_fn(&resp);
                    }

                    if (self.latency_histogram) |histogram| {
                        const now_ns = getMonotonicNs();
                        const latency_ns = if (now_ns > self.intended_start_ns)
                            now_ns - self.intended_start_ns
                        else
                            0;
                        if (self.expected_interval > 0) {
                            histogram.recordCorrectedValue(latency_ns, self.expected_interval);
                        } else {
                            _ = histogram.recordValue(latency_ns);
                        }
                    }

                    if (!self.parser.keep_alive) {
                        self.reconnect();
                        return false;
                    }

                    self.scheduleNextRequest();
                    return false;
                },
                .need_more_data => {
                    if (self.recv_len == 0) return true;
                    continue;
                },
                .status => |code| {
                    self.response_status = code;
                    continue;
                },
                .header => |h| {
                    if (self.script_response_fn != null) {
                        const needed = h.name.len + 2 + h.value.len + 2;
                        const avail = self.response_headers_buf.len - self.response_headers_len;
                        if (needed <= avail) {
                            var pos = self.response_headers_len;
                            @memcpy(self.response_headers_buf[pos..][0..h.name.len], h.name);
                            pos += h.name.len;
                            @memcpy(self.response_headers_buf[pos..][0..2], ": ");
                            pos += 2;
                            @memcpy(self.response_headers_buf[pos..][0..h.value.len], h.value);
                            pos += h.value.len;
                            @memcpy(self.response_headers_buf[pos..][0..2], "\r\n");
                            pos += 2;
                            self.response_headers_len = pos;
                        }
                    }
                    continue;
                },
                .body_chunk => |chunk| {
                    if (self.script_response_fn != null) {
                        const avail = self.response_body_buf.len - self.response_body_len;
                        const copy_len = @min(chunk.len, avail);
                        @memcpy(self.response_body_buf[self.response_body_len..][0..copy_len], chunk[0..copy_len]);
                        self.response_body_len += copy_len;
                    }
                    continue;
                },
            }
        }
    }

    /// On error: close the current socket, create a new one, and reconnect.
    pub fn reconnect(self: *Connection) void {
        if (self.timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.timer_fd = null;
        }

        if (self.socket.fd >= 0) {
            if (self.state != .disconnected) {
                self.event_loop.removeFd(self.socket.fd);
            }
            self.socket.deinit();
        }

        self.state = .disconnected;
        self.recv_len = 0;
        self.send_pos = 0;
        self.send_len = 0;
        self.parser = HttpParser.init();

        self.scheduler.reset(getMonotonicNs());

        self.connect();
    }

    fn handleConnected(self: *Connection) void {
        if (self.use_tls) {
            self.state = .tls_handshake;
            self.socket.startTlsHandshake(self.host) catch {
                self.errors += 1;
                self.reconnect();
                return;
            };
        }

        self.event_loop.modifyFd(
            self.socket.fd,
            linux.EPOLL.IN,
            &onEvent,
            @ptrCast(self),
        );

        self.scheduleNextRequest();
    }

    fn getMonotonicNs() u64 {
        const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    fn formatHostHeader(buf: []u8, host: []const u8) usize {
        var pos: usize = 0;
        pos = appendSlice(buf, pos, "Host: ");
        pos = appendSlice(buf, pos, host);
        pos = appendSlice(buf, pos, "\r\n");
        return pos;
    }

    /// Format an HTTP request from a ScriptApi.Request.
    pub fn formatScriptRequest(
        buf: []u8,
        req: *const ScriptApi.Request,
        host: []const u8,
    ) usize {
        var pos: usize = 0;

        pos = appendSlice(buf, pos, ScriptApi.methodName(req.method));
        pos = appendSlice(buf, pos, " ");
        pos = appendSlice(buf, pos, req.path.slice());
        pos = appendSlice(buf, pos, " HTTP/1.1\r\n");

        const headers_data = req.headers.slice();
        const has_host = std.mem.indexOf(u8, headers_data, "Host:") != null or
            std.mem.indexOf(u8, headers_data, "host:") != null;

        if (!has_host) {
            pos = appendSlice(buf, pos, "Host: ");
            pos = appendSlice(buf, pos, host);
            pos = appendSlice(buf, pos, "\r\n");
        }

        pos = appendSlice(buf, pos, headers_data);

        const body_data = req.body.slice();
        if (body_data.len > 0) {
            pos = appendSlice(buf, pos, "Content-Length: ");
            var len_buf: [20]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_data.len}) catch "";
            pos = appendSlice(buf, pos, len_str);
            pos = appendSlice(buf, pos, "\r\n");
        }

        pos = appendSlice(buf, pos, "\r\n");

        if (body_data.len > 0) {
            pos = appendSlice(buf, pos, body_data);
        }

        return pos;
    }

    /// Format an HTTP GET request into the provided buffer.
    pub fn formatRequest(
        buf: []u8,
        path: []const u8,
        host: []const u8,
        headers: []const Config.Header,
    ) usize {
        var pos: usize = 0;

        pos = appendSlice(buf, pos, "GET ");
        pos = appendSlice(buf, pos, path);
        pos = appendSlice(buf, pos, " HTTP/1.1\r\n");

        pos = appendSlice(buf, pos, "Host: ");
        pos = appendSlice(buf, pos, host);
        pos = appendSlice(buf, pos, "\r\n");

        for (headers) |header| {
            pos = appendSlice(buf, pos, header.name);
            pos = appendSlice(buf, pos, ": ");
            pos = appendSlice(buf, pos, header.value);
            pos = appendSlice(buf, pos, "\r\n");
        }

        pos = appendSlice(buf, pos, "\r\n");

        return pos;
    }

    fn appendSlice(buf: []u8, pos: usize, data: []const u8) usize {
        const available = buf.len - pos;
        const to_copy = @min(data.len, available);
        @memcpy(buf[pos .. pos + to_copy], data[0..to_copy]);
        return pos + to_copy;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "request formatting" {
    var buf: [2048]u8 = undefined;

    {
        const headers: []const Config.Header = &.{};
        const len = Connection.formatRequest(&buf, "/", "example.com", headers);
        const expected = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
        try testing.expectEqualStrings(expected, buf[0..len]);
    }

    {
        const headers: []const Config.Header = &.{
            .{ .name = "Accept", .value = "text/html" },
            .{ .name = "Authorization", .value = "Bearer token123" },
        };
        const len = Connection.formatRequest(&buf, "/api/v1/data", "myhost.io", headers);
        const expected =
            "GET /api/v1/data HTTP/1.1\r\n" ++
            "Host: myhost.io\r\n" ++
            "Accept: text/html\r\n" ++
            "Authorization: Bearer token123\r\n" ++
            "\r\n";
        try testing.expectEqualStrings(expected, buf[0..len]);
    }

    {
        const headers: []const Config.Header = &.{};
        const len = Connection.formatRequest(&buf, "/index.html", "localhost", headers);
        const expected = "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n";
        try testing.expectEqualStrings(expected, buf[0..len]);
    }
}

test "script request formatting" {
    var buf: [4096]u8 = undefined;
    var path_buf: [2048]u8 = undefined;
    var headers_buf: [4096]u8 = undefined;
    var body_buf: [8192]u8 = undefined;

    {
        const path = "/api/users";
        @memcpy(path_buf[0..path.len], path);

        const hdrs = "Content-Type: application/json\r\n";
        @memcpy(headers_buf[0..hdrs.len], hdrs);

        const body = "{\"name\":\"test\"}";
        @memcpy(body_buf[0..body.len], body);

        const req = ScriptApi.Request{
            .method = .POST,
            .path = .{ .ptr = &path_buf, .len = path.len, .cap = path_buf.len },
            .headers = .{ .ptr = &headers_buf, .len = hdrs.len, .cap = headers_buf.len },
            .body = .{ .ptr = &body_buf, .len = body.len, .cap = body_buf.len },
        };

        const len = Connection.formatScriptRequest(&buf, &req, "example.com");
        const expected =
            "POST /api/users HTTP/1.1\r\n" ++
            "Host: example.com\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 15\r\n" ++
            "\r\n" ++
            "{\"name\":\"test\"}";
        try testing.expectEqualStrings(expected, buf[0..len]);
    }
}

test "connection init" {
    const el = try EventLoop.init();
    defer el.deinit();

    var scheduler = Scheduler.init(1000, 2, 5, 0, 0);

    const headers: []const Config.Header = &.{};
    const conn = Connection.init(
        "example.com",
        80,
        "/test",
        false,
        headers,
        &scheduler,
        el,
        2_000_000_000,
    );

    try testing.expectEqual(Connection.State.disconnected, conn.state);
    try testing.expectEqualStrings("example.com", conn.host);
    try testing.expectEqual(@as(u16, 80), conn.port);
    try testing.expectEqualStrings("/test", conn.path);
    try testing.expectEqual(false, conn.use_tls);
    try testing.expectEqual(@as(u64, 0), conn.bytes_read);
    try testing.expectEqual(@as(u64, 0), conn.bytes_written);
    try testing.expectEqual(@as(u64, 0), conn.complete_requests);
    try testing.expectEqual(@as(u64, 0), conn.errors);
    try testing.expectEqual(@as(usize, 0), conn.recv_len);
    try testing.expectEqual(@as(?posix.fd_t, null), conn.timer_fd);
    try testing.expectEqual(@as(u64, 2_000_000_000), conn.timeout_ns);
    try testing.expect(conn.script_request_fn == null);
    try testing.expect(conn.script_response_fn == null);
}

test "state transitions" {
    const el = try EventLoop.init();
    defer el.deinit();

    var scheduler = Scheduler.init(1000, 1, 1, 0, 0);

    const headers: []const Config.Header = &.{};
    const conn = Connection.init(
        "127.0.0.1",
        12345,
        "/",
        false,
        headers,
        &scheduler,
        el,
        2_000_000_000,
    );

    try testing.expectEqual(Connection.State.disconnected, conn.state);
    try testing.expectEqual(@as(posix.fd_t, -1), conn.socket.fd);
    try testing.expectEqual(@as(u64, 0), conn.complete_requests);
    try testing.expectEqual(@as(u64, 0), conn.bytes_read);
    try testing.expectEqual(@as(u64, 0), conn.bytes_written);
    try testing.expectEqual(@as(u64, 0), conn.errors);
    try testing.expectEqual(@as(u16, 0), conn.parser.status_code);
    try testing.expect(conn.parser.keep_alive);
}

test "format request buffer overflow protection" {
    var small_buf: [10]u8 = undefined;
    const headers: []const Config.Header = &.{};
    const len = Connection.formatRequest(&small_buf, "/", "example.com", headers);

    try testing.expectEqual(@as(usize, 10), len);
    try testing.expectEqualStrings("GET / HTTP", &small_buf);
}
