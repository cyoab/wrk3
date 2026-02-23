const std = @import("std");
const wrk3 = @import("wrk3_script");

var counter: u64 = 0;

export fn request(req: *wrk3.Request) callconv(.c) void {
    counter += 1;
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/api/items/{d}", .{counter % 1000}) catch return;
    req.path.set(path);
}
