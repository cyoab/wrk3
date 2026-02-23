const std = @import("std");
const testing = std.testing;

pub const Method = enum(u8) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
    HEAD = 5,
    OPTIONS = 6,
};

/// Writable buffer owned by the host. Scripts write into it.
pub const Buffer = extern struct {
    ptr: [*]u8,
    len: usize,
    cap: usize,

    pub fn slice(self: Buffer) []u8 {
        return self.ptr[0..self.len];
    }

    pub fn set(self: *Buffer, data: []const u8) void {
        const copy_len = @min(data.len, self.cap);
        @memcpy(self.ptr[0..copy_len], data[0..copy_len]);
        self.len = copy_len;
    }
};

/// Read-only buffer for response data.
pub const ConstBuffer = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn slice(self: ConstBuffer) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// Passed to request() — script fills in method, path, headers, body.
/// All buffers are pre-allocated by the host.
pub const Request = extern struct {
    method: Method,
    path: Buffer,
    headers: Buffer,
    body: Buffer,
};

/// Passed to response() — read-only view of the HTTP response.
pub const Response = extern struct {
    status: u16,
    headers: ConstBuffer,
    body: ConstBuffer,
};

/// Passed to setup() — thread context information.
pub const ThreadContext = extern struct {
    thread_id: u32,
    thread_count: u32,
    connections_per_thread: u32,
};

/// Passed to done() — final benchmark summary.
pub const Summary = extern struct {
    total_requests: u64,
    total_errors: u64,
    total_bytes_read: u64,
    total_bytes_written: u64,
    duration_ns: u64,
    avg_latency_ns: u64,
    max_latency_ns: u64,
    p50_ns: u64,
    p90_ns: u64,
    p99_ns: u64,
    p99_9_ns: u64,
    p99_99_ns: u64,
};

/// Method name lookup for HTTP request formatting.
pub fn methodName(method: Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Buffer set and slice" {
    var backing: [64]u8 = undefined;
    var buf = Buffer{
        .ptr = &backing,
        .len = 0,
        .cap = backing.len,
    };

    buf.set("hello");
    try testing.expectEqual(@as(usize, 5), buf.len);
    try testing.expectEqualStrings("hello", buf.slice());
}

test "Buffer set truncates when data exceeds capacity" {
    var backing: [4]u8 = undefined;
    var buf = Buffer{
        .ptr = &backing,
        .len = 0,
        .cap = backing.len,
    };

    buf.set("hello world");
    try testing.expectEqual(@as(usize, 4), buf.len);
    try testing.expectEqualStrings("hell", buf.slice());
}

test "Buffer set overwrites previous data" {
    var backing: [64]u8 = undefined;
    var buf = Buffer{
        .ptr = &backing,
        .len = 0,
        .cap = backing.len,
    };

    buf.set("first");
    try testing.expectEqualStrings("first", buf.slice());

    buf.set("second");
    try testing.expectEqualStrings("second", buf.slice());
}

test "ConstBuffer slice" {
    const data = "response body";
    const buf = ConstBuffer{
        .ptr = data.ptr,
        .len = data.len,
    };
    try testing.expectEqualStrings("response body", buf.slice());
}

test "methodName returns correct strings" {
    try testing.expectEqualStrings("GET", methodName(.GET));
    try testing.expectEqualStrings("POST", methodName(.POST));
    try testing.expectEqualStrings("PUT", methodName(.PUT));
    try testing.expectEqualStrings("DELETE", methodName(.DELETE));
    try testing.expectEqualStrings("PATCH", methodName(.PATCH));
    try testing.expectEqualStrings("HEAD", methodName(.HEAD));
    try testing.expectEqualStrings("OPTIONS", methodName(.OPTIONS));
}
