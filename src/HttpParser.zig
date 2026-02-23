const std = @import("std");

pub const HttpParser = struct {
    state: State = .status_line,
    content_length: ?u64 = null,
    chunked: bool = false,
    body_remaining: u64 = 0,
    consumed: usize = 0,
    keep_alive: bool = true,
    status_code: u16 = 0,
    /// Flag used to distinguish terminal chunk trailer from normal chunk trailer.
    /// Set to true when a 0-size chunk is encountered in chunked encoding.
    terminal_chunk: bool = false,

    pub const Event = union(enum) {
        status: u16,
        header: Header,
        body_chunk: []const u8,
        message_complete: void,
        need_more_data: void,
    };

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const State = enum {
        status_line,
        header_line,
        body_identity,
        body_chunked_size,
        body_chunked_data,
        body_chunked_trailer,
        done,
    };

    pub fn init() HttpParser {
        return .{};
    }

    /// Reset the parser for the next response, preserving keep_alive for the
    /// caller to read after message_complete.
    fn completeMessage(self: *HttpParser) Event {
        const ka = self.keep_alive;
        self.* = .{};
        self.keep_alive = ka;
        return .message_complete;
    }

    pub fn feed(self: *HttpParser, data: []const u8) Event {
        self.consumed = 0;

        switch (self.state) {
            .status_line => return self.parseStatusLine(data),
            .header_line => return self.parseHeaderLine(data),
            .body_identity => return self.parseBodyIdentity(data),
            .body_chunked_size => return self.parseChunkedSize(data),
            .body_chunked_data => return self.parseChunkedData(data),
            .body_chunked_trailer => return self.parseChunkedTrailer(data),
            .done => {
                // The done state is entered after the last body_chunk.
                // Emit message_complete and reset for the next response.
                return self.completeMessage();
            },
        }
    }

    fn parseStatusLine(self: *HttpParser, data: []const u8) Event {
        const line_end = findCRLF(data) orelse {
            return .need_more_data;
        };

        const line = data[0..line_end];

        // Parse "HTTP/1.x NNN reason"
        // Minimum valid: "HTTP/1.0 200" = 12 chars
        if (line.len < 12) {
            self.consumed = line_end + 2;
            self.status_code = 0;
            self.state = .header_line;
            return .{ .status = 0 };
        }

        if (!std.mem.startsWith(u8, line, "HTTP/1.")) {
            self.consumed = line_end + 2;
            self.status_code = 0;
            self.state = .header_line;
            return .{ .status = 0 };
        }

        // Determine HTTP version for keep-alive default
        if (line[7] == '0') {
            self.keep_alive = false; // HTTP/1.0 defaults to close
        } else {
            self.keep_alive = true; // HTTP/1.1 defaults to keep-alive
        }

        if (line[8] != ' ') {
            self.consumed = line_end + 2;
            self.status_code = 0;
            self.state = .header_line;
            return .{ .status = 0 };
        }

        // Parse 3-digit status code at positions 9..12
        if (!std.ascii.isDigit(line[9]) or
            !std.ascii.isDigit(line[10]) or
            !std.ascii.isDigit(line[11]))
        {
            self.consumed = line_end + 2;
            self.status_code = 0;
            self.state = .header_line;
            return .{ .status = 0 };
        }

        const code: u16 = (@as(u16, line[9] - '0') * 100) +
            (@as(u16, line[10] - '0') * 10) +
            (@as(u16, line[11] - '0'));

        self.status_code = code;
        self.consumed = line_end + 2;
        self.state = .header_line;
        return .{ .status = code };
    }

    fn parseHeaderLine(self: *HttpParser, data: []const u8) Event {
        const line_end = findCRLF(data) orelse {
            return .need_more_data;
        };

        const line = data[0..line_end];

        // Empty line signals end of headers
        if (line.len == 0) {
            self.consumed = line_end + 2;
            return self.transitionAfterHeaders();
        }

        // Parse "Name: Value"
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse {
            // Malformed header, skip it
            self.consumed = line_end + 2;
            return .need_more_data;
        };

        const name = line[0..colon_pos];
        var value_start = colon_pos + 1;
        while (value_start < line.len and line[value_start] == ' ') {
            value_start += 1;
        }
        const value = line[value_start..line.len];

        if (caseInsensitiveEqual(name, "content-length")) {
            self.content_length = std.fmt.parseUnsigned(u64, value, 10) catch null;
        }

        if (caseInsensitiveEqual(name, "transfer-encoding")) {
            if (caseInsensitiveContains(value, "chunked")) {
                self.chunked = true;
            }
        }

        if (caseInsensitiveEqual(name, "connection")) {
            if (caseInsensitiveContains(value, "close")) {
                self.keep_alive = false;
            } else if (caseInsensitiveContains(value, "keep-alive")) {
                self.keep_alive = true;
            }
        }

        self.consumed = line_end + 2;
        return .{ .header = .{ .name = name, .value = value } };
    }

    fn transitionAfterHeaders(self: *HttpParser) Event {
        // 204 No Content, 304 Not Modified -- no body
        if (self.status_code == 204 or self.status_code == 304) {
            return self.completeMessage();
        }

        // Chunked transfer encoding takes precedence
        if (self.chunked) {
            self.state = .body_chunked_size;
            return .need_more_data;
        }

        // Content-Length body
        if (self.content_length) |cl| {
            if (cl == 0) {
                return self.completeMessage();
            }
            self.body_remaining = cl;
            self.state = .body_identity;
            return .need_more_data;
        }

        // No Content-Length and no Transfer-Encoding: treat as no body
        return self.completeMessage();
    }

    fn parseBodyIdentity(self: *HttpParser, data: []const u8) Event {
        if (data.len == 0) {
            return .need_more_data;
        }

        const to_consume = @min(data.len, self.body_remaining);
        self.body_remaining -= to_consume;
        self.consumed = to_consume;

        if (self.body_remaining == 0) {
            // All body bytes consumed. Transition to done state so the next
            // call to feed emits message_complete.
            self.state = .done;
        }

        return .{ .body_chunk = data[0..to_consume] };
    }

    fn parseChunkedSize(self: *HttpParser, data: []const u8) Event {
        const line_end = findCRLF(data) orelse {
            return .need_more_data;
        };

        const line = data[0..line_end];

        // Parse hex chunk size (may have extensions after ';')
        var hex_end: usize = 0;
        while (hex_end < line.len and isHexDigit(line[hex_end])) {
            hex_end += 1;
        }

        if (hex_end == 0) {
            self.consumed = line_end + 2;
            return .need_more_data;
        }

        const chunk_size = std.fmt.parseUnsigned(u64, line[0..hex_end], 16) catch {
            self.consumed = line_end + 2;
            return .need_more_data;
        };

        self.consumed = line_end + 2;

        if (chunk_size == 0) {
            // Terminal chunk -- need to consume trailing \r\n
            self.terminal_chunk = true;
            self.state = .body_chunked_trailer;
            return .need_more_data;
        }

        self.body_remaining = chunk_size;
        self.state = .body_chunked_data;
        return .need_more_data;
    }

    fn parseChunkedData(self: *HttpParser, data: []const u8) Event {
        if (data.len == 0) {
            return .need_more_data;
        }

        const to_consume = @min(data.len, self.body_remaining);
        self.body_remaining -= to_consume;
        self.consumed = to_consume;

        if (self.body_remaining == 0) {
            // After chunk data, expect \r\n
            self.state = .body_chunked_trailer;
        }

        return .{ .body_chunk = data[0..to_consume] };
    }

    fn parseChunkedTrailer(self: *HttpParser, data: []const u8) Event {
        if (data.len < 2) {
            return .need_more_data;
        }

        if (data[0] == '\r' and data[1] == '\n') {
            self.consumed = 2;

            if (self.terminal_chunk) {
                self.terminal_chunk = false;
                return self.completeMessage();
            }

            self.state = .body_chunked_size;
            return .need_more_data;
        }

        // Unexpected bytes -- skip one byte and try again
        self.consumed = 1;
        return .need_more_data;
    }

    // --- Utility functions ---

    fn findCRLF(data: []const u8) ?usize {
        if (data.len < 2) return null;
        for (0..data.len - 1) |i| {
            if (data[i] == '\r' and data[i + 1] == '\n') {
                return i;
            }
        }
        return null;
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F');
    }

    fn caseInsensitiveEqual(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
        }
        return true;
    }

    fn caseInsensitiveContains(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        if (needle.len == 0) return true;
        const limit = haystack.len - needle.len + 1;
        for (0..limit) |i| {
            if (caseInsensitiveEqual(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Helper: feed all of `input` into the parser, collecting events.
fn collectAllEvents(parser: *HttpParser, input: []const u8) !struct {
    statuses: [8]u16 = .{0} ** 8,
    status_count: usize = 0,
    headers: [32]HttpParser.Header = undefined,
    header_count: usize = 0,
    body: [4096]u8 = undefined,
    body_len: usize = 0,
    complete_count: usize = 0,
    final_keep_alive: bool = true,
} {
    var result: @TypeOf(try collectAllEvents(parser, input)) = .{};
    var remaining = input;

    var iterations: usize = 0;
    const max_iterations = input.len * 4 + 200;

    while (iterations < max_iterations) : (iterations += 1) {
        const event = parser.feed(remaining);
        remaining = remaining[parser.consumed..];

        switch (event) {
            .status => |code| {
                if (result.status_count < result.statuses.len) {
                    result.statuses[result.status_count] = code;
                    result.status_count += 1;
                }
            },
            .header => |h| {
                if (result.header_count < result.headers.len) {
                    result.headers[result.header_count] = h;
                    result.header_count += 1;
                }
            },
            .body_chunk => |chunk| {
                const end = result.body_len + chunk.len;
                if (end <= result.body.len) {
                    @memcpy(result.body[result.body_len..end], chunk);
                    result.body_len = end;
                }
            },
            .message_complete => {
                result.final_keep_alive = parser.keep_alive;
                result.complete_count += 1;
                if (remaining.len == 0) break;
            },
            .need_more_data => {
                if (remaining.len == 0) {
                    // Check if the parser is in the done state, which means
                    // we need one more feed to get message_complete.
                    if (parser.state == .done) continue;
                    break;
                }
            },
        }
    }

    return result;
}

test "complete response in one feed" {
    var parser = HttpParser.init();

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 13\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Hello, World!";

    const result = try collectAllEvents(&parser, response);

    try testing.expectEqual(@as(usize, 1), result.status_count);
    try testing.expectEqual(@as(u16, 200), result.statuses[0]);
    try testing.expectEqual(@as(usize, 2), result.header_count);
    try testing.expectEqualStrings("Content-Length", result.headers[0].name);
    try testing.expectEqualStrings("13", result.headers[0].value);
    try testing.expectEqualStrings("Content-Type", result.headers[1].name);
    try testing.expectEqualStrings("text/plain", result.headers[1].value);
    try testing.expectEqualStrings("Hello, World!", result.body[0..result.body_len]);
    try testing.expectEqual(@as(usize, 1), result.complete_count);
}

test "byte-at-a-time parsing" {
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "Hello";

    var parser = HttpParser.init();
    var pos: usize = 0;
    var end: usize = 1;
    var status_seen = false;
    var header_count: usize = 0;
    var body_len: usize = 0;
    var body_buf: [64]u8 = undefined;
    var complete = false;

    var iterations: usize = 0;
    const max_iterations = response.len * 4 + 200;

    while (iterations < max_iterations) : (iterations += 1) {
        if (complete) break;
        if (pos >= response.len) {
            // No more input. Check if parser needs one more feed for done state.
            if (parser.state == .done) {
                const event = parser.feed("");
                switch (event) {
                    .message_complete => {
                        complete = true;
                    },
                    else => {},
                }
            }
            break;
        }

        const slice = response[pos..end];
        const event = parser.feed(slice);
        pos += parser.consumed;

        switch (event) {
            .status => |code| {
                try testing.expectEqual(@as(u16, 200), code);
                status_seen = true;
                end = @min(pos + 1, response.len);
            },
            .header => {
                header_count += 1;
                end = @min(pos + 1, response.len);
            },
            .body_chunk => |bc| {
                @memcpy(body_buf[body_len .. body_len + bc.len], bc);
                body_len += bc.len;
                end = @min(pos + 1, response.len);
            },
            .message_complete => {
                complete = true;
            },
            .need_more_data => {
                // Grow the window by one byte
                end = @min(end + 1, response.len);
            },
        }
    }

    try testing.expect(status_seen);
    try testing.expectEqual(@as(usize, 1), header_count);
    try testing.expectEqualStrings("Hello", body_buf[0..body_len]);
    try testing.expect(complete);
}

test "chunked transfer encoding" {
    var parser = HttpParser.init();

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "Hello\r\n" ++
        "7\r\n" ++
        ", World\r\n" ++
        "0\r\n" ++
        "\r\n";

    const result = try collectAllEvents(&parser, response);

    try testing.expectEqual(@as(u16, 200), result.statuses[0]);
    try testing.expectEqual(@as(usize, 1), result.header_count);
    try testing.expectEqualStrings("Hello, World", result.body[0..result.body_len]);
    try testing.expectEqual(@as(usize, 1), result.complete_count);
}

test "content-length body" {
    var parser = HttpParser.init();

    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 10\r\n" ++
        "\r\n" ++
        "0123456789";

    const result = try collectAllEvents(&parser, response);

    try testing.expectEqual(@as(u16, 200), result.statuses[0]);
    try testing.expectEqualStrings("0123456789", result.body[0..result.body_len]);
    try testing.expectEqual(@as(usize, 1), result.complete_count);

    // Verify body_remaining tracking mid-parse
    var parser2 = HttpParser.init();
    const partial =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 10\r\n" ++
        "\r\n" ++
        "01234";

    var remaining: []const u8 = partial;
    var body_remaining_seen: u64 = 0;

    var iters: usize = 0;
    while (iters < 200) : (iters += 1) {
        const event = parser2.feed(remaining);
        remaining = remaining[parser2.consumed..];
        switch (event) {
            .body_chunk => {
                body_remaining_seen = parser2.body_remaining;
            },
            .need_more_data => {
                if (remaining.len == 0) break;
            },
            else => {},
        }
    }

    // After consuming "01234" (5 bytes) of 10, body_remaining should be 5
    try testing.expectEqual(@as(u64, 5), body_remaining_seen);
}

test "no-body response 204" {
    var parser = HttpParser.init();

    const response =
        "HTTP/1.1 204 No Content\r\n" ++
        "Server: test\r\n" ++
        "\r\n";

    const result = try collectAllEvents(&parser, response);

    try testing.expectEqual(@as(u16, 204), result.statuses[0]);
    try testing.expectEqual(@as(usize, 0), result.body_len);
    try testing.expectEqual(@as(usize, 1), result.complete_count);
}

test "no-body response 304" {
    var parser = HttpParser.init();

    const response =
        "HTTP/1.1 304 Not Modified\r\n" ++
        "ETag: \"abc\"\r\n" ++
        "\r\n";

    const result = try collectAllEvents(&parser, response);

    try testing.expectEqual(@as(u16, 304), result.statuses[0]);
    try testing.expectEqual(@as(usize, 0), result.body_len);
    try testing.expectEqual(@as(usize, 1), result.complete_count);
}

test "keep-alive detection" {
    // HTTP/1.1 default is keep-alive
    {
        var parser = HttpParser.init();
        const response =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n";

        const result = try collectAllEvents(&parser, response);
        try testing.expectEqual(@as(usize, 1), result.complete_count);
        try testing.expect(result.final_keep_alive);
    }

    // Connection: close overrides
    {
        var parser = HttpParser.init();
        const response =
            "HTTP/1.1 200 OK\r\n" ++
            "Connection: close\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n";

        const result = try collectAllEvents(&parser, response);
        try testing.expectEqual(@as(usize, 1), result.complete_count);
        try testing.expect(!result.final_keep_alive);
    }

    // HTTP/1.0 default is close
    {
        var parser = HttpParser.init();
        const response =
            "HTTP/1.0 200 OK\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n";

        const result = try collectAllEvents(&parser, response);
        try testing.expectEqual(@as(usize, 1), result.complete_count);
        try testing.expect(!result.final_keep_alive);
    }
}

test "malformed status line" {
    // Completely garbage status line
    {
        var parser = HttpParser.init();
        const response =
            "GARBAGE\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n";

        const result = try collectAllEvents(&parser, response);
        try testing.expectEqual(@as(u16, 0), result.statuses[0]);
        try testing.expectEqual(@as(usize, 1), result.complete_count);
    }

    // Too short
    {
        var parser = HttpParser.init();
        const response =
            "HTTP\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n";

        const result = try collectAllEvents(&parser, response);
        try testing.expectEqual(@as(u16, 0), result.statuses[0]);
        try testing.expectEqual(@as(usize, 1), result.complete_count);
    }
}

test "multiple responses" {
    var parser = HttpParser.init();

    const responses =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "Hello" ++
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Length: 9\r\n" ++
        "\r\n" ++
        "Not Found";

    const result = try collectAllEvents(&parser, responses);

    try testing.expectEqual(@as(usize, 2), result.status_count);
    try testing.expectEqual(@as(u16, 200), result.statuses[0]);
    try testing.expectEqual(@as(u16, 404), result.statuses[1]);
    try testing.expectEqual(@as(usize, 2), result.complete_count);
    try testing.expectEqualStrings("HelloNot Found", result.body[0..result.body_len]);
}
