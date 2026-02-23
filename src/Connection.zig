const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const Socket = @import("Socket.zig");
const HttpParser = @import("HttpParser.zig").HttpParser;
const Scheduler = @import("Scheduler.zig").Scheduler;
const EventLoop = @import("EventLoop.zig").EventLoop;
const Config = @import("Config.zig").Config;

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

    // Buffers
    recv_buf: [16384]u8,
    recv_len: usize,

    // Send buffer for partial writes
    send_buf: [2048]u8,
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
        };
    }

    /// Initiate a TCP connection and register with the event loop.
    pub fn connect(self: *Connection) void {
        self.socket = Socket.initTcp(self.host, self.port) catch {
            self.errors += 1;
            return;
        };

        // Register with event loop: watch for writable (connect completion) or
        // handle post-connect immediately if already connected.
        if (self.socket.state == .connecting) {
            self.state = .connecting;
            self.event_loop.addFd(
                self.socket.fd,
                linux.EPOLL.OUT,
                &onEvent,
                @ptrCast(self),
            );
        } else {
            // Already connected (e.g., loopback), handle post-connect.
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
            // removeFd can fail if fd wasn't added; in deinit we ignore that.
            if (self.state != .disconnected) {
                self.event_loop.removeFd(self.socket.fd);
            }
            self.socket.deinit();
        }

        self.state = .disconnected;
    }

    /// Main event callback registered with epoll. Dispatches based on
    /// connection state.
    pub fn onEvent(context: *anyopaque, events: u32) void {
        const self: *Connection = @ptrCast(@alignCast(context));

        // Check for errors or hangup.
        if (events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
            self.errors += 1;
            self.reconnect();
            return;
        }

        switch (self.state) {
            .connecting => {
                // EPOLLOUT when connecting means connect completed (or failed).
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
                // TLS handshake is done synchronously in startTlsHandshake,
                // so this state shouldn't normally fire from epoll. If it does,
                // treat it as an error.
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
            .waiting, .disconnected => {
                // Shouldn't get events in these states; ignore.
            },
        }
    }

    /// Timer callback: time to send the next request.
    pub fn onTimerEvent(context: *anyopaque, _: u32) void {
        const self: *Connection = @ptrCast(@alignCast(context));

        // Clean up the one-shot timer.
        if (self.timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.timer_fd = null;
        }

        self.sendRequest();
    }

    /// After a response completes, use the scheduler to determine when to
    /// send the next request. If the scheduled time is in the past, send
    /// immediately; otherwise arm a timer.
    pub fn scheduleNextRequest(self: *Connection) void {
        self.intended_start_ns = self.scheduler.nextSendTime();
        self.scheduler.advance();

        const now_ns = getMonotonicNs();

        if (self.intended_start_ns <= now_ns) {
            // Send immediately.
            self.sendRequest();
        } else {
            // Set a one-shot timer for the remaining delay.
            const delay_ns = self.intended_start_ns - now_ns;
            self.state = .waiting;

            // Modify the fd to not watch for anything while waiting.
            self.event_loop.modifyFd(
                self.socket.fd,
                0, // no events
                &onEvent,
                @ptrCast(self),
            );

            self.timer_fd = self.event_loop.addTimer(
                delay_ns,
                0, // one-shot
                &onTimerEvent,
                @ptrCast(self),
            );
        }
    }

    /// Format and send the HTTP GET request.
    pub fn sendRequest(self: *Connection) void {
        const len = formatRequest(
            &self.send_buf,
            self.path,
            self.host,
            self.headers,
        );
        self.send_len = len;
        self.send_pos = 0;

        self.state = .sending;
        self.parser = HttpParser.init();
        self.recv_len = 0;

        // Try to send right away.
        self.continueSend();
    }

    /// Continue sending any remaining data in the send buffer.
    fn continueSend(self: *Connection) void {
        while (self.send_pos < self.send_len) {
            const sent = self.socket.send(self.send_buf[self.send_pos..self.send_len]) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        // Register for EPOLLOUT to continue later.
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

        // All data sent -- switch to receiving.
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
                // Connection closed by peer.
                // If we were expecting data, this is an error.
                if (self.state == .receiving) {
                    self.errors += 1;
                }
                self.reconnect();
                return;
            }

            self.recv_len += n;
            self.bytes_read += n;

            // Feed buffered data to the parser.
            if (!self.processRecvBuffer()) return;
        }
    }

    /// Feed the receive buffer to the parser, processing events.
    /// Returns true if we should continue reading, false if we should stop
    /// (either because we completed a message and scheduled the next request,
    /// or because we hit an error and reconnected).
    fn processRecvBuffer(self: *Connection) bool {
        while (self.recv_len > 0) {
            const event = self.parser.feed(self.recv_buf[0..self.recv_len]);
            const consumed = self.parser.consumed;

            // Shift consumed bytes out of the buffer.
            if (consumed > 0 and consumed < self.recv_len) {
                std.mem.copyForwards(u8, &self.recv_buf, self.recv_buf[consumed..self.recv_len]);
                self.recv_len -= consumed;
            } else if (consumed >= self.recv_len) {
                self.recv_len = 0;
            }

            switch (event) {
                .message_complete => {
                    self.complete_requests += 1;

                    if (!self.parser.keep_alive) {
                        // Server wants to close the connection.
                        self.reconnect();
                        return false;
                    }

                    self.scheduleNextRequest();
                    return false;
                },
                .need_more_data => {
                    // Need more data from the socket.
                    return true;
                },
                .status, .header, .body_chunk => {
                    // Continue parsing -- there may be more events in the buffer.
                    continue;
                },
            }
        }
        return true;
    }

    /// On error: close the current socket, create a new one, and reconnect.
    pub fn reconnect(self: *Connection) void {
        // Cancel any pending timer.
        if (self.timer_fd) |tfd| {
            self.event_loop.removeTimer(tfd);
            self.timer_fd = null;
        }

        // Remove from event loop and close the socket.
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

        // Reset the scheduler so we don't get a burst of catch-up requests.
        self.scheduler.reset(getMonotonicNs());

        // Reconnect.
        self.connect();
    }

    // -------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------

    /// Handle the transition after TCP connect completes (possibly do TLS,
    /// then schedule the first request).
    fn handleConnected(self: *Connection) void {
        if (self.use_tls) {
            self.state = .tls_handshake;
            self.socket.startTlsHandshake(self.host) catch {
                self.errors += 1;
                self.reconnect();
                return;
            };
        }

        // Now connected (plain or TLS handshake done).
        // Register for reading + writing and schedule the first request.
        self.event_loop.modifyFd(
            self.socket.fd,
            linux.EPOLL.IN,
            &onEvent,
            @ptrCast(self),
        );

        self.scheduleNextRequest();
    }

    /// Get the current monotonic clock time in nanoseconds.
    fn getMonotonicNs() u64 {
        const ts = posix.clock_gettime(.MONOTONIC) catch return 0;
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    /// Format an HTTP GET request into the provided buffer.
    /// Returns the number of bytes written.
    pub fn formatRequest(
        buf: []u8,
        path: []const u8,
        host: []const u8,
        headers: []const Config.Header,
    ) usize {
        var pos: usize = 0;

        // "GET {path} HTTP/1.1\r\n"
        pos = appendSlice(buf, pos, "GET ");
        pos = appendSlice(buf, pos, path);
        pos = appendSlice(buf, pos, " HTTP/1.1\r\n");

        // "Host: {host}\r\n"
        pos = appendSlice(buf, pos, "Host: ");
        pos = appendSlice(buf, pos, host);
        pos = appendSlice(buf, pos, "\r\n");

        // Custom headers
        for (headers) |header| {
            pos = appendSlice(buf, pos, header.name);
            pos = appendSlice(buf, pos, ": ");
            pos = appendSlice(buf, pos, header.value);
            pos = appendSlice(buf, pos, "\r\n");
        }

        // Final CRLF
        pos = appendSlice(buf, pos, "\r\n");

        return pos;
    }

    /// Append a slice to the buffer at the given position. Returns the new
    /// position. If the buffer would overflow, writes as much as fits.
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

    // Basic request with no custom headers.
    {
        const headers: []const Config.Header = &.{};
        const len = Connection.formatRequest(&buf, "/", "example.com", headers);
        const expected = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
        try testing.expectEqualStrings(expected, buf[0..len]);
    }

    // Request with path and custom headers.
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

    // Request with empty path (should still work).
    {
        const headers: []const Config.Header = &.{};
        const len = Connection.formatRequest(&buf, "/index.html", "localhost", headers);
        const expected = "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n";
        try testing.expectEqualStrings(expected, buf[0..len]);
    }
}

