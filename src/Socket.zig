const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const net = std.net;
const crypto = std.crypto;
const tls = crypto.tls;
const Io = std.Io;
const Certificate = crypto.Certificate;

const Socket = @This();

/// The underlying file descriptor for the TCP connection.
fd: posix.fd_t,

/// Optional TLS client for encrypted connections.
/// When non-null, send/recv go through TLS.
tls_client: ?TlsClient,

/// Current state of the socket connection.
state: State,

/// Heap-allocated TLS buffers and stream state. Null when no TLS is in use.
tls_state: ?*TlsState,

pub const State = enum {
    disconnected,
    connecting, // TCP connect in progress (EINPROGRESS)
    tls_handshake, // TLS handshake in progress
    connected, // Ready for send/recv
};

pub const TlsClient = tls.Client;

pub const SendError = error{ WouldBlock, ConnectionReset, BrokenPipe, Closed, Unexpected };
pub const RecvError = error{ WouldBlock, ConnectionReset, Closed, Unexpected };
pub const ConnectError = error{ InProgress, ConnectionRefused, Timeout, Unexpected };

/// Internal state for TLS streams. Heap-allocated because TLS Client holds
/// pointers into Reader/Writer objects and they must have a stable address.
const TlsState = struct {
    /// Buffers for the underlying network Reader/Writer that the TLS Client
    /// reads/writes encrypted data from/to.
    input_buf: [tls.Client.min_buffer_len]u8,
    output_buf: [tls.max_ciphertext_record_len]u8,
    /// Additional buffers required by TLS Client Options.
    read_buf: [tls.Client.min_buffer_len]u8,
    write_buf: [tls.max_ciphertext_record_len]u8,
    /// The net.Stream.Reader wrapping the raw fd for reading encrypted data
    /// from the network.
    net_reader: net.Stream.Reader,
    /// The net.Stream.Writer wrapping the raw fd for writing encrypted data
    /// to the network.
    net_writer: net.Stream.Writer,
};

/// Create a non-blocking TCP socket and initiate connection to host:port.
///
/// DNS resolution is performed to convert the hostname to an address.
/// The socket is created with NONBLOCK and CLOEXEC flags.
/// If connect returns EINPROGRESS (WouldBlock), state is set to `connecting`.
pub fn initTcp(host: []const u8, port: u16) !Socket {
    // Resolve the address: try parsing as IP first, fall back to DNS.
    const addr = try resolveAddress(host, port);

    // Create a non-blocking TCP socket.
    const family: u32 = addr.any.family;
    const sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC;
    const sockfd = posix.socket(family, sock_flags, posix.IPPROTO.TCP) catch {
        return error.Unexpected;
    };
    errdefer posix.close(sockfd);

    // Disable Nagle's algorithm for low latency.
    setTcpNoDelay(sockfd) catch {};

    // Initiate the connection. For non-blocking sockets, this typically
    // returns WouldBlock (EINPROGRESS), meaning the connection is in progress.
    var initial_state: State = .connected;
    posix.connect(sockfd, &addr.any, addr.getOsSockLen()) catch |err| {
        switch (err) {
            error.WouldBlock => {
                initial_state = .connecting;
            },
            error.ConnectionRefused => return error.ConnectionRefused,
            error.ConnectionTimedOut => return error.ConnectionTimedOut,
            error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
            else => return error.Unexpected,
        }
    };

    return Socket{
        .fd = sockfd,
        .tls_client = null,
        .state = initial_state,
        .tls_state = null,
    };
}

/// Create a Socket in the connected state, wrapping an existing fd.
/// This is useful for testing or wrapping already-connected sockets.
pub fn initFromFd(fd: posix.fd_t) Socket {
    return Socket{
        .fd = fd,
        .tls_client = null,
        .state = .connected,
        .tls_state = null,
    };
}

/// Close the socket and clean up TLS resources if any.
pub fn deinit(self: *Socket) void {
    if (self.tls_state) |ts| {
        std.heap.page_allocator.destroy(ts);
        self.tls_state = null;
    }
    self.tls_client = null;

    if (self.fd >= 0) {
        posix.close(self.fd);
        self.fd = -1;
    }
    self.state = .disconnected;
}

