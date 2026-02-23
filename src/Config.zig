const std = @import("std");
const Units = @import("Units.zig");
const testing = std.testing;

// ============================================================================
// Config Struct
// ============================================================================

pub const Config = struct {
    threads: u32 = 2,
    connections: u32 = 10,
    duration_ns: u64 = 10_000_000_000, // 10s default
    rate: u64, // required, no default
    timeout_ns: u64 = 2_000_000_000, // 2s default
    print_latency: bool = false,
    headers: []Header,
    url: Url,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Url = struct {
        scheme: Scheme,
        host: []const u8,
        port: u16,
        path: []const u8,

        pub const Scheme = enum { http, https };
    };
};

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    MissingUrl,
    MissingRate,
    InvalidArgument,
    InvalidUrl,
    OutOfMemory,
};

// ============================================================================
// Usage
// ============================================================================

pub fn printUsage() void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;
    stderr.writeAll(
        \\Usage: wrk3 <options> <url>
        \\  -c, --connections <N>   Number of connections (default: 10)
        \\  -d, --duration    <T>   Duration of test (default: 10s)
        \\  -t, --threads     <N>   Number of threads (default: 2)
        \\  -R, --rate        <N>   Target requests/sec (required)
        \\  -H, --header      <H>   Add header (repeatable), format "Name: Value"
        \\  -L, --latency           Print latency percentile distribution
        \\      --timeout     <T>   Socket timeout (default: 2s)
        \\
    ) catch {};
    stderr.flush() catch {};
}

// ============================================================================
// URL Parsing
// ============================================================================

fn parseUrl(raw: []const u8) Error!Config.Url {
    // Parse scheme.
    const scheme: Config.Url.Scheme, const after_scheme: []const u8 = blk: {
        if (std.mem.startsWith(u8, raw, "http://")) {
            break :blk .{ .http, raw["http://".len..] };
        } else if (std.mem.startsWith(u8, raw, "https://")) {
            break :blk .{ .https, raw["https://".len..] };
        } else {
            return error.InvalidUrl;
        }
    };

    if (after_scheme.len == 0) return error.InvalidUrl;

    // Split host+port from path.
    const slash_pos = std.mem.indexOfScalar(u8, after_scheme, '/');
    const host_port = if (slash_pos) |pos| after_scheme[0..pos] else after_scheme;
    const path = if (slash_pos) |pos| after_scheme[pos..] else "/";

    if (host_port.len == 0) return error.InvalidUrl;

    // Split host from port.
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_pos| {
        const host = host_port[0..colon_pos];
        const port_str = host_port[colon_pos + 1 ..];
        if (host.len == 0) return error.InvalidUrl;
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidUrl;
        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = path,
        };
    } else {
        // No port specified — use default.
        const default_port: u16 = switch (scheme) {
            .http => 80,
            .https => 443,
        };
        return .{
            .scheme = scheme,
            .host = host_port,
            .port = default_port,
            .path = path,
        };
    }
}

// ============================================================================
// Argument Parsing
// ============================================================================

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) Error!Config {
    var threads: u32 = 2;
    var connections: u32 = 10;
    var duration_ns: u64 = 10_000_000_000;
    var rate: ?u64 = null;
    var timeout_ns: u64 = 2_000_000_000;
    var print_latency: bool = false;
    var header_list: std.ArrayList(Config.Header) = .empty;
    defer header_list.deinit(allocator);
    var url_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            threads = parseU32(args[i]) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--connections")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            connections = parseU32(args[i]) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--duration")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            duration_ns = Units.parseDuration(args[i]) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--rate")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            rate = Units.parseCount(args[i]) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            timeout_ns = Units.parseDuration(args[i]) orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--header")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgument;
            const header = parseHeader(args[i]) orelse return error.InvalidArgument;
            header_list.append(allocator, header) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--latency")) {
            print_latency = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument — treat as URL.
            url_str = arg;
        } else {
            return error.InvalidArgument;
        }
    }

    if (url_str == null) return error.MissingUrl;
    if (rate == null) return error.MissingRate;

    const url = try parseUrl(url_str.?);
    const headers = header_list.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return .{
        .threads = threads,
        .connections = connections,
        .duration_ns = duration_ns,
        .rate = rate.?,
        .timeout_ns = timeout_ns,
        .print_latency = print_latency,
        .headers = headers,
        .url = url,
    };
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch return null;
}

