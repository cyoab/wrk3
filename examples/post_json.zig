const std = @import("std");
const wrk3 = @import("wrk3_script");

var counter: u64 = 0;

export fn request(req: *wrk3.Request) callconv(.c) void {
    counter += 1;
    req.method = .POST;
    req.path.set("/api/users");
    req.headers.set("Content-Type: application/json\r\n");
    var buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"name\":\"user{d}\"}}", .{ counter, counter }) catch return;
    req.body.set(body);
}