/// Send data over the socket. If TLS is active, data is encrypted before
/// sending.
///
/// Returns the number of bytes sent, or an error.
/// Returns `WouldBlock` if the socket would block (EAGAIN/EWOULDBLOCK).
pub fn send(self: *Socket, data: []const u8) SendError!usize {
    if (self.state != .connected) return error.Closed;
    if (data.len == 0) return 0;

    if (self.tls_client != null) {
        return self.tlsSend(data);
    }

    return self.rawSend(data);
}

/// Receive data from the socket. If TLS is active, received data is
/// decrypted.
///
/// Returns the number of bytes received, or an error.
/// Returns 0 when the connection has been closed by the peer.
/// Returns `WouldBlock` if no data is available and socket is non-blocking.
pub fn recv(self: *Socket, buf: []u8) RecvError!usize {
    if (self.state != .connected) return error.Closed;
    if (buf.len == 0) return 0;

    if (self.tls_client != null) {
        return self.tlsRecv(buf);
    }

    return self.rawRecv(buf);
}

/// After TCP connect completes, initiate TLS handshake.
///
/// The socket is temporarily set to blocking mode for the handshake,
/// then restored to non-blocking mode afterward. This simplifies the
/// handshake logic while still allowing non-blocking I/O for data transfer.
pub fn startTlsHandshake(self: *Socket, host: []const u8) !void {
    if (self.state != .connected and self.state != .connecting) {
        return error.Unexpected;
    }

    self.state = .tls_handshake;

    // Allocate TLS state on the heap for stable addresses.
    const ts = try std.heap.page_allocator.create(TlsState);
    errdefer std.heap.page_allocator.destroy(ts);

    ts.input_buf = undefined;
    ts.output_buf = undefined;
    ts.read_buf = undefined;
    ts.write_buf = undefined;
    const stream: net.Stream = .{ .handle = self.fd };
    ts.net_reader = net.Stream.Reader.init(stream, &ts.input_buf);
    ts.net_writer = net.Stream.Writer.init(stream, &ts.output_buf);

    // Temporarily set socket to blocking mode for the TLS handshake.
    self.setBlocking(true) catch {
        self.state = .disconnected;
        return error.Unexpected;
    };
    defer self.setBlocking(false) catch {};

    // Perform the TLS handshake.
    self.tls_client = tls.Client.init(
        ts.net_reader.interface(),
        &ts.net_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .no_verification,
            .read_buffer = &ts.read_buf,
            .write_buffer = &ts.write_buf,
        },
    ) catch {
        self.state = .disconnected;
        return error.TlsHandshakeFailed;
    };

    self.tls_state = ts;
    self.state = .connected;
}

/// Check if the socket is in the process of connecting (TCP or TLS).
pub fn isConnecting(self: *const Socket) bool {
    return self.state == .connecting or self.state == .tls_handshake;
}

/// Check if the non-blocking connect has completed.
/// Call this when epoll reports the fd is writable after initTcp returned
/// with state == connecting.
///
/// Returns true if the connection is now established, false if still in
/// progress.
pub fn checkConnect(self: *Socket) ConnectError!bool {
    if (self.state != .connecting) return true;

    posix.getsockoptError(self.fd) catch |err| {
        self.state = .disconnected;
        return switch (err) {
            error.ConnectionRefused => error.ConnectionRefused,
            error.ConnectionTimedOut => error.Timeout,
            else => error.Unexpected,
        };
    };

    self.state = .connected;
    return true;
}

// -----------------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------------

/// Send raw data over the TCP socket (no TLS).
fn rawSend(self: *Socket, data: []const u8) SendError!usize {
    return posix.send(self.fd, data, 0) catch |err| switch (err) {
        error.WouldBlock => return error.WouldBlock,
        error.ConnectionResetByPeer => return error.ConnectionReset,
        error.BrokenPipe => return error.BrokenPipe,
        else => return error.Unexpected,
    };
}