fn parseHeader(s: []const u8) ?Config.Header {
    // Format: "Name: Value" or "Name:Value"
    const colon_pos = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const name = s[0..colon_pos];
    if (name.len == 0) return null;

    var value = s[colon_pos + 1 ..];
    // Trim leading spaces from value.
    while (value.len > 0 and value[0] == ' ') {
        value = value[1..];
    }

    return .{
        .name = name,
        .value = value,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "minimal args" {
    const args = [_][]const u8{ "-R", "100", "http://localhost" };
    const config = try parse(testing.allocator, &args);
    defer testing.allocator.free(config.headers);

    try testing.expectEqual(@as(u32, 2), config.threads);
    try testing.expectEqual(@as(u32, 10), config.connections);
    try testing.expectEqual(@as(u64, 10_000_000_000), config.duration_ns);
    try testing.expectEqual(@as(u64, 100), config.rate);
    try testing.expectEqual(@as(u64, 2_000_000_000), config.timeout_ns);
    try testing.expectEqual(false, config.print_latency);
    try testing.expectEqual(@as(usize, 0), config.headers.len);
    try testing.expectEqual(Config.Url.Scheme.http, config.url.scheme);
    try testing.expectEqualStrings("localhost", config.url.host);
    try testing.expectEqual(@as(u16, 80), config.url.port);
    try testing.expectEqualStrings("/", config.url.path);
}

test "full args" {
    const args = [_][]const u8{
        "-t",     "4",
        "-c",     "100",
        "-d",     "30s",
        "-R",     "1000",
        "--timeout", "5s",
        "-L",
        "-H",     "Accept: text/html",
        "http://example.com/path",
    };
    const config = try parse(testing.allocator, &args);
    defer testing.allocator.free(config.headers);

    try testing.expectEqual(@as(u32, 4), config.threads);
    try testing.expectEqual(@as(u32, 100), config.connections);
    try testing.expectEqual(@as(u64, 30_000_000_000), config.duration_ns);
    try testing.expectEqual(@as(u64, 1000), config.rate);
    try testing.expectEqual(@as(u64, 5_000_000_000), config.timeout_ns);
    try testing.expectEqual(true, config.print_latency);
    try testing.expectEqual(@as(usize, 1), config.headers.len);
    try testing.expectEqualStrings("Accept", config.headers[0].name);
    try testing.expectEqualStrings("text/html", config.headers[0].value);
    try testing.expectEqual(Config.Url.Scheme.http, config.url.scheme);
    try testing.expectEqualStrings("example.com", config.url.host);
    try testing.expectEqual(@as(u16, 80), config.url.port);
    try testing.expectEqualStrings("/path", config.url.path);
}

test "defaults" {
    // Verify default values by constructing with required fields only.
    const config = Config{
        .rate = 100,
        .headers = &.{},
        .url = .{
            .scheme = .http,
            .host = "localhost",
            .port = 80,
            .path = "/",
        },
    };

    try testing.expectEqual(@as(u32, 2), config.threads);
    try testing.expectEqual(@as(u32, 10), config.connections);
    try testing.expectEqual(@as(u64, 10_000_000_000), config.duration_ns);
    try testing.expectEqual(@as(u64, 2_000_000_000), config.timeout_ns);
    try testing.expectEqual(false, config.print_latency);
}

test "url parsing http" {
    const url = try parseUrl("http://example.com");
    try testing.expectEqual(Config.Url.Scheme.http, url.scheme);
    try testing.expectEqualStrings("example.com", url.host);
    try testing.expectEqual(@as(u16, 80), url.port);
    try testing.expectEqualStrings("/", url.path);
}

test "url parsing https with port" {
    const url = try parseUrl("https://example.com:8443/api");
    try testing.expectEqual(Config.Url.Scheme.https, url.scheme);
    try testing.expectEqualStrings("example.com", url.host);
    try testing.expectEqual(@as(u16, 8443), url.port);
    try testing.expectEqualStrings("/api", url.path);
}

test "url parsing http with port and path" {
    const url = try parseUrl("http://localhost:8080/test");
    try testing.expectEqual(Config.Url.Scheme.http, url.scheme);
    try testing.expectEqualStrings("localhost", url.host);
    try testing.expectEqual(@as(u16, 8080), url.port);
    try testing.expectEqualStrings("/test", url.path);
}

test "multiple headers" {
    const args = [_][]const u8{
        "-R",
        "100",
        "-H",
        "Accept: text/html",
        "-H",
        "Authorization: Bearer tok",
        "http://x",
    };
    const config = try parse(testing.allocator, &args);
    defer testing.allocator.free(config.headers);

    try testing.expectEqual(@as(usize, 2), config.headers.len);
    try testing.expectEqualStrings("Accept", config.headers[0].name);
    try testing.expectEqualStrings("text/html", config.headers[0].value);
    try testing.expectEqualStrings("Authorization", config.headers[1].name);
    try testing.expectEqualStrings("Bearer tok", config.headers[1].value);
}

test "missing rate error" {
    const args = [_][]const u8{"http://localhost"};
    const result = parse(testing.allocator, &args);
    try testing.expectError(error.MissingRate, result);
}

test "missing url error" {
    const args = [_][]const u8{ "-R", "100" };
    const result = parse(testing.allocator, &args);
    try testing.expectError(error.MissingUrl, result);
}

test "long form args" {
    const args = [_][]const u8{
        "--connections", "50",
        "--duration",    "30s",
        "--rate",        "500",
        "--threads",     "4",
        "http://x",
    };
    const config = try parse(testing.allocator, &args);
    defer testing.allocator.free(config.headers);

    try testing.expectEqual(@as(u32, 4), config.threads);
    try testing.expectEqual(@as(u32, 50), config.connections);
    try testing.expectEqual(@as(u64, 30_000_000_000), config.duration_ns);
    try testing.expectEqual(@as(u64, 500), config.rate);
}
