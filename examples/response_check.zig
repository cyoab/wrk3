const std = @import("std");
const wrk3 = @import("wrk3_script");

var error_count: u64 = 0;
var status_counts: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };

export fn response(resp: *const wrk3.Response) callconv(.c) void {
    if (resp.status >= 400) {
        error_count += 1;
    }
    const bucket: usize = resp.status / 100;
    if (bucket >= 1 and bucket <= 5) {
        status_counts[bucket] += 1;
    }
}

export fn done(summary: *const wrk3.Summary) callconv(.c) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const stderr = &w.interface;
    stderr.print("\n--- Script Summary ---\n", .{}) catch return;
    stderr.print("  1xx: {d}\n", .{status_counts[1]}) catch return;
    stderr.print("  2xx: {d}\n", .{status_counts[2]}) catch return;
    stderr.print("  3xx: {d}\n", .{status_counts[3]}) catch return;
    stderr.print("  4xx: {d}\n", .{status_counts[4]}) catch return;
    stderr.print("  5xx: {d}\n", .{status_counts[5]}) catch return;
    stderr.print("  Total errors (script): {d}\n", .{error_count}) catch return;
    stderr.print("  Total requests: {d}\n", .{summary.total_requests}) catch return;
    stderr.print("  P99 latency: {d}us\n", .{summary.p99_ns / 1000}) catch return;
    stderr.flush() catch {};
}