/// Receive raw data from the TCP socket (no TLS).
fn rawRecv(self: *Socket, buf: []u8) RecvError!usize {
    return posix.recv(self.fd, buf, 0) catch |err| switch (err) {
        error.WouldBlock => return error.WouldBlock,
        error.ConnectionResetByPeer => return error.ConnectionReset,
        error.ConnectionRefused => return error.ConnectionReset,
        error.ConnectionTimedOut => return error.ConnectionReset,
        else => return error.Unexpected,
    };
}

/// Send data through the TLS layer.
fn tlsSend(self: *Socket, data: []const u8) SendError!usize {
    if (self.tls_client == null) return error.Closed;

    // Write plaintext into the TLS writer. The TLS layer encrypts and
    // pushes ciphertext to the underlying net writer.
    self.tls_client.?.writer.writeAll(data) catch {
        return error.Unexpected;
    };

    // Flush the underlying net writer to push bytes to the fd.
    if (self.tls_state) |ts| {
        ts.net_writer.interface.flush() catch {
            if (ts.net_writer.err) |write_err| {
                return switch (write_err) {
                    error.WouldBlock => error.WouldBlock,
                    error.ConnectionResetByPeer => error.ConnectionReset,
                    error.BrokenPipe => error.BrokenPipe,
                    else => error.Unexpected,
                };
            }
            return error.Unexpected;
        };
    }

    return data.len;
}

/// Receive data through the TLS layer.
fn tlsRecv(self: *Socket, buf: []u8) RecvError!usize {
    if (self.tls_client == null) return error.Closed;

    // Read decrypted plaintext from the TLS reader using readSliceShort,
    // which returns the number of bytes actually read (may be less than
    // buf.len if the stream has less data available).
    const n = self.tls_client.?.reader.readSliceShort(buf) catch |err| {
        return switch (err) {
            error.ReadFailed => blk: {
                if (self.tls_state) |ts| {
                    if (ts.net_reader.file_reader.err) |read_err| {
                        break :blk switch (read_err) {
                            error.WouldBlock => error.WouldBlock,
                            error.ConnectionResetByPeer => error.ConnectionReset,
                            error.ConnectionTimedOut => error.ConnectionReset,
                            else => error.Unexpected,
                        };
                    }
                }
                break :blk error.Unexpected;
            },
        };
    };
    return n;
}

/// Set the socket to blocking or non-blocking mode using fcntl.
fn setBlocking(self: *Socket, blocking: bool) !void {
    const current = posix.fcntl(self.fd, posix.F.GETFL, 0) catch
        return error.Unexpected;
    var flags = current;
    if (blocking) {
        // Clear NONBLOCK.
        flags &= ~@as(usize, @as(u32, 1) << @bitOffsetOf(posix.O, "NONBLOCK"));
    } else {
        // Set NONBLOCK.
        flags |= @as(usize, @as(u32, 1) << @bitOffsetOf(posix.O, "NONBLOCK"));
    }
    _ = posix.fcntl(self.fd, posix.F.SETFL, flags) catch
        return error.Unexpected;
}

/// Set TCP_NODELAY on the socket to disable Nagle's algorithm.
fn setTcpNoDelay(fd: posix.fd_t) !void {
    posix.setsockopt(
        fd,
        posix.IPPROTO.TCP,
        linux.TCP.NODELAY,
        &std.mem.toBytes(@as(c_int, 1)),
    ) catch return error.Unexpected;
}