test "connection init" {
    // We need a valid Scheduler and EventLoop for init. We can create a
    // Scheduler on the stack; for the EventLoop we need to allocate.
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

    // Initial state should be disconnected.
    try testing.expectEqual(Connection.State.disconnected, conn.state);

    // Socket fd should be -1 before connect.
    try testing.expectEqual(@as(posix.fd_t, -1), conn.socket.fd);

    // After init, all counters should be zero.
    try testing.expectEqual(@as(u64, 0), conn.complete_requests);
    try testing.expectEqual(@as(u64, 0), conn.bytes_read);
    try testing.expectEqual(@as(u64, 0), conn.bytes_written);
    try testing.expectEqual(@as(u64, 0), conn.errors);

    // Verify the parser is in its initial state.
    try testing.expectEqual(@as(u16, 0), conn.parser.status_code);
    try testing.expect(conn.parser.keep_alive);
}

test "format request buffer overflow protection" {
    // Use a very small buffer to verify we don't crash.
    var small_buf: [10]u8 = undefined;
    const headers: []const Config.Header = &.{};
    const len = Connection.formatRequest(&small_buf, "/", "example.com", headers);

    // Should fill the buffer without overflowing.
    try testing.expectEqual(@as(usize, 10), len);
    try testing.expectEqualStrings("GET / HTTP", &small_buf);
}