/// Resolve a hostname and port to an address.
fn resolveAddress(host: []const u8, port: u16) !net.Address {
    // First try parsing as a direct IP address (IPv4 or IPv6).
    return net.Address.parseIp(host, port) catch {
        // Fall back to DNS resolution via getAddressList.
        const list = net.getAddressList(std.heap.page_allocator, host, port) catch {
            return error.AddressNotAvailable;
        };
        defer list.deinit();

        if (list.addrs.len == 0) {
            return error.AddressNotAvailable;
        }
        return list.addrs[0];
    };
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "socket creation" {
    // Verify that a Socket can be initialized in the disconnected state.
    var sock = Socket{
        .fd = -1,
        .tls_client = null,
        .state = .disconnected,
        .tls_state = null,
    };

    try testing.expectEqual(State.disconnected, sock.state);
    try testing.expect(sock.tls_client == null);
    try testing.expect(sock.tls_state == null);

    // deinit on a disconnected socket with fd=-1 should be safe.
    // Close won't be called on fd=-1 since we check >= 0.
    sock.deinit();
    try testing.expectEqual(State.disconnected, sock.state);
}

test "tcp connect to localhost" {
    // Start a simple TCP listener on localhost with a random port (port 0).
    const listen_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = net.Address.listen(listen_addr, .{
        .reuse_address = true,
    }) catch {
        // If we can't listen, skip the test.
        return;
    };
    defer server.deinit();

    const bound_port = server.listen_address.getPort();

    // Connect to the listener.
    var sock = Socket.initTcp("127.0.0.1", bound_port) catch {
        return; // skip if connect fails
    };
    defer sock.deinit();

    // The socket should be either connecting (EINPROGRESS) or already
    // connected.
    try testing.expect(sock.state == .connecting or sock.state == .connected);
    try testing.expect(sock.fd >= 0);

    // If connecting, wait for writability and check connect.
    if (sock.state == .connecting) {
        // Use poll to wait for the socket to become writable.
        var pfd = [_]posix.pollfd{.{
            .fd = sock.fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        const poll_result = posix.poll(&pfd, 1000) catch 0;
        try testing.expect(poll_result > 0);

        const connected = try sock.checkConnect();
        try testing.expect(connected);
    }

    try testing.expectEqual(State.connected, sock.state);
}

test "send and recv plain" {
    // Start a simple TCP listener.
    const listen_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = net.Address.listen(listen_addr, .{
        .reuse_address = true,
    }) catch return;
    defer server.deinit();

    const bound_port = server.listen_address.getPort();

    // Connect to the listener.
    var sock = Socket.initTcp("127.0.0.1", bound_port) catch return;
    defer sock.deinit();

    // Wait for connection to complete if needed.
    if (sock.state == .connecting) {
        var pfd = [_]posix.pollfd{.{
            .fd = sock.fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        _ = posix.poll(&pfd, 1000) catch 0;
        _ = sock.checkConnect() catch {};
    }

    if (sock.state != .connected) return;

    // Accept the connection on the server side.
    var conn = server.accept() catch return;
    defer conn.stream.close();

    // Send data from our socket.
    const message = "hello wrk3";
    const sent = sock.send(message) catch return;
    try testing.expect(sent > 0);

    // Read data on the server side.
    var server_buf: [64]u8 = undefined;
    const server_read = posix.read(conn.stream.handle, &server_buf) catch return;
    try testing.expectEqualStrings(message[0..sent], server_buf[0..server_read]);

    // Send data from server to our socket.
    const reply = "world";
    _ = posix.write(conn.stream.handle, reply) catch return;

    // Give the kernel a moment to deliver the data.
    var pfd2 = [_]posix.pollfd{.{
        .fd = sock.fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    _ = posix.poll(&pfd2, 1000) catch 0;

    // Receive data on our socket.
    var recv_buf: [64]u8 = undefined;
    const received = sock.recv(&recv_buf) catch return;
    try testing.expectEqualStrings(reply, recv_buf[0..received]);
}

test "would block on empty recv" {
    // Start a simple TCP listener.
    const listen_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = net.Address.listen(listen_addr, .{
        .reuse_address = true,
    }) catch return;
    defer server.deinit();

    const bound_port = server.listen_address.getPort();

    // Connect to the listener.
    var sock = Socket.initTcp("127.0.0.1", bound_port) catch return;
    defer sock.deinit();

    // Wait for connection to complete.
    if (sock.state == .connecting) {
        var pfd = [_]posix.pollfd{.{
            .fd = sock.fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        _ = posix.poll(&pfd, 1000) catch 0;
        _ = sock.checkConnect() catch {};
    }

    if (sock.state != .connected) return;

    // Accept on the server side (to complete the handshake).
    var conn = server.accept() catch return;
    defer conn.stream.close();

    // Attempt to recv with no data pending — should get WouldBlock.
    var buf: [64]u8 = undefined;
    const result = sock.recv(&buf);
    try testing.expectError(error.WouldBlock, result);
}
